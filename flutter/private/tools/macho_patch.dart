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
        findFirstPayloadOffset,
        parseLoadCommands;
import 'macho_strip.dart' show stripLocalSymbols;
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
      return _patchSingleMachO64(thinSlice, options);
    }
    return _patchFatMachO(inputBytes, options);
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

  return _patchSingleMachO64(inputBytes, options);
}

/// Patches every slice of a universal (fat) Mach-O binary and reassembles it,
/// preserving the fat32/fat64 header width.
Uint8List _patchFatMachO(Uint8List inputBytes, PatchOptions options) {
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
    final patchedBytes = _patchSingleMachO64(s.bytes, options);
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

Uint8List _patchSingleMachO64(Uint8List inputBytes, PatchOptions options) {
  // Locals: PatchOptions' public fields do not promote on null checks.
  final platform = options.platform;
  final minOs = options.minOs;
  final installName = options.installName;
  var workBytes = inputBytes;
  var originalCommands = parseLoadCommands(workBytes);
  if (options.stripSymbols) {
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
    _rewriteLoadCommand(lc, options, state);
  }

  if (platform != null && minOs != null && !state.wroteBuildVersion) {
    state.updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: options.sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !state.wroteIdDylib) {
    state.updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final rpath in options.rpaths) {
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
  LoadCommand lc,
  PatchOptions options,
  _PatchRewrite state,
) {
  // Locals: PatchOptions' public fields do not promote on null checks.
  final platform = options.platform;
  final minOs = options.minOs;
  final sdkVersion = options.sdkVersion;
  final installName = options.installName;
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
