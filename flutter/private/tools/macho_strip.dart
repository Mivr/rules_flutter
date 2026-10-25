/// Mach-O symbol stripping: the `strip -x` rewrite behind `patch
/// --strip-symbols`.
///
/// The input image is split into its surviving symbols ([_KeptSymbols]), a
/// rewrite plan ([_StripPlan]) lays the compacted tables out, and the plan
/// emits the stripped image: rebuilt from the `__LINKEDIT` segment, or
/// patched in place when the binary has none.

import 'dart:convert';
import 'dart:typed_data';

import 'macho_constants.dart';
import 'macho_parse.dart'
    show
        LoadCommand,
        buildLcSymtab,
        isSingleRangeLinkeditCommand,
        movedTableRanges;
import 'macho_ranges.dart'
    show
        RewrittenLayout,
        accountedRangesOf,
        auditOutputRanges,
        describeStripCommand,
        notePayloadRange,
        rangeWithinFile,
        rangesIntersect,
        relocatedNoteCommand,
        segmentNameOf;

/// A decoded 16-byte `nlist_64` symbol-table entry.
class _NlistEntry {
  _NlistEntry({
    required this.index,
    required this.strx,
    required this.nType,
    required this.nSect,
    required this.nDesc,
    required this.nValue,
    required this.name,
  });

  /// The entry's position in the original table.
  final int index;

  /// The entry's offset into the original string table.
  final int strx;

  final int nType;
  final int nSect;
  final int nDesc;
  final int nValue;

  /// The raw name bytes (without the NUL terminator).
  final Uint8List name;

  /// Whether this entry is a debugging (stab) entry.
  bool get isStab => (nType & nStabMask) != 0;

  /// Whether this entry is visible outside the binary.
  bool get isExternal => (nType & nExtBit) != 0;

  /// Whether this entry is an undefined import rather than a definition.
  bool get isUndefined => (nType & nTypeMask) == nTypeUndef && nSect == 0;
}

/// The compacted Mach-O file and its updated load commands.
class StrippedSymbols {
  StrippedSymbols(this.bytes, this.commands);

  /// The file bytes with the compacted symbol and string tables.
  final Uint8List bytes;

  /// The load commands with `LC_SYMTAB`, `LC_DYSYMTAB`, moved table offsets
  /// and the `__LINKEDIT` size updated to the new layout.
  final List<LoadCommand> commands;
}

/// Drops every local symbol and stab entry from [inputBytes]' symbol table,
/// `strip -x` style: what `flutter build` runs on the AOT dylib after
/// gen_snapshot, because gen_snapshot's `--strip` drops only the DWARF
/// sections on Apple while the locals and stabs keep every unobfuscated
/// function name.
///
/// Only exported (`N_EXT`, stab-free) and undefined symbols survive, in that
/// order. `LC_SYMTAB` and the `LC_DYSYMTAB` index groups are rebuilt over a
/// string table holding just the survivors' names; the indirect symbol table
/// is remapped through the new indices; every other `__LINKEDIT` payload
/// (export trie, code signature blob, ...) moves down byte-identical so the
/// file shrinks. The loader-facing commands and the embedded code signature
/// (recomputed by the surrounding patch step) keep working: no load command
/// the loader needs is touched.
///
/// Binaries without an `LC_SYMTAB` come back unchanged. Anything the rewrite
/// cannot remap (table-of-contents, module, reference-symbol or relocation
/// tables, payloads outside `__LINKEDIT`) throws a [FormatException] rather
/// than shipping a corrupt binary.
StrippedSymbols stripLocalSymbols(
  Uint8List inputBytes,
  List<LoadCommand> commands,
) {
  final symtabIndex = commands.indexWhere((c) => c.cmd == lcSymtab);
  if (symtabIndex < 0) return StrippedSymbols(inputBytes, commands);
  final table = _readSymtab(inputBytes, commands[symtabIndex]);
  return _StripPlan(
    input: inputBytes,
    commands: commands,
    table: table,
    kept: _KeptSymbols.of(table.entries),
    symtabIndex: symtabIndex,
    dysymtabIndex: commands.indexWhere((c) => c.cmd == lcDysymtab),
  ).emit();
}

/// The `LC_SYMTAB` table contents: decoded entries plus string table bounds.
class _SymtabTable {
  _SymtabTable({
    required this.entries,
    required this.symoff,
    required this.nsyms,
    required this.stroff,
    required this.strsize,
  });

  final List<_NlistEntry> entries;
  final int symoff;
  final int nsyms;
  final int stroff;
  final int strsize;
}

/// Reads and bounds-checks the `LC_SYMTAB` table of [inputBytes].
_SymtabTable _readSymtab(Uint8List inputBytes, LoadCommand symtabLc) {
  if (symtabLc.bytes.length < 24) {
    throw const FormatException('Truncated LC_SYMTAB load command.');
  }
  final bd = ByteData.sublistView(symtabLc.bytes);
  final symoff = bd.getUint32(8, Endian.little);
  final nsyms = bd.getUint32(12, Endian.little);
  final stroff = bd.getUint32(16, Endian.little);
  final strsize = bd.getUint32(20, Endian.little);
  if (symoff + nsyms * 16 > inputBytes.length ||
      stroff + strsize > inputBytes.length) {
    throw const FormatException(
      'LC_SYMTAB points past the end of the file.',
    );
  }
  final entries = <_NlistEntry>[];
  for (var i = 0; i < nsyms; i++) {
    entries.add(_readNlistEntry(inputBytes, symoff, stroff, strsize, i));
  }
  return _SymtabTable(
    entries: entries,
    symoff: symoff,
    nsyms: nsyms,
    stroff: stroff,
    strsize: strsize,
  );
}

/// Decodes the `nlist_64` entry [index] at [symoff], resolving its name.
_NlistEntry _readNlistEntry(
  Uint8List inputBytes,
  int symoff,
  int stroff,
  int strsize,
  int index,
) {
  final at = symoff + index * 16;
  final bd = ByteData.sublistView(inputBytes, at, at + 16);
  final strx = bd.getUint32(0, Endian.little);
  if (strx >= strsize) {
    throw FormatException(
      'Symbol table entry $index names a string past the string table.',
    );
  }
  var end = stroff + strx;
  while (end < stroff + strsize && inputBytes[end] != 0) {
    end++;
  }
  return _NlistEntry(
    index: index,
    strx: strx,
    nType: bd.getUint8(4),
    nSect: bd.getUint8(5),
    nDesc: bd.getUint16(6, Endian.little),
    nValue: bd.getUint64(8, Endian.little),
    name: Uint8List.fromList(inputBytes.sublist(stroff + strx, end)),
  );
}

/// Which symbols survive a `strip -x` rewrite: the decision behind
/// [stripLocalSymbols], split from the parsed table before anything is laid
/// out. Defined externals keep their relative order and come first, then the
/// undefined imports; locals and stab entries are gone.
class _KeptSymbols {
  _KeptSymbols(this.defined, this.undefined);

  /// Splits [entries] into the survivors: defined externals first (keeping
  /// their relative order), then undefined imports. Locals and stabs are
  /// gone.
  factory _KeptSymbols.of(List<_NlistEntry> entries) {
    final defined = <_NlistEntry>[];
    final undefined = <_NlistEntry>[];
    for (final entry in entries) {
      if (entry.isStab || !entry.isExternal) continue;
      if (entry.isUndefined) {
        undefined.add(entry);
      } else {
        defined.add(entry);
      }
    }
    return _KeptSymbols(defined, undefined);
  }

  /// The surviving defined externals, in table order.
  final List<_NlistEntry> defined;

  /// The surviving undefined imports, in table order.
  final List<_NlistEntry> undefined;

  /// Every survivor, defined first: the new table's entry order.
  List<_NlistEntry> get ordered => [...defined, ...undefined];

  /// Maps each survivor's old table index to its new one.
  Map<int, int> indexRemap() {
    final kept = ordered;
    return {for (var i = 0; i < kept.length; i++) kept[i].index: i};
  }

  /// The compacted symbol and string tables holding just the survivors.
  ({Uint8List symtab, _KeptStrings strings}) tables() {
    final kept = ordered;
    final strings = _buildKeptStrings(kept);
    return (
      symtab: _buildKeptSymtab(kept, strings.offsets),
      strings: strings,
    );
  }
}

/// A rebuilt string table: its bytes plus each kept symbol's new offset.
class _KeptStrings {
  _KeptStrings(this.bytes, this.offsets);

  final Uint8List bytes;
  final List<int> offsets;
}

/// Builds the string table holding just [ordered]' names; offset 0 stays the
/// empty string so entries without a name keep pointing at one.
_KeptStrings _buildKeptStrings(List<_NlistEntry> ordered) {
  final out = BytesBuilder(copy: false)..addByte(0);
  final offsets = <int>[];
  for (final entry in ordered) {
    if (entry.name.isEmpty) {
      offsets.add(0);
    } else {
      offsets.add(out.length);
      out.add(entry.name);
      out.addByte(0);
    }
  }
  return _KeptStrings(out.toBytes(), offsets);
}

/// Serializes [ordered] as `nlist_64` entries with the new string offsets.
Uint8List _buildKeptSymtab(List<_NlistEntry> ordered, List<int> strOffsets) {
  final out = Uint8List(ordered.length * 16);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < ordered.length; i++) {
    final entry = ordered[i];
    bd.setUint32(i * 16, strOffsets[i], Endian.little);
    bd.setUint8(i * 16 + 4, entry.nType);
    bd.setUint8(i * 16 + 5, entry.nSect);
    bd.setUint16(i * 16 + 6, entry.nDesc, Endian.little);
    bd.setUint64(i * 16 + 8, entry.nValue, Endian.little);
  }
  return out;
}

/// The remapped `LC_DYSYMTAB`: its new command bytes and indirect table.
class _RemappedDysymtab {
  _RemappedDysymtab({
    required this.commandBytes,
    required this.indirectBytes,
    required this.indirectOffset,
    required this.indirectCount,
  });

  /// The new 80-byte `LC_DYSYMTAB` command (indirect offset fixed by layout).
  final Uint8List commandBytes;

  /// The remapped indirect symbol table, or null when the binary has none.
  final Uint8List? indirectBytes;

  /// The indirect table's original file offset (0 when absent).
  final int indirectOffset;

  /// The indirect table's entry count.
  final int indirectCount;
}

/// Rebuilds the `LC_DYSYMTAB` index groups over the compacted table: no
/// locals, then the defined externals, then the undefined imports.
///
/// Table-of-contents, module, reference-symbol and relocation tables index
/// symbols in ways this rewrite does not track, so a binary carrying any of
/// them fails loudly instead of shipping with dangling indices.
_RemappedDysymtab _remapDysymtab(
  Uint8List inputBytes,
  LoadCommand dysymtabLc,
  Map<int, int> remap,
  int nDefined,
  int nUndefined,
) {
  if (dysymtabLc.bytes.length < 80) {
    throw const FormatException('Truncated LC_DYSYMTAB load command.');
  }
  final bd = ByteData.sublistView(dysymtabLc.bytes);
  final ntoc = bd.getUint32(36, Endian.little);
  final nmodtab = bd.getUint32(44, Endian.little);
  final nextrefsyms = bd.getUint32(52, Endian.little);
  final indirectsymoff = bd.getUint32(56, Endian.little);
  final nindirectsyms = bd.getUint32(60, Endian.little);
  final nextrel = bd.getUint32(68, Endian.little);
  final nlocrel = bd.getUint32(76, Endian.little);
  if (ntoc != 0 ||
      nmodtab != 0 ||
      nextrefsyms != 0 ||
      nextrel != 0 ||
      nlocrel != 0) {
    throw const FormatException(
      'Cannot strip local symbols from a binary with table-of-contents, '
      'module, reference-symbol or relocation tables.',
    );
  }
  Uint8List? indirectBytes;
  if (nindirectsyms > 0) {
    if (indirectsymoff + nindirectsyms * 4 > inputBytes.length) {
      throw const FormatException(
        'LC_DYSYMTAB indirect symbols run past the end of the file.',
      );
    }
    indirectBytes = _remapIndirectTable(
      inputBytes,
      indirectsymoff,
      nindirectsyms,
      remap,
    );
  }
  final out = Uint8List.fromList(dysymtabLc.bytes);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(8, 0, Endian.little); // ilocalsym: no locals left
  outBd.setUint32(12, 0, Endian.little); // nlocalsym
  outBd.setUint32(16, 0, Endian.little); // iextdefsym: externals start at 0
  outBd.setUint32(20, nDefined, Endian.little); // nextdefsym
  outBd.setUint32(24, nDefined, Endian.little); // iundefsym
  outBd.setUint32(28, nUndefined, Endian.little); // nundefsym
  return _RemappedDysymtab(
    commandBytes: out,
    indirectBytes: indirectBytes,
    indirectOffset: indirectsymoff,
    indirectCount: nindirectsyms,
  );
}

/// Remaps indirect-table entries through [remap]. `INDIRECT_SYMBOL_LOCAL`
/// and `INDIRECT_SYMBOL_ABS` entries name no table index and stay as they
/// are; entries naming a dropped symbol become `INDIRECT_SYMBOL_ABS`, which
/// keeps their no-dynamic-binding meaning once the symbol is gone.
Uint8List _remapIndirectTable(
  Uint8List inputBytes,
  int offset,
  int count,
  Map<int, int> remap,
) {
  final out = Uint8List(count * 4);
  final inBd = ByteData.sublistView(inputBytes, offset, offset + count * 4);
  final outBd = ByteData.sublistView(out);
  for (var i = 0; i < count; i++) {
    final entry = inBd.getUint32(i * 4, Endian.little);
    if ((entry & indirectSymbolSpecialMask) != 0) {
      outBd.setUint32(i * 4, entry, Endian.little);
      continue;
    }
    outBd.setUint32(i * 4, remap[entry] ?? indirectSymbolAbs, Endian.little);
  }
  return out;
}

/// The `__LINKEDIT` segment command, or null when the binary has none.
LoadCommand? _findLinkeditSegment(List<LoadCommand> commands) {
  for (final lc in commands) {
    if (lc.cmd != lcSegment64 || lc.bytes.length < 72) continue;
    final name = ascii.decode(lc.bytes.sublist(8, 24)).split('\x00').first;
    if (name == '__LINKEDIT') return lc;
  }
  return null;
}

/// One `__LINKEDIT` payload to lay out: its original file range, its new
/// bytes, and the new offset [_layoutLinkeditPayloads] assigns it. The code
/// signature payload sets [align16]: like ld64 and llvm-strip, the rewrite
/// places `LC_CODE_SIGNATURE` at a 16-byte-aligned file offset, zero-padding
/// the gap before it inside `__LINKEDIT`.
class _LinkeditPayload {
  _LinkeditPayload({
    required this.oldOffset,
    required this.oldSize,
    required this.bytes,
  });

  final int oldOffset;
  final int oldSize;
  final Uint8List bytes;

  /// Whether the layout aligns this payload's new offset to 16 bytes (set by
  /// [_alignSignaturePayload] for `LC_CODE_SIGNATURE`).
  bool align16 = false;
  int newOffset = -1;
}

/// Collects every `__LINKEDIT` payload besides the symbol and string tables:
/// the linkedit table commands' data ranges. For `LC_DYLD_INFO` and
/// `LC_DYLD_INFO_ONLY` that is all five pairs (rebase, bind, weak bind, lazy
/// bind, export), not just the rebase pair. Zero-length ranges are not
/// payloads; anything else is bounds-checked against the file.
void _collectTablePayloads(
  Uint8List inputBytes,
  List<LoadCommand> commands,
  List<_LinkeditPayload> into,
  int linkeditOff,
) {
  for (final lc in commands) {
    if (lc.cmd == lcNote) {
      _collectNotePayload(inputBytes, lc, into, linkeditOff);
      continue;
    }
    for (final range in movedTableRanges(lc)) {
      if (range.size == 0) continue;
      if (range.offset + range.size > inputBytes.length) {
        throw FormatException(
          'Load command 0x${lc.cmd.toRadixString(16)} points past the '
          'end of the file.',
        );
      }
      into.add(
        _LinkeditPayload(
          oldOffset: range.offset,
          oldSize: range.size,
          bytes: Uint8List.fromList(
            inputBytes.sublist(range.offset, range.offset + range.size),
          ),
        ),
      );
    }
  }
}

/// Collects [lc]'s (`LC_NOTE`) payload for the compacting rewrite when it
/// reaches into `__LINKEDIT`: a well-formed note moves down byte-identical
/// with its u64 offset rewritten. A payload fully before [linkeditOff] is not
/// collected: those bytes are copied verbatim, so the note keeps naming them.
/// An empty payload is not a payload; anything else is bounds-checked against
/// the file like the table ranges above. A payload straddling [linkeditOff]
/// is refused: the rewrite cannot move half a payload.
void _collectNotePayload(
  Uint8List inputBytes,
  LoadCommand lc,
  List<_LinkeditPayload> into,
  int linkeditOff,
) {
  final range = notePayloadRange(lc);
  if (range.size == 0) return;
  if (!rangeWithinFile(range.offset, range.size, inputBytes.length)) {
    throw FormatException(
      'Load command 0x${lc.cmd.toRadixString(16)} points past the '
      'end of the file.',
    );
  }
  if (rangeWithinFile(range.offset, range.size, linkeditOff)) return;
  if (range.offset < linkeditOff) {
    throw FormatException(
      'Cannot strip local symbols: load command '
      '0x${lc.cmd.toRadixString(16)} straddles __LINKEDIT.',
    );
  }
  into.add(
    _LinkeditPayload(
      oldOffset: range.offset,
      oldSize: range.size,
      bytes: Uint8List.fromList(
        inputBytes.sublist(range.offset, range.offset + range.size),
      ),
    ),
  );
}

/// Marks the `LC_CODE_SIGNATURE` payload (when present and non-empty) for
/// 16-byte alignment: ld64 and llvm-strip place the signature blob aligned,
/// and the resign step keeps the stripped offset as the new `codeLimit`.
void _alignSignaturePayload(
  List<LoadCommand> commands,
  List<_LinkeditPayload> payloads,
) {
  for (final lc in commands) {
    if (lc.cmd != lcCodeSignature || lc.bytes.length < 16) continue;
    final dataoff = ByteData.sublistView(lc.bytes).getUint32(8, Endian.little);
    final datasize = ByteData.sublistView(lc.bytes)
        .getUint32(12, Endian.little);
    if (datasize == 0) continue;
    for (final payload in payloads) {
      if (payload.oldOffset == dataoff) payload.align16 = true;
    }
  }
}

/// Throws when a load command names a file range inside `__LINKEDIT` that
/// the rewrite cannot move. The symbol tables, the indirect table, the dyld
/// and linkedit data tables and any note payload reaching into `__LINKEDIT`
/// are collected for the move; segments are checked by
/// [_checkNoPayloadPastLinkedit]. Anything else with a real file range
/// reaching into `__LINKEDIT` would otherwise keep pointing at bytes the
/// compacting rewrite reuses, so the strip fails loudly naming the command
/// instead. Commands the tool does not know are refused by
/// [accountedRangesOf] whatever their bytes look like, because the tool
/// cannot know where their ranges are.
///
/// [linkeditOff] is the `__LINKEDIT` file offset.
void _throwOnUnmovedLinkeditRanges(
  List<LoadCommand> commands,
  int linkeditOff,
) {
  for (final lc in commands) {
    switch (lc.cmd) {
      case lcSegment64:
      case lcSymtab:
      case lcDysymtab:
      case lcDyldInfo:
      case lcDyldInfoOnly:
      case lcNote:
        continue;
    }
    if (isSingleRangeLinkeditCommand(lc.cmd)) continue;
    for (final range in accountedRangesOf(lc)) {
      if (range.size == 0) continue;
      if (range.offset + range.size > linkeditOff) {
        throw FormatException(
          'Cannot strip local symbols: ${describeStripCommand(lc)} points '
          'into __LINKEDIT.',
        );
      }
    }
  }
}

/// Throws when any segment or section file range outside [linkedit] reaches
/// into [linkeditOff]: the compacting rewrite below rebuilds everything from
/// there to the end of the file, so nothing else may live there. A second
/// segment named `__LINKEDIT` is refused outright: only [linkedit], the
/// segment the rewrite resizes, may carry that name.
void _checkNoPayloadPastLinkedit(
  List<LoadCommand> commands,
  LoadCommand linkedit,
  int linkeditOff,
) {
  for (final lc in commands) {
    if (lc.cmd != lcSegment64 || lc.bytes.length < 72) continue;
    if (identical(lc, linkedit)) continue;
    final bd = ByteData.sublistView(lc.bytes);
    final name = segmentNameOf(lc);
    if (name == '__LINKEDIT') {
      throw const FormatException(
        'Cannot strip local symbols: more than one __LINKEDIT segment '
        '(load command 0x19).',
      );
    }
    _checkRangeOutsideLinkedit(
      linkeditOff,
      bd.getUint64(40, Endian.little),
      bd.getUint64(48, Endian.little),
      'segment $name',
    );
    final nsects = bd.getUint32(64, Endian.little);
    for (var s = 0; s < nsects; s++) {
      final sectOff = 72 + s * 80;
      if (sectOff + 80 > lc.bytes.length) break;
      final sectBd = ByteData.sublistView(lc.bytes, sectOff, sectOff + 80);
      if ((sectBd.getUint32(68, Endian.little) & sectionTypeMask) ==
          sectionTypeZerofill) {
        continue;
      }
      _checkRangeOutsideLinkedit(
        linkeditOff,
        sectBd.getUint32(48, Endian.little),
        sectBd.getUint64(40, Endian.little),
        'a section of segment $name',
      );
    }
  }
}

/// Throws when the file range [offset]/[size] overlaps [linkeditOff]. Every
/// range reaching here is inside the input already (the input-side check in
/// [emit] refused the rest), so there is no past-the-end case left to skip.
void _checkRangeOutsideLinkedit(
  int linkeditOff,
  int offset,
  int size,
  String what,
) {
  if (size == 0) return;
  if (!rangeWithinFile(offset, size, linkeditOff)) {
    throw FormatException(
      'Cannot strip local symbols: $what reaches into __LINKEDIT.',
    );
  }
}

/// Lays [payloads] out contiguously from [linkeditOff] in file order,
/// failing on overlapping or out-of-file original ranges. Payloads marked
/// [align16] start at a 16-byte-aligned file offset; the output buffer is
/// freshly zeroed, so the padding gap stays zero-filled inside `__LINKEDIT`.
int _layoutLinkeditPayloads(
  List<_LinkeditPayload> payloads,
  int linkeditOff,
  int fileLength,
) {
  payloads.sort((a, b) => a.oldOffset.compareTo(b.oldOffset));
  var cursor = linkeditOff;
  var end = linkeditOff;
  for (final payload in payloads) {
    if (payload.oldOffset < linkeditOff ||
        !rangeWithinFile(payload.oldOffset, payload.oldSize, fileLength)) {
      throw const FormatException(
        'Cannot strip local symbols: a linkedit payload lies outside '
        '__LINKEDIT.',
      );
    }
    if (payload.oldOffset < end) {
      throw const FormatException(
        'Cannot strip local symbols: linkedit payloads overlap.',
      );
    }
    end = payload.oldOffset + payload.oldSize;
    if (payload.align16) {
      cursor += (16 - (cursor % 16)) % 16;
    }
    payload.newOffset = cursor;
    cursor += payload.bytes.length;
  }
  return cursor - linkeditOff;
}

/// A strip rewrite ready to lay out: the input image with its surviving
/// symbols decided and its compacted tables already built. The emitters below
/// work from these fields, so no table offset travels as a parameter.
class _StripPlan {
  _StripPlan({
    required this.input,
    required this.commands,
    required this.table,
    required this.kept,
    required this.symtabIndex,
    required this.dysymtabIndex,
  }) : tables = kept.tables();

  /// The image under rewrite.
  final Uint8List input;

  /// The parsed load commands.
  final List<LoadCommand> commands;

  /// The decoded `LC_SYMTAB` layout.
  final _SymtabTable table;

  /// The surviving symbols.
  final _KeptSymbols kept;

  /// The `LC_SYMTAB` position in [commands].
  final int symtabIndex;

  /// The `LC_DYSYMTAB` position in [commands], or -1 when absent.
  final int dysymtabIndex;

  /// The compacted symbol and string tables.
  final ({Uint8List symtab, _KeptStrings strings}) tables;

  /// Emits the stripped image: rebuilt from `__LINKEDIT` when the binary
  /// has one, patched in place otherwise.
  StrippedSymbols emit() {
    _throwOnInputRangesPastEnd();
    _RemappedDysymtab? remapped;
    if (dysymtabIndex >= 0) {
      remapped = _remapDysymtab(
        input,
        commands[dysymtabIndex],
        kept.indexRemap(),
        kept.defined.length,
        kept.undefined.length,
      );
    }
    final linkedit = _findLinkeditSegment(commands);
    if (linkedit == null) return _layInPlace(remapped);
    return _layCompacting(linkedit, remapped);
  }

  /// Throws when any load command names a file range past the end of the
  /// input: a range the input never had is a range the rewrite cannot account
  /// for, on either path, so the strip fails loudly naming the command. The
  /// containment test is overflow-safe: u64 fields at or above 2^63 read as
  /// negative, and smaller values can still sum past 2^63 and wrap. This runs
  /// before either layout because the compacting rewrite can emit an output
  /// longer than its input (signature alignment padding), which would
  /// otherwise launder a past-the-end input range into looking valid to the
  /// output audit.
  void _throwOnInputRangesPastEnd() {
    for (final lc in commands) {
      for (final range in accountedRangesOf(lc)) {
        if (range.size == 0) continue;
        if (!rangeWithinFile(range.offset, range.size, input.length)) {
          throw FormatException(
            'Cannot strip local symbols: ${describeStripCommand(lc)} points '
            'past the end of the file.',
          );
        }
      }
    }
  }

  /// Rewrites the symbol tables in place (no `__LINKEDIT` segment to
  /// resize): the compacted tables must fit where the old ones were, and the
  /// freed tail is zeroed. Used only for binaries without a `__LINKEDIT`
  /// segment.
  StrippedSymbols _layInPlace(_RemappedDysymtab? remapped) {
    final newSymtab = tables.symtab;
    final newStrings = tables.strings.bytes;
    final oldEnd = table.stroff + table.strsize;
    if (table.symoff + newSymtab.length + newStrings.length > oldEnd) {
      throw const FormatException(
        'Cannot strip local symbols without a __LINKEDIT segment to shrink.',
      );
    }
    _throwOnInPlaceOverlap(remapped);
    final out = Uint8List.fromList(input);
    out.setRange(table.symoff, table.symoff + newSymtab.length, newSymtab);
    final newStroff = table.symoff + newSymtab.length;
    out.setRange(newStroff, newStroff + newStrings.length, newStrings);
    out.fillRange(newStroff + newStrings.length, oldEnd, 0);
    if (remapped?.indirectBytes != null) {
      out.setRange(
        remapped!.indirectOffset,
        remapped.indirectOffset + remapped.indirectBytes!.length,
        remapped.indirectBytes!,
      );
    }
    final stripped = StrippedSymbols(
      out,
      _commandsFor(
        (
          symoff: table.symoff,
          nsyms: newSymtab.length ~/ 16,
          stroff: newStroff,
          strsize: newStrings.length,
        ),
        remapped,
        remapped?.indirectOffset ?? 0,
        null,
        null,
        input.length,
      ),
    );
    auditOutputRanges(
      stripped.commands,
      RewrittenLayout(linkeditOff: 0, fileLength: out.length),
    );
    return stripped;
  }

  /// Throws when any load command besides the rewritten symbol, string and
  /// indirect-symbol tables names bytes the in-place rewrite touches: the
  /// compacted tables and their zeroed tail must belong to those tables
  /// alone, or the rewrite would wipe a resident payload the way the
  /// compacting path refuses to. Segments and their sections ride an in-place
  /// rewrite untouched (the file keeps its length, so their ranges stay
  /// valid), and the indirect table can only live where the old tables were
  /// not. The rewritten tables must also never overlap each other.
  void _throwOnInPlaceOverlap(_RemappedDysymtab? remapped) {
    final oldEnd = table.stroff + table.strsize;
    final oldSize = oldEnd - table.symoff;
    final indirectLen = remapped?.indirectBytes?.length ?? 0;
    final indirectOff = remapped?.indirectOffset ?? 0;
    for (var i = 0; i < commands.length; i++) {
      final lc = commands[i];
      if (lc.cmd == lcSymtab || lc.cmd == lcSegment64 || i == dysymtabIndex) {
        continue;
      }
      for (final range in accountedRangesOf(lc)) {
        if (range.size == 0) continue;
        if (rangesIntersect(
              range.offset,
              range.size,
              table.symoff,
              oldSize,
            ) ||
            (indirectLen > 0 &&
                rangesIntersect(
                  range.offset,
                  range.size,
                  indirectOff,
                  indirectLen,
                ))) {
          throw FormatException(
            'Cannot strip local symbols: ${describeStripCommand(lc)} names '
            'bytes the stripped tables occupy; refusing to strip without a '
            '__LINKEDIT segment.',
          );
        }
      }
    }
    if (remapped == null || remapped.indirectBytes == null) return;
    final newStrOff = table.symoff + tables.symtab.length;
    if (rangesIntersect(
          remapped.indirectOffset,
          remapped.indirectBytes!.length,
          table.symoff,
          oldSize,
        ) ||
        rangesIntersect(
          remapped.indirectOffset,
          remapped.indirectBytes!.length,
          newStrOff,
          tables.strings.bytes.length,
        )) {
      throw FormatException(
        'Cannot strip local symbols: load command '
        '0x${lcDysymtab.toRadixString(16)} names bytes the stripped tables '
        'occupy; refusing to strip without a __LINKEDIT segment.',
      );
    }
  }

  /// Rebuilds `__LINKEDIT` from the linkedit file offset: the compacted
  /// symbol table, the compacted string table, then every other linkedit
  /// payload in file order, and truncates the file after the last one.
  StrippedSymbols _layCompacting(
    LoadCommand linkedit,
    _RemappedDysymtab? remapped,
  ) {
    final linkeditBd = ByteData.sublistView(linkedit.bytes);
    final linkeditOff = linkeditBd.getUint64(40, Endian.little).toInt();
    _checkNoPayloadPastLinkedit(commands, linkedit, linkeditOff);
    final symPayload = _LinkeditPayload(
      oldOffset: table.symoff,
      oldSize: table.nsyms * 16,
      bytes: tables.symtab,
    );
    final strPayload = _LinkeditPayload(
      oldOffset: table.stroff,
      oldSize: table.strsize,
      bytes: tables.strings.bytes,
    );
    final payloads = <_LinkeditPayload>[symPayload, strPayload];
    _LinkeditPayload? indirectPayload;
    if (remapped?.indirectBytes != null) {
      indirectPayload = _LinkeditPayload(
        oldOffset: remapped!.indirectOffset,
        oldSize: remapped.indirectCount * 4,
        bytes: remapped.indirectBytes!,
      );
      payloads.add(indirectPayload);
    }
    _collectTablePayloads(input, commands, payloads, linkeditOff);
    _alignSignaturePayload(commands, payloads);
    _throwOnUnmovedLinkeditRanges(commands, linkeditOff);
    final newLinkeditSize = _layoutLinkeditPayloads(
      payloads,
      linkeditOff,
      input.length,
    );

    final out = Uint8List(linkeditOff + newLinkeditSize);
    out.setRange(0, linkeditOff, input);
    final moved = <int, int>{};
    for (final payload in payloads) {
      out.setRange(
        payload.newOffset,
        payload.newOffset + payload.bytes.length,
        payload.bytes,
      );
      moved[payload.oldOffset] = payload.newOffset;
    }
    final stripped = StrippedSymbols(
      out,
      _commandsFor(
        (
          symoff: symPayload.newOffset,
          nsyms: tables.symtab.length ~/ 16,
          stroff: strPayload.newOffset,
          strsize: tables.strings.bytes.length,
        ),
        remapped,
        indirectPayload?.newOffset ?? 0,
        moved,
        (linkedit, newLinkeditSize),
        input.length,
      ),
    );
    auditOutputRanges(
      stripped.commands,
      RewrittenLayout(linkeditOff: linkeditOff, fileLength: out.length),
    );
    return stripped;
  }

  /// Returns [commands] with the stripped table positions applied: a rebuilt
  /// `LC_SYMTAB` from [geometry], the regrouped `LC_DYSYMTAB`, moved table
  /// data offsets from [movedOffsets] (null keeps every offset: the in-place
  /// rewrite), and a resized `__LINKEDIT` segment when [resizedLinkedit] is
  /// given. [fileLength] is the input file's length: a note payload must name
  /// bytes inside it before its offset is relocated.
  List<LoadCommand> _commandsFor(
    ({int symoff, int nsyms, int stroff, int strsize}) geometry,
    _RemappedDysymtab? remapped,
    int newIndirectOff,
    Map<int, int>? movedOffsets,
    (LoadCommand, int)? resizedLinkedit,
    int fileLength,
  ) {
    final updated = <LoadCommand>[];
    var seenSymtab = false;
    var seenDysymtab = false;
    for (var i = 0; i < commands.length; i++) {
      final lc = commands[i];
      if (i == symtabIndex && !seenSymtab) {
        seenSymtab = true;
        updated.add(
          buildLcSymtab(
            symoff: geometry.symoff,
            nsyms: geometry.nsyms,
            stroff: geometry.stroff,
            strsize: geometry.strsize,
          ),
        );
        continue;
      }
      if (i == dysymtabIndex && remapped != null && !seenDysymtab) {
        seenDysymtab = true;
        final bytes = Uint8List.fromList(remapped.commandBytes);
        if (remapped.indirectBytes != null) {
          ByteData.sublistView(
            bytes,
          ).setUint32(56, newIndirectOff, Endian.little);
        }
        updated.add(LoadCommand(lc.cmd, bytes));
        continue;
      }
      if (resizedLinkedit != null && identical(lc, resizedLinkedit.$1)) {
        final bytes = Uint8List.fromList(lc.bytes);
        final bd = ByteData.sublistView(bytes);
        bd.setUint64(48, resizedLinkedit.$2, Endian.little); // filesize
        bd.setUint64(32, resizedLinkedit.$2, Endian.little); // vmsize
        updated.add(LoadCommand(lc.cmd, bytes));
        continue;
      }
      if (movedOffsets != null && movedTableRanges(lc).isNotEmpty) {
        updated.add(_relocatedTableCommand(lc, movedOffsets));
        continue;
      }
      if (movedOffsets != null && lc.cmd == lcNote) {
        updated.add(relocatedNoteCommand(lc, movedOffsets, fileLength));
        continue;
      }
      updated.add(lc);
    }
    return updated;
  }
}

/// Returns [lc] with every non-empty table range relocated through
/// [movedOffsets]: all five pairs for `LC_DYLD_INFO`/`LC_DYLD_INFO_ONLY`,
/// the single pair for the other linkedit table commands.
///
/// Throws [FormatException] when a non-empty range has no new offset: the
/// fail-closed scan should have refused such a command already.
LoadCommand _relocatedTableCommand(LoadCommand lc, Map<int, int> movedOffsets) {
  final bytes = Uint8List.fromList(lc.bytes);
  final bd = ByteData.sublistView(bytes);
  for (final range in movedTableRanges(lc)) {
    if (range.size == 0) continue;
    final fresh = movedOffsets[range.offset];
    if (fresh == null) {
      throw FormatException(
        'Cannot strip local symbols: load command '
        '0x${lc.cmd.toRadixString(16)} points at bytes the rewrite reused.',
      );
    }
    bd.setUint32(range.field, fresh, Endian.little);
  }
  return LoadCommand(lc.cmd, bytes);
}
