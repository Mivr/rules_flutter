/// Mach-O patching: the `patch` subcommand and its core.
///
/// Rewrites load commands (`LC_BUILD_VERSION`, identities, rpaths) in thin
/// and Fat binaries via [patchMachO], resigning the embedded code signature.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'macho_cli.dart';
import 'macho_constants.dart';
import 'macho_fat.dart'
    show
        FatSlice,
        buildFatMachO,
        cpuTypeForArch,
        extractFatSlices,
        isFatMachO,
        isMachO32,
        isMachO64,
        thinFatMachO;
import 'macho_parse.dart'
    show
        LoadCommand,
        buildLcBuildVersion,
        buildLcIdDylib,
        buildLcRpath,
        buildLcSymtab,
        findFirstPayloadOffset,
        parseLoadCommands;
import 'macho_stub.dart' show sha256;

/// Writes [bytes] to [outputPath], creating parent directories as needed.
void _writePatchedOutput(Uint8List bytes, String outputPath) {
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

/// Parsed `patch` subcommand flags.
class _PatchArgs {
  _PatchArgs({
    required this.inputPath,
    required this.outputPath,
    required this.platformName,
    required this.minOsStr,
    required this.sdkVersionStr,
    required this.installName,
    required this.arch,
    required this.rpaths,
    required this.allowNonMacho,
    required this.stripSymbols,
  });

  final String? inputPath;
  final String? outputPath;
  final String? platformName;
  final String? minOsStr;
  final String? sdkVersionStr;
  final String? installName;
  final String? arch;
  final List<String> rpaths;
  final Set<String> allowNonMacho;

  /// Whether to drop local and stab symbols, `strip -x` style.
  final bool stripSymbols;
}

/// Parses `patch` flags; unknown flags fail usage.
_PatchArgs _parsePatchArgs(List<String> args) {
  String? inputPath;
  String? outputPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  String? arch;
  final rpaths = <String>[];
  final allowNonMacho = <String>{};
  var stripSymbols = false;
  final flags = FlagCursor(args);
  while (flags.moveNext()) {
    final arg = flags.current;
    if (arg.startsWith('--allow-non-macho=')) {
      addCommaParts(
        allowNonMacho,
        arg.substring('--allow-non-macho='.length),
      );
      continue;
    }
    switch (arg) {
      case '--strip-symbols':
        stripSymbols = true;
      case '--input':
        inputPath = flags.take('--input');
      case '--output':
        outputPath = flags.take('--output');
      case '--platform':
        platformName = flags.take('--platform');
      case '--min-os':
        minOsStr = flags.take('--min-os');
      case '--sdk-version':
        sdkVersionStr = flags.take('--sdk-version');
      case '--install-name':
        installName = flags.take('--install-name');
      case '--arch':
        arch = flags.take('--arch');
      case '--rpath':
        for (final part in flags.take('--rpath').split(',')) {
          if (part.isNotEmpty) rpaths.add(part);
        }
      case '--allow-non-macho':
        final next = flags.peek();
        if (next == null || next.startsWith('--')) {
          usageError(
            '--allow-non-macho requires an explicit binary or framework name',
          );
        }
        addCommaParts(allowNonMacho, flags.take('--allow-non-macho'));
      default:
        usageError('Unknown flag for patch: $arg');
    }
  }
  return _PatchArgs(
    inputPath: inputPath,
    outputPath: outputPath,
    platformName: platformName,
    minOsStr: minOsStr,
    sdkVersionStr: sdkVersionStr,
    installName: installName,
    arch: arch,
    rpaths: rpaths,
    allowNonMacho: allowNonMacho,
    stripSymbols: stripSymbols,
  );
}

/// Runs the `patch` subcommand: parses [args] and writes a patched Mach-O file.
void runPatch(List<String> args) {
  final parsed = _parsePatchArgs(args);
  final inputPath = parsed.inputPath;
  final outputPath = parsed.outputPath;
  if (inputPath == null || outputPath == null) {
    usageError('patch requires --input and --output');
  }

  final versions = parsePlatformVersions(
    parsed.platformName,
    parsed.minOsStr,
    parsed.sdkVersionStr,
  );

  final inputBytes = File(inputPath).readAsBytesSync();
  final isAllowed = isAllowedNonMacho(
    parsed.allowNonMacho,
    inputPath: inputPath,
    outputPath: outputPath,
    installName: parsed.installName,
  );

  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    _passThroughOrRejectPatchInput(
      inputBytes,
      inputPath,
      outputPath,
      isAllowed,
    );
    return;
  }

  final Uint8List patched;
  try {
    patched = patchMachO(
      inputBytes,
      PatchOptions(
        platform: versions.platform,
        minOs: versions.minOs,
        sdkVersion: versions.sdkVersion,
        installName: parsed.installName,
        rpaths: parsed.rpaths,
        arch: parsed.arch,
        stripSymbols: parsed.stripSymbols,
      ),
    );
  } on FormatException catch (e) {
    if (isAllowed) {
      _writePatchedOutput(inputBytes, outputPath);
      return;
    }
    throw FormatException('Input file "$inputPath": ${e.message}');
  }

  _writePatchedOutput(patched, outputPath);
}

/// Handles a non-64-bit `patch` input: passes it through when explicitly
/// allowed, otherwise throws the 32-bit or non-Mach-O error.
void _passThroughOrRejectPatchInput(
  Uint8List inputBytes,
  String inputPath,
  String outputPath,
  bool isAllowed,
) {
  if (isAllowed) {
    _writePatchedOutput(inputBytes, outputPath);
    return;
  }
  if (isMachO32(inputBytes)) {
    throw FormatException(
      'Input file "$inputPath" is an unsupported 32-bit Mach-O binary '
      '(0xfeedface). Only 64-bit Mach-O binaries are supported unless '
      'explicitly listed in allow_non_macho.',
    );
  }
  throw FormatException(
    'Input file "$inputPath" is a non-Mach-O file (not a 64-bit or '
    'universal Mach-O binary). Only Mach-O binaries are permitted unless '
    'explicitly listed in allow_non_macho.',
  );
}

/// Extracts the NUL-terminated string starting at [offset] in [bytes].
String _readLcString(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return '';
  var end = offset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
}

/// Resolved `patchMachO` options: platform versions, identity, and search
/// paths applied to the binary. Grouped so the patch entry points stay small.
class PatchOptions {
  const PatchOptions({
    this.platform,
    this.minOs,
    this.sdkVersion,
    this.installName,
    this.rpaths = const [],
    this.arch,
    this.stripSymbols = false,
  });

  /// The `LC_BUILD_VERSION` platform constant, if any.
  final int? platform;

  /// The packed minimum-OS version, if any.
  final int? minOs;

  /// The packed SDK version, if any.
  final int? sdkVersion;

  /// The new `LC_ID_DYLIB` install name, if any.
  final String? installName;

  /// The `LC_RPATH` entries to add.
  final List<String> rpaths;

  /// The fat slice to thin (`"arm64"` or `"x86_64"`), if any.
  final String? arch;

  /// Whether to drop local and stab symbols from `LC_SYMTAB`, `strip -x`
  /// style, keeping only exported and undefined symbols.
  final bool stripSymbols;
}

/// Patches a 64-bit or universal (fat) Mach-O binary in memory and recomputes
/// its embedded `LC_CODE_SIGNATURE` SHA-256 page hashes if present.
///
/// When [inputBytes] is a universal (fat) Mach-O binary:
/// - If [arch] is provided (`"arm64"` or `"x86_64"`), the fat binary is thinned
///   to that slice and the slice is patched.
/// - Otherwise, every slice in the fat binary is patched and reassembled into
///   a universal (fat) Mach-O binary.
///
/// Throws [FormatException] if [inputBytes] (or any slice being patched) is a
/// 32-bit Mach-O binary or non-Mach-O data.
Uint8List patchMachO(
  Uint8List inputBytes, [
  PatchOptions options = const PatchOptions(),
]) {
  final arch = options.arch;
  if (isFatMachO(inputBytes)) {
    if (arch != null) {
      final thinSlice = thinFatMachO(inputBytes, arch);
      return _patchSingleMachO64(
        thinSlice,
        platform: options.platform,
        minOs: options.minOs,
        sdkVersion: options.sdkVersion,
        installName: options.installName,
        rpaths: options.rpaths,
        stripSymbols: options.stripSymbols,
      );
    }
    return _patchFatMachO(
      inputBytes,
      platform: options.platform,
      minOs: options.minOs,
      sdkVersion: options.sdkVersion,
      installName: options.installName,
      rpaths: options.rpaths,
      stripSymbols: options.stripSymbols,
    );
  }

  if (isMachO32(inputBytes)) {
    throw const FormatException(
      'Unsupported 32-bit Mach-O binary (0xfeedface); only 64-bit Mach-O '
      'binaries are supported.',
    );
  }

  if (!isMachO64(inputBytes)) {
    throw const FormatException(
      'Not a Mach-O binary (expected 64-bit or universal Mach-O).',
    );
  }

  if (arch != null) {
    _checkThinArch(inputBytes, arch);
  }

  return _patchSingleMachO64(
    inputBytes,
    platform: options.platform,
    minOs: options.minOs,
    sdkVersion: options.sdkVersion,
    installName: options.installName,
    rpaths: options.rpaths,
    stripSymbols: options.stripSymbols,
  );
}

/// Patches every slice of a universal (fat) Mach-O binary and reassembles it,
/// preserving the fat32/fat64 header width.
Uint8List _patchFatMachO(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
  bool stripSymbols = false,
}) {
  final slices = extractFatSlices(inputBytes);
  final bd = ByteData.sublistView(inputBytes);
  final isFat64 =
      bd.getUint32(0, Endian.big) == fatMagic64 ||
      bd.getUint32(0, Endian.little) == fatMagic64;
  final patchedSlices = <FatSlice>[];
  for (var i = 0; i < slices.length; i++) {
    final s = slices[i];
    if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
      throw FormatException(
        'Fat Mach-O slice $i (cputype 0x${s.cputype.toRadixString(16)}) is '
        'an unsupported 32-bit Mach-O binary.',
      );
    }
    if (!isMachO64(s.bytes)) {
      throw FormatException(
        'Fat Mach-O slice $i is not a valid 64-bit Mach-O binary.',
      );
    }
    final patchedBytes = _patchSingleMachO64(
      s.bytes,
      platform: platform,
      minOs: minOs,
      sdkVersion: sdkVersion,
      installName: installName,
      rpaths: rpaths,
      stripSymbols: stripSymbols,
    );
    patchedSlices.add(
      FatSlice(
        cputype: s.cputype,
        cpusubtype: s.cpusubtype,
        align: s.align,
        bytes: patchedBytes,
      ),
    );
  }
  return buildFatMachO(patchedSlices, fat64: isFat64);
}

/// Throws when a thin binary's cputype is not the requested [arch].
void _checkThinArch(Uint8List inputBytes, String arch) {
  final targetCpu = cpuTypeForArch(arch);
  final actualCpu = ByteData.sublistView(
    inputBytes,
  ).getUint32(4, Endian.little);
  if (actualCpu != targetCpu) {
    throw FormatException(
      'Mach-O cputype 0x${actualCpu.toRadixString(16)} does not match '
      'requested architecture "$arch".',
    );
  }
}

Uint8List _patchSingleMachO64(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
  bool stripSymbols = false,
}) {
  var workBytes = inputBytes;
  var originalCommands = parseLoadCommands(workBytes);
  if (stripSymbols) {
    final stripped = stripLocalSymbols(workBytes, originalCommands);
    workBytes = stripped.bytes;
    originalCommands = stripped.commands;
  }
  final bdIn = ByteData.sublistView(workBytes);
  final oldSizeofcmds = bdIn.getUint32(20, Endian.little);
  final maxLoadCommandEnd = findFirstPayloadOffset(
    originalCommands,
    workBytes.length,
  );

  final state = _PatchRewrite();
  for (final lc in originalCommands) {
    _rewriteLoadCommand(
      lc,
      platform: platform,
      minOs: minOs,
      sdkVersion: sdkVersion,
      installName: installName,
      state: state,
    );
  }

  if (platform != null && minOs != null && !state.wroteBuildVersion) {
    state.updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !state.wroteIdDylib) {
    state.updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final rpath in rpaths) {
    if (state.existingRpaths.add(rpath)) {
      state.updatedCommands.add(buildLcRpath(rpath));
    }
  }

  if (state.codeSigCommand != null) {
    state.updatedCommands.add(state.codeSigCommand!);
  }

  return _emitPatchedMachO(
    workBytes,
    oldSizeofcmds,
    maxLoadCommandEnd,
    state.updatedCommands,
    state.codeSigCommand,
  );
}

/// Mutable rewrite state for [_patchSingleMachO64].
class _PatchRewrite {
  final updatedCommands = <LoadCommand>[];
  var wroteBuildVersion = false;
  var wroteIdDylib = false;
  final existingRpaths = <String>{};
  LoadCommand? codeSigCommand;
}

/// Rewrites one load command into [state], stripping legacy version-minimum
/// commands and holding `LC_CODE_SIGNATURE` last.
void _rewriteLoadCommand(
  LoadCommand lc, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  required _PatchRewrite state,
}) {
  // Strip legacy LC_VERSION_MIN_* commands when setting LC_BUILD_VERSION.
  if (platform != null &&
      (lc.cmd == lcVersionMinMacosx ||
          lc.cmd == lcVersionMinIphoneos ||
          lc.cmd == lcVersionMinTvos ||
          lc.cmd == lcVersionMinWatchos)) {
    return;
  }

  if (lc.cmd == lcBuildVersion && platform != null && minOs != null) {
    if (!state.wroteBuildVersion) {
      state.updatedCommands.add(
        buildLcBuildVersion(
          platform: platform,
          minos: minOs,
          sdk: sdkVersion ?? minOs,
        ),
      );
      state.wroteBuildVersion = true;
    }
    return;
  }

  if (lc.cmd == lcIdDylib && installName != null) {
    if (!state.wroteIdDylib) {
      final versions = _idDylibVersions(lc);
      state.updatedCommands.add(
        buildLcIdDylib(
          installName,
          timestamp: versions.timestamp,
          currentVersion: versions.currentVersion,
          compatibilityVersion: versions.compatibilityVersion,
        ),
      );
      state.wroteIdDylib = true;
    }
    return;
  }

  if (lc.cmd == lcRpath && lc.bytes.length >= 12) {
    final lcBd = ByteData.sublistView(lc.bytes);
    final pathOffset = lcBd.getUint32(8, Endian.little);
    state.existingRpaths.add(_readLcString(lc.bytes, pathOffset));
    state.updatedCommands.add(lc);
    return;
  }

  // Hold LC_CODE_SIGNATURE so any newly added load commands are placed
  // before LC_CODE_SIGNATURE (matching ld64 / vtool conventions).
  if (lc.cmd == lcCodeSignature && state.codeSigCommand == null) {
    state.codeSigCommand = lc;
    return;
  }

  state.updatedCommands.add(lc);
}

/// The version fields an `LC_ID_DYLIB` rewrite preserves, defaulting as new.
({int timestamp, int currentVersion, int compatibilityVersion})
_idDylibVersions(LoadCommand lc) {
  if (lc.bytes.length < 24) {
    return (
      timestamp: 2,
      currentVersion: 0x00010000,
      compatibilityVersion: 0x00010000,
    );
  }
  final lcBd = ByteData.sublistView(lc.bytes);
  return (
    timestamp: lcBd.getUint32(12, Endian.little),
    currentVersion: lcBd.getUint32(16, Endian.little),
    compatibilityVersion: lcBd.getUint32(20, Endian.little),
  );
}

/// Serializes [updatedCommands] over [inputBytes], growing a header-only
/// buffer or fitting before the first payload offset, then re-signs.
Uint8List _emitPatchedMachO(
  Uint8List inputBytes,
  int oldSizeofcmds,
  int maxLoadCommandEnd,
  List<LoadCommand> updatedCommands,
  LoadCommand? codeSigCommand,
) {
  var newSizeofcmds = 0;
  for (final lc in updatedCommands) {
    newSizeofcmds += lc.cmdsize;
  }

  final newLoadCmdEnd = mhHeaderSize64 + newSizeofcmds;
  // If the file has no payload sections/segments at all (header-only fixture)
  // and grows past EOF, extend the buffer; otherwise verify we fit before
  // the first payload offset.
  final bool isHeaderOnly =
      maxLoadCommandEnd == inputBytes.length &&
      mhHeaderSize64 + oldSizeofcmds == inputBytes.length;

  if (!isHeaderOnly && newLoadCmdEnd > maxLoadCommandEnd) {
    throw StateError(
      'Not enough header padding for load commands: need $newLoadCmdEnd bytes, '
      'first payload is at $maxLoadCommandEnd.',
    );
  }

  final outLength = isHeaderOnly
      ? math.max<int>(inputBytes.length, newLoadCmdEnd)
      : inputBytes.length;
  final out = Uint8List(outLength);
  out.setRange(0, inputBytes.length, inputBytes);

  // Zero the old load command region first so any shrinkage leaves clean zeroes.
  final clearEnd = math.min<int>(
    out.length,
    mhHeaderSize64 + math.max<int>(oldSizeofcmds, newSizeofcmds),
  );
  out.fillRange(mhHeaderSize64, clearEnd, 0);

  // Write updated header fields (ncmds, sizeofcmds) and load commands.
  final bdOut = ByteData.sublistView(out);
  bdOut.setUint32(16, updatedCommands.length, Endian.little);
  bdOut.setUint32(20, newSizeofcmds, Endian.little);

  var writeOffset = mhHeaderSize64;
  for (final lc in updatedCommands) {
    out.setRange(writeOffset, writeOffset + lc.cmdsize, lc.bytes);
    writeOffset += lc.cmdsize;
  }

  if (codeSigCommand != null) {
    _resignEmbeddedCodeSignature(out, codeSigCommand);
  }

  return out;
}

/// Recomputes SHA-256 page hashes inside `LC_CODE_SIGNATURE`'s `CS_CodeDirectory`
/// blob if present.
void _resignEmbeddedCodeSignature(Uint8List bytes, LoadCommand codeSigLc) {
  if (codeSigLc.bytes.length < 16) return;
  final lcBd = ByteData.sublistView(codeSigLc.bytes);
  final dataoff = lcBd.getUint32(8, Endian.little);
  final datasize = lcBd.getUint32(12, Endian.little);
  if (dataoff == 0 || datasize < 12 || dataoff + datasize > bytes.length) {
    return;
  }

  final bd = ByteData.sublistView(bytes);
  final superMagic = bd.getUint32(dataoff, Endian.big);
  if (superMagic != csMagicEmbeddedSignature) {
    return;
  }
  final blobCount = bd.getUint32(dataoff + 8, Endian.big);
  for (var i = 0; i < blobCount; i++) {
    final indexOff = dataoff + 12 + i * 8;
    if (indexOff + 8 > dataoff + datasize) break;
    final blobOffset = bd.getUint32(indexOff + 4, Endian.big);
    final cdOff = dataoff + blobOffset;
    if (cdOff + 44 > dataoff + datasize) continue;

    final blobMagic = bd.getUint32(cdOff, Endian.big);
    if (blobMagic != csMagicCodeDirectory) continue;

    final cdLength = bd.getUint32(cdOff + 4, Endian.big);
    final hashOffset = bd.getUint32(cdOff + 16, Endian.big);
    final nCodeSlots = bd.getUint32(cdOff + 28, Endian.big);
    final codeLimit = bd.getUint32(cdOff + 32, Endian.big);
    final hashSize = bd.getUint8(cdOff + 36);
    final hashType = bd.getUint8(cdOff + 37);
    final pageSizeShift = bd.getUint8(cdOff + 39);

    if (hashType != csHashTypeSha256 || hashSize != 32) {
      continue;
    }
    final pageSize = pageSizeShift > 0 ? (1 << pageSizeShift) : codeLimit;
    final hashesStart = cdOff + hashOffset;
    if (hashesStart + nCodeSlots * 32 > cdOff + cdLength ||
        hashesStart + nCodeSlots * 32 > bytes.length) {
      continue;
    }

    for (var slot = 0; slot < nCodeSlots; slot++) {
      final pageStart = slot * pageSize;
      final pageEnd = math.min<int>(pageStart + pageSize, codeLimit);
      if (pageStart >= bytes.length ||
          pageEnd > bytes.length ||
          pageStart >= pageEnd) {
        break;
      }
      final digest = sha256(Uint8List.sublistView(bytes, pageStart, pageEnd));
      bytes.setRange(
        hashesStart + slot * 32,
        hashesStart + (slot + 1) * 32,
        digest,
      );
    }
  }
}

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
  final kept = _partitionKept(table.entries);
  final ordered = [...kept.defined, ...kept.undefined];
  final remap = <int, int>{
    for (var i = 0; i < ordered.length; i++) ordered[i].index: i,
  };
  final strings = _buildKeptStrings(ordered);
  final newSymtab = _buildKeptSymtab(ordered, strings.offsets);

  final dysymtabIndex = commands.indexWhere((c) => c.cmd == lcDysymtab);
  _RemappedDysymtab? remapped;
  if (dysymtabIndex >= 0) {
    remapped = _remapDysymtab(
      inputBytes,
      commands[dysymtabIndex],
      remap,
      kept.defined.length,
      kept.undefined.length,
    );
  }

  final linkedit = _findLinkeditSegment(commands);
  if (linkedit == null) {
    return _stripInPlace(
      inputBytes,
      commands,
      symtabIndex,
      table,
      dysymtabIndex,
      remapped,
      newSymtab,
      strings.bytes,
    );
  }
  return _stripCompacting(
    inputBytes,
    commands,
    symtabIndex,
    table,
    dysymtabIndex,
    remapped,
    linkedit,
    newSymtab,
    strings.bytes,
  );
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

/// Splits [entries] into the survivors: defined externals first (keeping
/// their relative order), then undefined imports. Locals and stabs are gone.
({List<_NlistEntry> defined, List<_NlistEntry> undefined}) _partitionKept(
  List<_NlistEntry> entries,
) {
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
  return (defined: defined, undefined: undefined);
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
/// bytes, and the new offset [_layoutLinkeditPayloads] assigns it.
class _LinkeditPayload {
  _LinkeditPayload({
    required this.oldOffset,
    required this.oldSize,
    required this.bytes,
  });

  final int oldOffset;
  final int oldSize;
  final Uint8List bytes;
  int newOffset = -1;
}

/// Collects every `__LINKEDIT` payload besides the symbol and string tables:
/// the linkedit table commands' data ranges. Zero-length ranges are not
/// payloads; anything else is bounds-checked against the file.
void _collectTablePayloads(
  Uint8List inputBytes,
  List<LoadCommand> commands,
  List<_LinkeditPayload> into,
) {
  for (final lc in commands) {
    switch (lc.cmd) {
      case lcFunctionStarts:
      case lcDataInCode:
      case lcDyldInfo:
      case lcDyldInfoOnly:
      case lcDyldExportsTrie:
      case lcDyldChainedFixups:
      case lcCodeSignature:
        if (lc.bytes.length < 16) {
          throw FormatException(
            'Truncated load command 0x${lc.cmd.toRadixString(16)}.',
          );
        }
        final bd = ByteData.sublistView(lc.bytes);
        final dataoff = bd.getUint32(8, Endian.little);
        final datasize = bd.getUint32(12, Endian.little);
        if (datasize == 0) continue;
        if (dataoff + datasize > inputBytes.length) {
          throw FormatException(
            'Load command 0x${lc.cmd.toRadixString(16)} points past the '
            'end of the file.',
          );
        }
        into.add(
          _LinkeditPayload(
            oldOffset: dataoff,
            oldSize: datasize,
            bytes: Uint8List.fromList(
              inputBytes.sublist(dataoff, dataoff + datasize),
            ),
          ),
        );
    }
  }
}

/// Throws when any segment or section file range outside `__LINKEDIT` reaches
/// into [linkeditOff]: the compacting rewrite below rebuilds everything from
/// there to the end of the file, so nothing else may live there.
void _checkNoPayloadPastLinkedit(
  Uint8List inputBytes,
  List<LoadCommand> commands,
  int linkeditOff,
) {
  for (final lc in commands) {
    if (lc.cmd != lcSegment64 || lc.bytes.length < 72) continue;
    final bd = ByteData.sublistView(lc.bytes);
    final name = ascii.decode(lc.bytes.sublist(8, 24)).split('\x00').first;
    if (name == '__LINKEDIT') continue;
    _checkRangeOutsideLinkedit(
      inputBytes.length,
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
      _checkRangeOutsideLinkedit(
        inputBytes.length,
        linkeditOff,
        sectBd.getUint32(48, Endian.little),
        sectBd.getUint64(40, Endian.little),
        'a section of segment $name',
      );
    }
  }
}

/// Throws when the file range [offset]/[size] overlaps [linkeditOff].
void _checkRangeOutsideLinkedit(
  int fileLength,
  int linkeditOff,
  int offset,
  int size,
  String what,
) {
  if (size == 0 || offset >= fileLength) return;
  if (offset + size > linkeditOff && offset < fileLength) {
    throw FormatException(
      'Cannot strip local symbols: $what reaches into __LINKEDIT.',
    );
  }
}

/// Lays [payloads] out contiguously from [linkeditOff] in file order,
/// failing on overlapping or out-of-file original ranges.
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
        payload.oldOffset + payload.oldSize > fileLength) {
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
    payload.newOffset = cursor;
    cursor += payload.bytes.length;
  }
  return cursor - linkeditOff;
}

/// Rewrites the symbol tables in place (no `__LINKEDIT` segment to resize):
/// the compacted tables must fit where the old ones were, and the freed tail
/// is zeroed. Used only for binaries without a `__LINKEDIT` segment.
StrippedSymbols _stripInPlace(
  Uint8List inputBytes,
  List<LoadCommand> commands,
  int symtabIndex,
  _SymtabTable table,
  int dysymtabIndex,
  _RemappedDysymtab? remapped,
  Uint8List newSymtab,
  Uint8List newStrings,
) {
  final oldEnd = table.stroff + table.strsize;
  if (table.symoff + newSymtab.length + newStrings.length > oldEnd) {
    throw const FormatException(
      'Cannot strip local symbols without a __LINKEDIT segment to shrink.',
    );
  }
  final out = Uint8List.fromList(inputBytes);
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
  return StrippedSymbols(
    out,
    _updatedStripCommands(
      commands,
      symtabIndex,
      table.symoff,
      newSymtab.length ~/ 16,
      newStroff,
      newStrings.length,
      dysymtabIndex,
      remapped,
      remapped?.indirectOffset ?? 0,
      null,
      null,
    ),
  );
}

/// Rebuilds `__LINKEDIT` from [linkeditOff]: the compacted symbol table, the
/// compacted string table, then every other linkedit payload in file order,
/// and truncates the file after the last one.
StrippedSymbols _stripCompacting(
  Uint8List inputBytes,
  List<LoadCommand> commands,
  int symtabIndex,
  _SymtabTable table,
  int dysymtabIndex,
  _RemappedDysymtab? remapped,
  LoadCommand linkedit,
  Uint8List newSymtab,
  Uint8List newStrings,
) {
  final linkeditBd = ByteData.sublistView(linkedit.bytes);
  final linkeditOff = linkeditBd.getUint64(40, Endian.little).toInt();
  _checkNoPayloadPastLinkedit(inputBytes, commands, linkeditOff);
  final symPayload = _LinkeditPayload(
    oldOffset: table.symoff,
    oldSize: table.nsyms * 16,
    bytes: newSymtab,
  );
  final strPayload = _LinkeditPayload(
    oldOffset: table.stroff,
    oldSize: table.strsize,
    bytes: newStrings,
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
  _collectTablePayloads(inputBytes, commands, payloads);
  final newLinkeditSize = _layoutLinkeditPayloads(
    payloads,
    linkeditOff,
    inputBytes.length,
  );

  final out = Uint8List(linkeditOff + newLinkeditSize);
  out.setRange(0, linkeditOff, inputBytes);
  final moved = <int, int>{};
  for (final payload in payloads) {
    out.setRange(
      payload.newOffset,
      payload.newOffset + payload.bytes.length,
      payload.bytes,
    );
    moved[payload.oldOffset] = payload.newOffset;
  }
  return StrippedSymbols(
    out,
    _updatedStripCommands(
      commands,
      symtabIndex,
      symPayload.newOffset,
      newSymtab.length ~/ 16,
      strPayload.newOffset,
      newStrings.length,
      dysymtabIndex,
      remapped,
      indirectPayload?.newOffset ?? 0,
      moved,
      (linkedit, newLinkeditSize),
    ),
  );
}

/// Returns [commands] with the stripped table positions applied: a rebuilt
/// `LC_SYMTAB`, regrouped `LC_DYSYMTAB`, moved table data offsets from
/// [movedOffsets] (null keeps every offset: the in-place rewrite), and a
/// resized `__LINKEDIT` segment when [resizedLinkedit] is given.
List<LoadCommand> _updatedStripCommands(
  List<LoadCommand> commands,
  int symtabIndex,
  int newSymoff,
  int newNsyms,
  int newStroff,
  int newStrsize,
  int dysymtabIndex,
  _RemappedDysymtab? remapped,
  int newIndirectOff,
  Map<int, int>? movedOffsets,
  (LoadCommand, int)? resizedLinkedit,
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
          symoff: newSymoff,
          nsyms: newNsyms,
          stroff: newStroff,
          strsize: newStrsize,
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
    if (movedOffsets != null && _isMovedTableCommand(lc)) {
      final bd = ByteData.sublistView(lc.bytes);
      final dataoff = bd.getUint32(8, Endian.little);
      final datasize = bd.getUint32(12, Endian.little);
      if (datasize != 0 && movedOffsets.containsKey(dataoff)) {
        final bytes = Uint8List.fromList(lc.bytes);
        ByteData.sublistView(
          bytes,
        ).setUint32(8, movedOffsets[dataoff]!, Endian.little);
        updated.add(LoadCommand(lc.cmd, bytes));
        continue;
      }
    }
    updated.add(lc);
  }
  return updated;
}

/// Whether [lc] is a linkedit table command whose data offset the compacting
/// rewrite moves (besides the symbol tables, handled separately).
bool _isMovedTableCommand(LoadCommand lc) {
  switch (lc.cmd) {
    case lcFunctionStarts:
    case lcDataInCode:
    case lcDyldInfo:
    case lcDyldInfoOnly:
    case lcDyldExportsTrie:
    case lcDyldChainedFixups:
    case lcCodeSignature:
      return lc.bytes.length >= 16;
    default:
      return false;
  }
}
