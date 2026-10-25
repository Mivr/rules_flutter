/// Mach-O embedded code signature rebuild behind `patch` and
/// `patch --strip-symbols`.
///
/// After the strip rewrite compacts `__LINKEDIT` and the retag rewrite edits
/// load commands, the `LC_CODE_SIGNATURE` blob no longer describes the file:
/// its `codeLimit` still names the old signature offset and its page hashes
/// still cover the old pages. [resignEmbeddedSignature] rebuilds the
/// `CS_SuperBlob` over the new layout: every `CS_CodeDirectory` gets the new
/// `codeLimit`, a recomputed slot count and fresh SHA-256 page hashes, while
/// the identifier, flags, special slots and every other blob are kept
/// byte-identical. Anything the rebuild cannot recompute (a non-SHA-256 hash
/// type, a real CMS signature blob) throws a [FormatException] rather than
/// shipping a stale signature. Pure Dart; never shells out.

import 'dart:convert';
import 'dart:typed_data';

import 'macho_constants.dart';
import 'macho_parse.dart' show LoadCommand, fileRangesOf, parseLoadCommands;
import 'macho_ranges.dart' show notePayloadRange, rangeWithinFile;
import 'macho_stub.dart' show sha256;

/// `CS_CodeDirectory` versions carrying a `codeLimit64` word at offset 56.
const _cdVersionCodeLimit64 = 0x20300;

/// Offset of the `codeLimit64` word inside a new-style `CS_CodeDirectory`.
const _codeLimit64Field = 56;

/// Rebuilds the `LC_CODE_SIGNATURE` embedded in [bytes] over its current
/// layout and returns the resigned file bytes.
///
/// The signature's file offset becomes the new `codeLimit`, its slot count
/// becomes `ceil(codeLimit / pageSize)`, and every code slot becomes the
/// SHA-256 of its page in the output, so the hashes never cover the
/// signature itself. When the rebuilt blob is smaller the trailing payloads
/// shift down and `LC_CODE_SIGNATURE`'s `datasize` plus the `__LINKEDIT`
/// `filesize`/`vmsize` follow the new size.
///
/// Files without an `LC_CODE_SIGNATURE` come back unchanged. Corrupt or
/// unrebuildable signatures throw [FormatException].
Uint8List resignEmbeddedSignature(Uint8List bytes) {
  final plan = _ResignPlan.parse(bytes);
  if (plan == null) return bytes;
  return plan.apply();
}

/// One `CS_SuperBlob` index entry: the blob's [type], its [offset] relative
/// to the SuperBlob start, and its [length] in bytes.
class _BlobEntry {
  _BlobEntry({required this.type, required this.offset, required this.length});

  final int type;
  final int offset;
  final int length;
}

/// A signature rewrite ready to run: the parsed file with its signature and
/// segment commands located. Methods below work from these fields so no
/// offset travels as a long parameter list.
class _ResignPlan {
  _ResignPlan({
    required this.bytes,
    required this.commands,
    required this.codeSigIndex,
    required this.linkeditIndex,
    required this.dataoff,
    required this.datasize,
  });

  /// The file bytes under rewrite.
  final Uint8List bytes;

  /// The file's parsed load commands.
  final List<LoadCommand> commands;

  /// The `LC_CODE_SIGNATURE` position in [commands].
  final int codeSigIndex;

  /// The `__LINKEDIT` segment position in [commands], or -1 when absent.
  final int linkeditIndex;

  /// The signature blob's file offset.
  final int dataoff;

  /// The signature blob's size in bytes.
  final int datasize;

  /// Locates the signature in [bytes]; null when the file is unsigned.
  ///
  /// Throws [FormatException] on a duplicated, truncated or non-signature
  /// `LC_CODE_SIGNATURE`, or on a real CMS blob the rebuild cannot re-create.
  static _ResignPlan? parse(Uint8List bytes) {
    final commands = parseLoadCommands(bytes);
    var codeSigIndex = -1;
    for (var i = 0; i < commands.length; i++) {
      if (commands[i].cmd != lcCodeSignature) continue;
      if (codeSigIndex >= 0) {
        throw const FormatException(
          'Cannot rebuild the embedded code signature: duplicate '
          'LC_CODE_SIGNATURE commands.',
        );
      }
      codeSigIndex = i;
    }
    if (codeSigIndex < 0) return null;
    final codeSig = commands[codeSigIndex];
    if (codeSig.bytes.length < 16) {
      throw const FormatException('Truncated LC_CODE_SIGNATURE command.');
    }
    final lcBd = ByteData.sublistView(codeSig.bytes);
    final dataoff = lcBd.getUint32(8, Endian.little);
    final datasize = lcBd.getUint32(12, Endian.little);
    _checkSignatureRange(bytes.length, dataoff, datasize);
    _checkSuperBlob(bytes, dataoff, datasize);
    return _ResignPlan(
      bytes: bytes,
      commands: commands,
      codeSigIndex: codeSigIndex,
      linkeditIndex: _findLinkeditIndex(commands),
      dataoff: dataoff,
      datasize: datasize,
    );
  }

  /// Rebuilds every `CS_CodeDirectory`, reassembles the `CS_SuperBlob`,
  /// splices it over the old blob and patches the affected load commands.
  ///
  /// The page hashes go in last, after the load commands are patched: hashing
  /// before that would cover stale header bytes whenever the rebuilt
  /// signature changes size.
  Uint8List apply() {
    final sigBytes = Uint8List.fromList(
      bytes.sublist(dataoff, dataoff + datasize),
    );
    final rebuilt = <_RebuiltBlob>[];
    for (final entry in _parseBlobIndex(sigBytes)) {
      final blob = Uint8List.fromList(
        sigBytes.sublist(entry.offset, entry.offset + entry.length),
      );
      if (_isCodeDirectory(blob)) {
        final fresh = _rebuildCodeDirectory(blob, dataoff);
        rebuilt.add(
          _RebuiltBlob(
            type: entry.type,
            bytes: fresh.bytes,
            pageSize: fresh.pageSize,
          ),
        );
      } else {
        rebuilt.add(
          _RebuiltBlob(type: entry.type, bytes: blob, pageSize: null),
        );
      }
    }
    final out = _spliceSignature(
      _assembleSuperBlob(
        [for (final blob in rebuilt) blob.bytes],
        [for (final blob in rebuilt) blob.type],
      ),
    );
    _fillCodeHashes(out, rebuilt);
    return out;
  }

  /// Splices [fresh] over the old blob, shifts trailing payloads when the
  /// size changed, and patches the load commands in the returned bytes.
  Uint8List _spliceSignature(Uint8List fresh) {
    final tail = bytes.length - dataoff - datasize;
    final out = Uint8List(dataoff + fresh.length + tail);
    out.setRange(0, dataoff, bytes);
    out.setRange(dataoff, dataoff + fresh.length, fresh);
    out.setRange(dataoff + fresh.length, out.length, bytes, dataoff + datasize);
    _patchCommands(out, dataoff + datasize, datasize - fresh.length);
    return out;
  }

  /// Patches the load commands in [out] after the splice: the signature's
  /// `datasize`, the `__LINKEDIT` sizes, and every table range at or past
  /// [oldSigEnd] shifted down by [shrink] bytes.
  void _patchCommands(Uint8List out, int oldSigEnd, int shrink) {
    final freshSize = datasize - shrink;
    var commandOff = mhHeaderSize64;
    for (var i = 0; i < commands.length; i++) {
      final lc = commands[i];
      final patched = i == codeSigIndex
          ? _withDatasize(lc, freshSize)
          : i == linkeditIndex
          ? _resizedLinkedit(lc, out.length)
          : _shiftedRanges(lc, oldSigEnd, shrink, bytes.length);
      out.setRange(commandOff, commandOff + lc.cmdsize, patched);
      commandOff += lc.cmdsize;
    }
  }
}

/// Returns [lc] with its `datasize` word set to [freshSize].
Uint8List _withDatasize(LoadCommand lc, int freshSize) {
  final patched = Uint8List.fromList(lc.bytes);
  ByteData.sublistView(patched).setUint32(12, freshSize, Endian.little);
  return patched;
}

/// Throws when the signature range is empty, truncated or past the file.
void _checkSignatureRange(int fileLength, int dataoff, int datasize) {
  if (dataoff == 0 || datasize < 12 || dataoff + datasize > fileLength) {
    throw FormatException(
      'LC_CODE_SIGNATURE points past the end of the file '
      '(offset $dataoff, size $datasize, file $fileLength).',
    );
  }
}

/// Throws when the blob at [dataoff] is not a `CS_SuperBlob`, is truncated,
/// or carries a real CMS signature blob the rebuild cannot re-create: either
/// non-zero trailer bytes past the SuperBlob or a signature-slot
/// (`0x10000`) wrapper holding a payload. An empty signature wrapper (what
/// ad-hoc `codesign` writes) is kept as is.
void _checkSuperBlob(Uint8List bytes, int dataoff, int datasize) {
  final view = Uint8List.sublistView(bytes, dataoff, dataoff + datasize);
  final bd = ByteData.sublistView(view);
  if (bd.getUint32(0, Endian.big) != csMagicEmbeddedSignature) {
    throw const FormatException(
      'LC_CODE_SIGNATURE does not point at an embedded signature blob.',
    );
  }
  final superLength = bd.getUint32(4, Endian.big);
  if (superLength > datasize) {
    throw const FormatException('Truncated embedded signature blob.');
  }
  for (var i = superLength; i < datasize; i++) {
    if (view[i] != 0) {
      throw const FormatException(
        'Cannot rebuild the embedded code signature: it carries a CMS '
        'signature blob.',
      );
    }
  }
  for (final entry in _parseBlobIndex(view)) {
    if (entry.type == csSlotSignature && entry.length > 8) {
      throw const FormatException(
        'Cannot rebuild the embedded code signature: it carries a CMS '
        'signature blob.',
      );
    }
  }
}

/// Returns the `__LINKEDIT` segment position in [commands], or -1.
int _findLinkeditIndex(List<LoadCommand> commands) {
  for (var i = 0; i < commands.length; i++) {
    final lc = commands[i];
    if (lc.cmd != lcSegment64 || lc.bytes.length < 72) continue;
    final name = ascii.decode(lc.bytes.sublist(8, 24)).split('\x00').first;
    if (name == '__LINKEDIT') return i;
  }
  return -1;
}

/// Reads the `CS_SuperBlob` index of [sigBytes], bounds-checked.
List<_BlobEntry> _parseBlobIndex(Uint8List sigBytes) {
  final bd = ByteData.sublistView(sigBytes);
  if (sigBytes.length < 12) {
    throw const FormatException('Truncated embedded signature blob.');
  }
  final count = bd.getUint32(8, Endian.big);
  if (12 + count * 8 > sigBytes.length) {
    throw const FormatException('Truncated embedded signature index.');
  }
  final entries = <_BlobEntry>[];
  for (var i = 0; i < count; i++) {
    final type = bd.getUint32(12 + i * 8, Endian.big);
    final offset = bd.getUint32(12 + i * 8 + 4, Endian.big);
    if (offset + 8 > sigBytes.length) {
      throw const FormatException('Truncated embedded signature blob.');
    }
    final length = ByteData.sublistView(
      sigBytes,
      offset,
      offset + 8,
    ).getUint32(4, Endian.big);
    if (length < 8 || offset + length > sigBytes.length) {
      throw const FormatException('Truncated embedded signature blob.');
    }
    entries.add(_BlobEntry(type: type, offset: offset, length: length));
  }
  return entries;
}

/// Whether [blob] is a `CS_CodeDirectory`.
bool _isCodeDirectory(Uint8List blob) {
  if (blob.length < 4) return false;
  return ByteData.sublistView(blob).getUint32(0, Endian.big) ==
      csMagicCodeDirectory;
}

/// Reassembles a `CS_SuperBlob` from [blobs] with index [types], laid out
/// contiguously in index order with fresh blob offsets.
Uint8List _assembleSuperBlob(List<Uint8List> blobs, List<int> types) {
  var size = 12 + blobs.length * 8;
  for (final blob in blobs) {
    size += blob.length;
  }
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, csMagicEmbeddedSignature, Endian.big);
  bd.setUint32(4, size, Endian.big);
  bd.setUint32(8, blobs.length, Endian.big);
  var cursor = 12 + blobs.length * 8;
  for (var i = 0; i < blobs.length; i++) {
    bd.setUint32(12 + i * 8, types[i], Endian.big);
    bd.setUint32(12 + i * 8 + 4, cursor, Endian.big);
    out.setRange(cursor, cursor + blobs[i].length, blobs[i]);
    cursor += blobs[i].length;
  }
  return out;
}

/// One reassembled SuperBlob entry: its index [type], its [bytes], and, for
/// `CS_CodeDirectory` entries, the hash [pageSize] [_fillCodeHashes] needs.
class _RebuiltBlob {
  _RebuiltBlob({
    required this.type,
    required this.bytes,
    required this.pageSize,
  });

  final int type;
  final Uint8List bytes;
  final int? pageSize;
}

/// Fills the code-slot hashes of every rebuilt `CS_CodeDirectory` in [out]
/// from the final file bytes: the pages (and the header covering them) are
/// only stable once the splice and the load-command patch are done.
///
/// The hash writes land at or past `codeLimit` while every hashed page lies
/// below it, so hashing [out] in place is sound.
void _fillCodeHashes(Uint8List out, List<_RebuiltBlob> rebuilt) {
  final commands = parseLoadCommands(out);
  final codeSig = commands.singleWhere((c) => c.cmd == lcCodeSignature);
  final sigBd = ByteData.sublistView(codeSig.bytes);
  final dataoff = sigBd.getUint32(8, Endian.little);
  final datasize = sigBd.getUint32(12, Endian.little);
  final sigBytes = Uint8List.sublistView(out, dataoff, dataoff + datasize);
  final entries = _parseBlobIndex(sigBytes);
  if (entries.length != rebuilt.length) {
    throw const FormatException('Truncated embedded signature blob.');
  }
  for (var i = 0; i < entries.length; i++) {
    final pageSize = rebuilt[i].pageSize;
    if (pageSize == null) continue;
    final cdOff = dataoff + entries[i].offset;
    final cdBd = ByteData.sublistView(out, cdOff, cdOff + 44);
    final hashOffset = cdBd.getUint32(16, Endian.big);
    final slots = cdBd.getUint32(28, Endian.big);
    final freshHashes = _hashPages(out, dataoff, pageSize, slots);
    out.setRange(
      cdOff + hashOffset,
      cdOff + hashOffset + freshHashes.length,
      freshHashes,
    );
  }
}

/// Rebuilds one `CS_CodeDirectory` [cd] over the new [codeLimit]: fresh slot
/// count, zeroed code slots (filled by [_fillCodeHashes] once the output is
/// stable), kept identifier, flags, special slots and trailing words.
///
/// Throws [FormatException] on an unhashable directory (anything but
/// SHA-256) or a malformed one.
({Uint8List bytes, int pageSize}) _rebuildCodeDirectory(
  Uint8List cd,
  int codeLimit,
) {
  final dir = _ParsedCodeDirectory.read(cd);
  final pageSize = dir.pageSizeFor(codeLimit);
  if (pageSize <= 0) {
    throw const FormatException(
      'Cannot rebuild the embedded code signature: invalid page size.',
    );
  }
  final freshSlots = (codeLimit + pageSize - 1) ~/ pageSize;
  final freshLength = cd.length + (freshSlots - dir.slots) * 32;
  final out = Uint8List(freshLength);
  // Everything through slot 0 (header plus special slots) is kept
  // byte-identical; the code slots stay zero until [_fillCodeHashes].
  out.setRange(0, dir.hashOffset, cd);
  final newHashesEnd = dir.hashOffset + freshSlots * 32;
  out.setRange(newHashesEnd, freshLength, cd, dir.oldHashesEnd);
  final bd = ByteData.sublistView(out);
  bd.setUint32(4, freshLength, Endian.big);
  bd.setUint32(28, freshSlots, Endian.big);
  bd.setUint32(32, codeLimit, Endian.big);
  dir.zeroCodeLimit64(bd, freshLength, newHashesEnd);
  return (bytes: out, pageSize: pageSize);
}

/// Hashes the [slots] pages below [codeLimit] in [fileBytes].
Uint8List _hashPages(
  Uint8List fileBytes,
  int codeLimit,
  int pageSize,
  int slots,
) {
  final out = Uint8List(slots * 32);
  for (var slot = 0; slot < slots; slot++) {
    final start = slot * pageSize;
    var end = start + pageSize;
    if (end > codeLimit) end = codeLimit;
    if (start >= fileBytes.length || end > fileBytes.length || start >= end) {
      throw FormatException(
        'Cannot rebuild the embedded code signature: page $slot '
        'reaches past the end of the file.',
      );
    }
    final digest = sha256(Uint8List.sublistView(fileBytes, start, end));
    out.setRange(slot * 32, (slot + 1) * 32, digest);
  }
  return out;
}

/// Returns [lc] resized to [fileLength]: the `__LINKEDIT` `filesize` and
/// `vmsize` both become the new trailing size.
Uint8List _resizedLinkedit(LoadCommand lc, int fileLength) {
  final patched = Uint8List.fromList(lc.bytes);
  final bd = ByteData.sublistView(patched);
  final fileoff = bd.getUint64(40, Endian.little).toInt();
  final size = fileLength - fileoff;
  bd.setUint64(48, size, Endian.little);
  bd.setUint64(32, size, Endian.little);
  return patched;
}

/// Returns [lc] with every table range, symbol-table range and indirect-table
/// range at or past [oldSigEnd] shifted down by [shrink] bytes. A well-formed
/// `LC_NOTE` at or past [oldSigEnd] shifts its u64 data offset the same way:
/// the splice above moves its payload with the tail, so leaving the offset
/// would dangle it past the shrunk signature. A truncated note command, or
/// one whose payload is not inside the [fileLength]-byte file it names (u64
/// fields at or above 2^63 read as negative and smaller values can still
/// wrap, so the containment test is overflow-safe), is left alone: the strip
/// refuses those before any resign, and a bare retag keeps ignoring what it
/// cannot parse.
Uint8List _shiftedRanges(
  LoadCommand lc,
  int oldSigEnd,
  int shrink,
  int fileLength,
) {
  if (shrink == 0) return lc.bytes;
  if (lc.cmd == lcNote) return _shiftedNote(lc, oldSigEnd, shrink, fileLength);
  final refs = fileRangesOf(lc);
  var dirty = false;
  for (final ref in refs) {
    if (ref.size != 0 && ref.offset >= oldSigEnd) dirty = true;
  }
  if (!dirty) return lc.bytes;
  final patched = Uint8List.fromList(lc.bytes);
  final bd = ByteData.sublistView(patched);
  for (final ref in refs) {
    if (ref.size != 0 && ref.offset >= oldSigEnd) {
      bd.setUint32(ref.field, ref.offset - shrink, Endian.little);
    }
  }
  return patched;
}

/// Returns [lc]'s (`LC_NOTE`) bytes with its u64 data offset shifted down by
/// [shrink] bytes when its payload sits at or past [oldSigEnd]. Anything
/// else comes back unchanged: payloads before the splice do not move, empty
/// payloads have no offset, and truncated or past-the-end commands stay
/// exactly as a retag found them.
Uint8List _shiftedNote(
  LoadCommand lc,
  int oldSigEnd,
  int shrink,
  int fileLength,
) {
  if (lc.bytes.length < 40) return lc.bytes;
  final range = notePayloadRange(lc);
  if (range.size == 0 || range.offset < oldSigEnd) return lc.bytes;
  if (!rangeWithinFile(range.offset, range.size, fileLength)) return lc.bytes;
  final patched = Uint8List.fromList(lc.bytes);
  ByteData.sublistView(
    patched,
  ).setUint64(range.field, range.offset - shrink, Endian.little);
  return patched;
}

/// A bounds-checked `CS_CodeDirectory` header: the values the rebuild reads
/// and writes, grouped so the rebuild stays under the parameter limit.
///
/// Everything the rebuild keeps (identifier, scatter and team strings, spare
/// words) sits before the hash array and is copied byte-identical, so the
/// header carries no offsets out: any string or vector at or past the hash
/// array fails the read instead of being moved.
class _ParsedCodeDirectory {
  _ParsedCodeDirectory({
    required this.version,
    required this.oldLimit,
    required this.pageShift,
    required this.hashOffset,
    required this.identOffset,
    required this.identEnd,
    required this.slots,
    required this.hashesStart,
    required this.oldHashesEnd,
  });

  /// The directory version word.
  final int version;

  /// The directory's current `codeLimit`.
  final int oldLimit;

  /// The `pageSize` field: the base-2 logarithm of the hash page size.
  final int pageShift;

  /// Offset of hash slot 0.
  final int hashOffset;

  /// Offset of the identifier string.
  final int identOffset;

  /// End (past the NUL) of the identifier string.
  final int identEnd;

  /// Count of code slots.
  final int slots;

  /// Start of the hash array (special slots first, then code slots).
  final int hashesStart;

  /// End of the old hash array.
  final int oldHashesEnd;

  /// Reads and validates the header of [cd], throwing [FormatException]
  /// when it is truncated, malformed or unhashable.
  ///
  /// The scatter-vector and team-ID words are only read when the [version]
  /// defines them (0x20100 and 0x20200) and the header reaching up to the
  /// identifier or the hash array actually contains them; anything else at
  /// those positions is payload bytes, not offsets. A referenced string or
  /// vector at or past the hash array is refused: ad-hoc and linker
  /// signatures never put anything there, and moving it would corrupt it.
  static _ParsedCodeDirectory read(Uint8List cd) {
    if (cd.length < 44) {
      throw const FormatException('Truncated CodeDirectory blob.');
    }
    final bd = ByteData.sublistView(cd);
    final version = bd.getUint32(8, Endian.big);
    final hashOffset = bd.getUint32(16, Endian.big);
    final identOffset = bd.getUint32(20, Endian.big);
    final specials = bd.getUint32(24, Endian.big);
    final slots = bd.getUint32(28, Endian.big);
    if (bd.getUint8(36) != 32 || bd.getUint8(37) != csHashTypeSha256) {
      throw const FormatException(
        'Cannot rebuild the embedded code signature: unsupported '
        'CodeDirectory hash type.',
      );
    }
    final hashesStart = hashOffset - specials * 32;
    final oldHashesEnd = hashOffset + slots * 32;
    if (hashesStart < 0 || hashOffset > cd.length || oldHashesEnd > cd.length) {
      throw const FormatException('Truncated CodeDirectory hash array.');
    }
    final identEnd = _identEnd(cd, identOffset, hashesStart);
    final headerExtent = identOffset < hashesStart ? identOffset : hashesStart;
    _checkAuxOffset(
      _presentOffset(bd, cd.length, headerExtent, 44, version, 0x20100),
      hashesStart,
      cd.length,
      'scatter vector',
    );
    _checkAuxOffset(
      _presentOffset(bd, cd.length, headerExtent, 48, version, 0x20200),
      hashesStart,
      cd.length,
      'team ID',
    );
    return _ParsedCodeDirectory(
      version: version,
      oldLimit: bd.getUint32(32, Endian.big),
      pageShift: bd.getUint8(39),
      hashOffset: hashOffset,
      identOffset: identOffset,
      identEnd: identEnd,
      slots: slots,
      hashesStart: hashesStart,
      oldHashesEnd: oldHashesEnd,
    );
  }

  /// The hash page size: `1 << pageShift`, or one page covering [codeLimit]
  /// when the shift is unset.
  int pageSizeFor(int codeLimit) {
    if (pageShift > 0) return 1 << pageShift;
    return codeLimit > 0 ? oldLimit : 4096;
  }

  /// Zeroes the `codeLimit64` word in [bd] when the directory carries one:
  /// version 0x20300 or later with room outside the identifier and hashes.
  /// Older or truncated directories keep their bytes as they are.
  void zeroCodeLimit64(ByteData bd, int freshLength, int newHashesEnd) {
    if (version < _cdVersionCodeLimit64 ||
        freshLength < _codeLimit64Field + 8) {
      return;
    }
    if (_codeLimit64Field < newHashesEnd &&
        _codeLimit64Field + 8 > hashesStart) {
      return;
    }
    if (_codeLimit64Field < identEnd && _codeLimit64Field + 8 > identOffset) {
      return;
    }
    bd.setUint64(_codeLimit64Field, 0, Endian.big);
  }
}

/// Throws when the auxiliary string or vector at [offset] would need moving:
/// anything at or past the hash array ([hashesStart]). Ad-hoc and linker
/// signatures keep every referenced string before the hashes; a non-zero
/// offset that does not even point inside the directory is payload garbage
/// and is left untouched, copied byte-identical with the header.
void _checkAuxOffset(
  int offset,
  int hashesStart,
  int cdLength,
  String what,
) {
  if (offset == 0 || offset >= cdLength) return;
  if (offset >= hashesStart) {
    throw FormatException('Malformed CodeDirectory $what offset.');
  }
}

/// Reads the version-gated 4-byte offset at [field]: the value when [version]
/// defines it ([since] or later) and the header reaching up to the identifier
/// or the hash array ([headerExtent]) actually contains the field, else 0.
/// Anything else at that position is identifier or padding bytes, not an
/// offset: a version-0x20100 directory with its identifier at 44 keeps
/// `fixture\0` there, not a scatter vector.
int _presentOffset(
  ByteData bd,
  int cdLength,
  int headerExtent,
  int field,
  int version,
  int since,
) {
  if (version < since || field + 4 > headerExtent || field + 4 > cdLength) {
    return 0;
  }
  return bd.getUint32(field, Endian.big);
}

/// Returns the end (past the NUL) of the identifier at [offset] in [cd].
///
/// A value of 0 or past the blob is left untouched: the header bytes are
/// copied as they are. An identifier at or past the hash array
/// ([hashesStart]), or one running into it, is refused: ad-hoc and linker
/// signatures keep the identifier before the hashes, and moving it would
/// corrupt it.
int _identEnd(Uint8List cd, int offset, int hashesStart) {
  if (offset == 0 || offset >= cd.length) return offset;
  if (offset >= hashesStart) {
    throw const FormatException('Malformed CodeDirectory identifier.');
  }
  var end = offset;
  while (end < hashesStart && end < cd.length && cd[end] != 0) {
    end++;
  }
  if (end >= hashesStart) {
    throw const FormatException('Malformed CodeDirectory identifier.');
  }
  if (end >= cd.length) {
    throw const FormatException('Truncated CodeDirectory identifier.');
  }
  return end + 1;
}
