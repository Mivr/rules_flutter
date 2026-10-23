/// Verifies the device release `App.framework` is what a release engineer
/// ships: a real AOT snapshot for a physical iPhone, obfuscated, with split
/// debug info and a tree-shaken icon font.
///
/// Reads the two `:app_release_device` bundles (the obfuscated release and
/// its un-obfuscated twin, both built `-c opt` for `arm64`) and the debug
/// simulator bundle `:app_simulator`, and checks:
///
/// * `App.framework/App` parses as a 64-bit Mach-O for arm64 whose
///   `LC_BUILD_VERSION` platform is iOS (2), not the simulator (7), and whose
///   dyld exports (or symbol table) carry the AOT snapshot symbols
///   (`kDartVmSnapshotInstructions`, `kDartIsolateSnapshotInstructions`);
/// * the snapshot itself targets iOS on arm64: its VM features string (whose
///   first word is `product` in a release build) names `arm64` and `ios`,
///   not `macos` (the framework rule stamps `LC_BUILD_VERSION` itself, so
///   the load command alone cannot show what the snapshot was compiled for);
/// * obfuscation: the class `MyApp` from `lib/main.dart` is absent from the
///   release binary but present in the twin's, so the check cannot pass
///   vacuously;
/// * split debug info: the `.symbols` file exists, is non-empty, and carries
///   an object-file magic;
/// * icon tree shaking: `fonts/MaterialIcons-Regular.otf` in the release
///   framework's `flutter_assets/` is at most a tenth of the same font in the
///   debug bundle (which is never tree-shaken) and stays a valid OpenType
///   file.
///
/// The Mach-O header and load commands are parsed here with `dart:typed_data`
/// (`otool`/`nm` are not consulted). Every failed assertion prints what it
/// expected and what it found. A missing input fails the test; nothing here
/// is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// AOT snapshot symbols the release binary must export, without their
/// leading underscore (the export trie keeps it, the byte search does not
/// care, so both spellings are accepted below).
const _vmInstructions = 'kDartVmSnapshotInstructions';

/// The isolate snapshot symbol, as above.
const _isolateInstructions = 'kDartIsolateSnapshotInstructions';

/// Class in `lib/main.dart` that obfuscation must rename away.
const _obfuscatedClass = 'MyApp';

/// Basename of the split-debug-info file the release application emits.
const _symbolsName = 'app_flutter_release.symbols';

/// Path suffix of the subset icon font inside a framework's `flutter_assets`.
const _fontSuffix = 'flutter_assets/fonts/MaterialIcons-Regular.otf';

/// Basename of the debug simulator bundle in the test's `data`.
const _debugIpaName = 'app.ipa';

/// Mach-O magic of a little-endian 64-bit binary.
const _magic64 = 0xfeedfacf;

/// Mach-O `cputype` of arm64.
const _cpuArm64 = 0x0100000c;

/// `LC_BUILD_VERSION` load command number.
const _lcBuildVersion = 0x32;

/// `LC_SYMTAB` load command number.
const _lcSymtab = 0x2;

/// `LC_DYLD_INFO_ONLY` load command number.
const _lcDyldInfoOnly = 0x80000022;

/// `LC_DYLD_EXPORTS_TRIE` load command number.
const _lcDyldExportsTrie = 0x80000033;

/// `LC_BUILD_VERSION` platform number of iOS (7 would be the simulator).
const _platformIos = 2;

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    _abort('FAIL: missing TEST_SRCDIR or TEST_WORKSPACE env vars');
  }
  final files = _allFiles(Directory('$srcDir/$workspace'));

  final releaseApp = _takeSingle(
    files,
    _isReleaseApp,
    'one release App.framework/App in the runfiles',
  );
  final twinApp = _takeSingle(
    files,
    _isTwinApp,
    'one un-obfuscated twin App.framework/App in the runfiles',
  );
  final symbols = _takeSingle(
    files,
    _isSymbols,
    'one $_symbolsName in the runfiles',
  );
  final releaseFont = _takeSingle(
    files,
    _isReleaseFont,
    'one release $_fontSuffix in the runfiles',
  );
  final debugIpa = _takeSingle(
    files,
    _isDebugIpa,
    'one $_debugIpaName in the runfiles',
  );

  final report = _Report();
  final releaseBytes = _readOrAbort(releaseApp);
  final twinBytes = _readOrAbort(twinApp);
  _checkMachO(report, 'release', releaseApp.path, releaseBytes);
  _checkMachO(report, 'twin', twinApp.path, twinBytes);
  _checkFeatures(report, 'release', releaseApp.path, releaseBytes);
  _checkFeatures(report, 'twin', twinApp.path, twinBytes);
  _checkObfuscation(
    report,
    releaseBytes,
    releaseApp.path,
    twinBytes,
    twinApp.path,
  );
  _checkSymbols(report, symbols);
  _checkIconSubset(report, releaseFont, _readDebugFont(debugIpa));

  if (!report.passed) exit(1);
  print(
    'PASS: the device release App.framework is an obfuscated AOT '
    'snapshot with split debug info and tree-shaken icons',
  );
}

/// Stops the test with [message]: a missing input fails, never skips.
Never _abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// Every file under [root], following the runfiles symlinks.
List<File> _allFiles(Directory root) {
  final out = <File>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) out.add(entity);
  }
  return out;
}

/// Whether [file] is the obfuscated release framework binary.
bool _isReleaseApp(File file) {
  final path = file.path;
  return path.endsWith('App.framework/App') && !path.contains('plain');
}

/// Whether [file] is the un-obfuscated twin framework binary.
bool _isTwinApp(File file) {
  final path = file.path;
  return path.endsWith('App.framework/App') && path.contains('plain');
}

/// Whether [file] is the release split-debug-info file.
bool _isSymbols(File file) => file.path.endsWith('/$_symbolsName');

/// Whether [file] is the release framework's subset icon font.
bool _isReleaseFont(File file) {
  final path = file.path;
  return path.contains(_fontSuffix) && !path.contains('plain');
}

/// Whether [file] is the debug simulator bundle.
bool _isDebugIpa(File file) => file.path.endsWith('/$_debugIpaName');

/// The single file matching [matches], or a failure naming what was found.
File _takeSingle(
  List<File> files,
  bool Function(File) matches,
  String description,
) {
  final hits = [
    for (final f in files)
      if (matches(f)) f,
  ];
  if (hits.length != 1) {
    final paths = [for (final f in hits.take(4)) f.path].join(', ');
    _abort(
      'FAIL: expected $description; found ${hits.length}'
      '${paths.isEmpty ? '' : ': $paths'}',
    );
  }
  return hits[0];
}

/// The bytes of [file], or a failure naming the read error.
Uint8List _readOrAbort(File file) {
  try {
    return file.readAsBytesSync();
  } on FileSystemException catch (e) {
    _abort('FAIL: could not read ${file.path}: $e');
  }
}

/// Collects passing and failing checks; every failure names expected/found.
class _Report {
  final _failures = <String>[];

  /// Whether every check so far passed.
  bool get passed => _failures.isEmpty;

  /// Records one check of [description], printing the outcome.
  void check(String description, {required bool ok, String? found}) {
    if (ok) {
      print('OK: $description');
    } else {
      stderr.writeln(
        'FAIL: expected $description; found ${found ?? 'nothing'}',
      );
      _failures.add(description);
    }
  }
}

/// Checks [bytes] is a 64-bit arm64 Mach-O for iOS exporting the snapshot.
void _checkMachO(_Report report, String role, String path, Uint8List bytes) {
  _MachO macho;
  try {
    macho = _parseMachO(bytes);
  } on FormatException catch (e) {
    report.check(
      'a $role App binary whose Mach-O header and load commands parse',
      ok: false,
      found: '$e in $path',
    );
    return;
  }
  report
    ..check(
      'a $role App binary that is a 64-bit Mach-O for arm64',
      ok: macho.cpuType == _cpuArm64,
      found: 'cputype 0x${macho.cpuType.toRadixString(16)} in $path',
    )
    ..check(
      'a $role App binary targeting iOS (platform $_platformIos), '
      'not the simulator',
      ok: macho.platform == _platformIos,
      found: macho.platform == null
          ? 'no LC_BUILD_VERSION in $path'
          : 'platform ${macho.platform} in $path',
    );
  for (final symbol in [_vmInstructions, _isolateInstructions]) {
    report.check(
      'a $role App binary exporting the AOT snapshot symbol $symbol',
      ok: macho.exportNames.any((n) => n == symbol || n == '_$symbol'),
      found:
          '${macho.exportNames.length} exported names in $path, '
          'none of them $symbol',
    );
  }
}

/// Checks the snapshot was compiled for iOS on arm64, not for macOS.
///
/// The VM embeds its features as a space-separated word string whose first
/// word is `product` in a release build; the target CPU and OS are words of
/// it. The framework rule stamps `LC_BUILD_VERSION` itself, so only this
/// string shows what gen_snapshot actually compiled for.
void _checkFeatures(_Report report, String role, String path, Uint8List bytes) {
  final features = _featuresString(bytes);
  final words = features.split(' ');
  report
    ..check(
      'a $role App binary whose snapshot features start with product '
      '(a release snapshot)',
      ok: words.isNotEmpty && words.first == 'product',
      found: features.isEmpty ? 'no features string in $path' : features,
    )
    ..check(
      'a $role App binary whose snapshot features name arm64',
      ok: words.contains('arm64'),
      found: features.isEmpty ? 'no features string in $path' : features,
    )
    ..check(
      'a $role App binary whose snapshot features name ios, not macos',
      ok: words.contains('ios') && !words.contains('macos'),
      found: features.isEmpty ? 'no features string in $path' : features,
    );
}

/// The VM features string in [bytes], or empty when the binary holds none.
///
/// The string is a space-separated word list starting at `product` (for
/// example `product no-asan ... arm64 ios no-compressed-pointers`). It is
/// stored glued to a hash with no separator, so it is found by its opening
/// word rather than as a whole printable run, and read to the next
/// non-printable byte.
String _featuresString(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final at = text.indexOf('product ');
  if (at < 0) return '';
  var end = at;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit < 0x20 || unit > 0x7e) break;
    end++;
  }
  return text.substring(at, end);
}

/// Checks the class is gone from the release binary but kept in the twin.
void _checkObfuscation(
  _Report report,
  Uint8List releaseBytes,
  String releasePath,
  Uint8List twinBytes,
  String twinPath,
) {
  final needle = utf8.encode(_obfuscatedClass);
  report
    ..check(
      'a release App binary that hides $_obfuscatedClass (obfuscated)',
      ok: !_hasBytes(releaseBytes, needle),
      found: 'the name $_obfuscatedClass in $releasePath',
    )
    ..check(
      'an un-obfuscated twin App binary that keeps $_obfuscatedClass, '
      'so the check above cannot pass vacuously',
      ok: _hasBytes(twinBytes, needle),
      found: 'no $_obfuscatedClass bytes in $twinPath',
    );
}

/// Checks the `.symbols` file is non-empty and carries an object magic.
void _checkSymbols(_Report report, File symbols) {
  final bytes = _readOrAbort(symbols);
  report.check(
    'a non-empty split-debug-info .symbols file',
    ok: bytes.isNotEmpty,
    found: '${bytes.length} bytes at ${symbols.path}',
  );
  if (bytes.length < 4) return;
  final view = ByteData.sublistView(bytes, 0, 4);
  final magic = view.getUint32(0, Endian.little);
  final magicBig = view.getUint32(0);
  final isElf =
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46;
  report.check(
    'a .symbols file that is an object file (a Mach-O or ELF magic)',
    ok:
        magic == 0xfeedface ||
        magic == _magic64 ||
        magicBig == 0xcafebabe ||
        magicBig == 0xcefaedfe ||
        magicBig == 0xcffaedfe ||
        isElf,
    found: 'first bytes 0x${magic.toRadixString(16)} at ${symbols.path}',
  );
}

/// Checks the release icon font is a small, still-valid subset of the debug
/// font.
void _checkIconSubset(_Report report, File releaseFont, _FontPair fonts) {
  final releaseBytes = _readOrAbort(releaseFont);
  report
    ..check(
      'a tree-shaken icon font at most a tenth of the debug font '
      '(${fonts.debugBytes.length} bytes)',
      ok: releaseBytes.length * 10 <= fonts.debugBytes.length,
      found: '${releaseBytes.length} bytes at ${releaseFont.path}',
    )
    ..check(
      'a tree-shaken icon font that stays a valid OpenType file',
      ok: _isOpenType(releaseBytes),
      found:
          '${releaseBytes.length} bytes at ${releaseFont.path} '
          'starting with ${_fontTag(releaseBytes)}',
    );
}

/// The release font under test beside the debug font it is measured against.
class _FontPair {
  const _FontPair(this.debugBytes, this.debugPath);

  final Uint8List debugBytes;
  final String debugPath;
}

/// Extracts the debug `.ipa` and reads its full icon font into memory.
_FontPair _readDebugFont(File ipa) {
  final tmp = Directory.systemTemp.createTempSync('ios_release_font_');
  try {
    ProcessResult unzipped;
    try {
      unzipped = Process.runSync('unzip', ['-q', ipa.path, '-d', tmp.path]);
    } on ProcessException catch (e) {
      _abort('FAIL: could not run the `unzip` tool on ${ipa.path}: $e');
    }
    if (unzipped.exitCode != 0) {
      _abort('FAIL: could not extract ${ipa.path}: ${unzipped.stderr}');
    }
    final font = File(
      '${tmp.path}/Payload/app.app/Frameworks/App.framework/$_fontSuffix',
    );
    if (!font.existsSync()) {
      _abort(
        'FAIL: expected the debug icon font at ${font.path}; '
        'the bundle holds: ${_childNames(font.parent)}',
      );
    }
    return _FontPair(_readOrAbort(font), font.path);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Names the entries directly inside [dir], or notes that it is missing.
String _childNames(Directory dir) {
  if (!dir.existsSync()) return 'no directory at ${dir.path}';
  final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()
    ..sort();
  return names.isEmpty ? 'an empty directory' : names.join(', ');
}

/// Whether [bytes] starts with an OpenType sfnt magic.
bool _isOpenType(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final tag = _fontTag(bytes);
  return tag == '00010000' || tag == '4f54544f' || tag == '74727565';
}

/// The first four bytes of [bytes] as lowercase hex, or `short`.
String _fontTag(Uint8List bytes) {
  if (bytes.length < 4) return 'short';
  return [
    for (var i = 0; i < 4; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Whether [haystack] holds [needle] as contiguous bytes.
bool _hasBytes(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// What the test learned from one Mach-O binary.
class _MachO {
  const _MachO({
    required this.cpuType,
    required this.platform,
    required this.exportNames,
  });

  /// The header `cputype` (arm64 expected).
  final int cpuType;

  /// The `LC_BUILD_VERSION` platform, or null when the command is absent.
  final int? platform;

  /// Exported symbol names from the export trie and the symbol table.
  final Set<String> exportNames;
}

/// Parses the Mach-O header and load commands of [bytes].
///
/// Throws a [FormatException] naming the offset when the bytes are truncated
/// or shaped unexpectedly, so a binary the loader would reject fails this
/// test instead of passing it.
_MachO _parseMachO(Uint8List bytes) {
  final head = _Reader(bytes);
  final magic = head.u32();
  if (magic != _magic64) {
    throw FormatException(
      'expected a 64-bit Mach-O magic 0x${_magic64.toRadixString(16)}, '
      'found 0x${magic.toRadixString(16)}',
    );
  }
  final cpuType = head.u32();
  head.skip(8);
  final ncmds = head.u32();
  head.skip(12);
  int? platform;
  final names = <String>{};
  for (var i = 0; i < ncmds; i++) {
    final commandAt = head.offset;
    final command = head.u32();
    final cmdsize = head.u32();
    if (cmdsize < 8 || commandAt + cmdsize > bytes.length) {
      throw FormatException(
        'load command $i runs past the file at $commandAt '
        '(cmdsize $cmdsize of ${bytes.length} bytes)',
      );
    }
    switch (command) {
      case _lcBuildVersion:
        platform ??= _buildVersionPlatform(bytes, commandAt);
      case _lcSymtab:
        names.addAll(_symtabNames(bytes, commandAt));
      case _lcDyldInfoOnly:
        names.addAll(_infoTrieNames(bytes, commandAt));
      case _lcDyldExportsTrie:
        names.addAll(_exportsTrieNames(bytes, commandAt));
    }
    head.offset = commandAt + cmdsize;
  }
  return _MachO(cpuType: cpuType, platform: platform, exportNames: names);
}

/// The platform field of the `LC_BUILD_VERSION` at [commandAt].
int _buildVersionPlatform(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  return reader.u32();
}

/// Symbol names from the `LC_SYMTAB` string table at [commandAt].
Set<String> _symtabNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final symoff = reader.u32();
  final nsyms = reader.u32();
  final stroff = reader.u32();
  final strsize = reader.u32();
  if (symoff + nsyms * 16 > bytes.length || stroff + strsize > bytes.length) {
    throw FormatException(
      'LC_SYMTAB at $commandAt points past the file '
      '(symbols $symoff+$nsyms, strings $stroff+$strsize)',
    );
  }
  final names = <String>{};
  for (var i = 0; i < nsyms; i++) {
    final strx = _u32At(bytes, symoff + i * 16);
    names.add(_tableString(bytes, stroff, strsize, strx));
  }
  return names;
}

/// Export names from the `LC_DYLD_INFO_ONLY` export trie at [commandAt].
Set<String> _infoTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)
    ..offset = commandAt + 8
    ..skip(32);
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// Export names from the `LC_DYLD_EXPORTS_TRIE` at [commandAt].
Set<String> _exportsTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// Reads one little-endian u32 at [offset], failing past the end.
int _u32At(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw FormatException('u32 at $offset runs past ${bytes.length} bytes');
  }
  return ByteData.sublistView(
    bytes,
    offset,
    offset + 4,
  ).getUint32(0, Endian.little);
}

/// Reads the NUL-terminated string at [tableAt] + [index].
String _tableString(Uint8List bytes, int tableAt, int tableSize, int index) {
  if (index < 0 || tableAt + index >= tableAt + tableSize) {
    throw FormatException(
      'string index $index runs past the $tableSize-byte table at $tableAt',
    );
  }
  var end = tableAt + index;
  while (end < tableAt + tableSize && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(tableAt + index, end), allowMalformed: true);
}

/// A dyld export trie: child offsets count from the trie's own start.
class _Trie {
  _Trie(this.bytes, this.start, this.size) {
    if (start < 0 || size < 0 || start + size > bytes.length) {
      throw FormatException(
        'export trie at $start runs past the file '
        '(size $size of ${bytes.length} bytes)',
      );
    }
  }

  final Uint8List bytes;
  final int start;
  final int size;

  /// Every exported name in the trie.
  Set<String> names() {
    final out = <String>{};
    _walk(start, '', out);
    return out;
  }

  /// Collects the names under the node at [node], prefixed by [prefix].
  void _walk(int node, String prefix, Set<String> out) {
    if (node < start || node >= start + size) {
      throw FormatException(
        'export trie node at $node runs past the trie at $start '
        '(size $size)',
      );
    }
    final reader = _Reader(bytes)..offset = node;
    final terminalSize = reader.uleb();
    final terminalEnd = reader.offset + terminalSize;
    if (terminalEnd > start + size) {
      throw FormatException(
        'export trie terminal at $node runs past the trie end',
      );
    }
    if (terminalSize > 0) {
      reader.uleb();
      out.add(prefix);
      reader.offset = terminalEnd;
    }
    final children = reader.u8();
    for (var i = 0; i < children; i++) {
      final edge = reader.cstring();
      final child = reader.uleb();
      _walk(start + child, prefix + edge, out);
    }
  }
}

/// A bounds-checked cursor over Mach-O bytes.
class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  /// Skips [count] bytes.
  void skip(int count) {
    _need(count);
    offset += count;
  }

  /// Reads one byte.
  int u8() {
    _need(1);
    return bytes[offset++];
  }

  /// Reads one little-endian u32.
  int u32() {
    _need(4);
    final value = ByteData.sublistView(
      bytes,
      offset,
      offset + 4,
    ).getUint32(0, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads one uleb128 value.
  int uleb() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = u8();
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw FormatException('uleb128 overflows at ${offset - 1}');
      }
    }
  }

  /// Reads one NUL-terminated string.
  String cstring() {
    final start = offset;
    while (true) {
      _need(1);
      if (bytes[offset++] == 0) break;
    }
    return utf8.decode(bytes.sublist(start, offset - 1), allowMalformed: true);
  }

  /// Throws a [FormatException] unless [count] bytes are readable.
  void _need(int count) {
    if (offset < 0 || offset + count > bytes.length) {
      throw FormatException(
        'truncated Mach-O at $offset (needs $count of ${bytes.length})',
      );
    }
  }
}
