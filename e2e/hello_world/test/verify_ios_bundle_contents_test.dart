/// Inspects the iOS simulator `.ipa` built from `:hello_world_ios`: the
/// version it carries, the pub packages' assets and fonts, the platform
/// gating of those assets, and the debug payload.
///
/// `:hello_world_ios` is a `flutter_ios_app` over `:hello_world_app`, which
/// depends on the `platform_assets` path package (unconditional `any.txt`
/// plus per-platform entries), on `cupertino_icons` and on the toolchain
/// `material_icons`. The test reads `hello_world_ios.ipa` through
/// `:hello_world_ios_simulator` and asserts, each with its own message
/// naming what it expected and what it found:
///
/// * the app's `Info.plist` carries `CFBundleShortVersionString` `2.3.4`
///   and `CFBundleVersion` `42` from `:hello_world_ios_app_version`;
/// * `App.framework/flutter_assets/packages/platform_assets/assets/any.txt`
///   is present with the committed file's bytes (staged through `data`),
///   and the asset manifest lists it;
/// * `.../assets/ios_only.txt` is present and listed, while
///   `android_only.txt`, `web_only.txt` and `union_android.txt` are absent
///   from both the files and the asset manifest;
/// * `FontManifest.json` lists the family
///   `packages/cupertino_icons/CupertinoIcons` with its font file present
///   in the bundle, lists `MaterialIcons`, and carries the app's own
///   `HelloSans` entry exactly as declared (regular face, then the bold face
///   with `weight` 700) with both bundled files byte-identical to the
///   committed ones;
/// * the debug payload `App.framework/flutter_assets/kernel_blob.bin` is
///   present and non-empty.
///
/// The archive is walked in memory (central directory, raw inflate via
/// `dart:io`'s `ZLibCodec`), the plist is decoded as binary or XML without
/// helpers, and the manifests are parsed as bytes or JSON: no host `unzip`,
/// `plutil` or `xcrun` runs here. A missing input fails the test; nothing
/// here is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The simulator bundle, forwarded by `:hello_world_ios_simulator`.
const _ipaName = 'hello_world_ios.ipa';

/// The committed asset staged through `data`, whose bytes the bundled copy
/// must equal.
const _committedAssetPath = 'platform_assets/assets/any.txt';

/// Asset keys relative to `flutter_assets/`, as the engine loads them.
const _anyAsset = 'packages/platform_assets/assets/any.txt';
const _iosOnlyAsset = 'packages/platform_assets/assets/ios_only.txt';

/// Assets for other platforms that must reach neither the bundle files nor
/// the asset manifest.
const _absentAssets = [
  'packages/platform_assets/assets/android_only.txt',
  'packages/platform_assets/assets/web_only.txt',
  'packages/platform_assets/assets/union_android.txt',
];

/// Font families the bundle's `FontManifest.json` must name.
const _cupertinoFamily = 'packages/cupertino_icons/CupertinoIcons';
const _materialFamily = 'MaterialIcons';

/// The app's own family, declared through `flutter_font_family` and bundled
/// bare as the root pubspec's fonts are.
const _helloFamily = 'HelloSans';
const _regularFont = 'fonts/HelloSans-Regular.ttf';
const _boldFont = 'fonts/HelloSans-Bold.ttf';

/// The `HelloSans` entry `FontManifest.json` must carry, in order.
const _helloFonts = [
  {'asset': _regularFont},
  {'asset': _boldFont, 'weight': 700},
];

/// Records one expectation: [description] names what the bundle should
/// hold, [ok] whether it does, and [found] what is there instead.
typedef _Check = void Function(String description, bool ok, String found);

/// The zip archive or its `.app` layout is not what the checks require.
class _BundleError implements Exception {
  _BundleError(this.message);
  final String message;
  @override
  String toString() => 'BundleError: $message';
}

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipa = File('$testSrcDir/$testWorkspace/$_ipaName');
  if (!ipa.existsSync()) {
    stderr.writeln(
      'FAIL: expected the simulator bundle at ${ipa.path}, '
      'found nothing (stage `:hello_world_ios_simulator` through `data`)',
    );
    exit(1);
  }
  final committed = File('$testSrcDir/$testWorkspace/$_committedAssetPath');
  if (!committed.existsSync()) {
    stderr.writeln(
      'FAIL: expected the committed asset at ${committed.path} '
      '(staged through `data`), found nothing',
    );
    exit(1);
  }

  final Map<String, Uint8List> files;
  final String appDir;
  try {
    files = _unpackZip(ipa.path);
    appDir = _findAppDir(files.keys);
  } on _BundleError catch (e) {
    stderr.writeln('FAIL: could not open the simulator bundle: $e');
    exit(1);
  }
  final committedBytes = committed.readAsBytesSync();
  final committedFonts = <String, Uint8List>{
    _regularFont: File('$testSrcDir/$testWorkspace/$_regularFont')
        .readAsBytesSync(),
    _boldFont: File('$testSrcDir/$testWorkspace/$_boldFont').readAsBytesSync(),
  };
  final assetsDir = '$appDir/Frameworks/App.framework/flutter_assets';
  final manifestText = _manifestText(files, assetsDir);

  var failed = false;
  void check(String description, bool ok, String found) {
    if (ok) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: expected $description; found $found');
      failed = true;
    }
  }

  _checkVersions(files, '$appDir/Info.plist', check);
  if (manifestText == null) {
    check(
      'an AssetManifest.bin in the bundle',
      false,
      'neither AssetManifest.bin nor AssetManifest.json under $assetsDir',
    );
  }
  _checkAnyAsset(files, assetsDir, committedBytes, manifestText, check);
  _checkPlatformAssets(files, assetsDir, manifestText, check);
  _checkFontManifest(files, assetsDir, committedFonts, check);
  _checkKernel(files, assetsDir, check);

  if (failed) exit(1);
  print(
    'PASS: the iOS bundle carries its version, assets, fonts and debug '
    'payload',
  );
}

/// Every file of the zip archive at [path], keyed by entry name. Walks the
/// central directory and inflates deflated entries with `dart:io`'s
/// `ZLibCodec`: no `unzip` runs here.
Map<String, Uint8List> _unpackZip(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);
  var directoryOffset = -1;
  var directoryEntries = 0;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) != 0x06054b50) continue;
    directoryEntries = view.getUint16(i + 8, Endian.little);
    directoryOffset = view.getUint32(i + 16, Endian.little);
    break;
  }
  if (directoryOffset < 0) {
    throw _BundleError(
      'a zip end-of-directory record in $path, '
      'searched ${bytes.length} bytes',
    );
  }
  final files = <String, Uint8List>{};
  var cursor = directoryOffset;
  for (var i = 0; i < directoryEntries; i++) {
    if (view.getUint32(cursor, Endian.little) != 0x02014b50) {
      throw _BundleError('a central directory entry at byte $cursor in $path');
    }
    final method = view.getUint16(cursor + 10, Endian.little);
    final packedSize = view.getUint32(cursor + 20, Endian.little);
    final nameSize = view.getUint16(cursor + 28, Endian.little);
    final extraSize = view.getUint16(cursor + 30, Endian.little);
    final commentSize = view.getUint16(cursor + 32, Endian.little);
    final headerOffset = view.getUint32(cursor + 42, Endian.little);
    final name = utf8.decode(
      bytes.sublist(cursor + 46, cursor + 46 + nameSize),
    );
    cursor += 46 + nameSize + extraSize + commentSize;
    if (name.endsWith('/')) continue;
    files[name] = _inflateEntry(
      bytes,
      view,
      name,
      headerOffset,
      packedSize,
      method,
      path,
    );
  }
  return files;
}

/// The raw (decompressed) bytes of the entry [name] whose local header sits
/// at [headerOffset] in the archive at [path].
Uint8List _inflateEntry(
  Uint8List bytes,
  ByteData view,
  String name,
  int headerOffset,
  int packedSize,
  int method,
  String path,
) {
  if (view.getUint32(headerOffset, Endian.little) != 0x04034b50) {
    throw _BundleError(
      'a local header for $name at byte $headerOffset '
      'in $path',
    );
  }
  final nameSize = view.getUint16(headerOffset + 26, Endian.little);
  final extraSize = view.getUint16(headerOffset + 28, Endian.little);
  final dataStart = headerOffset + 30 + nameSize + extraSize;
  final packed = bytes.sublist(dataStart, dataStart + packedSize);
  return switch (method) {
    0 => packed,
    8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(packed)),
    _ => throw _BundleError(
      '$name stored or deflated in $path, uses method $method',
    ),
  };
}

/// The one `.app` bundle under `Payload/`, e.g. `Payload/Hello World.app`.
String _findAppDir(Iterable<String> names) {
  final apps = <String>{};
  for (final name in names) {
    if (!name.startsWith('Payload/')) continue;
    final parts = name.substring('Payload/'.length).split('/');
    if (parts.length == 2 &&
        parts[0].endsWith('.app') &&
        parts[1] == 'Info.plist') {
      apps.add('Payload/${parts[0]}');
    }
  }
  if (apps.length != 1) {
    throw _BundleError(
      'one .app bundle under Payload/, holds ${apps.toList()..sort()}',
    );
  }
  return apps.single;
}

/// The asset manifest under [assetsDir] as searchable text: the
/// StandardMessageCodec `AssetManifest.bin` embeds each key as UTF-8 inline,
/// so decoding it lossily is enough to decide membership. Falls back to
/// `AssetManifest.json`; null when neither is bundled.
String? _manifestText(Map<String, Uint8List> files, String assetsDir) {
  for (final name in ['AssetManifest.bin', 'AssetManifest.json']) {
    final raw = files['$assetsDir/$name'];
    if (raw != null) return utf8.decode(raw, allowMalformed: true);
  }
  return null;
}

/// Whether [a] and [b] hold the same bytes in the same order.
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The app's `Info.plist` carries the version `:hello_world_ios` was given.
void _checkVersions(
  Map<String, Uint8List> files,
  String plistName,
  _Check check,
) {
  final raw = files[plistName];
  if (raw == null) {
    check(
      'an Info.plist in the simulator bundle',
      false,
      'no file at $plistName',
    );
    return;
  }
  String? shortVersion;
  String? buildVersion;
  try {
    if (_isBinaryPlist(raw)) {
      final plist = _BinaryPlistReader(raw).readTopDict();
      final short = plist['CFBundleShortVersionString'];
      final build = plist['CFBundleVersion'];
      if (short is String) shortVersion = short;
      if (build is String) buildVersion = build;
    } else {
      final text = utf8.decode(raw);
      shortVersion = _xmlPlistString(text, 'CFBundleShortVersionString');
      buildVersion = _xmlPlistString(text, 'CFBundleVersion');
    }
  } on FormatException catch (e) {
    check(
      'an Info.plist that parses as a string-keyed dict',
      false,
      'a parse failure: $e',
    );
    return;
  }
  check(
    'Info.plist CFBundleShortVersionString 2.3.4',
    shortVersion == '2.3.4',
    'CFBundleShortVersionString $shortVersion',
  );
  check(
    'Info.plist CFBundleVersion 42',
    buildVersion == '42',
    'CFBundleVersion $buildVersion',
  );
}

/// Whether [raw] opens with the binary plist magic.
bool _isBinaryPlist(Uint8List raw) {
  return raw.length >= 8 &&
      String.fromCharCodes(raw.sublist(0, 8)) == 'bplist00';
}

/// The `<string>` value of [key] in an XML property list, unescaping the
/// entities a version string could carry.
String _xmlPlistString(String text, String key) {
  final keyTag = '<key>$key</key>';
  final keyAt = text.indexOf(keyTag);
  if (keyAt < 0) {
    throw FormatException('expected $keyTag in the XML plist');
  }
  final rest = text.substring(keyAt + keyTag.length).trimLeft();
  const open = '<string>';
  if (!rest.startsWith(open)) {
    throw FormatException('expected a <string> value after $keyTag');
  }
  final closeAt = rest.indexOf('</string>', open.length);
  if (closeAt < 0) {
    throw FormatException('unterminated <string> after $keyTag');
  }
  return rest
      .substring(open.length, closeAt)
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

/// The unconditional asset is bundled byte-identical and manifested.
void _checkAnyAsset(
  Map<String, Uint8List> files,
  String assetsDir,
  Uint8List committed,
  String? manifestText,
  _Check check,
) {
  final bundled = files['$assetsDir/$_anyAsset'];
  if (bundled == null) {
    check(
      'bundled $_anyAsset beside the committed one',
      false,
      'no file at $assetsDir/$_anyAsset',
    );
  } else {
    check(
      'bundled $_anyAsset byte-identical to the committed one '
          '(${committed.length} bytes)',
      _bytesEqual(bundled, committed),
      '${bundled.length} bytes instead of ${committed.length}',
    );
  }
  if (manifestText != null) {
    check(
      'the asset manifest listing $_anyAsset',
      manifestText.contains(_anyAsset),
      'no $_anyAsset key in the manifest',
    );
  }
}

/// The iOS-only asset ships; every other platform's asset ships nowhere.
void _checkPlatformAssets(
  Map<String, Uint8List> files,
  String assetsDir,
  String? manifestText,
  _Check check,
) {
  final bundled = files['$assetsDir/$_iosOnlyAsset'];
  check(
    'bundled $_iosOnlyAsset in the iOS bundle',
    bundled != null && bundled.isNotEmpty,
    bundled == null
        ? 'no file at $assetsDir/$_iosOnlyAsset'
        : 'an empty file at $assetsDir/$_iosOnlyAsset',
  );
  if (manifestText != null) {
    check(
      'the asset manifest listing $_iosOnlyAsset',
      manifestText.contains(_iosOnlyAsset),
      'no $_iosOnlyAsset key in the manifest',
    );
  }
  for (final asset in _absentAssets) {
    check(
      '$asset absent from the iOS bundle files',
      !files.containsKey('$assetsDir/$asset'),
      'a file at $assetsDir/$asset the iOS bundle must not carry',
    );
    if (manifestText != null) {
      check(
        'the asset manifest omitting $asset',
        !manifestText.contains(asset),
        'a manifest key the bundle omits',
      );
    }
  }
}

/// `FontManifest.json` names the pub icon families whose every asset file
/// is bundled alongside, and the app's own `HelloSans` entry with its bytes.
void _checkFontManifest(
  Map<String, Uint8List> files,
  String assetsDir,
  Map<String, Uint8List> committedFonts,
  _Check check,
) {
  final raw = files['$assetsDir/FontManifest.json'];
  if (raw == null) {
    check(
      'a FontManifest.json in the bundle',
      false,
      'no file at $assetsDir/FontManifest.json',
    );
    return;
  }
  final List<dynamic> families;
  try {
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! List) {
      check(
        'a FontManifest.json shaped as a family list',
        false,
        'a ${decoded.runtimeType}: $decoded',
      );
      return;
    }
    families = decoded;
  } on FormatException catch (e) {
    check(
      'a FontManifest.json that parses as JSON',
      false,
      'a decode failure: $e',
    );
    return;
  }
  _checkFontFamily(families, files, assetsDir, _cupertinoFamily, check);
  _checkFontFamily(families, files, assetsDir, _materialFamily, check);
  _checkHelloSans(families, files, assetsDir, committedFonts, check);
}

/// The app's `HelloSans` entry is exactly the declaration, and each asset
/// carries the committed file's bytes.
void _checkHelloSans(
  List<dynamic> families,
  Map<String, Uint8List> files,
  String assetsDir,
  Map<String, Uint8List> committedFonts,
  _Check check,
) {
  Map<dynamic, dynamic>? entry;
  for (final item in families) {
    if (item is Map && item['family'] == _helloFamily) {
      entry = item;
      break;
    }
  }
  if (entry == null) {
    check(
      'a FontManifest.json family $_helloFamily',
      false,
      'families ${[for (final e in families)
        if (e is Map) e['family'] else e]}',
    );
    return;
  }
  final declared = entry['fonts'];
  check(
    'the $_helloFamily entry ${jsonEncode(_helloFonts)}',
    jsonEncode(declared) == jsonEncode(_helloFonts),
    'fonts ${jsonEncode(declared)}',
  );
  for (final asset in [_regularFont, _boldFont]) {
    final bundled = files['$assetsDir/$asset'];
    final committed = committedFonts[asset]!;
    check(
      'bundled $asset byte-identical to the committed file '
      '(${committed.length} bytes)',
      bundled != null && _bytesEqual(bundled, committed),
      bundled == null
          ? 'no file at $assetsDir/$asset'
          : '${bundled.length} bytes instead of ${committed.length}',
    );
  }
}

/// The [family] entry exists and every font asset it names is a bundle file.
void _checkFontFamily(
  List<dynamic> families,
  Map<String, Uint8List> files,
  String assetsDir,
  String family,
  _Check check,
) {
  Map<dynamic, dynamic>? entry;
  for (final item in families) {
    if (item is Map && item['family'] == family) {
      entry = item;
      break;
    }
  }
  if (entry == null) {
    check(
      'a FontManifest.json family $family',
      false,
      'families ${[for (final e in families)
        if (e is Map) e['family'] else e]}',
    );
    return;
  }
  final fonts = entry['fonts'];
  if (fonts is! List || fonts.isEmpty) {
    check('fonts listed under the $family family', false, 'fonts: $fonts');
    return;
  }
  for (final font in fonts) {
    final asset = font is Map ? font['asset'] : null;
    check(
      'the bundled $family font asset $asset',
      asset is String && files.containsKey('$assetsDir/$asset'),
      asset is String
          ? 'no file at $assetsDir/$asset'
          : 'a font entry with no asset path: $font',
    );
  }
}

/// The simulator build is a debug build, so the Dart kernel ships beside
/// the assets rather than compiled into the app binary.
void _checkKernel(
  Map<String, Uint8List> files,
  String assetsDir,
  _Check check,
) {
  final kernel = files['$assetsDir/kernel_blob.bin'];
  check(
    'a non-empty debug kernel_blob.bin in the bundle',
    kernel != null && kernel.isNotEmpty,
    kernel == null
        ? 'no file at $assetsDir/kernel_blob.bin'
        : 'an empty file at $assetsDir/kernel_blob.bin',
  );
}

/// Reads an Apple binary property list (`bplist00`) into plain Dart values:
/// null, booleans, integers, floats, dates (as epoch doubles), data,
/// strings, arrays and string-keyed dicts. Any other object, or bytes
/// running out mid-value, throws a [FormatException] naming the offset, so
/// a manifest the engine would reject fails this test instead of passing.
class _BinaryPlistReader {
  _BinaryPlistReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;

  int get _offsetSize => _view.getUint8(_bytes.length - 32 + 6);
  int get _refSize => _view.getUint8(_bytes.length - 32 + 7);
  int get _objectCount => _view.getUint64(_bytes.length - 32 + 8);
  int get _topObject => _view.getUint64(_bytes.length - 32 + 16);
  int get _tableOffset => _view.getUint64(_bytes.length - 32 + 24);

  /// The document's top-level value, which an `Info.plist` wraps in a dict.
  Map<String, Object?> readTopDict() {
    if (!_isBinaryPlist(_bytes)) {
      throw const FormatException('expected a bplist00 header');
    }
    final top = _value(_topObject);
    if (top is! Map<String, Object?>) {
      throw FormatException('expected the top object to be a dict, found $top');
    }
    return top;
  }

  /// The file offset of object [index] through the trailer's offset table.
  int _offsetOf(int index) {
    if (index < 0 || index >= _objectCount) {
      throw FormatException('object index $index is out of range');
    }
    var offset = 0;
    for (var i = 0; i < _offsetSize; i++) {
      offset = offset * 256 + _bytes[_tableOffset + index * _offsetSize + i];
    }
    return offset;
  }

  /// The object [index] points at.
  Object? _value(int index) {
    final start = _offsetOf(index);
    _need(start, 1);
    final marker = _bytes[start];
    final kind = marker >> 4;
    final info = marker & 0x0f;
    return switch (kind) {
      0x0 => _simple(info, start),
      0x1 => _sizedInt(start + 1, 1 << info),
      0x2 => _sizedFloat(start + 1, 1 << info),
      0x3 => _sizedFloat(start + 1, 8),
      0x4 => _rawBytes(start, info),
      0x5 => _ascii(start, info),
      0x6 => _unicode(start, info),
      0x8 => _sizedInt(start + 1, info + 1),
      0xA => _array(start, info),
      0xD => _dict(start, info),
      _ => throw FormatException(
        'unsupported bplist object 0x${marker.toRadixString(16)} '
        'at byte $start',
      ),
    };
  }

  /// The collection length for [info] at [pos], and the position after it:
  /// short lengths ride in the marker, long ones in the int that follows.
  (int, int) _length(int info, int pos) {
    if (info != 0x0f) return (info, pos);
    _need(pos, 1);
    final marker = _bytes[pos];
    if (marker >> 4 != 0x1) {
      throw FormatException('expected an int length at byte $pos');
    }
    final width = 1 << (marker & 0x0f);
    return (_sizedInt(pos + 1, width), pos + 1 + width);
  }

  /// A big-endian unsigned integer [width] bytes wide at [pos].
  int _sizedInt(int pos, int width) {
    if (width != 1 && width != 2 && width != 4 && width != 8) {
      throw FormatException('unsupported int width $width at byte $pos');
    }
    _need(pos, width);
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value * 256 + _bytes[pos + i];
    }
    return value;
  }

  /// A big-endian float [width] bytes wide at [pos].
  double _sizedFloat(int pos, int width) {
    _need(pos, width);
    final data = ByteData.sublistView(_bytes, pos, pos + width);
    return switch (width) {
      4 => data.getFloat32(0),
      8 => data.getFloat64(0),
      _ => throw FormatException('unsupported float width $width at byte $pos'),
    };
  }

  /// A data blob at the object starting at [start] with marker info [info].
  Uint8List _rawBytes(int start, int info) {
    final (length, pos) = _length(info, start + 1);
    _need(pos, length);
    return _bytes.sublist(pos, pos + length);
  }

  /// An ASCII string at the object starting at [start].
  String _ascii(int start, int info) {
    final (length, pos) = _length(info, start + 1);
    _need(pos, length);
    return String.fromCharCodes(_bytes.sublist(pos, pos + length));
  }

  /// A UTF-16 string of [info] characters at the object starting at [start].
  String _unicode(int start, int info) {
    final (length, pos) = _length(info, start + 1);
    _need(pos, length * 2);
    final units = <int>[];
    for (var i = 0; i < length; i++) {
      units.add(_bytes[pos + i * 2] * 256 + _bytes[pos + i * 2 + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// An array at the object starting at [start].
  List<Object?> _array(int start, int info) {
    final (count, pos) = _length(info, start + 1);
    _need(pos, count * _refSize);
    return [for (var i = 0; i < count; i++) _value(_ref(pos + i * _refSize))];
  }

  /// A dict at the object starting at [start]: key refs first, then values.
  Map<String, Object?> _dict(int start, int info) {
    final (count, pos) = _length(info, start + 1);
    _need(pos, count * 2 * _refSize);
    final map = <String, Object?>{};
    for (var i = 0; i < count; i++) {
      final key = _value(_ref(pos + i * _refSize));
      if (key is! String) {
        throw FormatException('expected a string dict key, found $key');
      }
      map[key] = _value(_ref(pos + (count + i) * _refSize));
    }
    return map;
  }

  /// The object index referenced at [pos].
  int _ref(int pos) {
    _need(pos, _refSize);
    var index = 0;
    for (var i = 0; i < _refSize; i++) {
      index = index * 256 + _bytes[pos + i];
    }
    return index;
  }

  /// A null, boolean or (rejected) reserved simple object.
  Object? _simple(int info, int start) => switch (info) {
    0x0 => null,
    0x8 => false,
    0x9 => true,
    _ => throw FormatException(
      'unsupported simple object 0x0${info.toRadixString(16)} '
      'at byte $start',
    ),
  };

  /// Fails when [count] bytes at [pos] would run past the buffer's end.
  void _need(int pos, int count) {
    if (pos + count > _bytes.length) {
      throw FormatException(
        'truncated plist: byte $pos needs $count more '
        'bytes of ${_bytes.length}',
      );
    }
  }
}
