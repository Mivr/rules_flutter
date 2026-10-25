/// Load-command file-range accounting for the symbol strip.
///
/// `strip -x` on Apple rebuilds `__LINKEDIT` from its file offset and, for
/// binaries without a `__LINKEDIT` segment, patches the symbol tables in
/// place. Both rewrites reuse, move or zero file bytes, so every byte a load
/// command names must be accounted for before anything is written: this
/// library reads every load command's file ranges with the command's real
/// layout, relocates the `LC_NOTE` payload the table collector moves, and
/// audits a rewritten image's ranges before the tool writes it. Anything it
/// cannot account for (a truncated command, an `LC_FILESET_ENTRY` whose size
/// the command does not name, or a command type it does not know) is a
/// [FormatException] naming the command, never a silently emitted binary.

import 'dart:convert';
import 'dart:typed_data';

import 'macho_constants.dart';
import 'macho_parse.dart'
    show
        CommandRange,
        LoadCommand,
        isSingleRangeLinkeditCommand,
        movedTableRanges;

/// Load command types that carry no file range and ride a strip untouched:
/// dynamic-linker and library names, UUIDs, version floors, the entry point
/// and the like. Kept as an explicit set so a command type this list does
/// not know is refused instead of silently assumed range-free.
bool carriesNoFileRange(int cmd) => _noRangeCommands.contains(cmd);

/// Every known load command type with no file range. Range-bearing commands
/// (`LC_SEGMENT_64`, `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_DYLD_INFO`,
/// `LC_DYLD_INFO_ONLY`, the `linkedit_data` commands, `LC_TWOLEVEL_HINTS`,
/// the encryption-info commands and `LC_NOTE`) are read by
/// [accountedRangesOf] instead and must not appear here.
const _noRangeCommands = <int>{
  lcThread,
  lcUnixthread,
  lcLoadFvmlib,
  lcIdFvmlib,
  lcIdent,
  lcFvmfile,
  lcPrepage,
  lcLoadDylib,
  lcIdDylib,
  lcLoadDylinker,
  lcIdDylinker,
  lcPreboundDylib,
  lcRoutines,
  lcSubFramework,
  lcSubUmbrella,
  lcSubClient,
  lcSubLibrary,
  lcPrebindCksum,
  lcLoadWeakDylib,
  lcRoutines64,
  lcUuid,
  lcRpath,
  lcReexportDylib,
  lcLoadUpwardDylib,
  lcVersionMinMacosx,
  lcVersionMinIphoneos,
  lcVersionMinTvos,
  lcVersionMinWatchos,
  lcDyldEnvironment,
  lcMain,
  lcSourceVersion,
  lcBuildVersion,
  lcLinkerInput,
};

/// Whether [cmd]'s ranges must live inside `__LINKEDIT` in a stripped image:
/// the symbol tables, the indirect table, the dyld tables and the linkedit
/// data blobs. Segments, sections and the other fixed ranges (two-level hints,
/// encryption ranges) survive wherever the input put them, as does an
/// `LC_NOTE` payload outside `__LINKEDIT`: the compacting rewrite copies those
/// bytes verbatim, so only notes reaching into `__LINKEDIT` are collected and
/// moved (which the layout then guarantees land inside it).
bool residesInLinkedit(int cmd) {
  return cmd == lcSymtab ||
      cmd == lcDysymtab ||
      cmd == lcDyldInfo ||
      cmd == lcDyldInfoOnly ||
      isSingleRangeLinkeditCommand(cmd);
}

/// Whether the file ranges `(aOff, aSize)` and `(bOff, bSize)` share a byte.
/// Empty ranges share nothing.
bool rangesIntersect(int aOff, int aSize, int bOff, int bSize) {
  if (aSize <= 0 || bSize <= 0) return false;
  return aOff < bOff + bSize && bOff < aOff + aSize;
}

/// Whether the file range (`offset`, `size`) lies wholly inside a file of
/// [length] bytes, computed overflow-safe and unsigned-correct: u64 command
/// fields at or above 2^63 read as negative through `ByteData.getUint64`,
/// and an offset and size that are each below 2^63 can still sum past it and
/// wrap negative, so callers must never form `offset + size`. A negative
/// part is outside every file; otherwise `offset` must not pass [length]
/// and `size` must fit the remainder, which cannot overflow.
bool rangeWithinFile(int offset, int size, int length) {
  if (size < 0 || offset < 0) return false;
  if (offset > length) return false;
  return size <= length - offset;
}

/// The segment name of [lc], or the empty string when [lc] is not a readable
/// `LC_SEGMENT_64` command.
String segmentNameOf(LoadCommand lc) {
  if (lc.cmd != lcSegment64 || lc.bytes.length < 24) return '';
  return ascii.decode(lc.bytes.sublist(8, 24)).split('\x00').first;
}

/// Names [lc] for strip errors: the segment name plus the hex type for
/// segments, the hex type otherwise.
String describeStripCommand(LoadCommand lc) {
  if (lc.cmd == lcSegment64) {
    return 'segment ${segmentNameOf(lc)} (0x${lc.cmd.toRadixString(16)})';
  }
  return 'load command 0x${lc.cmd.toRadixString(16)}';
}

/// Every file range [lc] names, read with the command's real layout:
/// segments with whatever name plus their sections (zero-fill sections name
/// no bytes and are skipped), both `LC_SYMTAB` tables, the `LC_DYSYMTAB`
/// indirect table, all five `LC_DYLD_INFO` pairs, the single pair of the
/// `linkedit_data` commands, the hints table, the encryption range and the
/// `LC_NOTE` payload.
///
/// Throws [FormatException] naming the command when a range-bearing command
/// is truncated, when `LC_DYSYMTAB` carries a table the strip does not remap,
/// when `LC_FILESET_ENTRY` names an embedded image whose size the command
/// does not carry, and when the command type is not known: the strip cannot
/// know where an unknown command's ranges are, so it refuses instead.
List<CommandRange> accountedRangesOf(LoadCommand lc) {
  switch (lc.cmd) {
    case lcSegment64:
      return _segmentRanges(lc);
    case lcSymtab:
      return _symtabRanges(lc);
    case lcDysymtab:
      return _dysymtabRanges(lc);
    case lcDyldInfo:
    case lcDyldInfoOnly:
      return movedTableRanges(lc);
    case lcTwolevelHints:
      return _hintsRanges(lc);
    case lcEncryptionInfo:
    case lcEncryptionInfo64:
      return _encryptionRanges(lc);
    case lcNote:
      return [notePayloadRange(lc)];
    case lcFilesetEntry:
      throw FormatException(
        'Cannot strip local symbols: ${describeStripCommand(lc)} names an '
        'embedded Mach-O image whose size the command does not carry.',
      );
  }
  if (isSingleRangeLinkeditCommand(lc.cmd)) {
    return movedTableRanges(lc);
  }
  if (carriesNoFileRange(lc.cmd)) return const [];
  throw FormatException(
    'Cannot strip local symbols: unknown ${describeStripCommand(lc)}; '
    'refusing to strip a binary with unaccounted ranges.',
  );
}

/// The file range of [lc]'s (`LC_SEGMENT_64`) segment plus its sections.
/// Throws [FormatException] naming the segment when the command or a section
/// is truncated.
List<CommandRange> _segmentRanges(LoadCommand lc) {
  if (lc.bytes.length < 72) {
    throw FormatException(
      'Cannot strip local symbols: truncated ${describeStripCommand(lc)}.',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  final ranges = <CommandRange>[
    CommandRange(
      field: 40,
      offset: bd.getUint64(40, Endian.little),
      size: bd.getUint64(48, Endian.little),
    ),
  ];
  final nsects = bd.getUint32(64, Endian.little);
  for (var s = 0; s < nsects; s++) {
    final at = 72 + s * 80;
    if (at + 80 > lc.bytes.length) {
      throw FormatException(
        'Cannot strip local symbols: truncated ${describeStripCommand(lc)} '
        'section ${s + 1}.',
      );
    }
    if ((bd.getUint32(at + 68, Endian.little) & sectionTypeMask) ==
        sectionTypeZerofill) {
      continue;
    }
    ranges.add(
      CommandRange(
        field: at + 48,
        offset: bd.getUint32(at + 48, Endian.little),
        size: bd.getUint64(at + 40, Endian.little),
      ),
    );
  }
  return ranges;
}

/// Both file ranges of [lc] (`LC_SYMTAB`): the symbol entries and the string
/// table. Throws [FormatException] naming the command when it is truncated.
List<CommandRange> _symtabRanges(LoadCommand lc) {
  if (lc.bytes.length < 24) {
    throw FormatException(
      'Cannot strip local symbols: truncated ${describeStripCommand(lc)}.',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  return [
    CommandRange(
      field: 8,
      offset: bd.getUint32(8, Endian.little),
      size: bd.getUint32(12, Endian.little) * 16,
    ),
    CommandRange(
      field: 16,
      offset: bd.getUint32(16, Endian.little),
      size: bd.getUint32(20, Endian.little),
    ),
  ];
}

/// The `LC_DYSYMTAB` indirect-symbol range of [lc]. Table-of-contents,
/// module, reference-symbol and relocation tables index symbols in ways the
/// strip does not track, so a command carrying any of them is refused with
/// the same error the indirect-table remap reports.
List<CommandRange> _dysymtabRanges(LoadCommand lc) {
  if (lc.bytes.length < 80) {
    throw FormatException(
      'Cannot strip local symbols: truncated ${describeStripCommand(lc)}.',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  if (bd.getUint32(36, Endian.little) != 0 ||
      bd.getUint32(44, Endian.little) != 0 ||
      bd.getUint32(52, Endian.little) != 0 ||
      bd.getUint32(68, Endian.little) != 0 ||
      bd.getUint32(76, Endian.little) != 0) {
    throw const FormatException(
      'Cannot strip local symbols from a binary with table-of-contents, '
      'module, reference-symbol or relocation tables.',
    );
  }
  final count = bd.getUint32(60, Endian.little);
  if (count == 0) return const [];
  return [
    CommandRange(
      field: 56,
      offset: bd.getUint32(56, Endian.little),
      size: count * 4,
    ),
  ];
}

/// The `LC_TWOLEVEL_HINTS` hints-table range of [lc]: `nhints` 4-byte entries
/// at `offset`. Throws [FormatException] naming the command when truncated.
List<CommandRange> _hintsRanges(LoadCommand lc) {
  if (lc.bytes.length < 16) {
    throw FormatException(
      'Cannot strip local symbols: truncated ${describeStripCommand(lc)}.',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  return [
    CommandRange(
      field: 8,
      offset: bd.getUint32(8, Endian.little),
      size: bd.getUint32(12, Endian.little) * 4,
    ),
  ];
}

/// The encrypted range of [lc] (`LC_ENCRYPTION_INFO` or
/// `LC_ENCRYPTION_INFO_64`): `cryptsize` bytes at `cryptoff`. Throws
/// [FormatException] naming the command when truncated.
List<CommandRange> _encryptionRanges(LoadCommand lc) {
  if (lc.bytes.length < 24) {
    throw FormatException(
      'Cannot strip local symbols: truncated ${describeStripCommand(lc)}.',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  return [
    CommandRange(
      field: 8,
      offset: bd.getUint32(8, Endian.little),
      size: bd.getUint32(12, Endian.little),
    ),
  ];
}

/// The file range [lc]'s (`LC_NOTE`) payload names: a 16-byte owner followed
/// by a u64 file offset and a u64 size, so the command is 40 bytes.
/// Throws [FormatException] naming the command when [lc] is shorter.
CommandRange notePayloadRange(LoadCommand lc) {
  if (lc.cmd != lcNote || lc.bytes.length < 40) {
    throw FormatException(
      'Cannot strip local symbols: malformed load command '
      '0x${lc.cmd.toRadixString(16)} (a note command is 40 bytes).',
    );
  }
  final bd = ByteData.sublistView(lc.bytes);
  return CommandRange(
    field: 24,
    offset: bd.getUint64(24, Endian.little),
    size: bd.getUint64(32, Endian.little),
  );
}

/// Returns [lc] (`LC_NOTE`) with its u64 data offset relocated through
/// [movedOffsets] when the payload was collected for the move. An empty
/// payload has no offset to move and comes back unchanged, as does a payload
/// the rewrite did not move: only notes reaching into `__LINKEDIT` are
/// collected for the move, and the bytes before `__LINKEDIT` are copied
/// verbatim, so an unmoved payload still names the same bytes.
///
/// Throws [FormatException] naming the command when it is malformed or its
/// payload is not inside the [fileLength]-byte file it names: u64 fields at
/// or above 2^63 read as negative and smaller values can still wrap, so the
/// containment test is overflow-safe. A payload the rewrite moved always has
/// a new offset (collection is total), so a missing entry means the payload
/// survived verbatim rather than reused bytes.
LoadCommand relocatedNoteCommand(
  LoadCommand lc,
  Map<int, int> movedOffsets,
  int fileLength,
) {
  final range = notePayloadRange(lc);
  if (range.size == 0) return lc;
  if (!rangeWithinFile(range.offset, range.size, fileLength)) {
    throw FormatException(
      'Cannot strip local symbols: load command '
      '0x${lc.cmd.toRadixString(16)} points past the end of the file.',
    );
  }
  final fresh = movedOffsets[range.offset];
  if (fresh == null) return lc;
  final bytes = Uint8List.fromList(lc.bytes);
  ByteData.sublistView(bytes).setUint64(24, fresh, Endian.little);
  return LoadCommand(lc.cmd, bytes);
}

/// The rewritten image's geometry for [auditOutputRanges]: grouped so the
/// audit stays under the parameter limit.
class RewrittenLayout {
  const RewrittenLayout({required this.linkeditOff, required this.fileLength});

  /// The `__LINKEDIT` file offset the rewrite rebuilt from, or 0 when the
  /// image has no `__LINKEDIT` segment (the in-place rewrite).
  final int linkeditOff;

  /// The rewritten image's length in bytes.
  final int fileLength;
}

/// Audits a strip rewrite's output before the tool writes it: every range
/// every load command names lies inside the file, every range that must live
/// in `__LINKEDIT` does, and no two of those ranges overlap. Any violation
/// is a [FormatException] naming the command, never a written file.
void auditOutputRanges(List<LoadCommand> commands, RewrittenLayout layout) {
  final managed = <CommandRange>[];
  for (final lc in commands) {
    _auditCommandRanges(lc, layout, managed);
  }
  managed.sort((a, b) => a.offset.compareTo(b.offset));
  for (var i = 1; i < managed.length; i++) {
    if (rangesIntersect(
      managed[i].offset,
      managed[i].size,
      managed[i - 1].offset,
      managed[i - 1].size,
    )) {
      throw const FormatException(
        'Cannot strip local symbols: rewritten linkedit ranges overlap.',
      );
    }
  }
}

/// Checks one [lc]'s ranges against [layout], collecting the ranges that must
/// live in `__LINKEDIT` into [managed] for the overlap check.
void _auditCommandRanges(
  LoadCommand lc,
  RewrittenLayout layout,
  List<CommandRange> managed,
) {
  for (final range in accountedRangesOf(lc)) {
    if (range.size == 0) continue;
    if (!rangeWithinFile(range.offset, range.size, layout.fileLength)) {
      throw FormatException(
        'Cannot strip local symbols: ${describeStripCommand(lc)} points '
        'past the end of the file.',
      );
    }
    if (!residesInLinkedit(lc.cmd)) continue;
    if (range.offset < layout.linkeditOff) {
      throw FormatException(
        'Cannot strip local symbols: ${describeStripCommand(lc)} escapes '
        '__LINKEDIT.',
      );
    }
    managed.add(range);
  }
}
