/// Verifies the simulator `.ipa` built from `:app` ships the workspace's own
/// asset together with the manifests describing it, as the engine on the
/// simulator actually loads them.
///
/// Reads the same `app.ipa` that `verify_ios_info_plist_test` reads, and
/// inspects the bundle the engine loads,
/// `Payload/app.app/Frameworks/App.framework/flutter_assets/`:
///
/// * `assets/message.txt` is there, and its bytes equal the committed
///   `assets/message.txt`, read through `data` (never copied into this file);
/// * `AssetManifest.bin` decodes (StandardMessageCodec) to a map that lists
///   `assets/message.txt` as a key whose value is a list of variant maps;
/// * `FontManifest.json` parses as JSON, names a `MaterialIcons` family, and
///   every font asset that family names is a file in the bundle.
///
/// Every failed assertion prints what it expected and what it found. A
/// missing `.ipa`, a missing committed asset, or a missing `unzip` fails the
/// test; nothing here is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Asset key of this workspace's first-party asset, relative to
/// `flutter_assets/`.
const _assetKey = 'assets/message.txt';

/// Font family the Material Icons bundle must declare.
const _iconFamily = 'MaterialIcons';

void main() {
  final env = Platform.environment;
  final testSrcDir = env['TEST_SRCDIR'];
  final testWorkspace = env['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipa = File('$testSrcDir/$testWorkspace/app.ipa');
  if (!ipa.existsSync()) {
    stderr.writeln(
      'FAIL: expected the simulator bundle at ${ipa.path}, found nothing',
    );
    exit(1);
  }
  final committed = File('$testSrcDir/$testWorkspace/$_assetKey');
  if (!committed.existsSync()) {
    stderr.writeln(
      'FAIL: expected the committed asset at ${committed.path} '
      '(staged through `data`), found nothing',
    );
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ios_bundle_assets_');
  try {
    ProcessResult extracted;
    try {
      extracted = Process.runSync('unzip', ['-q', ipa.path, '-d', tmpDir.path]);
    } on ProcessException catch (e) {
      stderr.writeln('FAIL: could not run the `unzip` tool: $e');
      exit(1);
    }
    if (extracted.exitCode != 0) {
      stderr.writeln(
        'FAIL: could not extract ${ipa.path}: ${extracted.stderr}',
      );
      exit(1);
    }

    final payload = Directory('${tmpDir.path}/Payload/app.app');
    final flutterAssets = Directory(
      '${payload.path}/Frameworks/App.framework/flutter_assets',
    );
    if (!flutterAssets.existsSync()) {
      stderr.writeln(
        'FAIL: expected the engine-loaded assets at ${flutterAssets.path}; '
        'the bundle holds: ${_childNames(payload)}',
      );
      exit(1);
    }

    final failures = <String>[];
    void check(String description, {required bool ok, String? found}) {
      if (ok) {
        print('OK: $description');
      } else {
        stderr.writeln(
          'FAIL: expected $description; found ${found ?? 'nothing'}',
        );
        failures.add(description);
      }
    }

    _checkBundledAsset(flutterAssets, committed, check);
    _checkAssetManifest(flutterAssets, check);
    _checkFontManifest(flutterAssets, check);

    if (failures.isNotEmpty) exit(1);
    print('PASS: the iOS bundle ships its asset, manifest and fonts');
  } finally {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  }
}

/// Names the entries directly inside [dir], or notes that [dir] is missing.
String _childNames(Directory dir) {
  if (!dir.existsSync()) return 'no directory at ${dir.path}';
  final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()
    ..sort();
  return names.isEmpty ? 'an empty directory' : names.join(', ');
}

/// The bundled asset exists and is byte-identical to the committed one.
void _checkBundledAsset(
  Directory flutterAssets,
  File committed,
  void Function(String, {required bool ok, String? found}) check,
) {
  final bundled = File('${flutterAssets.path}/$_assetKey');
  if (!bundled.existsSync()) {
    check(
      'bundled $_assetKey beside the committed one',
      ok: false,
      found:
          'no file at ${bundled.path}; the assets tree holds: '
          '${_childNames(Directory('${flutterAssets.path}/assets'))}',
    );
    return;
  }
  final want = committed.readAsBytesSync();
  final got = bundled.readAsBytesSync();
  check(
    'bundled $_assetKey byte-identical to the committed one '
    '(${want.length} bytes)',
    ok: _bytesEqual(want, got),
    found:
        '${got.length} bytes: '
        '"${utf8.decode(got, allowMalformed: true)}" instead of '
        '"${utf8.decode(want, allowMalformed: true)}"',
  );
}

/// `AssetManifest.bin` decodes to a map keying the asset to variant maps.
void _checkAssetManifest(
  Directory flutterAssets,
  void Function(String, {required bool ok, String? found}) check,
) {
  final manifest = File('${flutterAssets.path}/AssetManifest.bin');
  if (!manifest.existsSync()) {
    check(
      'a StandardMessageCodec AssetManifest.bin in the bundle',
      ok: false,
      found: 'no file at ${manifest.path}',
    );
    return;
  }
  Map<String, Object?> entries;
  try {
    entries = _decodeManifest(manifest.readAsBytesSync());
  } on StateError catch (e) {
    check(
      'an AssetManifest.bin that decodes as a string-keyed map',
      ok: false,
      found: 'a decode failure: $e',
    );
    return;
  } on FormatException catch (e) {
    check(
      'an AssetManifest.bin that decodes as a string-keyed map',
      ok: false,
      found: 'a decode failure: $e',
    );
    return;
  }
  final variants = entries[_assetKey];
  check(
    'AssetManifest.bin listing $_assetKey with variant maps',
    ok:
        variants is List &&
        variants.isNotEmpty &&
        variants.every((v) => v is Map),
    found: variants == null
        ? 'no such key among the ${entries.length} decoded keys: '
              '${entries.keys.toList()..sort()}'
        : 'a non-variant value for the key: $variants',
  );
}

/// `FontManifest.json` names the icon family whose every asset is bundled.
void _checkFontManifest(
  Directory flutterAssets,
  void Function(String, {required bool ok, String? found}) check,
) {
  final manifest = File('${flutterAssets.path}/FontManifest.json');
  if (!manifest.existsSync()) {
    check(
      'a FontManifest.json in the bundle',
      ok: false,
      found: 'no file at ${manifest.path}',
    );
    return;
  }
  final decoded = jsonDecode(manifest.readAsStringSync());
  if (decoded is! List) {
    check(
      'a FontManifest.json shaped as a family list',
      ok: false,
      found: 'a ${decoded.runtimeType}: $decoded',
    );
    return;
  }
  Map<String, dynamic>? family;
  for (final entry in decoded) {
    if (entry is Map && entry['family'] == _iconFamily) {
      family = entry.cast<String, dynamic>();
      break;
    }
  }
  if (family == null) {
    check(
      'a FontManifest.json family $_iconFamily',
      ok: false,
      found:
          'families '
          '${[for (final e in decoded) e is Map ? e['family'] : e]}',
    );
    return;
  }
  final fonts = family['fonts'];
  if (fonts is! List || fonts.isEmpty) {
    check(
      'fonts listed under the $_iconFamily family',
      ok: false,
      found: 'fonts: $fonts',
    );
    return;
  }
  for (final font in fonts) {
    final asset = font is Map ? font['asset'] : null;
    check(
      'the bundled $_iconFamily font asset $asset',
      ok: asset is String && File('${flutterAssets.path}/$asset').existsSync(),
      found: asset is String
          ? 'no file at ${flutterAssets.path}/$asset'
          : 'a font entry with no asset path: $font',
    );
  }
}

/// Whether [a] and [b] hold the same bytes in the same order.
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Decodes [bytes] as one StandardMessageCodec message and requires the
/// string-keyed map `generate_asset_manifest` writes for `AssetManifest.bin`.
Map<String, Object?> _decodeManifest(Uint8List bytes) {
  final value = _ManifestReader(bytes).readValue();
  if (value is! Map<String, Object?>) {
    throw StateError(
      'expected the manifest to decode to a string-keyed map, found $value',
    );
  }
  return value;
}

/// Reads the StandardMessageCodec encoding the asset bundle tool writes:
/// null, booleans, integers, doubles, strings, lists and string-keyed maps.
/// Any other tag, or bytes running out mid-value, throws a [StateError]
/// naming the offset, so a manifest the engine would reject fails this test
/// instead of passing it.
class _ManifestReader {
  final Uint8List _bytes;
  int _offset = 0;

  _ManifestReader(this._bytes);

  /// Reads one value at the current offset.
  Object? readValue() {
    final tag = _readByte();
    return switch (tag) {
      0 => null,
      1 => true,
      2 => false,
      3 => _readSizedInt(4),
      4 => _readSizedInt(8),
      6 => _readFloat(),
      7 => _readString(),
      12 => _readList(),
      13 => _readStringMap(),
      _ => throw StateError(
        'unsupported StandardMessageCodec tag $tag at byte ${_offset - 1}',
      ),
    };
  }

  int _readByte() {
    _requireBytes(1);
    return _bytes[_offset++];
  }

  void _requireBytes(int count) {
    if (_offset + count > _bytes.length) {
      throw StateError(
        'truncated manifest: byte $_offset needs $count more '
        'bytes of ${_bytes.length}',
      );
    }
  }

  /// Reads a little-endian-or-host size in the codec's short/long form. The
  /// writer emits sizes in host order; every Apple host is little-endian, and
  /// manifests in practice use the single-byte form anyway.
  int _readSize() {
    final first = _readByte();
    if (first < 254) return first;
    final width = first == 254 ? 2 : 4;
    _requireBytes(width);
    final data = ByteData.sublistView(_bytes, _offset, _offset + width);
    _offset += width;
    return width == 2
        ? data.getUint16(0, Endian.host)
        : data.getUint32(0, Endian.host);
  }

  int _readSizedInt(int width) {
    _requireBytes(width);
    final data = ByteData.sublistView(_bytes, _offset, _offset + width);
    _offset += width;
    return width == 4
        ? data.getInt32(0, Endian.host)
        : data.getInt64(0, Endian.host);
  }

  double _readFloat() {
    _offset += (8 - _offset % 8) % 8;
    _requireBytes(8);
    final value = ByteData.sublistView(
      _bytes,
      _offset,
      _offset + 8,
    ).getFloat64(0, Endian.host);
    _offset += 8;
    return value;
  }

  String _readString() {
    final length = _readSize();
    _requireBytes(length);
    final value = utf8.decode(_bytes.sublist(_offset, _offset + length));
    _offset += length;
    return value;
  }

  List<Object?> _readList() {
    final length = _readSize();
    return [for (var i = 0; i < length; i++) readValue()];
  }

  Map<String, Object?> _readStringMap() {
    final length = _readSize();
    final map = <String, Object?>{};
    for (var i = 0; i < length; i++) {
      final key = readValue();
      if (key is! String) {
        throw StateError('expected a string map key at entry $i, found $key');
      }
      map[key] = readValue();
    }
    return map;
  }
}
