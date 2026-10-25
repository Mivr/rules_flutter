import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../macho_edit.dart' as macho;
import '../macho_constants.dart' as macho;
import '../macho_fat.dart' as macho;
import '../macho_framework.dart' as macho;
import '../macho_parse.dart' as macho;
import '../macho_patch.dart' as macho;
import '../macho_ranges.dart' as macho;
import '../macho_strip.dart' as macho;
import '../macho_stub.dart' as macho;

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _readCString(Uint8List bytes, int start) {
  var end = start;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(start, end));
}

/// Builds a minimal valid stored (uncompressed) ZIP from [files] and
/// [symlinks] (link path to target), with Unix modes matching the framework
/// producer (`0100644` files, `0120777` links). For
/// `extractFrameworkZip` unit coverage, including hostile names.
Uint8List _storedZip(
  Map<String, List<int>> files, {
  Map<String, String> symlinks = const {},
}) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final names = [...files.keys, ...symlinks.keys]..sort();
  var offset = 0;
  for (final name in names) {
    final isLink = symlinks.containsKey(name);
    final payload = isLink ? utf8.encode(symlinks[name]!) : files[name]!;
    final nameBytes = utf8.encode(name);
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint32(14, 0, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, payload.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    local.add(lh.buffer.asUint8List());
    local.add(nameBytes);
    local.add(payload);
    final mode = isLink ? 0xA1FF : 0x81A4;
    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0, Endian.little)
      ..setUint32(16, 0, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, payload.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, mode << 16, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central.add(ch.buffer.asUint8List());
    central.add(nameBytes);
    offset += 30 + nameBytes.length + payload.length;
  }
  final centralBytes = central.toBytes();
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, names.length, Endian.little)
    ..setUint16(10, names.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  return Uint8List.fromList([
    ...local.toBytes(),
    ...centralBytes,
    ...eocd.buffer.asUint8List(),
  ]);
}

/// Builds a synthetic 64-bit Mach-O binary with an embedded `LC_CODE_SIGNATURE`
/// (`CS_SuperBlob` + `CS_CodeDirectory` with SHA-256 4096-byte page hashes)
/// at offset 0x2000 (spanning 2 code pages of 0x1000 bytes each).
Uint8List _buildSignedMachO({
  bool includeLegacyVersionMin = false,
  String installName = '@rpath/Old.framework/Old',
}) {
  const pageSize = 0x1000;
  const codeLimit = 0x2000; // 2 pages

  // Build CS_CodeDirectory (44-byte header + identifier "test\0" + 2 * 32-byte hashes)
  final ident = ascii.encode('test\x00');
  const cdHeaderSize = 44;
  final hashOffset = cdHeaderSize + ident.length;
  const nCodeSlots = 2;
  final cdLength = hashOffset + nCodeSlots * 32;

  // CS_SuperBlob: 12-byte header + 1 * 8-byte BlobIndex + CS_CodeDirectory
  final superLength = 12 + 8 + cdLength;
  final alignedSigSize = (superLength + 15) & ~15;
  final totalSize = codeLimit + alignedSigSize;

  final buf = Uint8List(totalSize);
  final bd = ByteData.sublistView(buf);

  // Fill page 1 (0x1000..0x2000) with deterministic code bytes.
  for (var i = pageSize; i < codeLimit; i++) {
    buf[i] = (i * 31 + 7) & 0xff;
  }

  // LC_SEGMENT_64 (__TEXT) covering 0..0x2000
  final textSeg = Uint8List(72);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, macho.lcSegment64, Endian.little);
  textBd.setUint32(4, 72, Endian.little);
  textSeg.setRange(8, 14, ascii.encode('__TEXT'));
  textBd.setUint64(24, 0, Endian.little);
  textBd.setUint64(32, codeLimit, Endian.little);
  textBd.setUint64(40, 0, Endian.little);
  textBd.setUint64(48, codeLimit, Endian.little);
  textBd.setUint32(56, 5, Endian.little);
  textBd.setUint32(60, 5, Endian.little);

  // LC_SEGMENT_64 (__LINKEDIT) covering 0x2000..totalSize
  final linkeditSeg = Uint8List(72);
  final linkeditBd = ByteData.sublistView(linkeditSeg);
  linkeditBd.setUint32(0, macho.lcSegment64, Endian.little);
  linkeditBd.setUint32(4, 72, Endian.little);
  linkeditSeg.setRange(8, 18, ascii.encode('__LINKEDIT'));
  linkeditBd.setUint64(24, codeLimit, Endian.little);
  linkeditBd.setUint64(32, alignedSigSize, Endian.little);
  linkeditBd.setUint64(40, codeLimit, Endian.little);
  linkeditBd.setUint64(48, alignedSigSize, Endian.little);
  linkeditBd.setUint32(56, 1, Endian.little);
  linkeditBd.setUint32(60, 1, Endian.little);

  final commands = <macho.LoadCommand>[
    macho.LoadCommand(macho.lcSegment64, textSeg),
    macho.LoadCommand(macho.lcSegment64, linkeditSeg),
    macho.buildLcIdDylib(installName),
  ];

  if (includeLegacyVersionMin) {
    final legacy = Uint8List(16);
    final lbd = ByteData.sublistView(legacy);
    lbd.setUint32(0, macho.lcVersionMinIphoneos, Endian.little);
    lbd.setUint32(4, 16, Endian.little);
    lbd.setUint32(8, 0x000b0000, Endian.little); // 11.0
    lbd.setUint32(12, 0x000b0000, Endian.little);
    commands.add(macho.LoadCommand(macho.lcVersionMinIphoneos, legacy));
  }

  // LC_CODE_SIGNATURE pointing to offset 0x2000
  final codeSigLc = Uint8List(16);
  final csLcBd = ByteData.sublistView(codeSigLc);
  csLcBd.setUint32(0, macho.lcCodeSignature, Endian.little);
  csLcBd.setUint32(4, 16, Endian.little);
  csLcBd.setUint32(8, codeLimit, Endian.little);
  csLcBd.setUint32(12, superLength, Endian.little);
  commands.add(macho.LoadCommand(macho.lcCodeSignature, codeSigLc));

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  bd.setUint32(0, macho.mhMagic64, Endian.little);
  bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
  bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
  bd.setUint32(28, 0, Endian.little);

  var off = macho.mhHeaderSize64;
  for (final lc in commands) {
    buf.setRange(off, off + lc.cmdsize, lc.bytes);
    off += lc.cmdsize;
  }

  // Write CS_SuperBlob at codeLimit (0x2000).
  bd.setUint32(codeLimit, macho.csMagicEmbeddedSignature, Endian.big);
  bd.setUint32(codeLimit + 4, superLength, Endian.big);
  bd.setUint32(codeLimit + 8, 1, Endian.big); // count = 1
  bd.setUint32(codeLimit + 12, 0, Endian.big); // type = CSSLOT_CODEDIRECTORY
  bd.setUint32(codeLimit + 16, 20, Endian.big); // offset = 20

  final cdOff = codeLimit + 20;
  bd.setUint32(cdOff, macho.csMagicCodeDirectory, Endian.big);
  bd.setUint32(cdOff + 4, cdLength, Endian.big);
  bd.setUint32(cdOff + 8, 0x20400, Endian.big); // version
  bd.setUint32(
    cdOff + 12,
    0x20002,
    Endian.big,
  ); // flags = adhoc | linker-signed
  bd.setUint32(cdOff + 16, hashOffset, Endian.big);
  bd.setUint32(cdOff + 20, cdHeaderSize, Endian.big); // identOffset
  bd.setUint32(cdOff + 24, 0, Endian.big); // nSpecialSlots
  bd.setUint32(cdOff + 28, nCodeSlots, Endian.big);
  bd.setUint32(cdOff + 32, codeLimit, Endian.big);
  bd.setUint8(cdOff + 36, 32); // hashSize = 32
  bd.setUint8(cdOff + 37, macho.csHashTypeSha256); // hashType = SHA-256
  bd.setUint8(cdOff + 38, 0); // platform
  bd.setUint8(cdOff + 39, 12); // pageSizeShift = 12 (4096 bytes)
  bd.setUint32(cdOff + 40, 0, Endian.big); // spare2
  buf.setRange(
    cdOff + cdHeaderSize,
    cdOff + cdHeaderSize + ident.length,
    ident,
  );

  // Fill initial hashes with zeroes so we can verify _resignEmbeddedCodeSignature
  // updates them to the real SHA-256 digests.
  return buf;
}

String? _resolveHermeticTool(String envVar) {
  final rel = Platform.environment[envVar];
  if (rel == null || rel.isEmpty) return null;
  if (File(rel).existsSync()) return File(rel).absolute.path;
  final runfilesDir =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesDir != null) {
    for (final candidate in [
      '$runfilesDir/$rel',
      '$runfilesDir/_main/$rel',
    ]) {
      if (File(candidate).existsSync()) return File(candidate).absolute.path;
    }
  }
  return null;
}

/// Builds a synthetic 32-bit little-endian Mach-O header (`MH_MAGIC = 0xfeedface`).
Uint8List _buildMachO32({int cputype = macho.cpuTypeArm}) {
  final buf = Uint8List(64);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, macho.mhMagic32, Endian.little);
  bd.setUint32(4, cputype, Endian.little);
  bd.setUint32(8, 9, Endian.little); // cpusubtype = ARM_V7
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, 0, Endian.little); // ncmds = 0
  bd.setUint32(20, 0, Endian.little); // sizeofcmds = 0
  bd.setUint32(
    24,
    macho.mhNoundefs | macho.mhDyldlink | macho.mhTwolevel,
    Endian.little,
  );
  return buf;
}

/// Builds a synthetic 64-bit Mach-O exercising every load-command kind the
/// patcher rewrites or scans: a `__TEXT` segment with one section (file bytes
/// at 0x1000), a `__LINKEDIT` segment, `LC_SYMTAB`/`LC_DYSYMTAB`, the four
/// linkedit table commands (`LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`,
/// `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`), all four legacy
/// `LC_VERSION_MIN_*` commands, and `LC_ID_DYLIB` (but no `LC_BUILD_VERSION`
/// or `LC_RPATH`, so the patcher takes the add paths for those).
Uint8List _buildFullCoverageMachO() {
  Uint8List tableCommand(int cmd, int dataoff, int datasize) {
    final buf = Uint8List(16);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, cmd, Endian.little);
    bd.setUint32(4, 16, Endian.little);
    bd.setUint32(8, dataoff, Endian.little);
    bd.setUint32(12, datasize, Endian.little);
    return buf;
  }

  Uint8List versionMin(int cmd) {
    final buf = Uint8List(16);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, cmd, Endian.little);
    bd.setUint32(4, 16, Endian.little);
    bd.setUint32(8, 0x000b0000, Endian.little);
    bd.setUint32(12, 0x000b0000, Endian.little);
    return buf;
  }

  // `__TEXT` segment with one `section_64` (80 bytes at command offset 72).
  final textSeg = Uint8List(72 + 80);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, macho.lcSegment64, Endian.little);
  textBd.setUint32(4, 152, Endian.little);
  textSeg.setRange(8, 8 + '__TEXT'.length, ascii.encode('__TEXT'));
  textBd.setUint64(24, 0, Endian.little);
  textBd.setUint64(32, 0x4000, Endian.little);
  textBd.setUint64(40, 0, Endian.little);
  textBd.setUint64(48, 0x4000, Endian.little);
  textBd.setUint32(56, 5, Endian.little);
  textBd.setUint32(60, 5, Endian.little);
  textBd.setUint32(64, 1, Endian.little);
  textSeg.setRange(72, 72 + '__text'.length, ascii.encode('__text'));
  textSeg.setRange(
    72 + 16,
    72 + 16 + '__TEXT'.length,
    ascii.encode('__TEXT'),
  );
  textBd.setUint64(72 + 32, 0x100, Endian.little);
  textBd.setUint64(72 + 40, 0x200, Endian.little);
  textBd.setUint32(72 + 48, 0x1000, Endian.little);
  textBd.setUint32(72 + 52, 2, Endian.little);

  final commands = <Uint8List>[
    textSeg,
    macho.buildLcSegment64((
      segname: '__LINKEDIT',
      vmaddr: 0x4000,
      vmsize: 0x1000,
      fileoff: 0x4000,
      filesize: 0x1000,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )).bytes,
    macho
        .buildLcSymtab(symoff: 0x4000, nsyms: 2, stroff: 0x4020, strsize: 0x20)
        .bytes,
    macho.buildLcDysymtab().bytes,
    tableCommand(macho.lcFunctionStarts, 0x4100, 0x10),
    tableCommand(macho.lcDataInCode, 0x4110, 0x10),
    tableCommand(macho.lcDyldExportsTrie, 0x4120, 0x10),
    tableCommand(macho.lcDyldChainedFixups, 0x4130, 0x10),
    versionMin(macho.lcVersionMinMacosx),
    versionMin(macho.lcVersionMinIphoneos),
    versionMin(macho.lcVersionMinTvos),
    versionMin(macho.lcVersionMinWatchos),
    macho.buildLcIdDylib('@rpath/Old.framework/Old').bytes,
  ];

  var sizeofcmds = 0;
  for (final c in commands) {
    sizeofcmds += c.length;
  }
  const fileSize = 0x5000;
  final buf = Uint8List(fileSize);
  for (var i = 0; i < fileSize; i++) {
    buf[i] = (i * 31 + 7) & 0xff;
  }
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, macho.mhMagic64, Endian.little);
  bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
  bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
  bd.setUint32(28, 0, Endian.little);
  var off = macho.mhHeaderSize64;
  for (final c in commands) {
    buf.setRange(off, off + c.length, c);
    off += c.length;
  }
  return buf;
}

/// Appends [value] as ULEB128 to [out].
void _writeUleb(BytesBuilder out, int value) {
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

/// Builds the export trie under test: `_kDartSnapshotData` at 0x5000 and
/// `_kDartSnapshotText` at 0x4000 sharing the `_kDartSnapshot` edge, matching
/// the `n_value`s in [_buildUnstrippedDylib].
Uint8List _buildSnapshotExportsTrie() {
  // Every node is terminalSize, terminal bytes, childCount, children, so a
  // leaf terminal ends with an explicit zero child count.
  List<int> terminal(int address) {
    final out = BytesBuilder(copy: false)..addByte(0);
    _writeUleb(out, 0); // flags
    _writeUleb(out, address);
    final bytes = out.toBytes();
    return [bytes.length - 1, ...bytes.sublist(1), 0];
  }

  final nodeA = terminal(0x5000);
  final nodeB = terminal(0x4000);
  final edge0 = utf8.encode('_kDartSnapshot\x00');
  final edgeA = utf8.encode('Data\x00');
  final edgeB = utf8.encode('Text\x00');
  // Child offsets are absolute from the trie start.
  final offNode1 = 2 + edge0.length + 1;
  final offA = offNode1 + 2 + edgeA.length + 1 + edgeB.length + 1;
  final offB = offA + nodeA.length;
  assert(offB < 128, 'child offsets must stay single ULEB bytes');
  final node1 = BytesBuilder(copy: false)
    ..addByte(0) // terminalSize = 0
    ..addByte(2) // two children
    ..add(edgeA)
    ..addByte(offA)
    ..add(edgeB)
    ..addByte(offB);
  final node0 = BytesBuilder(copy: false)
    ..addByte(0) // terminalSize = 0
    ..addByte(1) // one child
    ..add(edge0)
    ..addByte(offNode1); // node1 starts after this node
  return Uint8List.fromList([
    ...node0.toBytes(),
    ...node1.toBytes(),
    ...nodeA,
    ...nodeB,
  ]);
}

/// Builds a synthetic arm64 dylib with a gen_snapshot-style symbol table:
/// two local text symbols, `N_FUN`/`N_SO` stab entries naming `MyApp`, two
/// exported globals, one undefined import, an export trie naming the
/// exports, and a three-entry indirect table (a kept export, a dropped
/// local, and an `INDIRECT_SYMBOL_LOCAL` entry).
///
/// Returns the binary and the file offsets of its symbol table, string
/// table, indirect table and export trie for the assertions.
({
  Uint8List bytes,
  int symoff,
  int stroff,
  int strsize,
  int indirectoff,
  int trieoff,
  int triesize,
})
_buildUnstrippedDylib() {
  const names = [
    '_myLocal',
    '_otherLocal',
    '_MyApp.build',
    'MyApp.dart',
    '_kDartSnapshotText',
    '_kDartSnapshotData',
    '_printf',
  ];
  // N_SECT locals, N_FUN/N_SO stabs, N_SECT|N_EXT exports, N_UNDF|N_EXT import.
  const types = [0x0e, 0x0e, 0x24, 0x64, 0x0f, 0x0f, 0x01];
  const sects = [1, 1, 1, 0, 1, 1, 0];
  const values = [0x1000, 0x1100, 0x1200, 0, 0x4000, 0x5000, 0];

  final strings = BytesBuilder(copy: false)..addByte(0);
  final strx = <int>[];
  for (final name in names) {
    strx.add(strings.length);
    strings.add(utf8.encode(name));
    strings.addByte(0);
  }
  final strBytes = strings.toBytes();
  final symBytes = BytesBuilder(copy: false);
  for (var i = 0; i < names.length; i++) {
    final entry = ByteData(16)
      ..setUint32(0, strx[i], Endian.little)
      ..setUint8(4, types[i])
      ..setUint8(5, sects[i])
      ..setUint16(6, 0, Endian.little)
      ..setUint64(8, values[i], Endian.little);
    symBytes.add(entry.buffer.asUint8List());
  }

  final trie = _buildSnapshotExportsTrie();
  // Indirect entries: the kept `_kDartSnapshotText` (old index 4), the
  // dropped `_myLocal` (old index 0), and a LOCAL entry naming no index.
  final indirect = ByteData(12)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, 0, Endian.little)
    ..setUint32(8, macho.indirectSymbolLocal, Endian.little);

  // `__TEXT` with one `__text` section so `n_sect = 1` resolves.
  final textSeg = Uint8List(72 + 80);
  final textBd = ByteData.sublistView(textSeg);
  textBd.setUint32(0, macho.lcSegment64, Endian.little);
  textBd.setUint32(4, 152, Endian.little);
  textSeg.setRange(8, 8 + '__TEXT'.length, ascii.encode('__TEXT'));
  textBd.setUint64(24, 0, Endian.little);
  textBd.setUint64(32, 0x4000, Endian.little);
  textBd.setUint64(40, 0, Endian.little);
  textBd.setUint64(48, 0x400, Endian.little);
  textBd.setUint32(56, 5, Endian.little);
  textBd.setUint32(60, 5, Endian.little);
  textBd.setUint32(64, 1, Endian.little);
  textSeg.setRange(72, 72 + '__text'.length, ascii.encode('__text'));
  textSeg.setRange(
    72 + 16,
    72 + 16 + '__TEXT'.length,
    ascii.encode('__TEXT'),
  );
  textBd.setUint64(72 + 32, 0x1000, Endian.little);
  textBd.setUint64(72 + 40, 0x200, Endian.little);
  textBd.setUint32(72 + 48, 0x200, Endian.little);
  textBd.setUint32(72 + 52, 2, Endian.little);

  const symoff = 0x400;
  final symLen = symBytes.length;
  final stroff = symoff + symLen;
  final indirectoff = (stroff + strBytes.length + 3) & ~3;
  final trieoff = indirectoff + indirect.lengthInBytes;
  final fileSize = trieoff + trie.length;
  final linkSize = fileSize - symoff;

  final dysymtab = ByteData(80)
    ..setUint32(0, macho.lcDysymtab, Endian.little)
    ..setUint32(4, 80, Endian.little)
    ..setUint32(8, 0, Endian.little) // ilocalsym
    ..setUint32(12, 4, Endian.little) // nlocalsym
    ..setUint32(16, 4, Endian.little) // iextdefsym
    ..setUint32(20, 2, Endian.little) // nextdefsym
    ..setUint32(24, 6, Endian.little) // iundefsym
    ..setUint32(28, 1, Endian.little) // nundefsym
    ..setUint32(56, indirectoff, Endian.little) // indirectsymoff
    ..setUint32(60, 3, Endian.little); // nindirectsyms
  final exportsTrie = ByteData(16)
    ..setUint32(0, macho.lcDyldExportsTrie, Endian.little)
    ..setUint32(4, 16, Endian.little)
    ..setUint32(8, trieoff, Endian.little)
    ..setUint32(12, trie.length, Endian.little);

  final commands = <Uint8List>[
    textSeg,
    macho.buildLcSegment64((
      segname: '__LINKEDIT',
      vmaddr: 0x4000,
      vmsize: linkSize,
      fileoff: symoff,
      filesize: linkSize,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )).bytes,
    macho
        .buildLcSymtab(
          symoff: symoff,
          nsyms: names.length,
          stroff: stroff,
          strsize: strBytes.length,
        )
        .bytes,
    dysymtab.buffer.asUint8List(),
    exportsTrie.buffer.asUint8List(),
    macho.buildLcIdDylib('@rpath/Strip.dylib').bytes,
  ];

  var sizeofcmds = 0;
  for (final c in commands) {
    sizeofcmds += c.length;
  }
  final buf = Uint8List(fileSize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, macho.mhMagic64, Endian.little);
  bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
  bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
  bd.setUint32(12, macho.mhDylib, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
  bd.setUint32(28, 0, Endian.little);
  var off = macho.mhHeaderSize64;
  for (final c in commands) {
    buf.setRange(off, off + c.length, c);
    off += c.length;
  }
  buf.setRange(symoff, symoff + symLen, symBytes.toBytes());
  buf.setRange(stroff, stroff + strBytes.length, strBytes);
  buf.setRange(
    indirectoff,
    indirectoff + indirect.lengthInBytes,
    indirect.buffer.asUint8List(),
  );
  buf.setRange(trieoff, trieoff + trie.length, trie);
  return (
    bytes: buf,
    symoff: symoff,
    stroff: stroff,
    strsize: strBytes.length,
    indirectoff: indirectoff,
    trieoff: trieoff,
    triesize: trie.length,
  );
}

/// Reads the symbol names and `n_type` bytes of the `LC_SYMTAB` in [bytes].
({List<String> names, List<int> types}) _readTestSymtab(Uint8List bytes) {
  final lc = macho
      .parseLoadCommands(bytes)
      .singleWhere((c) => c.cmd == macho.lcSymtab);
  final bd = ByteData.sublistView(lc.bytes);
  final symoff = bd.getUint32(8, Endian.little);
  final nsyms = bd.getUint32(12, Endian.little);
  final stroff = bd.getUint32(16, Endian.little);
  final names = <String>[];
  final types = <int>[];
  for (var i = 0; i < nsyms; i++) {
    final entry = ByteData.sublistView(
      bytes,
      symoff + i * 16,
      symoff + (i + 1) * 16,
    );
    names.add(_readCString(bytes, stroff + entry.getUint32(0, Endian.little)));
    types.add(entry.getUint8(4));
  }
  return (names: names, types: types);
}

/// Reads the six `LC_DYSYMTAB` index groups of [bytes] in command order.
List<int> _readTestDysymtabGroups(Uint8List bytes) {
  final lc = macho
      .parseLoadCommands(bytes)
      .singleWhere((c) => c.cmd == macho.lcDysymtab);
  final bd = ByteData.sublistView(lc.bytes);
  return [for (var at = 8; at < 32; at += 4) bd.getUint32(at, Endian.little)];
}

/// Reads the indirect symbol entries of [bytes].
List<int> _readTestIndirect(Uint8List bytes) {
  final lc = macho
      .parseLoadCommands(bytes)
      .singleWhere((c) => c.cmd == macho.lcDysymtab);
  final bd = ByteData.sublistView(lc.bytes);
  final off = bd.getUint32(56, Endian.little);
  final count = bd.getUint32(60, Endian.little);
  final table = ByteData.sublistView(bytes, off, off + count * 4);
  return [
    for (var i = 0; i < count; i++) table.getUint32(i * 4, Endian.little),
  ];
}

/// Copies the dylib in [bytes] with a local-relocation count, so the
/// local-symbol strip refuses it like a real dylib carrying relocations.
Uint8List _withLocalRelocations(Uint8List bytes) {
  final out = Uint8List.fromList(bytes);
  var off = macho.mhHeaderSize64;
  for (final lc in macho.parseLoadCommands(bytes)) {
    if (lc.cmd == macho.lcDysymtab) {
      ByteData.sublistView(
        out,
        off,
        off + lc.cmdsize,
      ).setUint32(76, 1, Endian.little);
      return out;
    }
    off += lc.cmdsize;
  }
  throw StateError('Test dylib has no LC_DYSYMTAB to refuse stripping.');
}

void main() {
  group('sha256', () {
    test('matches FIPS 180-4 test vectors', () {
      expect(
        _hex(macho.sha256(Uint8List(0))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        _hex(macho.sha256(Uint8List.fromList(ascii.encode('abc')))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        _hex(
          macho.sha256(
            Uint8List.fromList(
              ascii.encode(
                'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
              ),
            ),
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });
  });

  group('parsePackedVersion', () {
    test('packs major.minor.patch into uint32', () {
      expect(macho.parsePackedVersion('13.0'), 0x000d0000);
      expect(macho.parsePackedVersion('16.2.1'), 0x00100201);
      expect(macho.parsePackedVersion('10.15'), 0x000a0f00);
    });
  });

  group('generateStubMachO', () {
    test('synthesizes well-formed arm64 iOS stub dylib with segments, symtab, UUID, and flags', () {
      final bytes = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      expect(macho.isMachO64(bytes), isTrue);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(4, Endian.little), macho.cpuTypeArm64);
      expect(bd.getUint32(12, Endian.little), macho.mhDylib);
      final flags = bd.getUint32(24, Endian.little);
      expect(
        flags,
        macho.mhNoundefs |
            macho.mhDyldlink |
            macho.mhTwolevel |
            macho.mhNoReexportedDylibs,
      );

      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.map((c) => c.cmd), [
        macho.lcSegment64, // __TEXT
        macho.lcSegment64, // __LINKEDIT
        macho.lcIdDylib,
        macho.lcSymtab,
        macho.lcDysymtab,
        macho.lcUuid,
        macho.lcBuildVersion,
      ]);

      // Verify __TEXT segment.
      expect(_readCString(cmds[0].bytes, 8), '__TEXT');
      final textBd = ByteData.sublistView(cmds[0].bytes);
      expect(textBd.getUint64(24, Endian.little), 0); // vmaddr
      expect(textBd.getUint64(32, Endian.little), 0x4000); // vmsize
      expect(textBd.getUint64(40, Endian.little), 0); // fileoff
      expect(textBd.getUint64(48, Endian.little), 0x4000); // filesize
      expect(textBd.getUint32(56, Endian.little), 5); // maxprot = r-x
      expect(textBd.getUint32(60, Endian.little), 5); // initprot = r-x

      // Verify __LINKEDIT segment.
      expect(_readCString(cmds[1].bytes, 8), '__LINKEDIT');
      final linkeditBd = ByteData.sublistView(cmds[1].bytes);
      expect(linkeditBd.getUint64(24, Endian.little), 0x4000); // vmaddr
      expect(linkeditBd.getUint64(32, Endian.little), 0x4000); // vmsize
      expect(linkeditBd.getUint64(40, Endian.little), 0x4000); // fileoff
      expect(linkeditBd.getUint64(48, Endian.little), 8); // filesize
      expect(linkeditBd.getUint32(56, Endian.little), 1); // maxprot = r--
      expect(linkeditBd.getUint32(60, Endian.little), 1); // initprot = r--

      // Verify LC_ID_DYLIB.
      final idLc = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(_readCString(idLc.bytes, 24), '@rpath/App.framework/App');

      // Verify LC_SYMTAB points into __LINKEDIT.
      final symtabLc = cmds.singleWhere((c) => c.cmd == macho.lcSymtab);
      final symtabBd = ByteData.sublistView(symtabLc.bytes);
      expect(symtabBd.getUint32(8, Endian.little), 0x4000); // symoff
      expect(symtabBd.getUint32(12, Endian.little), 0); // nsyms
      expect(symtabBd.getUint32(16, Endian.little), 0x4000); // stroff
      expect(symtabBd.getUint32(20, Endian.little), 8); // strsize

      // Verify LC_DYSYMTAB is 80 bytes.
      final dysymtabLc = cmds.singleWhere((c) => c.cmd == macho.lcDysymtab);
      expect(dysymtabLc.cmdsize, 80);

      // Verify LC_UUID is non-zero, deterministic, and content-derived.
      final uuidLc = cmds.singleWhere((c) => c.cmd == macho.lcUuid);
      final uuidBytes = uuidLc.bytes.sublist(8, 24);
      expect(uuidBytes.any((b) => b != 0), isTrue);

      final bytesSame = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('13.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      expect(_hex(bytes), _hex(bytesSame));

      final bytesDiffContent = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('16.2'),
        installName: '@rpath/App.framework/App',
      );
      final uuidDiff = macho
          .parseLoadCommands(bytesDiffContent)
          .singleWhere((c) => c.cmd == macho.lcUuid)
          .bytes
          .sublist(8, 24);
      expect(_hex(uuidBytes), isNot(_hex(uuidDiff)));

      // Verify LC_BUILD_VERSION.
      final bvLc = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvLc.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIos);
      expect(bvBd.getUint32(12, Endian.little), 0x000d0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100200);
    });

    test('synthesizes valid x86_64 iOS simulator stub dylib', () {
      final bytes = macho.generateStubMachO(
        arch: 'x86_64',
        platform: macho.platformIosSimulator,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('15.0'),
        installName: '@rpath/App.framework/App',
      );
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(4, Endian.little), macho.cpuTypeX86_64);
      expect(bd.getUint32(8, Endian.little), macho.cpuSubtypeX86_64All);
      final cmds = macho.parseLoadCommands(bytes);
      final bvLc = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvLc.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIosSimulator);
      expect(bvBd.getUint32(12, Endian.little), 0x000e0000);
      expect(bvBd.getUint32(16, Endian.little), 0x000f0000);
    });

    test('hermetic llvm-objdump and llvm-otool accept generated stubs', () {
      final objdump = _resolveHermeticTool('LLVM_OBJDUMP');
      final otool = _resolveHermeticTool('LLVM_OTOOL');
      if (Platform.environment.containsKey('TEST_SRCDIR')) {
        expect(
          objdump,
          isNotNull,
          reason: 'LLVM_OBJDUMP must resolve in Bazel test',
        );
        expect(
          otool,
          isNotNull,
          reason: 'LLVM_OTOOL must resolve in Bazel test',
        );
      }
      if (objdump == null || otool == null) return;

      final tempDir = Directory.systemTemp.createTempSync('macho_llvm_stub_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      for (final arch in ['arm64', 'x86_64']) {
        final dylibPath = '${tempDir.path}/stub_$arch.dylib';
        File(dylibPath).writeAsBytesSync(
          macho.generateStubMachO(
            arch: arch,
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('12.3'),
            sdkVersion: macho.parsePackedVersion('14.1'),
            installName: '@rpath/App.framework/Versions/A/App',
          ),
        );

        final objdumpRes = Process.runSync(objdump, [
          '--macho',
          '--private-headers',
          '--dylib-id',
          dylibPath,
        ]);
        expect(objdumpRes.exitCode, 0, reason: '${objdumpRes.stderr}');
        final out = objdumpRes.stdout as String;
        expect(out, contains('NOUNDEFS'));
        expect(out, contains('DYLDLINK'));
        expect(out, contains('TWOLEVEL'));
        expect(out, contains('NO_REEXPORTED_DYLIBS'));
        expect(out, contains('segname __TEXT'));
        expect(out, contains('segname __LINKEDIT'));
        expect(out, contains('cmd LC_ID_DYLIB'));
        expect(out, contains('@rpath/App.framework/Versions/A/App'));
        expect(out, contains('cmd LC_SYMTAB'));
        expect(out, contains('cmd LC_DYSYMTAB'));
        expect(out, contains('cmd LC_UUID'));
        expect(out, contains('cmd LC_BUILD_VERSION'));
        expect(out, contains('platform macos'));
        expect(out, contains('minos 12.3'));
        expect(out, contains('sdk 14.1'));

        final otoolRes = Process.runSync(otool, ['-hv', '-l', '-L', dylibPath]);
        expect(otoolRes.exitCode, 0, reason: '${otoolRes.stderr}');
        expect(
          otoolRes.stdout as String,
          contains('NOUNDEFS DYLDLINK TWOLEVEL'),
        );
      }
    });
  });

  group('patchMachO', () {
    test('patches LC_BUILD_VERSION, LC_ID_DYLIB, LC_RPATH and re-signs LC_CODE_SIGNATURE', () {
      final input = _buildSignedMachO(includeLegacyVersionMin: true);
      final patched = macho.patchMachO(
        input,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('13.0'),
          sdkVersion: macho.parsePackedVersion('16.0'),
          installName: '@rpath/MyPlugin.framework/MyPlugin',
          rpaths: ['@executable_path/Frameworks', '@loader_path/Frameworks'],
        ),
      );

      final cmds = macho.parseLoadCommands(patched);
      // Legacy LC_VERSION_MIN_IPHONEOS must be stripped.
      expect(
        cmds.where((c) => c.cmd == macho.lcVersionMinIphoneos),
        isEmpty,
      );
      // LC_CODE_SIGNATURE must remain the final load command.
      expect(cmds.last.cmd, macho.lcCodeSignature);

      // Verify LC_ID_DYLIB was updated and 8-byte aligned.
      final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(idCmd.cmdsize % 8, 0);
      expect(
        _readCString(idCmd.bytes, 24),
        '@rpath/MyPlugin.framework/MyPlugin',
      );

      // Verify LC_BUILD_VERSION was added.
      final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvCmd.bytes);
      expect(bvBd.getUint32(8, Endian.little), macho.platformIos);
      expect(bvBd.getUint32(12, Endian.little), 0x000d0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100000);

      // Verify LC_RPATH commands were added and deduplicated on second patch.
      final rpathCmds = cmds.where((c) => c.cmd == macho.lcRpath).toList();
      expect(rpathCmds.length, 2);
      expect(
        _readCString(rpathCmds[0].bytes, 12),
        '@executable_path/Frameworks',
      );
      expect(_readCString(rpathCmds[1].bytes, 12), '@loader_path/Frameworks');

      // Verify embedded CS_CodeDirectory page hashes match actual SHA-256 of pages 0 and 1.
      const cdOff = 0x2000 + 20;
      const hashOffset = 44 + 5; // "test\0"
      final hashesStart = cdOff + hashOffset;
      final page0Hash = patched.sublist(hashesStart, hashesStart + 32);
      final page1Hash = patched.sublist(hashesStart + 32, hashesStart + 64);

      expect(
        _hex(page0Hash),
        _hex(macho.sha256(Uint8List.sublistView(patched, 0, 0x1000))),
      );
      expect(
        _hex(page1Hash),
        _hex(macho.sha256(Uint8List.sublistView(patched, 0x1000, 0x2000))),
      );

      // Re-patching with an existing LC_BUILD_VERSION and duplicate rpath replaces
      // LC_BUILD_VERSION in place without duplicating rpaths.
      final repatched = macho.patchMachO(
        patched,
        macho.PatchOptions(
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('14.0'),
          rpaths: ['@executable_path/Frameworks'],
        ),
      );
      final cmds2 = macho.parseLoadCommands(repatched);
      expect(cmds2.where((c) => c.cmd == macho.lcBuildVersion).length, 1);
      expect(cmds2.where((c) => c.cmd == macho.lcRpath).length, 2);
      final bv2Bd = ByteData.sublistView(
        cmds2.singleWhere((c) => c.cmd == macho.lcBuildVersion).bytes,
      );
      expect(bv2Bd.getUint32(8, Endian.little), macho.platformMacos);
      expect(bv2Bd.getUint32(12, Endian.little), 0x000b0000);
      expect(bv2Bd.getUint32(16, Endian.little), 0x000e0000);
    });

    test('patches all slices in a fat (0xcafebabe) Mach-O binary and thins when arch is set', () {
      final arm64Slice = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );
      final x86Slice = macho.generateStubMachO(
        arch: 'x86_64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );

      final fatInput = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeX86_64,
          cpusubtype: macho.cpuSubtypeX86_64All,
          bytes: x86Slice,
        ),
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm64Slice,
        ),
      ]);
      expect(macho.isFatMachO(fatInput), isTrue);

      // Patch all slices in fat binary.
      final patchedFat = macho.patchMachO(
        fatInput,
        macho.PatchOptions(
          platform: macho.platformIosSimulator,
          minOs: macho.parsePackedVersion('15.4'),
          sdkVersion: macho.parsePackedVersion('17.0'),
          installName: '@rpath/MyFat.framework/MyFat',
        ),
      );
      expect(macho.isFatMachO(patchedFat), isTrue);
      final slices = macho.extractFatSlices(patchedFat);
      expect(slices.length, 2);
      for (final s in slices) {
        final cmds = macho.parseLoadCommands(s.bytes);
        final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
        expect(_readCString(idCmd.bytes, 24), '@rpath/MyFat.framework/MyFat');
        final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
        final bvBd = ByteData.sublistView(bvCmd.bytes);
        expect(bvBd.getUint32(8, Endian.little), macho.platformIosSimulator);
        expect(bvBd.getUint32(12, Endian.little), 0x000f0400);
        expect(bvBd.getUint32(16, Endian.little), 0x00110000);
      }

      // Thin fat binary to arm64 slice while patching.
      final thinnedArm64 = macho.patchMachO(
        fatInput,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('16.1'),
          sdkVersion: macho.parsePackedVersion('17.0'),
          installName: '@rpath/Thinned.framework/Thinned',
          arch: 'arm64',
        ),
      );
      expect(macho.isFatMachO(thinnedArm64), isFalse);
      expect(macho.isMachO64(thinnedArm64), isTrue);
      expect(
        ByteData.sublistView(thinnedArm64).getUint32(4, Endian.little),
        macho.cpuTypeArm64,
      );
      final thinCmds = macho.parseLoadCommands(thinnedArm64);
      expect(
        _readCString(
          thinCmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/Thinned.framework/Thinned',
      );

      // Verify with hermetic llvm-lipo and llvm-objdump if available.
      final lipo = _resolveHermeticTool('LLVM_LIPO');
      final objdump = _resolveHermeticTool('LLVM_OBJDUMP');
      if (lipo != null && objdump != null) {
        final tempDir = Directory.systemTemp.createTempSync('macho_fat_test_');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final fatPath = '${tempDir.path}/patched_fat.dylib';
        File(fatPath).writeAsBytesSync(patchedFat);

        final lipoRes = Process.runSync(lipo, ['-archs', fatPath]);
        expect(lipoRes.exitCode, 0, reason: '${lipoRes.stderr}');
        expect((lipoRes.stdout as String).trim(), 'x86_64 arm64');

        final objdumpRes = Process.runSync(objdump, [
          '--macho',
          '--private-headers',
          '--arch=all',
          fatPath,
        ]);
        expect(objdumpRes.exitCode, 0, reason: '${objdumpRes.stderr}');
        final out = objdumpRes.stdout as String;
        expect('minos 15.4'.allMatches(out).length, 2);
        expect('@rpath/MyFat.framework/MyFat'.allMatches(out).length, 2);
      }
    });

    test(
      'rejects 32-bit Mach-O and non-Mach-O inputs with FormatException',
      () {
        final macho32 = _buildMachO32();
        expect(macho.isMachO32(macho32), isTrue);
        expect(
          () => macho.patchMachO(
            macho32,
            macho.PatchOptions(
              platform: macho.platformIos,
              minOs: macho.parsePackedVersion('13.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('32-bit Mach-O'),
            ),
          ),
        );

        // Fat binary containing a 32-bit slice must also fail loudly.
        final fatWith32 = macho.buildFatMachO([
          macho.FatSlice(
            cputype: macho.cpuTypeArm,
            cpusubtype: 9,
            bytes: macho32,
          ),
        ]);
        expect(macho.isFatMachO(fatWith32), isTrue);
        expect(
          () => macho.patchMachO(
            fatWith32,
            macho.PatchOptions(
              platform: macho.platformIos,
              minOs: macho.parsePackedVersion('13.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('32-bit Mach-O'),
            ),
          ),
        );

        // Plain non-Mach-O bytes must fail loudly.
        final plainBytes = Uint8List.fromList(
          utf8.encode('not a macho binary'),
        );
        expect(
          () => macho.patchMachO(
            plainBytes,
            macho.PatchOptions(
              platform: macho.platformMacos,
              minOs: macho.parsePackedVersion('11.0'),
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Not a Mach-O'),
            ),
          ),
        );
      },
    );

    test(
      'patches every load-command kind and pins the patched bytes',
      () {
        final input = _buildFullCoverageMachO();
        final patched = macho.patchMachO(
          input,
          macho.PatchOptions(
            platform: macho.platformIos,
            minOs: macho.parsePackedVersion('13.0'),
            sdkVersion: macho.parsePackedVersion('16.0'),
            installName: '@rpath/New.framework/New',
            rpaths: ['@executable_path/Frameworks'],
          ),
        );
        expect(patched.length, input.length);

        // All four legacy version-min commands are stripped; the linkedit
        // table commands keep their offsets; build-version and rpath append.
        expect(macho.parseLoadCommands(patched).map((c) => c.cmd), [
          macho.lcSegment64,
          macho.lcSegment64,
          macho.lcSymtab,
          macho.lcDysymtab,
          macho.lcFunctionStarts,
          macho.lcDataInCode,
          macho.lcDyldExportsTrie,
          macho.lcDyldChainedFixups,
          macho.lcIdDylib,
          macho.lcBuildVersion,
          macho.lcRpath,
        ]);

        final idCmd = macho
            .parseLoadCommands(patched)
            .singleWhere((c) => c.cmd == macho.lcIdDylib);
        expect(_readCString(idCmd.bytes, 24), '@rpath/New.framework/New');

        // Section and linkedit payload bytes survive the rewrite untouched.
        expect(patched.sublist(0x1000, 0x1200), input.sublist(0x1000, 0x1200));
        expect(patched.sublist(0x4000, 0x5000), input.sublist(0x4000, 0x5000));

        // Pins the patched bytes: any moved byte fails this digest.
        expect(
          _hex(macho.sha256(patched)),
          'b6730c0ff3cdd07b52f2e122679a38b27865479eaee0db94ae49af27b5364fcc',
        );
      },
    );

    test(
      'stripSymbols drops locals and stabs, keeping exports and imports',
      () {
        final input = _buildUnstrippedDylib();
        final stripped = macho.patchMachO(
          input.bytes,
          macho.PatchOptions(stripSymbols: true),
        );
        expect(stripped.length, lessThan(input.bytes.length));

        // Only the two exports and the undefined import survive, defined
        // first, with no stab entry left.
        final table = _readTestSymtab(stripped);
        expect(table.names, [
          '_kDartSnapshotText',
          '_kDartSnapshotData',
          '_printf',
        ]);
        expect(table.types, [0x0f, 0x0f, 0x01]);
        for (final type in table.types) {
          expect(type & 0xe0, 0);
        }

        // The dysymtab groups say so too: no locals, two defined
        // externals, one undefined import.
        expect(_readTestDysymtabGroups(stripped), [0, 0, 0, 2, 2, 1]);

        // The indirect table remaps the kept export, absolves the dropped
        // local, and keeps the LOCAL entry.
        expect(_readTestIndirect(stripped), [
          0,
          macho.indirectSymbolAbs,
          macho.indirectSymbolLocal,
        ]);

        // No dropped name survives anywhere, and the export trie moves
        // down byte-identical.
        final text = latin1.decode(stripped);
        for (final gone in ['_myLocal', '_otherLocal', 'MyApp']) {
          expect(text, isNot(contains(gone)));
        }
        Uint8List trieOf(Uint8List bytes) {
          final lc = macho
              .parseLoadCommands(bytes)
              .singleWhere((c) => c.cmd == macho.lcDyldExportsTrie);
          final bd = ByteData.sublistView(lc.bytes);
          final off = bd.getUint32(8, Endian.little);
          final size = bd.getUint32(12, Endian.little);
          return bytes.sublist(off, off + size);
        }

        expect(trieOf(stripped), trieOf(input.bytes));

        // The hermetic llvm tools agree: only the two exports and the
        // import remain, with no debugger entries.
        final nm = _resolveHermeticTool('LLVM_NM');
        final objdump = _resolveHermeticTool('LLVM_OBJDUMP');
        if (Platform.environment.containsKey('TEST_SRCDIR')) {
          expect(nm, isNotNull, reason: 'LLVM_NM must resolve in Bazel');
          expect(
            objdump,
            isNotNull,
            reason: 'LLVM_OBJDUMP must resolve in Bazel',
          );
        }
        if (nm == null || objdump == null) return;

        final stripDir = Directory.systemTemp.createTempSync(
          'macho_strip_test_',
        );
        addTearDown(() => stripDir.deleteSync(recursive: true));
        final strippedPath = '${stripDir.path}/stripped.dylib';
        File(strippedPath).writeAsBytesSync(stripped);

        final nmRes = Process.runSync(nm, [strippedPath]);
        expect(nmRes.exitCode, 0, reason: '${nmRes.stderr}');
        final nmOut = nmRes.stdout as String;
        expect(nmOut, contains('T _kDartSnapshotText'));
        expect(nmOut, contains('T _kDartSnapshotData'));
        expect(nmOut, contains('_printf'));
        for (final gone in ['myLocal', 'otherLocal', 'MyApp']) {
          expect(nmOut, isNot(contains(gone)));
        }

        final nmDebugRes = Process.runSync(nm, [
          '--debug-syms',
          strippedPath,
        ]);
        expect(nmDebugRes.exitCode, 0, reason: '${nmDebugRes.stderr}');
        final nmDebugOut = nmDebugRes.stdout as String;
        expect(nmDebugOut, isNot(contains('FUN')));
        expect(nmDebugOut, isNot(contains('MyApp')));

        final symsRes = Process.runSync(objdump, [
          '--macho',
          '--syms',
          strippedPath,
        ]);
        expect(symsRes.exitCode, 0, reason: '${symsRes.stderr}');
        final symLines = [
          for (final line in (symsRes.stdout as String).split('\n'))
            if (RegExp(r'^[0-9a-f]{16} ').hasMatch(line)) line,
        ];
        expect(symLines.length, 3);
        expect(symsRes.stdout as String, contains('_kDartSnapshotText'));
        expect(symsRes.stdout as String, contains('_kDartSnapshotData'));

        final trieRes = Process.runSync(objdump, [
          '--macho',
          '--exports-trie',
          strippedPath,
        ]);
        expect(trieRes.exitCode, 0, reason: '${trieRes.stderr}');
        final trieOut = trieRes.stdout as String;
        expect(trieOut, contains('_kDartSnapshotText'));
        expect(trieOut, contains('_kDartSnapshotData'));
      },
    );

    test('a patch without stripping leaves the symbol table as it was', () {
      final input = _buildUnstrippedDylib();
      final patched = macho.patchMachO(
        input.bytes,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('13.0'),
        ),
      );

      // Same entries, same groups, same indirect entries.
      final before = _readTestSymtab(input.bytes);
      final after = _readTestSymtab(patched);
      expect(after.names, before.names);
      expect(after.types, before.types);
      expect(
        _readTestDysymtabGroups(patched),
        _readTestDysymtabGroups(input.bytes),
      );
      expect(_readTestIndirect(patched), _readTestIndirect(input.bytes));

      // The table payload bytes survive untouched.
      final end = input.stroff + input.strsize;
      expect(
        patched.sublist(input.symoff, end),
        input.bytes.sublist(input.symoff, end),
      );
    });

    test('patches a fat64 binary and keeps the fat64 header', () {
      final arm = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Old.dylib',
      );
      final fat64 = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm,
        ),
      ], fat64: true);
      expect(macho.isFatMachO(fat64), isTrue);

      final patched = macho.patchMachO(
        fat64,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('13.0'),
          installName: '@rpath/New.dylib',
        ),
      );
      expect(
        ByteData.sublistView(patched).getUint32(0, Endian.big),
        macho.fatMagic64,
      );
      final slices = macho.extractFatSlices(patched);
      expect(slices.length, 1);
      final cmds = macho.parseLoadCommands(slices.single.bytes);
      expect(
        _readCString(
          cmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/New.dylib',
      );
      expect(
        _hex(macho.sha256(patched)),
        '36506d4d5d9e1190abc535e120d81b15cb5bb74f8f801412e159ef83428a7cc3',
      );
    });

    test('checks the requested arch against a thin binary', () {
      final stub = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Arch.dylib',
      );
      final matched = macho.patchMachO(
        stub,
        macho.PatchOptions(
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('12.0'),
          arch: 'arm64',
        ),
      );
      expect(macho.isMachO64(matched), isTrue);
      expect(
        () => macho.patchMachO(
          stub,
          macho.PatchOptions(
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('12.0'),
            arch: 'x86_64',
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('does not match'),
          ),
        ),
      );
    });

    test('adds LC_ID_DYLIB to an execute stub that has none', () {
      final stub = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformIos,
        minOs: macho.parsePackedVersion('14.0'),
        sdkVersion: macho.parsePackedVersion('14.0'),
        installName: '',
        fileType: macho.mhExecute,
      );
      expect(
        macho.parseLoadCommands(stub).where((c) => c.cmd == macho.lcIdDylib),
        isEmpty,
      );
      final patched = macho.patchMachO(
        stub,
        macho.PatchOptions(
          platform: macho.platformIos,
          minOs: macho.parsePackedVersion('14.0'),
          installName: '@rpath/Runner',
        ),
      );
      final cmds = macho.parseLoadCommands(patched);
      expect(
        _readCString(
          cmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
          24,
        ),
        '@rpath/Runner',
      );
    });
  });

  /// Deterministic filler for a linkedit payload: byte `i` is
  /// `(i * 31 + seed) & 0xff`, so every table has recognizable contents.
  Uint8List _patternBytes(int seed, int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = (i * 31 + seed) & 0xff;
    }
    return out;
  }

  /// Builds a signed arm64 dylib for the COV-24 strip-integrity tests: 220 local
  /// symbols plus stabs (so the strip removes more than two pages), an
  /// `LC_DYLD_INFO` (or `LC_DYLD_INFO_ONLY`) with all five pairs non-empty, the
  /// four single-range table commands, an export trie, an indirect table, a
  /// `LC_UUID`, and an embedded signature whose CodeDirectory carries one
  /// special slot and a requirements blob.
  ///
  /// The linkedit payloads are laid out in scrambled file order (chained fixups
  /// first, the signature last). With [cmsTrailer], non-zero bytes follow the
  /// SuperBlob inside `LC_CODE_SIGNATURE`, modelling a real CMS signature.
  /// With [cmsWrapper] set to `'empty'`, the SuperBlob carries a signature-slot
  /// (`0x10000`) blob wrapper without a payload (what ad-hoc `codesign`
  /// writes); `'payload'` gives that wrapper a payload a rebuild must refuse.
  /// With [alternateCd], the SuperBlob also carries an alternate CodeDirectory
  /// (`0x1000`) the rebuild must re-sign like the primary. With
  /// [legacyIdent44], the primary CodeDirectory is a version-0x20100 directory
  /// whose identifier starts at offset 44 (no scatter/team words there).
  ({
    Uint8List bytes,
    int linkeditOff,
    List<Uint8List> dyldRanges,
    Uint8List functionStarts,
    Uint8List dataInCode,
    Uint8List exportsTrie,
    Uint8List chainedFixups,
    Uint8List specialSlot,
    Uint8List requirements,
  })
  _buildStripIntegrityDylib({
    required bool dyldInfoOnly,
    bool cmsTrailer = false,
    String? cmsWrapper,
    bool alternateCd = false,
    bool legacyIdent44 = false,
  }) {
    const linkeditOff = 0x3000;
    const nLocals = 220;
    final names = [
      for (var i = 0; i < nLocals; i++)
        '_local_${i}_with_long_padding_0123456789abcdef',
      '_MyApp.build',
      'MyApp.dart',
      '_kDartSnapshotText',
      '_kDartSnapshotData',
      '_printf',
    ];
    final types = [
      for (var i = 0; i < nLocals; i++) 0x0e,
      0x24,
      0x64,
      0x0f,
      0x0f,
      0x01,
    ];
    final sects = [
      for (var i = 0; i < nLocals; i++) 1,
      1,
      0,
      1,
      1,
      0,
    ];

    final strings = BytesBuilder(copy: false)..addByte(0);
    final strx = <int>[];
    for (final name in names) {
      strx.add(strings.length);
      strings.add(utf8.encode(name));
      strings.addByte(0);
    }
    final strBytes = strings.toBytes();
    final symBytes = BytesBuilder(copy: false);
    for (var i = 0; i < names.length; i++) {
      final entry = ByteData(16)
        ..setUint32(0, strx[i], Endian.little)
        ..setUint8(4, types[i])
        ..setUint8(5, sects[i])
        ..setUint16(6, 0, Endian.little)
        ..setUint64(8, 0x1000 + i * 8, Endian.little);
      symBytes.add(entry.buffer.asUint8List());
    }
    final symTab = symBytes.toBytes();

    // Linkedit payloads with distinct contents, in scrambled file order.
    final chained = _patternBytes(23, 48);
    final rebase = _patternBytes(11, 256);
    final bind = _patternBytes(12, 320);
    final weak = _patternBytes(13, 192);
    final lazy = _patternBytes(14, 224);
    final export = _patternBytes(15, 160);
    final funcStarts = _patternBytes(21, 64);
    final dataInCode = _patternBytes(22, 80);
    final trie = _buildSnapshotExportsTrie();
    final specialSlot = _patternBytes(8, 32);
    final requirements = _patternBytes(9, 32);
    // Every SuperBlob entry points at a `CS_Blob` (magic + length + body),
    // so the requirements payload carries its header; the verifier compares
    // the body bytes.
    final requirementsBlob = Uint8List(40);
    final requirementsBd = ByteData.sublistView(requirementsBlob);
    requirementsBd.setUint32(0, 0xfade0c01, Endian.big);
    requirementsBd.setUint32(4, requirementsBlob.length, Endian.big);
    requirementsBlob.setRange(8, 40, requirements);
    final indirect = ByteData(12)
      ..setUint32(0, nLocals + 2, Endian.little)
      ..setUint32(4, 0, Endian.little)
      ..setUint32(8, macho.indirectSymbolLocal, Endian.little);

    // Size the signature: SuperBlob header + index + requirements + primary
    // CodeDirectory (+ CMS wrapper, alternate CodeDirectory and CMS trailer
    // when asked). The slot count follows the signature offset.
    final wrapperLength = cmsWrapper == null
        ? 0
        : cmsWrapper == 'empty'
        ? 8
        : 32;
    final nBlobs =
        (cmsTrailer ? 3 : 2) +
        (cmsWrapper == null ? 0 : 1) +
        (alternateCd ? 1 : 0);
    var nSlots = 8;
    var sigLength = 0;
    for (var i = 0; i < 3; i++) {
      final cdLength = 128 + nSlots * 32 + 5;
      sigLength =
          12 +
          nBlobs * 8 +
          requirementsBlob.length +
          wrapperLength +
          (alternateCd ? cdLength : 0) +
          cdLength;
      final base =
          linkeditOff +
          chained.length +
          symTab.length +
          bind.length +
          strBytes.length +
          rebase.length +
          funcStarts.length +
          weak.length +
          12 +
          lazy.length +
          trie.length +
          export.length +
          dataInCode.length;
      nSlots = (base + sigLength + 0xfff) ~/ 0x1000;
    }
    final cdLength = 128 + nSlots * 32 + 5;
    final superLength =
        12 +
        nBlobs * 8 +
        requirementsBlob.length +
        wrapperLength +
        (alternateCd ? cdLength : 0) +
        cdLength;
    final sigDatasize = superLength + (cmsTrailer ? 24 : 0);

    // Assign file offsets in scrambled order.
    var cursor = linkeditOff;
    int take(Uint8List payload) {
      final off = cursor;
      cursor += payload.length;
      return off;
    }

    final chainedOff = take(chained);
    final symoff = take(symTab);
    final bindOff = take(bind);
    final stroff = take(strBytes);
    final rebaseOff = take(rebase);
    final funcOff = take(funcStarts);
    final weakOff = take(weak);
    cursor = (cursor + 3) & ~3;
    final indirectOff = cursor;
    cursor += 12;
    final lazyOff = take(lazy);
    final trieOff = take(trie);
    final exportOff = take(export);
    final dicOff = take(dataInCode);
    final sigOff = cursor;
    final fileSize = sigOff + sigDatasize;

    Uint8List tableCommand(int cmd, int dataoff, int datasize) {
      final buf = Uint8List(16);
      final bd = ByteData.sublistView(buf);
      bd.setUint32(0, cmd, Endian.little);
      bd.setUint32(4, 16, Endian.little);
      bd.setUint32(8, dataoff, Endian.little);
      bd.setUint32(12, datasize, Endian.little);
      return buf;
    }

    final dyldCmd = Uint8List(48);
    final dyldBd = ByteData.sublistView(dyldCmd);
    dyldBd.setUint32(
      0,
      dyldInfoOnly ? macho.lcDyldInfoOnly : macho.lcDyldInfo,
      Endian.little,
    );
    dyldBd.setUint32(4, 48, Endian.little);
    final pairs = [
      (rebaseOff, rebase.length),
      (bindOff, bind.length),
      (weakOff, weak.length),
      (lazyOff, lazy.length),
      (exportOff, export.length),
    ];
    for (var i = 0; i < pairs.length; i++) {
      dyldBd.setUint32(8 + i * 8, pairs[i].$1, Endian.little);
      dyldBd.setUint32(12 + i * 8, pairs[i].$2, Endian.little);
    }

    final textSeg = Uint8List(72 + 80);
    final textBd = ByteData.sublistView(textSeg);
    textBd.setUint32(0, macho.lcSegment64, Endian.little);
    textBd.setUint32(4, 152, Endian.little);
    textSeg.setRange(8, 8 + '__TEXT'.length, ascii.encode('__TEXT'));
    textBd.setUint64(24, 0, Endian.little);
    textBd.setUint64(32, 0x4000, Endian.little);
    textBd.setUint64(40, 0, Endian.little);
    textBd.setUint64(48, 0x3000, Endian.little);
    textBd.setUint32(56, 5, Endian.little);
    textBd.setUint32(60, 5, Endian.little);
    textBd.setUint32(64, 1, Endian.little);
    textSeg.setRange(72, 72 + '__text'.length, ascii.encode('__text'));
    textSeg.setRange(
      72 + 16,
      72 + 16 + '__TEXT'.length,
      ascii.encode('__TEXT'),
    );
    // The section lives in the code pages, past the load commands, so the
    // patched commands fit before the first payload offset.
    textBd.setUint64(72 + 32, 0x1000, Endian.little);
    textBd.setUint64(72 + 40, 0x200, Endian.little);
    textBd.setUint32(72 + 48, 0x1000, Endian.little);
    textBd.setUint32(72 + 52, 2, Endian.little);

    final dysymtab = ByteData(80)
      ..setUint32(0, macho.lcDysymtab, Endian.little)
      ..setUint32(4, 80, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, nLocals + 2, Endian.little)
      ..setUint32(16, nLocals + 2, Endian.little)
      ..setUint32(20, 2, Endian.little)
      ..setUint32(24, nLocals + 4, Endian.little)
      ..setUint32(28, 1, Endian.little)
      ..setUint32(56, indirectOff, Endian.little)
      ..setUint32(60, 3, Endian.little);

    final commands = <Uint8List>[
      textSeg,
      macho.buildLcSegment64((
        segname: '__LINKEDIT',
        vmaddr: 0x4000,
        vmsize: fileSize - linkeditOff,
        fileoff: linkeditOff,
        filesize: fileSize - linkeditOff,
        maxprot: 1,
        initprot: 1,
        nsects: 0,
        flags: 0,
      )).bytes,
      macho
          .buildLcSymtab(
            symoff: symoff,
            nsyms: names.length,
            stroff: stroff,
            strsize: strBytes.length,
          )
          .bytes,
      dysymtab.buffer.asUint8List(),
      dyldCmd,
      tableCommand(macho.lcFunctionStarts, funcOff, funcStarts.length),
      tableCommand(macho.lcDataInCode, dicOff, dataInCode.length),
      tableCommand(macho.lcDyldExportsTrie, trieOff, trie.length),
      tableCommand(macho.lcDyldChainedFixups, chainedOff, chained.length),
      macho.buildLcUuid(_patternBytes(7, 16)).bytes,
      macho.buildLcIdDylib('@rpath/Strip.dylib').bytes,
      tableCommand(macho.lcCodeSignature, sigOff, sigDatasize),
    ];
    var sizeofcmds = 0;
    for (final c in commands) {
      sizeofcmds += c.length;
    }

    final buf = Uint8List(fileSize);
    for (var i = 0; i < linkeditOff; i++) {
      buf[i] = (i * 31 + 7) & 0xff;
    }
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, macho.mhMagic64, Endian.little);
    bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
    bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
    bd.setUint32(12, macho.mhDylib, Endian.little);
    bd.setUint32(16, commands.length, Endian.little);
    bd.setUint32(20, sizeofcmds, Endian.little);
    bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
    bd.setUint32(28, 0, Endian.little);
    var off = macho.mhHeaderSize64;
    for (final c in commands) {
      buf.setRange(off, off + c.length, c);
      off += c.length;
    }
    buf.setRange(symoff, symoff + symTab.length, symTab);
    buf.setRange(stroff, stroff + strBytes.length, strBytes);
    buf.setRange(
      indirectOff,
      indirectOff + 12,
      indirect.buffer.asUint8List(),
    );
    final blobs = [
      rebase,
      bind,
      weak,
      lazy,
      export,
      funcStarts,
      dataInCode,
      trie,
    ];
    final blobOffs = [
      rebaseOff,
      bindOff,
      weakOff,
      lazyOff,
      exportOff,
      funcOff,
      dicOff,
      trieOff,
    ];
    for (var i = 0; i < blobs.length; i++) {
      buf.setRange(blobOffs[i], blobOffs[i] + blobs[i].length, blobs[i]);
    }
    buf.setRange(chainedOff, chainedOff + chained.length, chained);

    // Builds one CodeDirectory with zeroed hashes; the patch step recomputes
    // them. The special slot keeps [specialSlot] so the verifier can check it
    // survives the rebuild byte-identical.
    Uint8List buildCd({
      required int version,
      required String ident,
      required int identOffset,
    }) {
      final cd = Uint8List(cdLength);
      final cbd = ByteData.sublistView(cd);
      cbd.setUint32(0, macho.csMagicCodeDirectory, Endian.big);
      cbd.setUint32(4, cdLength, Endian.big);
      cbd.setUint32(8, version, Endian.big);
      cbd.setUint32(12, 0x20002, Endian.big);
      cbd.setUint32(16, 128, Endian.big); // hashOffset
      cbd.setUint32(20, identOffset, Endian.big);
      cbd.setUint32(24, 1, Endian.big); // nSpecialSlots
      cbd.setUint32(28, nSlots, Endian.big);
      cbd.setUint32(32, sigOff, Endian.big); // codeLimit
      cd[36] = 32;
      cd[37] = 2; // SHA-256
      cd[38] = 0;
      cd[39] = 12; // 4096-byte pages
      cbd.setUint32(40, 0, Endian.big);
      cbd.setUint64(
        56,
        0xdeadbeefdeadbeef,
        Endian.big,
      ); // stale codeLimit64
      cbd.setUint64(64, 0x1000, Endian.big); // execSegBase
      cbd.setUint64(72, 0x2000, Endian.big); // execSegLimit
      cbd.setUint64(80, 3, Endian.big); // execSegFlags
      final identBytes = ascii.encode('$ident\x00');
      cd.setRange(
        identOffset,
        identOffset + identBytes.length,
        identBytes,
      );
      cd.setRange(96, 128, specialSlot);
      return cd;
    }

    // The signature-slot wrapper: empty for ad-hoc `codesign` output, or
    // carrying a payload the rebuild must refuse.
    Uint8List? wrapperBytes;
    if (cmsWrapper != null) {
      wrapperBytes = Uint8List(wrapperLength);
      final wbd = ByteData.sublistView(wrapperBytes);
      wbd.setUint32(0, macho.csMagicBlobWrapper, Endian.big);
      wbd.setUint32(4, wrapperLength, Endian.big);
      if (wrapperLength > 8) {
        wrapperBytes.setRange(
          8,
          wrapperLength,
          _patternBytes(33, wrapperLength - 8),
        );
      }
    }

    // The embedded signature: SuperBlob with a requirements blob and the
    // primary CodeDirectory, plus the CMS wrapper and alternate CodeDirectory
    // when asked.
    final entries = <(int, Uint8List)>[
      (2, requirementsBlob),
      (
        0,
        buildCd(
          version: legacyIdent44 ? 0x20100 : 0x20400,
          ident: legacyIdent44 ? 'fixture' : 'test',
          identOffset: legacyIdent44 ? 44 : 88,
        ),
      ),
      if (wrapperBytes != null) (0x10000, wrapperBytes),
      if (alternateCd)
        (0x1000, buildCd(version: 0x20400, ident: 'alt', identOffset: 88)),
    ];
    var sigCursor = sigOff + 12 + nBlobs * 8;
    bd.setUint32(sigOff, macho.csMagicEmbeddedSignature, Endian.big);
    bd.setUint32(sigOff + 4, superLength, Endian.big);
    bd.setUint32(sigOff + 8, nBlobs, Endian.big);
    for (var i = 0; i < entries.length; i++) {
      bd.setUint32(sigOff + 12 + i * 8, entries[i].$1, Endian.big);
      bd.setUint32(sigOff + 12 + i * 8 + 4, sigCursor - sigOff, Endian.big);
      buf.setRange(sigCursor, sigCursor + entries[i].$2.length, entries[i].$2);
      sigCursor += entries[i].$2.length;
    }
    if (cmsTrailer) {
      buf.setRange(
        sigOff + superLength,
        sigOff + superLength + 24,
        _patternBytes(31, 24),
      );
    }
    return (
      bytes: buf,
      linkeditOff: linkeditOff,
      dyldRanges: [rebase, bind, weak, lazy, export],
      functionStarts: funcStarts,
      dataInCode: dataInCode,
      exportsTrie: trie,
      chainedFixups: chained,
      specialSlot: specialSlot,
      requirements: requirements,
    );
  }

  /// The five `(offset, size)` pairs of an `LC_DYLD_INFO` command body.
  List<(int, int)> _dyldPairs(Uint8List cmdBytes) {
    final bd = ByteData.sublistView(cmdBytes);
    return [
      for (var field = 8; field < 48; field += 8)
        (
          bd.getUint32(field, Endian.little),
          bd.getUint32(field + 4, Endian.little),
        ),
    ];
  }

  /// The `(offset, size)` pair of a single-range linkedit command body.
  (int, int) _singleRange(Uint8List cmdBytes) {
    final bd = ByteData.sublistView(cmdBytes);
    return (bd.getUint32(8, Endian.little), bd.getUint32(12, Endian.little));
  }

  /// Every relocatable `(offset, size)` range the load commands of [bytes] name.
  List<(int, int)> _allLinkeditRanges(Uint8List bytes) {
    final ranges = <(int, int)>[];
    for (final lc in macho.parseLoadCommands(bytes)) {
      if (lc.cmd == macho.lcSymtab) {
        final bd = ByteData.sublistView(lc.bytes);
        ranges.add((
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little) * 16,
        ));
        ranges.add((
          bd.getUint32(16, Endian.little),
          bd.getUint32(20, Endian.little),
        ));
      } else if (lc.cmd == macho.lcDysymtab) {
        final bd = ByteData.sublistView(lc.bytes);
        ranges.add((
          bd.getUint32(56, Endian.little),
          bd.getUint32(60, Endian.little) * 4,
        ));
      } else if (lc.cmd == macho.lcDyldInfo || lc.cmd == macho.lcDyldInfoOnly) {
        ranges.addAll(_dyldPairs(lc.bytes));
      } else if (lc.cmd == macho.lcFunctionStarts ||
          lc.cmd == macho.lcDataInCode ||
          lc.cmd == macho.lcDyldExportsTrie ||
          lc.cmd == macho.lcDyldChainedFixups ||
          lc.cmd == macho.lcCodeSignature) {
        ranges.add(_singleRange(lc.bytes));
      }
    }
    return ranges;
  }

  /// Fails the test when any linkedit range of [bytes] escapes `__LINKEDIT` or
  /// overlaps another range: the strip must never point a command at reused
  /// bytes.
  void _expectLinkeditSound(Uint8List bytes, int linkeditOff) {
    final ranges = [
      for (final r in _allLinkeditRanges(bytes))
        if (r.$2 != 0) r,
    ];
    for (final r in ranges) {
      expect(r.$1, greaterThanOrEqualTo(linkeditOff));
      expect(r.$1 + r.$2, lessThanOrEqualTo(bytes.length));
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      expect(
        ranges[i].$1,
        greaterThanOrEqualTo(ranges[i - 1].$1 + ranges[i - 1].$2),
      );
    }
  }

  /// Fails unless the embedded signature of [bytes] is a valid rebuild: the
  /// `codeLimit` names the signature offset, the slot count covers it, every
  /// page hash matches, the identifier/flags/special slot/requirements/execSeg
  /// words survive, and `codeLimit64` is zeroed.
  ///
  /// Like ld64 and llvm-strip, the rewrite places `LC_CODE_SIGNATURE` at a
  /// 16-byte-aligned file offset. [expectedIdent] and [expectedVersion] pin
  /// the primary CodeDirectory's identity; when [checkCodeLimit64Zero] is
  /// false the stale `codeLimit64` word must survive untouched instead (a
  /// pre-0x20300 directory carries none).
  void _expectValidStripSignature(
    Uint8List bytes, {
    required Uint8List specialSlot,
    required Uint8List requirements,
    String expectedIdent = 'test',
    int expectedVersion = 0x20400,
    bool checkCodeLimit64Zero = true,
    int expectedCount = 2,
  }) {
    final cmds = macho.parseLoadCommands(bytes);
    final sigLc = cmds.singleWhere((c) => c.cmd == macho.lcCodeSignature);
    final sigBd = ByteData.sublistView(sigLc.bytes);
    final dataoff = sigBd.getUint32(8, Endian.little);
    final datasize = sigBd.getUint32(12, Endian.little);
    expect(dataoff % 16, 0, reason: 'LC_CODE_SIGNATURE must stay 16-aligned');
    final blob = bytes.sublist(dataoff, dataoff + datasize);
    final bbd = ByteData.sublistView(blob);
    expect(bbd.getUint32(0, Endian.big), macho.csMagicEmbeddedSignature);
    final count = bbd.getUint32(8, Endian.big);
    var cdOff = -1;
    var reqOff = -1;
    var reqLength = 0;
    expect(count, expectedCount);
    for (var i = 0; i < count; i++) {
      final type = bbd.getUint32(12 + i * 8, Endian.big);
      final at = bbd.getUint32(12 + i * 8 + 4, Endian.big);
      if (type == 2) {
        reqOff = at;
        reqLength = bbd.getUint32(at + 4, Endian.big);
      } else if (type == 0) {
        cdOff = at;
      }
    }
    expect(cdOff, greaterThanOrEqualTo(0));
    expect(reqOff, greaterThanOrEqualTo(0));
    expect(reqLength, requirements.length + 8);
    expect(blob.sublist(reqOff + 8, reqOff + reqLength), equals(requirements));

    final cdBd = ByteData.sublistView(blob, cdOff, cdOff + 64);
    expect(cdBd.getUint32(0, Endian.big), macho.csMagicCodeDirectory);
    expect(cdBd.getUint32(8, Endian.big), expectedVersion);
    expect(cdBd.getUint32(12, Endian.big), 0x20002);
    expect(cdBd.getUint32(24, Endian.big), 1); // one special slot
    final slots = cdBd.getUint32(28, Endian.big);
    expect(slots, (dataoff + 0xfff) ~/ 0x1000);
    expect(cdBd.getUint32(32, Endian.big), dataoff); // codeLimit
    expect(cdBd.getUint8(36), 32);
    expect(cdBd.getUint8(37), 2); // SHA-256
    expect(cdBd.getUint8(39), 12);
    if (checkCodeLimit64Zero) {
      expect(cdBd.getUint64(56, Endian.big), 0); // zeroed codeLimit64
    } else {
      expect(cdBd.getUint64(56, Endian.big), 0xdeadbeefdeadbeef);
    }
    final execBd = ByteData.sublistView(blob, cdOff + 64, cdOff + 88);
    expect(execBd.getUint64(0, Endian.big), 0x1000);
    expect(execBd.getUint64(8, Endian.big), 0x2000);
    expect(execBd.getUint64(16, Endian.big), 3);

    final hashOffset = cdBd.getUint32(16, Endian.big);
    final identOffset = cdBd.getUint32(20, Endian.big);
    expect(_readCString(blob, cdOff + identOffset), expectedIdent);
    final hashesStart = cdOff + hashOffset - 32;
    expect(blob.sublist(hashesStart, hashesStart + 32), equals(specialSlot));
    for (var slot = 0; slot < slots; slot++) {
      final start = slot * 0x1000;
      var end = start + 0x1000;
      if (end > dataoff) end = dataoff;
      final want = macho.sha256(Uint8List.sublistView(bytes, start, end));
      final got = blob.sublist(
        hashesStart + 32 + slot * 32,
        hashesStart + 64 + slot * 32,
      );
      expect(got, equals(want), reason: 'page $slot hash');
    }

    // The `__LINKEDIT` segment tracks the new file size.
    for (final lc in cmds) {
      if (lc.cmd != macho.lcSegment64) continue;
      final name = ascii.decode(lc.bytes.sublist(8, 24)).split('\x00').first;
      if (name != '__LINKEDIT') continue;
      final segBd = ByteData.sublistView(lc.bytes);
      final fileoff = segBd.getUint64(40, Endian.little);
      expect(segBd.getUint64(48, Endian.little), bytes.length - fileoff);
    }
  }

  /// Returns the SuperBlob entry of [bytes] with index [type].
  Uint8List _superBlobEntry(Uint8List bytes, int type) {
    final sigLc = macho
        .parseLoadCommands(bytes)
        .singleWhere((c) => c.cmd == macho.lcCodeSignature);
    final sigBd = ByteData.sublistView(sigLc.bytes);
    final dataoff = sigBd.getUint32(8, Endian.little);
    final datasize = sigBd.getUint32(12, Endian.little);
    final blob = bytes.sublist(dataoff, dataoff + datasize);
    final bbd = ByteData.sublistView(blob);
    final count = bbd.getUint32(8, Endian.big);
    for (var i = 0; i < count; i++) {
      if (bbd.getUint32(12 + i * 8, Endian.big) != type) continue;
      final at = bbd.getUint32(12 + i * 8 + 4, Endian.big);
      final length = ByteData.sublistView(
        blob,
        at,
        at + 8,
      ).getUint32(4, Endian.big);
      return Uint8List.fromList(blob.sublist(at, at + length));
    }
    throw StateError('no SuperBlob entry with type $type');
  }

  /// Returns the primary CodeDirectory blob of [bytes].
  Uint8List _primaryCdBlob(Uint8List bytes) =>
      _superBlobEntry(bytes, macho.csSlotCodeDirectory);

  /// Returns [bytes] with [cmd] appended to its load commands.
  Uint8List _withAppendedCommand(Uint8List bytes, Uint8List cmd) {
    final cmds = macho.parseLoadCommands(bytes);
    var sizeofcmds = 0;
    for (final c in cmds) {
      sizeofcmds += c.cmdsize;
    }
    final out = Uint8List.fromList(bytes);
    final bd = ByteData.sublistView(out);
    out.setRange(
      macho.mhHeaderSize64 + sizeofcmds,
      macho.mhHeaderSize64 + sizeofcmds + cmd.length,
      cmd,
    );
    bd.setUint32(16, cmds.length + 1, Endian.little);
    bd.setUint32(20, sizeofcmds + cmd.length, Endian.little);
    return out;
  }

  /// Builds a header-only 64-bit Mach-O with no `LC_SYMTAB`.
  Uint8List _buildHeaderOnlyMachO() {
    final commands = [
      macho.buildLcUuid(_patternBytes(7, 16)).bytes,
      macho.buildLcIdDylib('@rpath/Bare.dylib').bytes,
    ];
    var sizeofcmds = 0;
    for (final c in commands) {
      sizeofcmds += c.length;
    }
    final buf = Uint8List(macho.mhHeaderSize64 + sizeofcmds);
    final bd = ByteData.sublistView(buf);
    bd.setUint32(0, macho.mhMagic64, Endian.little);
    bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
    bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
    bd.setUint32(12, macho.mhDylib, Endian.little);
    bd.setUint32(16, commands.length, Endian.little);
    bd.setUint32(20, sizeofcmds, Endian.little);
    bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
    var off = macho.mhHeaderSize64;
    for (final c in commands) {
      buf.setRange(off, off + c.length, c);
      off += c.length;
    }
    return buf;
  }

  /// Runs the COV-24 strip-integrity checks over a fixture using [dyldInfoOnly]
  /// for the dyld table command: every moved range keeps its bytes, the ranges
  /// never overlap, the signature is rebuilt over the shrunk layout, and a
  /// retag of the stripped binary re-signs cleanly.
  void _checkStripIntegrity({required bool dyldInfoOnly}) {
    final input = _buildStripIntegrityDylib(dyldInfoOnly: dyldInfoOnly);
    final stripped = macho.patchMachO(
      input.bytes,
      macho.PatchOptions(stripSymbols: true),
    );

    // More than two pages of locals and stabs are gone.
    expect(
      input.bytes.length - stripped.length,
      greaterThanOrEqualTo(2 * 0x1000),
    );

    final cmds = macho.parseLoadCommands(stripped);
    final dyldLc = cmds.singleWhere(
      (c) => c.cmd == (dyldInfoOnly ? macho.lcDyldInfoOnly : macho.lcDyldInfo),
    );
    final pairs = _dyldPairs(dyldLc.bytes);
    expect(pairs.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(
        stripped.sublist(pairs[i].$1, pairs[i].$1 + pairs[i].$2),
        equals(input.dyldRanges[i]),
      );
    }

    // The other table payloads move down byte-identical too.
    Uint8List moved(int cmd) {
      final lc = cmds.singleWhere((c) => c.cmd == cmd);
      final range = _singleRange(lc.bytes);
      return stripped.sublist(range.$1, range.$1 + range.$2);
    }

    expect(moved(macho.lcFunctionStarts), equals(input.functionStarts));
    expect(moved(macho.lcDataInCode), equals(input.dataInCode));
    expect(moved(macho.lcDyldExportsTrie), equals(input.exportsTrie));
    expect(moved(macho.lcDyldChainedFixups), equals(input.chainedFixups));

    _expectLinkeditSound(stripped, input.linkeditOff);
    _expectValidStripSignature(
      stripped,
      specialSlot: input.specialSlot,
      requirements: input.requirements,
    );

    // Only the two exports and the undefined import survive, defined first.
    expect(_readTestSymtab(stripped).names, [
      '_kDartSnapshotText',
      '_kDartSnapshotData',
      '_printf',
    ]);
    expect(_readTestDysymtabGroups(stripped), [0, 0, 0, 2, 2, 1]);
    expect(_readTestIndirect(stripped), [
      0,
      macho.indirectSymbolAbs,
      macho.indirectSymbolLocal,
    ]);

    // The UUID and install name survive the strip.
    expect(
      cmds.where((c) => c.cmd == macho.lcUuid).single.bytes,
      equals(
        macho
            .parseLoadCommands(input.bytes)
            .singleWhere((c) => c.cmd == macho.lcUuid)
            .bytes,
      ),
    );
    expect(
      _readCString(
        cmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
        24,
      ),
      '@rpath/Strip.dylib',
    );

    // A retag of the stripped binary re-signs over the edited layout.
    final retagged = macho.patchMachO(
      stripped,
      macho.PatchOptions(installName: '@rpath/Retagged.dylib'),
    );
    final retaggedCmds = macho.parseLoadCommands(retagged);
    expect(
      _readCString(
        retaggedCmds.singleWhere((c) => c.cmd == macho.lcIdDylib).bytes,
        24,
      ),
      '@rpath/Retagged.dylib',
    );
    _expectLinkeditSound(retagged, input.linkeditOff);
    _expectValidStripSignature(
      retagged,
      specialSlot: input.specialSlot,
      requirements: input.requirements,
    );
  }

  group('stripIntegrity (COV-24)', () {
    test('strip moves all five LC_DYLD_INFO ranges byte-identical', () {
      _checkStripIntegrity(dyldInfoOnly: false);
    });

    test('strip moves all five LC_DYLD_INFO_ONLY ranges byte-identical', () {
      _checkStripIntegrity(dyldInfoOnly: true);
    });

    test('strip refuses a load command pointing into __LINKEDIT', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      // LC_TWOLEVEL_HINTS (0x16) carries an (offset, nhints) pair at +8/+12.
      final hints = ByteData(16)
        ..setUint32(0, 0x16, Endian.little)
        ..setUint32(4, 16, Endian.little)
        ..setUint32(8, input.linkeditOff + 64, Endian.little)
        ..setUint32(12, 8, Endian.little);
      final boobyTrapped = _withAppendedCommand(
        input.bytes,
        hints.buffer.asUint8List(),
      );
      expect(
        () => macho.patchMachO(
          boobyTrapped,
          macho.PatchOptions(stripSymbols: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('__LINKEDIT'),
          ),
        ),
      );
    });

    test('patch refuses a non-SHA-256 CodeDirectory', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      final cmds = macho.parseLoadCommands(input.bytes);
      final sigLc = cmds.singleWhere((c) => c.cmd == macho.lcCodeSignature);
      final sigBd = ByteData.sublistView(sigLc.bytes);
      final dataoff = sigBd.getUint32(8, Endian.little);
      final blob = ByteData.sublistView(input.bytes, dataoff);
      final count = blob.getUint32(8, Endian.big);
      var cdOff = -1;
      for (var i = 0; i < count; i++) {
        if (blob.getUint32(12 + i * 8, Endian.big) == 0 &&
            ByteData.sublistView(
                  input.bytes,
                  dataoff + blob.getUint32(12 + i * 8 + 4, Endian.big),
                ).getUint32(0, Endian.big) ==
                macho.csMagicCodeDirectory) {
          cdOff = dataoff + blob.getUint32(12 + i * 8 + 4, Endian.big);
        }
      }
      expect(cdOff, greaterThanOrEqualTo(0));
      final doctored = Uint8List.fromList(input.bytes);
      doctored[cdOff + 37] = 1; // SHA-1: unhashable by the pure-Dart signer
      expect(
        () => macho.patchMachO(doctored, macho.PatchOptions()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('hash type'),
          ),
        ),
      );
    });

    test('patch refuses a CMS signature blob', () {
      final input = _buildStripIntegrityDylib(
        dyldInfoOnly: false,
        cmsTrailer: true,
      );
      expect(
        () => macho.patchMachO(input.bytes, macho.PatchOptions()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CMS'),
          ),
        ),
      );
    });

    test('patch refuses a payload-carrying CMS signature wrapper', () {
      final input = _buildStripIntegrityDylib(
        dyldInfoOnly: false,
        cmsWrapper: 'payload',
      );
      expect(
        () => macho.patchMachO(input.bytes, macho.PatchOptions()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CMS'),
          ),
        ),
      );
    });

    test(
      'strip keeps an empty CMS wrapper and rebuilds alternate CodeDirectories',
      () {
        final input = _buildStripIntegrityDylib(
          dyldInfoOnly: false,
          cmsWrapper: 'empty',
          alternateCd: true,
        );
        final stripped = macho.patchMachO(
          input.bytes,
          macho.PatchOptions(stripSymbols: true),
        );
        _expectLinkeditSound(stripped, input.linkeditOff);
        _expectValidStripSignature(
          stripped,
          specialSlot: input.specialSlot,
          requirements: input.requirements,
          expectedCount: 4,
        );

        // The empty signature wrapper survives byte-identical.
        final wrapper = _superBlobEntry(stripped, 0x10000);
        expect(wrapper.length, 8);
        final wbd = ByteData.sublistView(wrapper);
        expect(wbd.getUint32(0, Endian.big), macho.csMagicBlobWrapper);
        expect(wbd.getUint32(4, Endian.big), 8);

        // The alternate CodeDirectory is re-signed like the primary: the new
        // codeLimit, a covering slot count, the kept identifier and fresh
        // page hashes.
        final sigLc = macho
            .parseLoadCommands(stripped)
            .singleWhere((c) => c.cmd == macho.lcCodeSignature);
        final sigBd = ByteData.sublistView(sigLc.bytes);
        final dataoff = sigBd.getUint32(8, Endian.little);
        final alt = _superBlobEntry(stripped, 0x1000);
        final altBd = ByteData.sublistView(alt);
        expect(altBd.getUint32(0, Endian.big), macho.csMagicCodeDirectory);
        final altSlots = altBd.getUint32(28, Endian.big);
        expect(altSlots, (dataoff + 0xfff) ~/ 0x1000);
        expect(altBd.getUint32(32, Endian.big), dataoff);
        final altIdent = altBd.getUint32(20, Endian.big);
        expect(_readCString(alt, altIdent), 'alt');
        final altHashOff = altBd.getUint32(16, Endian.big);
        for (var slot = 0; slot < altSlots; slot++) {
          final start = slot * 0x1000;
          var end = start + 0x1000;
          if (end > dataoff) end = dataoff;
          expect(
            alt.sublist(
              altHashOff + slot * 32,
              altHashOff + (slot + 1) * 32,
            ),
            equals(macho.sha256(Uint8List.sublistView(stripped, start, end))),
            reason: 'alternate page $slot hash',
          );
        }
      },
    );

    test(
      'strip keeps a version-0x20100 identifier at offset 44 byte-identical',
      () {
        final input = _buildStripIntegrityDylib(
          dyldInfoOnly: false,
          legacyIdent44: true,
        );
        final stripped = macho.patchMachO(
          input.bytes,
          macho.PatchOptions(stripSymbols: true),
        );
        _expectLinkeditSound(stripped, input.linkeditOff);
        _expectValidStripSignature(
          stripped,
          specialSlot: input.specialSlot,
          requirements: input.requirements,
          expectedIdent: 'fixture',
          expectedVersion: 0x20100,
          checkCodeLimit64Zero: false,
        );

        // Offset 44 holds the identifier `fixture\0`, not a scatter vector:
        // the strip drops a slot yet the identifier bytes come out unchanged.
        expect(
          _primaryCdBlob(stripped).sublist(44, 52),
          equals(_primaryCdBlob(input.bytes).sublist(44, 52)),
        );
        expect(
          _primaryCdBlob(stripped).sublist(44, 52),
          equals(ascii.encode('fixture\x00')),
        );
      },
    );

    test('strip leaves a binary without LC_SYMTAB unchanged', () {
      final input = _buildHeaderOnlyMachO();
      final stripped = macho.patchMachO(
        input,
        macho.PatchOptions(stripSymbols: true),
      );
      expect(stripped, equals(input));
    });
  });

  group('stripHardening (COV-24 follow-up, RT29-flutter)', () {
    /// Builds a small unsigned arm64 dylib with no `__LINKEDIT` segment for
    /// the in-place strip tests: two local symbols and one global, an empty
    /// `LC_DYSYMTAB`, and (with [bindInGap]) an `LC_DYLD_INFO` whose bind
    /// table sits between the symbol entries and the string table, modelling
    /// RT29-flutter finding 01.
    ({Uint8List bytes, int symoff, int stroff, int strsize})
    _buildNoLinkeditDylib({required bool bindInGap}) {
      final names = ['_local_a', '_local_b', '_kept_global'];
      final types = [0x0e, 0x0e, 0x0f];
      final strings = BytesBuilder(copy: false)..addByte(0);
      final strx = <int>[];
      for (final name in names) {
        strx.add(strings.length);
        strings.add(utf8.encode(name));
        strings.addByte(0);
      }
      final strBytes = strings.toBytes();
      final symBytes = BytesBuilder(copy: false);
      for (var i = 0; i < names.length; i++) {
        final entry = ByteData(16)
          ..setUint32(0, strx[i], Endian.little)
          ..setUint8(4, types[i])
          ..setUint8(5, 1)
          ..setUint16(6, 0, Endian.little)
          ..setUint64(8, 0x1000 + i * 8, Endian.little);
        symBytes.add(entry.buffer.asUint8List());
      }
      final symTab = symBytes.toBytes();

      // Headers first, then the symbol entries at 0x400 (room for appended
      // commands below), the bind-table gap when asked, then the strings.
      const symoff = 0x400;
      final bind = _patternBytes(77, 320);
      final bindOff = symoff + symTab.length;
      final stroff = bindOff + (bindInGap ? bind.length : 0);
      final fileSize = stroff + strBytes.length;

      final dyldCmd = Uint8List(48);
      final dyldBd = ByteData.sublistView(dyldCmd);
      dyldBd.setUint32(0, macho.lcDyldInfo, Endian.little);
      dyldBd.setUint32(4, 48, Endian.little);
      if (bindInGap) {
        dyldBd.setUint32(16, bindOff, Endian.little);
        dyldBd.setUint32(20, bind.length, Endian.little);
      }

      final commands = <Uint8List>[
        macho.buildLcSegment64((
          segname: '__TEXT',
          vmaddr: 0,
          vmsize: fileSize,
          fileoff: 0,
          filesize: fileSize,
          maxprot: 5,
          initprot: 5,
          nsects: 0,
          flags: 0,
        )).bytes,
        macho
            .buildLcSymtab(
              symoff: symoff,
              nsyms: names.length,
              stroff: stroff,
              strsize: strBytes.length,
            )
            .bytes,
        macho.buildLcDysymtab().bytes,
        macho.buildLcIdDylib('@rpath/InPlace.dylib').bytes,
        if (bindInGap) dyldCmd,
        macho
            .buildLcBuildVersion(
              platform: 2,
              minos: 0x000e0000,
              sdk: 0x00110000,
            )
            .bytes,
      ];
      var sizeofcmds = 0;
      for (final c in commands) {
        sizeofcmds += c.length;
      }
      final buf = Uint8List(fileSize);
      final bd = ByteData.sublistView(buf);
      bd.setUint32(0, macho.mhMagic64, Endian.little);
      bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
      bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
      bd.setUint32(12, macho.mhDylib, Endian.little);
      bd.setUint32(16, commands.length, Endian.little);
      bd.setUint32(20, sizeofcmds, Endian.little);
      bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
      var off = macho.mhHeaderSize64;
      for (final c in commands) {
        buf.setRange(off, off + c.length, c);
        off += c.length;
      }
      buf.setRange(symoff, symoff + symTab.length, symTab);
      if (bindInGap) buf.setRange(bindOff, bindOff + bind.length, bind);
      buf.setRange(stroff, stroff + strBytes.length, strBytes);
      return (
        bytes: buf,
        symoff: symoff,
        stroff: stroff,
        strsize: strBytes.length,
      );
    }

    test(
      'strip refuses an in-place rewrite over a resident bind table (RT29 01)',
      () {
        final input = _buildNoLinkeditDylib(bindInGap: true);
        expect(
          () => macho.patchMachO(
            input.bytes,
            macho.PatchOptions(stripSymbols: true),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('0x22'), contains('__LINKEDIT')),
            ),
          ),
        );
      },
    );

    test(
      'strip rewrites small tables in place when nothing else lives there',
      () {
        final input = _buildNoLinkeditDylib(bindInGap: false);
        final stripped = macho.patchMachO(
          input.bytes,
          macho.PatchOptions(stripSymbols: true),
        );
        // The file keeps its length: only the locals are gone.
        expect(stripped.length, input.bytes.length);
        final symtab = macho
            .parseLoadCommands(stripped)
            .singleWhere((c) => c.cmd == macho.lcSymtab);
        final sbd = ByteData.sublistView(symtab.bytes);
        expect(sbd.getUint32(8, Endian.little), input.symoff);
        expect(sbd.getUint32(12, Endian.little), 1);
        final newStroff = sbd.getUint32(16, Endian.little);
        expect(newStroff, input.symoff + 16);
        final newStrsize = sbd.getUint32(20, Endian.little);
        expect(newStrsize, '_kept_global'.length + 2);
        expect(
          stripped.sublist(newStroff, newStroff + newStrsize),
          equals([0, ...ascii.encode('_kept_global'), 0]),
        );
        // The freed tail is zeroed, and only the tail changed past the tables.
        final oldEnd = input.stroff + input.strsize;
        expect(
          stripped.sublist(newStroff + newStrsize, oldEnd),
          everyElement(0),
        );
        expect(
          stripped.sublist(input.symoff, newStroff + newStrsize),
          isNot(equals(input.bytes.sublist(input.symoff, oldEnd))),
        );
        // The range-free commands ride along byte-identical.
        final before = macho.parseLoadCommands(input.bytes);
        final after = macho.parseLoadCommands(stripped);
        for (final cmd in [macho.lcBuildVersion, macho.lcIdDylib]) {
          expect(
            after.singleWhere((c) => c.cmd == cmd).bytes,
            equals(before.singleWhere((c) => c.cmd == cmd).bytes),
          );
        }
      },
    );

    test('strip refuses a short LC_NOTE command (RT29 02 demo A)', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      // A 32-byte 0x31 command: owner plus a u32 (offset, size) pair where the
      // u64 pair belongs. Too short to be a note, so it must be refused.
      final note = Uint8List(32);
      final nbd = ByteData.sublistView(note);
      nbd.setUint32(0, macho.lcNote, Endian.little);
      nbd.setUint32(4, 32, Endian.little);
      note.setRange(8, 24, ascii.encode('0123456789abcdef'));
      nbd.setUint32(24, 15936, Endian.little);
      nbd.setUint32(28, 32, Endian.little);
      final boobyTrapped = _withAppendedCommand(input.bytes, note);
      expect(
        () => macho.patchMachO(
          boobyTrapped,
          macho.PatchOptions(stripSymbols: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('0x31'),
          ),
        ),
      );
    });

    test('strip refuses a second __LINKEDIT segment (RT29 02 demo B)', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      final linkedit2 = macho.buildLcSegment64((
        segname: '__LINKEDIT',
        vmaddr: 0x4000,
        vmsize: 320,
        fileoff: input.linkeditOff + 64,
        filesize: 320,
        maxprot: 1,
        initprot: 1,
        nsects: 0,
        flags: 0,
      )).bytes;
      final boobyTrapped = _withAppendedCommand(input.bytes, linkedit2);
      expect(
        () => macho.patchMachO(
          boobyTrapped,
          macho.PatchOptions(stripSymbols: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('more than one __LINKEDIT'),
          ),
        ),
      );
    });

    test('strip refuses a segment reaching into __LINKEDIT', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      final data = macho.buildLcSegment64((
        segname: '__DATA',
        vmaddr: 0x10000,
        vmsize: 0x200,
        fileoff: input.linkeditOff - 0x100,
        filesize: 0x200,
        maxprot: 3,
        initprot: 3,
        nsects: 0,
        flags: 0,
      )).bytes;
      final boobyTrapped = _withAppendedCommand(input.bytes, data);
      expect(
        () => macho.patchMachO(
          boobyTrapped,
          macho.PatchOptions(stripSymbols: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('__LINKEDIT'),
          ),
        ),
      );
    });

    test('strip moves a well-formed LC_NOTE down with __LINKEDIT', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      // A note payload past the end of the file, inside a grown __LINKEDIT.
      final payload = _patternBytes(99, 64);
      final noteOff = input.bytes.length;
      final grown = Uint8List.fromList([...input.bytes, ...payload]);
      final segBd = ByteData.sublistView(
        grown,
        macho.mhHeaderSize64 + 152,
        macho.mhHeaderSize64 + 152 + 72,
      );
      segBd.setUint64(
        32,
        segBd.getUint64(32, Endian.little) + payload.length,
        Endian.little,
      );
      segBd.setUint64(
        48,
        segBd.getUint64(48, Endian.little) + payload.length,
        Endian.little,
      );
      final note = Uint8List(40);
      final nbd = ByteData.sublistView(note);
      nbd.setUint32(0, macho.lcNote, Endian.little);
      nbd.setUint32(4, 40, Endian.little);
      note.setRange(8, 24, ascii.encode('com.apple.test\x00\x00'));
      nbd.setUint64(24, noteOff, Endian.little);
      nbd.setUint64(32, payload.length, Endian.little);
      final noted = _withAppendedCommand(grown, note);
      final stripped = macho.patchMachO(
        noted,
        macho.PatchOptions(stripSymbols: true),
      );
      final noteLc = macho
          .parseLoadCommands(stripped)
          .singleWhere((c) => c.cmd == macho.lcNote);
      final movedBd = ByteData.sublistView(noteLc.bytes);
      final newOff = movedBd.getUint64(24, Endian.little).toInt();
      expect(newOff, lessThan(noteOff));
      expect(newOff, greaterThanOrEqualTo(input.linkeditOff));
      expect(movedBd.getUint64(32, Endian.little), payload.length);
      expect(
        stripped.sublist(newOff, newOff + payload.length),
        equals(payload),
      );
      _expectLinkeditSound(stripped, input.linkeditOff);
      _expectValidStripSignature(
        stripped,
        specialSlot: input.specialSlot,
        requirements: input.requirements,
      );
    });

    test('strip refuses an unknown load command type', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      // Unknown type 0x99 carrying a u32 (offset, size) pair into __LINKEDIT:
      // the tool cannot know where its range really is, so it refuses by name.
      final unknown = Uint8List(24);
      ByteData.sublistView(unknown)
        ..setUint32(0, 0x99, Endian.little)
        ..setUint32(4, 24, Endian.little)
        ..setUint32(8, input.linkeditOff + 64, Endian.little)
        ..setUint32(12, 32, Endian.little);
      final boobyTrapped = _withAppendedCommand(input.bytes, unknown);
      expect(
        () => macho.patchMachO(
          boobyTrapped,
          macho.PatchOptions(stripSymbols: true),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('0x99'),
          ),
        ),
      );
    });

    test('strip carries known range-free commands untouched', () {
      final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
      // LC_MAIN must be range-free for real producer binaries to keep
      // stripping: it carries only an entry offset, no file range.
      final main = Uint8List(24);
      ByteData.sublistView(main)
        ..setUint32(0, macho.lcMain, Endian.little)
        ..setUint32(4, 24, Endian.little)
        ..setUint64(8, 0x1000, Endian.little)
        ..setUint64(16, 0, Endian.little);
      final withMain = _withAppendedCommand(input.bytes, main);
      final withVersion = _withAppendedCommand(
        withMain,
        macho
            .buildLcBuildVersion(
              platform: 2,
              minos: 0x000e0000,
              sdk: 0x00110000,
            )
            .bytes,
      );
      final stripped = macho.patchMachO(
        withVersion,
        macho.PatchOptions(stripSymbols: true),
      );
      final cmds = macho.parseLoadCommands(stripped);
      expect(
        cmds.singleWhere((c) => c.cmd == macho.lcMain).bytes,
        equals(main),
      );
      expect(
        cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion).bytes,
        equals(
          macho
              .parseLoadCommands(withVersion)
              .singleWhere((c) => c.cmd == macho.lcBuildVersion)
              .bytes,
        ),
      );
      _expectLinkeditSound(stripped, input.linkeditOff);
    });

    group('auditOutputRanges', () {
      Uint8List rangeCommand(int size) {
        final buf = Uint8List(size);
        ByteData.sublistView(buf)..setUint32(4, size, Endian.little);
        return buf;
      }

      test('refuses overlapping rewritten ranges', () {
        final a = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(a)
          ..setUint32(0, macho.lcFunctionStarts, Endian.little)
          ..setUint32(8, 0x3100, Endian.little)
          ..setUint32(12, 64, Endian.little);
        final b = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(b)
          ..setUint32(0, macho.lcDataInCode, Endian.little)
          ..setUint32(8, 0x3130, Endian.little)
          ..setUint32(12, 64, Endian.little);
        expect(
          () => macho.auditOutputRanges(
            [
              macho.LoadCommand(macho.lcFunctionStarts, a),
              macho.LoadCommand(macho.lcDataInCode, b),
            ],
            macho.RewrittenLayout(linkeditOff: 0x3000, fileLength: 0x5000),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('overlap'),
            ),
          ),
        );
      });

      test('accepts adjacent ranges sharing only an edge', () {
        final a = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(a)
          ..setUint32(0, macho.lcFunctionStarts, Endian.little)
          ..setUint32(8, 0x3100, Endian.little)
          ..setUint32(12, 64, Endian.little);
        final b = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(b)
          ..setUint32(0, macho.lcDataInCode, Endian.little)
          ..setUint32(8, 0x3140, Endian.little)
          ..setUint32(12, 64, Endian.little);
        expect(
          () => macho.auditOutputRanges(
            [
              macho.LoadCommand(macho.lcFunctionStarts, a),
              macho.LoadCommand(macho.lcDataInCode, b),
            ],
            macho.RewrittenLayout(linkeditOff: 0x3000, fileLength: 0x5000),
          ),
          returnsNormally,
        );
      });

      test('refuses ranges past the end of the file', () {
        final a = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(a)
          ..setUint32(0, macho.lcFunctionStarts, Endian.little)
          ..setUint32(8, 0x4ff0, Endian.little)
          ..setUint32(12, 64, Endian.little);
        expect(
          () => macho.auditOutputRanges(
            [macho.LoadCommand(macho.lcFunctionStarts, a)],
            macho.RewrittenLayout(linkeditOff: 0x3000, fileLength: 0x5000),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('past the end'),
            ),
          ),
        );
      });

      test('refuses managed ranges escaping __LINKEDIT', () {
        final symtab = macho
            .buildLcSymtab(
              symoff: 0x1000,
              nsyms: 1,
              stroff: 0x2000,
              strsize: 16,
            )
            .bytes;
        expect(
          () => macho.auditOutputRanges(
            [macho.LoadCommand(macho.lcSymtab, symtab)],
            macho.RewrittenLayout(linkeditOff: 0x3000, fileLength: 0x5000),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('escapes'),
            ),
          ),
        );
      });

      test('accepts disjoint ranges inside the rewritten image', () {
        final a = Uint8List.fromList(rangeCommand(16));
        ByteData.sublistView(a)
          ..setUint32(0, macho.lcFunctionStarts, Endian.little)
          ..setUint32(8, 0x3100, Endian.little)
          ..setUint32(12, 64, Endian.little);
        final symtab = macho
            .buildLcSymtab(
              symoff: 0x3200,
              nsyms: 1,
              stroff: 0x3210,
              strsize: 16,
            )
            .bytes;
        expect(
          () => macho.auditOutputRanges(
            [
              macho.LoadCommand(macho.lcFunctionStarts, a),
              macho.LoadCommand(macho.lcSymtab, symtab),
            ],
            macho.RewrittenLayout(linkeditOff: 0x3000, fileLength: 0x5000),
          ),
          returnsNormally,
        );
      });
    });

    group('stripInputRanges (round 2)', () {
      /// A 16-byte `LC_TWOLEVEL_HINTS` command naming [offset]/[size]: hints
      /// ride a strip untouched, so any past-the-end range they name must be
      /// refused by the input-side check, not laundered by the output audit.
      Uint8List hintsCommand(int offset, int size) {
        final buf = Uint8List(16);
        ByteData.sublistView(buf)
          ..setUint32(0, macho.lcTwolevelHints, Endian.little)
          ..setUint32(4, 16, Endian.little)
          ..setUint32(8, offset, Endian.little)
          ..setUint32(12, size ~/ 4, Endian.little);
        return buf;
      }

      test(
        'strip refuses a range ending past the input on the compacting path',
        () {
          final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
          final boobyTrapped = _withAppendedCommand(
            input.bytes,
            hintsCommand(input.bytes.length - 2, 4),
          );
          expect(
            () => macho.patchMachO(
              boobyTrapped,
              macho.PatchOptions(stripSymbols: true),
            ),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(contains('0x16'), contains('past the end')),
              ),
            ),
          );
        },
      );

      test('strip refuses a range starting past the input on the compacting '
          'path', () {
        final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          hintsCommand(input.bytes.length + 8, 8),
        );
        expect(
          () => macho.patchMachO(
            boobyTrapped,
            macho.PatchOptions(stripSymbols: true),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('0x16'), contains('past the end')),
            ),
          ),
        );
      });

      test('strip refuses a range past the input on the in-place path', () {
        final input = _buildNoLinkeditDylib(bindInGap: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          hintsCommand(input.bytes.length + 8, 8),
        );
        expect(
          () => macho.patchMachO(
            boobyTrapped,
            macho.PatchOptions(stripSymbols: true),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('0x16'), contains('past the end')),
            ),
          ),
        );
      });

      /// Builds a small unsigned arm64 dylib with `__LINKEDIT` whose stripped
      /// output is LONGER than its input: a single global symbol means
      /// nothing is removed, and the signature-alignment padding adds two
      /// bytes. With [badHints], an `LC_TWOLEVEL_HINTS` names a range ending
      /// past the input but inside that longer output, so only the
      /// input-side check can refuse it.
      ({Uint8List bytes, int fileLength}) _buildGrowingDylib({
        required bool badHints,
      }) {
        const linkeditOff = 0x3000;
        const name = '_global12345';
        final strBytes = Uint8List.fromList([0, ...ascii.encode(name), 0]);
        final symTab =
            (ByteData(16)
                  ..setUint32(0, 1, Endian.little)
                  ..setUint8(4, 0x0f)
                  ..setUint8(5, 1)
                  ..setUint16(6, 0, Endian.little)
                  ..setUint64(8, 0x1000, Endian.little))
                .buffer
                .asUint8List();
        // Payloads packed with no gaps: the only size change at strip time
        // is the signature padding below.
        final sigOff = linkeditOff + symTab.length + strBytes.length;
        final sigBlob = _patternBytes(55, 40);
        final fileLength = sigOff + sigBlob.length;
        final sigCmd = Uint8List(16);
        ByteData.sublistView(sigCmd)
          ..setUint32(0, macho.lcCodeSignature, Endian.little)
          ..setUint32(4, 16, Endian.little)
          ..setUint32(8, sigOff, Endian.little)
          ..setUint32(12, sigBlob.length, Endian.little);
        final commands = <Uint8List>[
          macho.buildLcSegment64((
            segname: '__TEXT',
            vmaddr: 0,
            vmsize: linkeditOff,
            fileoff: 0,
            filesize: linkeditOff,
            maxprot: 5,
            initprot: 5,
            nsects: 0,
            flags: 0,
          )).bytes,
          macho.buildLcSegment64((
            segname: '__LINKEDIT',
            vmaddr: 0x4000,
            vmsize: fileLength - linkeditOff,
            fileoff: linkeditOff,
            filesize: fileLength - linkeditOff,
            maxprot: 1,
            initprot: 1,
            nsects: 0,
            flags: 0,
          )).bytes,
          macho
              .buildLcSymtab(
                symoff: linkeditOff,
                nsyms: 1,
                stroff: linkeditOff + symTab.length,
                strsize: strBytes.length,
              )
              .bytes,
          sigCmd,
          if (badHints) hintsCommand(fileLength - 2, 4),
          macho.buildLcUuid(_patternBytes(7, 16)).bytes,
          macho.buildLcIdDylib('@rpath/Grow.dylib').bytes,
        ];
        var sizeofcmds = 0;
        for (final c in commands) {
          sizeofcmds += c.length;
        }
        final buf = Uint8List(fileLength);
        final bd = ByteData.sublistView(buf);
        bd.setUint32(0, macho.mhMagic64, Endian.little);
        bd.setUint32(4, macho.cpuTypeArm64, Endian.little);
        bd.setUint32(8, macho.cpuSubtypeArm64All, Endian.little);
        bd.setUint32(12, macho.mhDylib, Endian.little);
        bd.setUint32(16, commands.length, Endian.little);
        bd.setUint32(20, sizeofcmds, Endian.little);
        bd.setUint32(24, macho.mhNoReexportedDylibs, Endian.little);
        var off = macho.mhHeaderSize64;
        for (final c in commands) {
          buf.setRange(off, off + c.length, c);
          off += c.length;
        }
        buf.setRange(linkeditOff, linkeditOff + symTab.length, symTab);
        buf.setRange(
          linkeditOff + symTab.length,
          linkeditOff + symTab.length + strBytes.length,
          strBytes,
        );
        buf.setRange(sigOff, sigOff + sigBlob.length, sigBlob);
        return (bytes: buf, fileLength: fileLength);
      }

      test('a clean strip can emit an output longer than its input', () {
        final input = _buildGrowingDylib(badHints: false);
        final stripped = macho.stripLocalSymbols(
          input.bytes,
          macho.parseLoadCommands(input.bytes),
        );
        // Nothing is removed, but the signature padding adds two bytes: an
        // output-side audit alone could never refuse a range in those bytes.
        expect(stripped.bytes.length, input.fileLength + 2);
      });

      test('strip refuses a range the longer output would launder', () {
        final input = _buildGrowingDylib(badHints: true);
        expect(
          () => macho.stripLocalSymbols(
            input.bytes,
            macho.parseLoadCommands(input.bytes),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('0x16'), contains('past the end')),
            ),
          ),
        );
      });
    });

    group('stripHostileU64 (round 3)', () {
      /// A 40-byte `LC_NOTE` naming [offset]/[size]: notes ride a strip
      /// untouched outside `__LINKEDIT`, so a hostile u64 pair must be refused
      /// by the input-side check naming the command. `setInt64` authors the
      /// top-bit values `setUint64` cannot take: they read back negative.
      Uint8List noteCommand(int offset, int size) {
        final note = Uint8List(40);
        final nbd = ByteData.sublistView(note);
        nbd.setUint32(0, macho.lcNote, Endian.little);
        nbd.setUint32(4, 40, Endian.little);
        note.setRange(8, 24, ascii.encode('com.apple.test\x00\x00'));
        nbd.setUint64(24, offset, Endian.little);
        if (size < 0) {
          nbd.setInt64(32, size, Endian.little);
        } else {
          nbd.setUint64(32, size, Endian.little);
        }
        return note;
      }

      /// A `__DATA` segment at [fileoff] with a hostile [filesize] authored
      /// the same way.
      Uint8List hostileDataSegment(int fileoff, int filesize) {
        final seg = macho.buildLcSegment64((
          segname: '__DATA',
          vmaddr: 0x10000,
          vmsize: 0x1000,
          fileoff: fileoff,
          filesize: 0x1000,
          maxprot: 3,
          initprot: 3,
          nsects: 0,
          flags: 0,
        )).bytes;
        if (filesize < 0) {
          ByteData.sublistView(seg).setInt64(48, filesize, Endian.little);
        } else {
          ByteData.sublistView(seg).setUint64(48, filesize, Endian.little);
        }
        return seg;
      }

      void expectPastEnd(Uint8List bytes, Matcher name) {
        expect(
          () => macho.patchMachO(
            bytes,
            macho.PatchOptions(stripSymbols: true),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('past the end'), name),
            ),
          ),
        );
      }

      test('rangeWithinFile is overflow-safe and unsigned-correct', () {
        expect(macho.rangeWithinFile(0x100, 64, 0x2000), isTrue);
        expect(macho.rangeWithinFile(0x100, 0, 0x2000), isTrue);
        // A top-bit size reads back negative: outside every file.
        expect(
          macho.rangeWithinFile(0x100, -0x8000000000000000, 0x2000),
          isFalse,
        );
        // A top-bit offset reads back negative: outside every file.
        expect(
          macho.rangeWithinFile(-0x8000000000000000, 64, 0x2000),
          isFalse,
        );
        // Each part fits below 2^63, but the sum wraps negative: a naive
        // `offset + size <= length` sum would call this inside the file.
        expect(
          macho.rangeWithinFile(0x100, 0x7FFFFFFFFFFFFFFF, 0x2000),
          isFalse,
        );
        expect(
          macho.rangeWithinFile(0x7FFFFFFFFFFFF000, 0x2000, 0x2000),
          isFalse,
        );
        // Adjacent-to-end and empty-at-end ranges stay valid.
        expect(macho.rangeWithinFile(0x2000, 0, 0x2000), isTrue);
        expect(macho.rangeWithinFile(0x1FF0, 16, 0x2000), isTrue);
      });

      test(
        'strip refuses a note with a top-bit size on the compacting path',
        () {
          final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
          final boobyTrapped = _withAppendedCommand(
            input.bytes,
            noteCommand(0x100, -0x8000000000000000),
          );
          expectPastEnd(boobyTrapped, contains('0x31'));
        },
      );

      test('strip refuses a note with a top-bit size on the in-place path', () {
        final input = _buildNoLinkeditDylib(bindInGap: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          noteCommand(0x100, -0x8000000000000000),
        );
        expectPastEnd(boobyTrapped, contains('0x31'));
      });

      test('strip refuses a note whose offset and size sum past 2^63 on the '
          'compacting path', () {
        final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          noteCommand(0x100, 0x7FFFFFFFFFFFFFFF),
        );
        expectPastEnd(boobyTrapped, contains('0x31'));
      });

      test('strip refuses a note whose offset and size sum past 2^63 on the '
          'in-place path', () {
        final input = _buildNoLinkeditDylib(bindInGap: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          noteCommand(0x100, 0x7FFFFFFFFFFFFFFF),
        );
        expectPastEnd(boobyTrapped, contains('0x31'));
      });

      test('strip refuses a segment with a top-bit filesize on the compacting '
          'path', () {
        final input = _buildStripIntegrityDylib(dyldInfoOnly: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          hostileDataSegment(0x1000, -0x8000000000000000),
        );
        expectPastEnd(boobyTrapped, contains('__DATA'));
      });

      test('strip refuses a segment with a top-bit filesize on the in-place '
          'path', () {
        final input = _buildNoLinkeditDylib(bindInGap: false);
        final boobyTrapped = _withAppendedCommand(
          input.bytes,
          hostileDataSegment(0x1000, -0x8000000000000000),
        );
        expectPastEnd(boobyTrapped, contains('__DATA'));
      });
    });
  });

  group('CLI', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('macho_edit_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('stub and patch CLI round-trip', () {
      final stubPath = '${tempDir.path}/stub.dylib';
      final patchedPath = '${tempDir.path}/patched.dylib';

      macho.main([
        'stub',
        '--output',
        stubPath,
        '--arch',
        'arm64',
        '--platform',
        'ios',
        '--min-os',
        '13.0',
        '--install-name',
        '@rpath/App.framework/App',
      ]);

      macho.main([
        'patch',
        '--input',
        stubPath,
        '--output',
        patchedPath,
        '--platform',
        'ios',
        '--min-os',
        '15.0',
        '--sdk-version',
        '16.2',
        '--install-name',
        '@rpath/Updated.framework/Updated',
        '--rpath',
        '@executable_path/Frameworks,@loader_path/Frameworks',
      ]);

      final patchedBytes = File(patchedPath).readAsBytesSync();
      final cmds = macho.parseLoadCommands(patchedBytes);
      final idCmd = cmds.singleWhere((c) => c.cmd == macho.lcIdDylib);
      expect(_readCString(idCmd.bytes, 24), '@rpath/Updated.framework/Updated');
      final bvCmd = cmds.singleWhere((c) => c.cmd == macho.lcBuildVersion);
      final bvBd = ByteData.sublistView(bvCmd.bytes);
      expect(bvBd.getUint32(12, Endian.little), 0x000f0000);
      expect(bvBd.getUint32(16, Endian.little), 0x00100200);
    });

    test('patch --strip-symbols drops local symbols from the CLI', () {
      final inPath = '${tempDir.path}/strip_in.dylib';
      final outPath = '${tempDir.path}/strip_out.dylib';
      File(inPath).writeAsBytesSync(_buildUnstrippedDylib().bytes);

      macho.main([
        'patch',
        '--input',
        inPath,
        '--output',
        outPath,
        '--strip-symbols',
      ]);

      final stripped = File(outPath).readAsBytesSync();
      final table = _readTestSymtab(stripped);
      expect(table.names, [
        '_kDartSnapshotText',
        '_kDartSnapshotData',
        '_printf',
      ]);
      expect(_readTestDysymtabGroups(stripped), [0, 0, 0, 2, 2, 1]);
    });

    test('patch fails loudly on non-Mach-O and 32-bit Mach-O unless named in --allow-non-macho', () {
      final dummyIn = File('${tempDir.path}/dummy.dylib')
        ..writeAsStringSync('not a macho file');
      final macho32In = File('${tempDir.path}/legacy32.dylib')
        ..writeAsBytesSync(_buildMachO32());
      final dummyOut = File('${tempDir.path}/out.dylib');

      // Without --allow-non-macho, non-Mach-O fails with FormatException.
      expect(
        () => macho.main([
          'patch',
          '--input',
          dummyIn.path,
          '--output',
          dummyOut.path,
          '--install-name',
          '@rpath/Foo.framework/Foo',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dummy.dylib'), contains('non-Mach-O')),
          ),
        ),
      );

      // Without --allow-non-macho (or with a different name), 32-bit Mach-O fails.
      expect(
        () => macho.main([
          'patch',
          '--input',
          macho32In.path,
          '--output',
          dummyOut.path,
          '--install-name',
          '@rpath/Legacy.framework/Legacy',
          '--allow-non-macho',
          'Other.framework',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('legacy32.dylib'), contains('32-bit Mach-O')),
          ),
        ),
      );

      // Naming the input or framework in --allow-non-macho allows it through.
      macho.main([
        'patch',
        '--input',
        dummyIn.path,
        '--output',
        dummyOut.path,
        '--install-name',
        '@rpath/Foo.framework/Foo',
        '--allow-non-macho',
        'dummy.dylib',
      ]);
      expect(dummyOut.readAsStringSync(), 'not a macho file');

      // A 32-bit Mach-O named in --allow-non-macho still passes through
      // unchanged.
      final macho32Out = File('${tempDir.path}/legacy32_out.dylib');
      macho.main([
        'patch',
        '--input',
        macho32In.path,
        '--output',
        macho32Out.path,
        '--install-name',
        '@rpath/Legacy.framework/Legacy',
        '--allow-non-macho',
        'legacy32.dylib',
      ]);
      expect(macho32Out.readAsBytesSync(), macho32In.readAsBytesSync());
    });

    test(
      'patch with --allow-non-macho fails on a Mach-O the strip refuses',
      () {
        final refusedIn = File('${tempDir.path}/Refused.dylib')
          ..writeAsBytesSync(
            _withLocalRelocations(_buildUnstrippedDylib().bytes),
          );
        final refusedOut = File('${tempDir.path}/refused_out.dylib');

        expect(
          () => macho.main([
            'patch',
            '--input',
            refusedIn.path,
            '--output',
            refusedOut.path,
            '--strip-symbols',
            '--allow-non-macho',
            'Refused.dylib',
          ]),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Refused.dylib'), contains('table-of-contents')),
            ),
          ),
        );
        expect(refusedOut.existsSync(), isFalse);
      },
    );

    test('patch and copy-files with --allow-non-macho fail on a Mach-O the patch refuses', () {
      final stubIn = File('${tempDir.path}/archstub.dylib')
        ..writeAsBytesSync(
          macho.generateStubMachO(
            arch: 'arm64',
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('11.0'),
            sdkVersion: macho.parsePackedVersion('11.0'),
            installName: '@rpath/ArchStub.dylib',
          ),
        );
      final stubOut = File('${tempDir.path}/archstub_out.dylib');

      // Thinning an arm64 binary to x86_64 is a patch refusal, not a pass-through.
      expect(
        () => macho.main([
          'patch',
          '--input',
          stubIn.path,
          '--output',
          stubOut.path,
          '--arch',
          'x86_64',
          '--allow-non-macho',
          'archstub.dylib',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('archstub.dylib'), contains('does not match')),
          ),
        ),
      );
      expect(stubOut.existsSync(), isFalse);

      final stagedDir = '${tempDir.path}/archstub_staged';
      expect(
        () => macho.main([
          'copy-files',
          '--platform',
          'macos',
          '--min-os',
          '13.2',
          '--arch',
          'x86_64',
          '--allow-non-macho',
          'archstub.dylib',
          '--output-dir',
          stagedDir,
          stubIn.path,
          'archstub.dylib',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('archstub.dylib'), contains('does not match')),
          ),
        ),
      );
      expect(File('$stagedDir/archstub.dylib').existsSync(), isFalse);
    });

    test('patch with --allow-non-macho still patches a patchable Mach-O', () {
      final stubIn = File('${tempDir.path}/allowed.dylib')
        ..writeAsBytesSync(
          macho.generateStubMachO(
            arch: 'arm64',
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('10.15'),
            sdkVersion: macho.parsePackedVersion('10.15'),
            installName: '@rpath/Allowed.dylib',
          ),
        );
      final stubOut = File('${tempDir.path}/allowed_out.dylib');

      macho.main([
        'patch',
        '--input',
        stubIn.path,
        '--output',
        stubOut.path,
        '--platform',
        'macos',
        '--min-os',
        '13.2',
        '--sdk-version',
        '13.2',
        '--allow-non-macho',
        'allowed.dylib',
      ]);

      final bvCmd = macho
          .parseLoadCommands(stubOut.readAsBytesSync())
          .singleWhere((c) => c.cmd == macho.lcBuildVersion);
      expect(
        ByteData.sublistView(bvCmd.bytes).getUint32(12, Endian.little),
        0x000d0200,
      );
    });

    test('stub --type execute generates valid MH_EXECUTE Mach-O binary', () {
      final execPath = '${tempDir.path}/Runner';
      macho.main([
        'stub',
        '--type',
        'execute',
        '--output',
        execPath,
        '--arch',
        'arm64',
        '--platform',
        'ios',
        '--min-os',
        '14.0',
      ]);

      final bytes = File(execPath).readAsBytesSync();
      expect(macho.isMachO64(bytes), isTrue);
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(12, Endian.little), macho.mhExecute);
      expect(
        bd.getUint32(24, Endian.little),
        macho.mhNoundefs | macho.mhDyldlink | macho.mhTwolevel | macho.mhPie,
      );
      final cmds = macho.parseLoadCommands(bytes);
      expect(cmds.where((c) => c.cmd == macho.lcIdDylib), isEmpty);
      expect(cmds.where((c) => c.cmd == macho.lcBuildVersion).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcUuid).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcSymtab).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcDysymtab).length, 1);
      expect(cmds.where((c) => c.cmd == macho.lcRpath).length, 1);

      final macExecPath = '${tempDir.path}/MacRunner';
      macho.main([
        'stub',
        '--type',
        'execute',
        '--output',
        macExecPath,
        '--arch',
        'arm64',
        '--platform',
        'macos',
        '--min-os',
        '11.0',
      ]);
      final macCmds = macho.parseLoadCommands(
        File(macExecPath).readAsBytesSync(),
      );
      final macRpaths = macCmds
          .where((c) => c.cmd == macho.lcRpath)
          .map((c) => _readCString(c.bytes, 12))
          .toList();
      expect(
        macRpaths,
        containsAll([
          '@executable_path/../Frameworks',
          '@executable_path/Frameworks',
        ]),
      );
    });

    test('copy-assets copies directory tree and optional debug snapshots', () {
      final srcAssets = Directory('${tempDir.path}/src_assets/sub')
        ..createSync(recursive: true);
      File('${srcAssets.path}/a.txt').writeAsStringSync('hello');
      final dill = File('${tempDir.path}/app.dill')..writeAsStringSync('dill');
      final vmSnap = File('${tempDir.path}/vm.bin')..writeAsStringSync('vm');
      final isoSnap = File('${tempDir.path}/iso.bin')..writeAsStringSync('iso');
      final dstAssets = '${tempDir.path}/dst_assets';

      macho.main([
        'copy-assets',
        '--src',
        '${tempDir.path}/src_assets',
        '--dst',
        dstAssets,
        '--kernel-blob',
        dill.path,
        '--vm-snapshot-data',
        vmSnap.path,
        '--isolate-snapshot-data',
        isoSnap.path,
      ]);

      expect(File('$dstAssets/sub/a.txt').readAsStringSync(), 'hello');
      expect(File('$dstAssets/kernel_blob.bin').readAsStringSync(), 'dill');
      expect(File('$dstAssets/vm_snapshot_data').readAsStringSync(), 'vm');
      expect(
        File('$dstAssets/isolate_snapshot_data').readAsStringSync(),
        'iso',
      );
    });

    test(
      'assemble-macos-framework builds versioned macOS App.framework layout and zip',
      () {
        final dylibBytes = macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('15.0'),
          sdkVersion: macho.parsePackedVersion('15.0'),
          installName: '@rpath/App.framework/Versions/A/App',
        );
        final binFile = File('${tempDir.path}/App_bin')
          ..writeAsBytesSync(dylibBytes);
        const plistXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>\n'
            '  <key>CFBundleExecutable</key><string>App</string>\n'
            '  <key>CFBundleIdentifier</key><string>io.flutter.flutter.app</string>\n'
            '  <key>CFBundlePackageType</key><string>FMWK</string>\n'
            '</dict></plist>\n';
        final plistFile = File('${tempDir.path}/Info.plist')
          ..writeAsStringSync(plistXml);
        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync(recursive: true);
        File('${assetsDir.path}/AssetManifest.bin').writeAsBytesSync([9, 9]);
        final wrapperDir = '${tempDir.path}/wrapper';
        final outputZip = '${tempDir.path}/App.framework.zip';

        macho.main([
          'assemble-macos-framework',
          '--binary',
          binFile.path,
          '--info-plist',
          plistFile.path,
          '--assets',
          assetsDir.path,
          '--output-dir',
          wrapperDir,
          '--output-zip',
          outputZip,
        ]);

        final fwPath = '$wrapperDir/App.framework';
        expect(
          File('$fwPath/Versions/A/App').readAsBytesSync(),
          equals(dylibBytes),
        );
        expect(
          File('$fwPath/Versions/A/Resources/Info.plist').readAsStringSync(),
          plistXml,
        );
        expect(
          File(
            '$fwPath/Versions/A/Resources/flutter_assets/AssetManifest.bin',
          ).readAsBytesSync(),
          [9, 9],
        );
        expect(Link('$fwPath/Versions/Current').targetSync(), 'A');
        expect(Link('$fwPath/App').targetSync(), 'Versions/Current/App');
        expect(
          Link('$fwPath/Resources').targetSync(),
          'Versions/Current/Resources',
        );

        // Verify the framework directory and zip pass verifyMacosFramework.
        macho.verifyMacosFramework(
          fwPath,
          frameworkName: 'App',
          frameworkZipPath: outputZip,
        );

        // Corrupting a symlink into a regular file (as rules_apple's _add_files does
        // when AppleBundleInfo is absent) must fail verifyMacosFramework.
        Link('$fwPath/App').deleteSync();
        File('$fwPath/App').writeAsBytesSync(dylibBytes);
        expect(
          () => macho.verifyMacosFramework(fwPath, frameworkName: 'App'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Expected top-level symlink at'),
            ),
          ),
        );
      },
    );

    test(
      'extractFrameworkZip recreates the versioned layout with real symlinks',
      () {
        final dylibBytes = macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('15.0'),
          sdkVersion: macho.parsePackedVersion('15.0'),
          installName: '@rpath/App.framework/Versions/A/App',
        );
        final binFile = File('${tempDir.path}/App_bin2')
          ..writeAsBytesSync(dylibBytes);
        const plistXml =
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<plist version="1.0"><dict>\n'
            '  <key>CFBundleExecutable</key><string>App</string>\n'
            '  <key>CFBundleIdentifier</key><string>io.flutter.flutter.app</string>\n'
            '  <key>CFBundlePackageType</key><string>FMWK</string>\n'
            '</dict></plist>\n';
        final plistFile = File('${tempDir.path}/Info2.plist')
          ..writeAsStringSync(plistXml);
        final assetsDir = Directory('${tempDir.path}/flutter_assets2')
          ..createSync(recursive: true);
        File('${assetsDir.path}/a.txt').writeAsStringSync('asset');
        final wrapperDir = '${tempDir.path}/wrapper2';
        final outputZip = '${tempDir.path}/App2.framework.zip';

        macho.main([
          'assemble-macos-framework',
          '--binary',
          binFile.path,
          '--info-plist',
          plistFile.path,
          '--assets',
          assetsDir.path,
          '--output-dir',
          wrapperDir,
          '--output-zip',
          outputZip,
        ]);

        // A consumer extracts the archive locally instead of trusting Bazel
        // to stage the framework tree with its symlinks intact.
        final extractedRoot = Directory('${tempDir.path}/extracted')
          ..createSync(recursive: true);
        macho.extractFrameworkZip(
          File(outputZip).readAsBytesSync(),
          extractedRoot,
        );
        final fwPath = '${extractedRoot.path}/App.framework';
        expect(
          File('$fwPath/Versions/A/App').readAsBytesSync(),
          equals(dylibBytes),
        );
        expect(
          File('$fwPath/Versions/A/Resources/flutter_assets/a.txt')
              .readAsStringSync(),
          'asset',
        );
        expect(
          FileSystemEntity.typeSync(
            '$fwPath/Versions/Current',
            followLinks: false,
          ),
          FileSystemEntityType.link,
        );
        expect(Link('$fwPath/Versions/Current').targetSync(), 'A');
        expect(Link('$fwPath/App').targetSync(), 'Versions/Current/App');
        expect(
          Link('$fwPath/Resources').targetSync(),
          'Versions/Current/Resources',
        );
        macho.verifyMacosFramework(
          fwPath,
          frameworkName: 'App',
          frameworkZipPath: outputZip,
        );
      },
    );

    test('extractFrameworkZip refuses unsafe entry paths and targets', () {
      Directory fresh(String name) =>
          Directory('${tempDir.path}/$name')..createSync(recursive: true);

      // Well-formed entries extract with contents and link targets intact.
      final goodDir = fresh('good');
      macho.extractFrameworkZip(
        _storedZip(
          {
            'F/Versions/A/f': [1, 2, 3],
          },
          symlinks: {
            'F/Versions/Current': 'A',
            'F/top': 'Versions/Current/f',
          },
        ),
        goodDir,
      );
      expect(File('${goodDir.path}/F/Versions/A/f').readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(Link('${goodDir.path}/F/Versions/Current').targetSync(), 'A');
      expect(Link('${goodDir.path}/F/top').targetSync(), 'Versions/Current/f');

      // Parent escapes in entry paths.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            '../evil': [1],
          }),
          fresh('evil1'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            'F/../../evil': [1],
          }),
          fresh('evil2'),
        ),
        throwsA(isA<FormatException>()),
      );
      // Absolute entry path.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip({
            '/abs/evil': [1],
          }),
          fresh('evil3'),
        ),
        throwsA(isA<FormatException>()),
      );
      // Absolute and escaping symlink targets.
      expect(
        () => macho.extractFrameworkZip(
          _storedZip(
            {
              'F/Versions/A/f': [1],
            },
            symlinks: {'F/l': '/abs'},
          ),
          fresh('evil4'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => macho.extractFrameworkZip(
          _storedZip(
            {
              'F/Versions/A/f': [1],
            },
            symlinks: {'F/l': '../A'},
          ),
          fresh('evil5'),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'copy-files copies source files under basenames or explicit names and patches when --platform/--min-os are given',
      () {
        final f1 = File('${tempDir.path}/one/libadd.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('add');
        final f2 = File('${tempDir.path}/two/libsub.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('sub');
        final outDir = '${tempDir.path}/staged';

        macho.main([
          'copy-files',
          '--output-dir',
          outDir,
          f1.path,
          'libadd.dylib',
          f2.path,
        ]);

        expect(File('$outDir/libadd.dylib').readAsStringSync(), 'add');
        expect(File('$outDir/libsub.dylib').readAsStringSync(), 'sub');

        // With --platform and --min-os, copy-files rewrites LC_BUILD_VERSION on Mach-O dylibs
        // and rejects non-Mach-O files unless named in --allow-non-macho.
        final machoLib = File('${tempDir.path}/three/libreal.dylib')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(
            macho.generateStubMachO(
              arch: 'arm64',
              platform: macho.platformMacos,
              minOs: macho.parsePackedVersion('10.15'),
              sdkVersion: macho.parsePackedVersion('10.15'),
              installName: '@rpath/libreal.dylib',
            ),
          );
        final patchedStaged = '${tempDir.path}/staged_patched';
        expect(
          () => macho.main([
            'copy-files',
            '--platform',
            'macos',
            '--min-os',
            '13.2',
            '--sdk-version',
            '13.2',
            '--output-dir',
            patchedStaged,
            f1.path,
            'libadd.dylib',
          ]),
          throwsA(isA<FormatException>()),
        );

        macho.main([
          'copy-files',
          '--platform',
          'macos',
          '--min-os',
          '13.2',
          '--sdk-version',
          '13.2',
          '--allow-non-macho',
          'libadd.dylib',
          '--output-dir',
          patchedStaged,
          machoLib.path,
          'libreal.dylib',
          f1.path,
          'libadd.dylib',
        ]);

        final realCmds = macho.parseLoadCommands(
          File('$patchedStaged/libreal.dylib').readAsBytesSync(),
        );
        final bvBd = ByteData.sublistView(
          realCmds.singleWhere((c) => c.cmd == macho.lcBuildVersion).bytes,
        );
        expect(bvBd.getUint32(12, Endian.little), 0x000d0200);
        expect(File('$patchedStaged/libadd.dylib').readAsStringSync(), 'add');
      },
    );

    test('fat combines thin slices into a universal binary', () {
      final armPath = '${tempDir.path}/arm.dylib';
      final x86Path = '${tempDir.path}/x86.dylib';
      final fatPath = '${tempDir.path}/fat.dylib';
      File(armPath).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Fat.dylib',
        ),
      );
      File(x86Path).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'x86_64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Fat.dylib',
        ),
      );

      macho.main(['fat', '--output', fatPath, armPath, x86Path]);

      final fat = File(fatPath).readAsBytesSync();
      expect(macho.isFatMachO(fat), isTrue);
      expect(macho.extractFatSlices(fat).length, 2);
    });

    test('verify checks a thin dylib and writes the stamp file', () {
      final libPath = '${tempDir.path}/libverify.dylib';
      final stampPath = '${tempDir.path}/verified.stamp';
      File(libPath).writeAsBytesSync(
        macho.generateStubMachO(
          arch: 'arm64',
          platform: macho.platformMacos,
          minOs: macho.parsePackedVersion('11.0'),
          sdkVersion: macho.parsePackedVersion('11.0'),
          installName: '@rpath/Verify.dylib',
        ),
      );

      macho.main(['verify', '--input', libPath, '--output', stampPath]);

      expect(File(stampPath).readAsStringSync(), 'verified\n');
    });

    test('verify checks a binary inside a zip archive', () {
      final zipPath = '${tempDir.path}/app.zip';
      File(zipPath).writeAsBytesSync(
        _storedZip({
          'Payload/App': macho.generateStubMachO(
            arch: 'arm64',
            platform: macho.platformMacos,
            minOs: macho.parsePackedVersion('11.0'),
            sdkVersion: macho.parsePackedVersion('11.0'),
            installName: '@rpath/Verify.dylib',
          ),
        }),
      );
      final stampPath = '${tempDir.path}/zip.stamp';

      macho.main([
        'verify',
        '--input',
        zipPath,
        '--binary-relpath',
        'Payload/App',
        '--expect-entry',
        'Payload/App',
        '--output',
        stampPath,
      ]);
      expect(File(stampPath).readAsStringSync(), 'verified\n');

      expect(
        () => macho.main([
          'verify',
          '--input',
          zipPath,
          '--binary-relpath',
          'Payload/App',
          '--expect-entry',
          'Payload/Missing',
          '--output',
          stampPath,
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('thinFatMachO', () {
    test('reports a missing arch and 32-bit-only binaries', () {
      final arm = macho.generateStubMachO(
        arch: 'arm64',
        platform: macho.platformMacos,
        minOs: macho.parsePackedVersion('11.0'),
        sdkVersion: macho.parsePackedVersion('11.0'),
        installName: '@rpath/Thin.dylib',
      );
      final fat = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm64,
          cpusubtype: macho.cpuSubtypeArm64All,
          bytes: arm,
        ),
      ]);
      expect(
        () => macho.thinFatMachO(fat, 'x86_64'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('does not contain a slice'),
          ),
        ),
      );

      final fat32 = macho.buildFatMachO([
        macho.FatSlice(
          cputype: macho.cpuTypeArm,
          cpusubtype: 9,
          bytes: _buildMachO32(),
        ),
      ]);
      expect(
        () => macho.thinFatMachO(fat32, 'arm64'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('32-bit'),
          ),
        ),
      );
    });
  });

  group('frameworkZipDeflate', () {
    test('compresses large payloads and pins the archive bytes', () {
      final dir = Directory.systemTemp.createTempSync('macho_zip_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sliceDir = Directory('${dir.path}/App.framework/Versions/A')
        ..createSync(recursive: true);
      final big = Uint8List(8192);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i ~/ 64) & 0xff;
      }
      File('${sliceDir.path}/App').writeAsBytesSync(big);
      File('${sliceDir.path}/small.txt').writeAsStringSync('x');

      final zip = macho.createFrameworkZipBytes(
        Directory('${dir.path}/App.framework'),
        archiveRootName: 'App.framework',
        executableRelPaths: {'App.framework/Versions/A/App'},
      );

      // 8 KiB of repetitive payload must deflate well below its raw size.
      expect(zip.length, lessThan(1024));
      final entries = macho.readFrameworkZipEntries(zip);
      expect(entries.length, 2);
      expect(entries.singleWhere((e) => e.path.endsWith('/App')).data, big);
      expect(
        _hex(macho.sha256(zip)),
        'f8c76bcd3d1d1ac19ab345a1043d3916f94ce22b188951762bb5f66dcd838ec4',
      );
    });
  });
}
