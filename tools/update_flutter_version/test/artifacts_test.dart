import 'package:test/test.dart';

import '../artifacts.dart';

void main() {
  group('desktopEngineArtifactPath', () {
    test('macOS release and debug (debug has no mode suffix)', () {
      expect(
        desktopEngineArtifactPath('macos', 'x64', 'release'),
        'darwin-x64-release/FlutterMacOS.framework.zip',
      );
      expect(
        desktopEngineArtifactPath('macos', 'x64', 'debug'),
        'darwin-x64/FlutterMacOS.framework.zip',
      );
    });

    test('Linux and Windows always carry a mode suffix', () {
      expect(
        desktopEngineArtifactPath('linux', 'x64', 'debug'),
        'linux-x64-debug/linux-x64-flutter-gtk.zip',
      );
      expect(
        desktopEngineArtifactPath('linux', 'arm64', 'release'),
        'linux-arm64-release/linux-arm64-flutter-gtk.zip',
      );
      expect(
        desktopEngineArtifactPath('windows', 'x64', 'release'),
        'windows-x64-release/windows-x64-flutter.zip',
      );
    });

    test('unknown OS has no artifact', () {
      expect(desktopEngineArtifactPath('ios', 'x64', 'release'), isNull);
    });
  });

  test('macOS arm64 engines are the x64 ones', () {
    expect(engineArchForOs('macos', 'arm64'), 'x64');
    expect(engineArchForOs('linux', 'arm64'), 'arm64');
  });

  test('gen_snapshot is fetched for the x64 host where arm64 has no build', () {
    expect(genSnapshotHostPlatform('darwin-arm64'), 'darwin-x64');
    expect(genSnapshotHostPlatform('linux-arm64'), 'linux-x64');
    expect(genSnapshotHostPlatform('windows-x64'), 'windows-x64');
  });

  test('each path is listed once', () {
    final paths = allEngineArtifacts();
    expect(paths.toSet().length, paths.length);
  });

  test('lists exactly the artifacts the repository rules download', () {
    // Pinned on purpose. A change to the rules' host or target matrix, or to
    // a path helper, must come with a change here; that is how the two stay
    // in step, since Starlark cannot be imported from Dart.
    expect(allEngineArtifacts().toSet(), {
      'flutter_patched_sdk.zip',
      'flutter_patched_sdk_product.zip',
      'sky_engine.zip',
      'dart-sdk-darwin-arm64.zip',
      'dart-sdk-darwin-x64.zip',
      'dart-sdk-linux-x64.zip',
      'dart-sdk-linux-arm64.zip',
      'dart-sdk-windows-x64.zip',
      'darwin-arm64/artifacts.zip',
      'darwin-x64/artifacts.zip',
      'linux-x64/artifacts.zip',
      'linux-arm64/artifacts.zip',
      'windows-x64/artifacts.zip',
      'darwin-arm64-release/artifacts.zip',
      'darwin-x64-release/artifacts.zip',
      'darwin-arm64/font-subset.zip',
      'darwin-x64/font-subset.zip',
      'linux-x64/font-subset.zip',
      'linux-arm64/font-subset.zip',
      'windows-x64/font-subset.zip',
      'flutter-web-sdk.zip',
      'darwin-x64-release/FlutterMacOS.framework.zip',
      'linux-x64-release/linux-x64-flutter-gtk.zip',
      'linux-arm64-release/linux-arm64-flutter-gtk.zip',
      'windows-x64-release/windows-x64-flutter.zip',
      'darwin-x64/FlutterMacOS.framework.zip',
      'linux-x64-debug/linux-x64-flutter-gtk.zip',
      'linux-arm64-debug/linux-arm64-flutter-gtk.zip',
      'windows-x64-debug/windows-x64-flutter.zip',
      'windows-x64/flutter-cpp-client-wrapper.zip',
      'ios-release/artifacts.zip',
      'ios/artifacts.zip',
      'android-arm64-release/artifacts.zip',
      'android-arm64/artifacts.zip',
      'android-x64-release/artifacts.zip',
      'android-x64/artifacts.zip',
      'android-arm64-release/darwin-x64.zip',
      'android-arm64-release/linux-x64.zip',
      'android-arm64-release/windows-x64.zip',
      'android-x64-release/darwin-x64.zip',
      'android-x64-release/linux-x64.zip',
      'android-x64-release/windows-x64.zip',
    });
  });

  test('the Android artifacts are in the snippet', () {
    final groups = engineArtifactGroups();
    final android = groups.firstWhere(
      (g) => g.comment.startsWith('Android engine'),
    );
    expect(android.paths, [
      'android-arm64-release/artifacts.zip',
      'android-arm64/artifacts.zip',
      'android-x64-release/artifacts.zip',
      'android-x64/artifacts.zip',
    ]);
  });
}
