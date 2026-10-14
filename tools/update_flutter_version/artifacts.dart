/// The engine artifacts the repository rules download for one Flutter version.
///
/// This is a Dart mirror of the naming in `flutter/private/artifact_urls.bzl`
/// and of the host and target tables in `flutter/private/toolchains_repo.bzl`
/// and `flutter/repositories.bzl`. Starlark cannot be imported from Dart, so
/// the mirror is kept by hand; `artifacts_test.dart` pins the expected set so
/// that a change to either side shows up as a test failure here. Every path
/// listed here is one that a rule requests, and each is looked up through
/// `flutter_artifact_sha256()` when the rule runs, so a path missing from
/// ARTIFACT_CHECKSUMS fails the build rather than downloading unverified.
library;

/// One heading in the printed snippet, with the artifacts under it.
class ArtifactGroup {
  final String comment;
  final List<String> paths;

  const ArtifactGroup(this.comment, this.paths);
}

/// Host platforms that have a `flutter_engine_artifacts` repo.
/// Mirrors `HOST_PLATFORMS` in toolchains_repo.bzl.
const hostPlatforms = [
  'darwin-arm64',
  'darwin-x64',
  'linux-x64',
  'linux-arm64',
  'windows-x64',
];

/// Android ABIs with a cross-compilation toolchain.
/// Mirrors the `android-*` entries of `CROSS_COMPILATION_PAIRS`.
const androidArches = ['arm64', 'x64'];

/// Desktop targets that get a `flutter_desktop_engine_repo`.
/// Mirrors the values of `DESKTOP_CROSS_PAIRS`.
const desktopTargets = ['darwin-x64', 'linux-x64', 'windows-x64'];

/// Host platform that a `gen_snapshot` is fetched for. Mirrors
/// `gen_snapshot_host_platform` in engine_helpers.bzl: arm64 hosts run the
/// x64 binary.
String genSnapshotHostPlatform(String host) {
  const fallback = {'darwin-arm64': 'darwin-x64', 'linux-arm64': 'linux-x64'};
  return fallback[host] ?? host;
}

/// Mirrors `dart_sdk_artifact_path`.
String dartSdkArtifactPath(String host) => 'dart-sdk-$host.zip';

/// Mirrors `host_artifacts_path`.
String hostArtifactsPath(String host, {String mode = 'debug'}) =>
    '${_withMode(host, mode)}/artifacts.zip';

/// Mirrors `android_engine_artifact_path`.
String androidEngineArtifactPath(String arch, String mode) =>
    '${_withMode('android-$arch', mode)}/artifacts.zip';

/// Mirrors `ios_engine_artifact_path`.
String iosEngineArtifactPath(String mode) =>
    '${_withMode('ios', mode)}/artifacts.zip';

/// Mirrors `gen_snapshot_cross_artifact_path`.
String genSnapshotCrossArtifactPath(String target, String mode, String host) =>
    '$target-$mode/$host.zip';

/// Mirrors `desktop_engine_artifact_path`. Returns null for an unknown OS.
/// macOS names its debug engine without a mode suffix; Linux and Windows
/// always carry one.
String? desktopEngineArtifactPath(String os, String arch, String mode) {
  final prefix = switch (os) {
    'macos' => 'darwin',
    'linux' => 'linux',
    'windows' => 'windows',
    _ => null,
  };
  if (prefix == null) return null;
  final platformDir = os == 'macos'
      ? _withMode('$prefix-$arch', mode)
      : '$prefix-$arch-$mode';
  return switch (os) {
    'macos' => '$platformDir/FlutterMacOS.framework.zip',
    'linux' => '$platformDir/linux-$arch-flutter-gtk.zip',
    'windows' => '$platformDir/windows-$arch-flutter.zip',
    _ => null,
  };
}

/// Mirrors `engine_arch_for_os`: macOS engines are x64 for both host archs.
String engineArchForOs(String os, String arch) => os == 'macos' ? 'x64' : arch;

String _withMode(String dir, String mode) =>
    mode == 'debug' ? dir : '$dir-$mode';

/// The engine artifacts for one version, grouped the way the printed snippet
/// lays them out. A path appears under the first group that names it.
List<ArtifactGroup> engineArtifactGroups() {
  final groups = <ArtifactGroup>[
    const ArtifactGroup('Patched Dart SDK for Flutter (debug + product)', [
      'flutter_patched_sdk.zip',
      'flutter_patched_sdk_product.zip',
    ]),
    const ArtifactGroup(
      'Dart SDK sources for the analyzer (dart:ui and friends, via lib/_embedder.yaml)',
      ['sky_engine.zip'],
    ),
    ArtifactGroup(
      'Host Dart SDK (the Flutter-bundled Dart SDK per host platform)',
      [
        for (final host in hostPlatforms) dartSdkArtifactPath(host),
      ],
    ),
    ArtifactGroup('Host tools (frontend_server, gen_snapshot, icudtl.dat)', [
      for (final host in hostPlatforms) hostArtifactsPath(host),
    ]),
    ArtifactGroup(
      'Release host tools (macOS only — product-mode gen_snapshot for AOT builds)',
      [
        for (final host in hostPlatforms)
          if (host.startsWith('darwin'))
            hostArtifactsPath(host, mode: 'release'),
      ],
    ),
    ArtifactGroup(
      'Font-subset tools (const_finder + font-subset binary for icon tree shaking)',
      [for (final host in hostPlatforms) '$host/font-subset.zip'],
    ),
    const ArtifactGroup('Flutter web SDK', ['flutter-web-sdk.zip']),
    ArtifactGroup(
      'Desktop engine runtime libraries (release mode)',
      [
        for (final host in hostPlatforms) _desktopEngine(host, 'release'),
        for (final target in desktopTargets) _desktopEngine(target, 'release'),
      ],
    ),
    ArtifactGroup(
      'Desktop engine runtime libraries (debug mode — JIT, needed for -c dbg)',
      [
        for (final host in hostPlatforms) _desktopEngine(host, 'debug'),
        for (final target in desktopTargets)
          if (!target.startsWith('darwin')) _desktopEngine(target, 'debug'),
      ],
    ),
    ArtifactGroup(
      'C++ client wrapper (Windows — flutter/plugin_registry.h)',
      [
        for (final host in hostPlatforms)
          if (host.startsWith('windows'))
            '$host/flutter-cpp-client-wrapper.zip',
      ],
    ),
    ArtifactGroup(
      'iOS engine (Flutter.xcframework — release for device, debug for simulator)',
      [iosEngineArtifactPath('release'), iosEngineArtifactPath('debug')],
    ),
    ArtifactGroup(
      'Android engine (flutter.jar — release and debug, per ABI)',
      [
        for (final arch in androidArches) ...[
          androidEngineArtifactPath(arch, 'release'),
          androidEngineArtifactPath(arch, 'debug'),
        ],
      ],
    ),
    ArtifactGroup(
      'Android gen_snapshot cross-compilers (release, per host)',
      [
        for (final arch in androidArches)
          for (final host in hostPlatforms)
            genSnapshotCrossArtifactPath(
              'android-$arch',
              'release',
              genSnapshotHostPlatform(host),
            ),
      ],
    ),
  ];

  // The printed snippet names each path once; the first group wins.
  final seen = <String>{};
  return [
    for (final group in groups)
      ArtifactGroup(group.comment, [
        for (final path in group.paths)
          if (seen.add(path)) path,
      ]),
  ];
}

/// Every engine artifact path a rule can download, each once, in print order.
/// Excludes `material_fonts.zip` (its URL comes from the version's metadata)
/// and the framework source tarball (GitHub, keyed by tag).
List<String> allEngineArtifacts() => [
  for (final group in engineArtifactGroups()) ...group.paths,
];

/// The desktop engine a host or target platform needs in [mode]. Built from
/// the platform's own OS and arch, the way `flutter_engine_artifacts` and
/// `flutter_desktop_engine_repo` build it.
String _desktopEngine(String platform, String mode) {
  final os = _osOf(platform);
  final arch = engineArchForOs(os, platform.split('-')[1]);
  final path = desktopEngineArtifactPath(os, arch, mode);
  if (path == null) {
    throw StateError('no desktop engine artifact for $platform ($mode)');
  }
  return path;
}

String _osOf(String platform) => switch (platform.split('-')[0]) {
  'darwin' => 'macos',
  final other => other,
};
