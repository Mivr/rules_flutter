/// Bazel-side driver for `flutter_integration_test`.
///
/// Launches a built Flutter application on the target platform (starting with
/// `web`, designed so `linux` and `android` share the harness), hosts a
/// localhost WebSocket + HTTP server, and drives the in-app `RemoteListener`
/// suite compiled into the application entrypoint.
///
/// Fails (exits non-zero) on:
/// - any test expectation failure (printing test name, expected, and actual),
/// - any uncaught Dart/Flutter/JS error,
/// - browser or target process crash / unexpected exit,
/// - dial-back or per-test timeout,
/// - zero executed cases (no test passed or failed): a run that executes
///   nothing is a broken harness, not a pass.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'bazel_test_protocol.dart';
import 'flutter_integration_test_android.dart';
import 'flutter_integration_test_ios.dart';
import 'flutter_integration_test_launcher.dart';
import 'flutter_integration_test_web_serve.dart';
import 'run_home.dart' as run_home;
import 'test_support.dart';

export 'flutter_integration_test_android.dart';
export 'flutter_integration_test_ios.dart';
export 'flutter_integration_test_launcher.dart';
export 'flutter_integration_test_web_serve.dart';

void main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln(
      'flutter_integration_test runner: unrecognised arguments: '
      '${args.join(" ")}',
    );
    exit(64);
  }

  final r = Runfiles.create();
  final platform =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PLATFORM'] ?? 'web';
  final testPath =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PATH'] ??
      'integration_test.dart';

  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }
  // The suite's library-level `@Tags`, extracted at build time: sent in the
  // handshake below so the test isolate's root group carries them, as
  // `test_core` sends `parseMetadata`'s result.
  final Set<String> libraryTags;
  try {
    libraryTags = readLibraryTags(Platform.environment, r.rlocation);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  final shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }

  final PlatformLauncher launcher;
  try {
    launcher = createPlatformLauncher(platform, Platform.environment, r);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  exitCode = await runIntegrationSuite(
    IntegrationSuiteRun(
      launcher: launcher,
      testPath: testPath,
      selection: selection,
      libraryTags: libraryTags,
      xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
      bazelTestTimeout: Platform.environment['TEST_TIMEOUT'],
      dialBackBound: dialBackBoundForPlatform(platform),
    ),
  );
}

/// Creates the [PlatformLauncher] for [platform] from environment variables.
PlatformLauncher createPlatformLauncher(
  String platform,
  Map<String, String> env,
  Runfiles r,
) {
  switch (platform) {
    case 'web':
      return _webLauncherFromEnv(env, r);
    case 'linux':
      return _linuxLauncherFromEnv(env, r);
    case 'android':
      return androidLauncherFromEnv(env, r);
    case 'ios':
      return iosLauncherFromEnv(env, r);
    default:
      throw FormatException(
        'Unsupported integration test platform "$platform". '
        'Supported platforms: web, linux, android, ios.',
      );
  }
}

/// Reads a required launcher environment variable, failing with the same
/// `platform="…"` message the builders always raised.
///
/// One helper for the web and Linux builders, so the missing-variable checks
/// they used to repeat stay identical everywhere.
String _requireLauncherEnv(
  Map<String, String> env,
  String key,
  String platform,
) {
  final value = env[key];
  if (value == null || value.isEmpty) {
    throw FormatException('$key must be set for platform="$platform".');
  }
  return value;
}

/// Builds the web launcher: the built bundle served over localhost HTTP to
/// the pinned `chrome-headless-shell`.
WebPlatformLauncher _webLauncherFromEnv(Map<String, String> env, Runfiles r) {
  final webDir = r.rlocation(
    _requireLauncherEnv(env, 'FLUTTER_INTEGRATION_TEST_WEB_DIR', 'web'),
  );
  final browserBinary = r.rlocation(
    _requireLauncherEnv(env, 'FLUTTER_INTEGRATION_TEST_BROWSER', 'web'),
  );
  final fontconfigKey = env['FLUTTER_INTEGRATION_TEST_FONTCONFIG'];
  final fontconfigFile = (fontconfigKey == null || fontconfigKey.isEmpty)
      ? null
      : r.rlocation(fontconfigKey);
  final robotoKey = env['FLUTTER_INTEGRATION_TEST_ROBOTO_FONT'];
  final robotoFont = (robotoKey == null || robotoKey.isEmpty)
      ? null
      : r.rlocation(robotoKey);
  return WebPlatformLauncher(
    webDir: webDir,
    browserBinary: browserBinary,
    fontconfigFile: fontconfigFile,
    robotoFontFile: robotoFont,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );
}

/// Builds the Linux launcher: the desktop bundle under a hermetic `Xvfb`.
LinuxPlatformLauncher _linuxLauncherFromEnv(
  Map<String, String> env,
  Runfiles r,
) {
  final bundleDir = r.rlocation(
    _requireLauncherEnv(env, 'FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE', 'linux'),
  );
  final binaryName = _requireLauncherEnv(
    env,
    'FLUTTER_INTEGRATION_TEST_LINUX_BINARY',
    'linux',
  );
  final xvfbBinary = r.rlocation(
    _requireLauncherEnv(env, 'FLUTTER_INTEGRATION_TEST_XVFB', 'linux'),
  );
  final xkbcompBinary = r.rlocation(
    _requireLauncherEnv(env, 'FLUTTER_INTEGRATION_TEST_XKBCOMP', 'linux'),
  );
  final fontconfigKey = env['FLUTTER_INTEGRATION_TEST_FONTCONFIG'];
  final fontconfigFile = (fontconfigKey == null || fontconfigKey.isEmpty)
      ? null
      : r.rlocation(fontconfigKey);
  return LinuxPlatformLauncher(
    bundleDir: bundleDir,
    binaryName: binaryName,
    xvfbBinary: xvfbBinary,
    xkbcompBinary: xkbcompBinary,
    fontconfigFile: fontconfigFile,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );
}

/// Builds the command-line flags passed to the hermetic `chrome-headless-shell`.
List<String> buildChromeArguments({
  required String url,
  required String userDataDir,
}) {
  return <String>[
    '--headless',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-extensions',
    '--disable-sync',
    '--disable-translate',
    '--metrics-recording-only',
    '--mute-audio',
    '--window-size=800,600',
    '--user-data-dir=$userDataDir',
    url,
  ];
}

/// Builds the hermetic environment for `chrome-headless-shell`.
///
/// Clears `PATH` so no host browser or binary on `PATH` can ever be invoked,
/// and sets `LD_LIBRARY_PATH` exclusively to the pinned runtime library
/// directories in runfiles.
Map<String, String> buildChromeEnvironment({
  required String browserBinary,
  required String scratchDir,
  EnvForwarding forwarding = const EnvForwarding(),
}) {
  final browserFile = File(browserBinary);
  final browserDir = browserFile.parent.path;
  final repoRoot = browserFile.parent.parent.path;
  final libDirs = <String>[
    browserDir,
    '$repoRoot/sysroot/usr/lib/x86_64-linux-gnu',
    '$repoRoot/sysroot/lib/x86_64-linux-gnu',
  ];

  final resolved = resolveForwarding(forwarding);
  final fontconfigFile = resolved.fontconfigFile;

  final result = <String, String>{
    'PATH': '',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    // Private HOME policy (RT37-flutter:02): every home-locating key lands
    // in the scratch dir, which the launcher removes afterwards.
    ...run_home.privateHomeEnv(scratchDir),
    'TMPDIR': scratchDir,
    'TZ': resolved.timeZone,
    if (fontconfigFile != null) ...{
      'FONTCONFIG_FILE': fontconfigFile,
      'FONTCONFIG_PATH': File(fontconfigFile).parent.path,
    },
  };
  result.addAll(resolved.declared);
  result['TZ'] = resolved.timeZone;
  return result;
}

/// Builds the command-line arguments passed to the hermetic `Xvfb` binary.
///
/// Uses `-displayfd 1` so `Xvfb` picks a free display number and writes
/// `<display>\n` to stdout once the X server is listening for connections.
List<String> buildXvfbArguments({required String xkbDir}) {
  return <String>[
    '-displayfd',
    '1',
    '-screen',
    '0',
    '1024x768x24',
    '-nolisten',
    'tcp',
    '-noreset',
    '-xkbdir',
    xkbDir,
  ];
}

/// Builds the hermetic environment for `Xvfb`.
///
/// Restricts `PATH` to the pinned sysroot `usr/bin` (so `xkbcomp` resolves
/// exclusively from the pinned package archive) and `LD_LIBRARY_PATH` to the
/// pinned sysroot library directories.
Map<String, String> buildXvfbEnvironment({
  required String sysrootDir,
  required String scratchDir,
}) {
  final libDirs = <String>[
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];
  return <String, String>{
    'PATH': '$sysrootDir/usr/bin',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    // Private HOME policy (RT37-flutter:02); see buildChromeEnvironment.
    ...run_home.privateHomeEnv(scratchDir),
    'TMPDIR': scratchDir,
    'XKB_BINDIR': '$sysrootDir/usr/bin',
  };
}

/// Builds the hermetic environment for the compiled Flutter Linux desktop app.
///
/// Directs GTK3, GDK, GLib, Fontconfig, libglvnd, and Mesa (`llvmpipe`
/// `swrast_dri.so`) to the pinned sysroot in runfiles and the `Xvfb` display.
Map<String, String> buildLinuxAppEnvironment({
  required String bundleDir,
  required String sysrootDir,
  required String scratchDir,
  required String display,
  required String harnessUrl,
  EnvForwarding forwarding = const EnvForwarding(),
}) {
  final libDirs = <String>[
    '$bundleDir/lib',
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];
  final driDir = '$sysrootDir/usr/lib/x86_64-linux-gnu/dri';

  final resolved = resolveForwarding(forwarding);
  final fontconfigFile = resolved.fontconfigFile;

  final result = <String, String>{
    'PATH': '$sysrootDir/usr/bin',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'DISPLAY': display,
    'GDK_BACKEND': 'x11',
    'LIBGL_ALWAYS_SOFTWARE': '1',
    'GALLIUM_DRIVER': 'llvmpipe',
    'LIBGL_DRIVERS_PATH': driDir,
    'GBM_DRIVERS_PATH': driDir,
    '__EGL_VENDOR_LIBRARY_DIRS': '$sysrootDir/usr/share/glvnd/egl_vendor.d',
    'XLOCALEDIR': '$sysrootDir/usr/share/X11/locale',
    'XKB_CONFIG_ROOT': '$sysrootDir/usr/share/X11/xkb',
    'GIO_MODULE_DIR': '$scratchDir/empty-gio-modules',
    'GTK_PATH': '$scratchDir/empty-gtk-path',
    'NO_AT_BRIDGE': '1',
    'GSETTINGS_BACKEND': 'memory',
    // Private HOME policy (RT37-flutter:02); see buildChromeEnvironment.
    // XDG_RUNTIME_DIR keeps its own subdir, as before: it is not one of
    // the helper's home-locating keys.
    ...run_home.privateHomeEnv(scratchDir),
    'TMPDIR': scratchDir,
    'XDG_RUNTIME_DIR': '$scratchDir/xdg-runtime',
    'FLUTTER_INTEGRATION_TEST_HARNESS_URL': harnessUrl,
    'TZ': resolved.timeZone,
    if (fontconfigFile != null) ...{
      'FONTCONFIG_FILE': fontconfigFile,
      'FONTCONFIG_PATH': File(fontconfigFile).parent.path,
    },
  };
  result.addAll(resolved.declared);
  result['TZ'] = resolved.timeZone;
  return result;
}

/// Copies the pinned `Xvfb` binary into [scratchDir] and clears its compiled-in
/// `XkbBinDirectory` (`"/usr/bin"`) so `Xvfb` invokes `xkbcomp` via `PATH`
/// (`<sysroot>/usr/bin/xkbcomp`) instead of `/usr/bin/xkbcomp`.
String prepareHermeticXvfbBinary({
  required String sourceXvfbBinary,
  required String scratchDir,
}) {
  final binDir = Directory('$scratchDir/bin')..createSync(recursive: true);
  final destPath = '${binDir.path}/Xvfb';
  File(sourceXvfbBinary).copySync(destPath);

  final bytes = File(destPath).readAsBytesSync();
  // In Xorg's xkbInit.c, XkbBinDirectory is initialized to "/usr/bin"
  // immediately adjacent to XkbBaseDirectory ("/usr/share/X11/xkb"). Clearing
  // "/usr/bin" to an empty C string causes XkbDDXCompileKeymapByNames to omit
  // the directory prefix and resolve `xkbcomp` from PATH.
  const usrBin = <int>[0x2f, 0x75, 0x73, 0x72, 0x2f, 0x62, 0x69, 0x6e, 0x00];
  const xkbShare = <int>[
    0x2f, 0x75, 0x73, 0x72, 0x2f, 0x73, 0x68, 0x61, 0x72, 0x65, // /usr/share
    0x2f, 0x58, 0x31, 0x31, 0x2f, 0x78, 0x6b, 0x62, 0x00, // /X11/xkb\0
  ];
  final xkbIdx = _indexOfBytes(bytes, xkbShare);
  if (xkbIdx >= usrBin.length) {
    final searchStart = xkbIdx - 32 < 0 ? 0 : xkbIdx - 32;
    final usrBinIdx = _indexOfBytes(
      bytes,
      usrBin,
      start: searchStart,
      end: xkbIdx,
    );
    if (usrBinIdx >= 0) {
      final raf = File(destPath).openSync(mode: FileMode.writeOnlyAppend);
      try {
        raf.setPositionSync(usrBinIdx);
        raf.writeFromSync(const <int>[0, 0, 0, 0, 0, 0, 0, 0]);
      } finally {
        raf.closeSync();
      }
    }
  }
  return destPath;
}

int _indexOfBytes(
  List<int> haystack,
  List<int> needle, {
  int start = 0,
  int? end,
}) {
  final limit = (end ?? haystack.length) - needle.length;
  outer:
  for (var i = start; i <= limit; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Launches the built Flutter web bundle in the pinned `chrome-headless-shell`
/// and serves the bundle over localhost HTTP.
class WebPlatformLauncher implements PlatformLauncher {
  WebPlatformLauncher({
    required this.webDir,
    required this.browserBinary,
    required this.baseTempDir,
    this.fontconfigFile,
    this.robotoFontFile,
  });

  /// Built web bundle directory served over localhost HTTP.
  final String webDir;

  /// Pinned `chrome-headless-shell` binary running the bundle.
  final String browserBinary;

  /// Scratch parent for the browser profile and XDG homes.
  final String baseTempDir;

  /// Pinned `fonts.conf`, used when the bundle ships no sysroot fonts.
  final String? fontconfigFile;

  /// Pinned Roboto font served to the bundle, when the target needs one.
  final String? robotoFontFile;

  Directory? _scratchDir;

  @override
  String get platformName => 'web';

  @override
  String get suiteRuntime => 'chrome';

  @override
  String get suiteCompiler => 'dart2js';

  @override
  Future<Process> startTarget(HarnessBinding binding) async {
    if (!File(browserBinary).existsSync()) {
      throw StateError(
        'Pinned chrome-headless-shell binary not found at "$browserBinary".',
      );
    }
    if (!Directory(webDir).existsSync()) {
      throw StateError('Built web bundle directory not found at "$webDir".');
    }

    final scratch = Directory(
      '$baseTempDir/chrome_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    final userDataDir = Directory('${scratch.path}/profile')
      ..createSync(recursive: true);
    Directory('${scratch.path}/fontconfig-cache').createSync(recursive: true);

    // The page URL carries the run's token; the in-app bootstrap forwards it
    // onto the dial-back URL, so the harness adopts only this run's browser.
    final pageUrl = 'http://127.0.0.1:${binding.port}/?token=${binding.token}';
    final args = buildChromeArguments(
      url: pageUrl,
      userDataDir: userDataDir.path,
    );
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final env = buildChromeEnvironment(
      browserBinary: browserBinary,
      scratchDir: scratch.path,
      forwarding: EnvForwarding(
        env: declaredEnv,
        tz: tz,
        fontconfigFile: fontconfigFile,
      ),
    );

    return Process.start(
      browserBinary,
      args,
      environment: env,
      includeParentEnvironment: false,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    await serveWebBundleRequest(
      request,
      webDir: webDir,
      robotoFontFile: robotoFontFile,
    );
  }

  @override
  Future<void> dispose() async {
    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Launches the built Flutter Linux desktop bundle inside a hermetic, pinned
/// `Xvfb` virtual display using the pinned GTK3 and Mesa software OpenGL/EGL
/// runtime libraries.
class LinuxPlatformLauncher implements PlatformLauncher {
  LinuxPlatformLauncher({
    required this.bundleDir,
    required this.binaryName,
    required this.xvfbBinary,
    required this.xkbcompBinary,
    required this.baseTempDir,
    this.fontconfigFile,
  });

  /// Built Linux desktop bundle directory.
  final String bundleDir;

  /// Bundle executable name inside [bundleDir].
  final String binaryName;

  /// Pinned `Xvfb` binary providing the virtual display.
  final String xvfbBinary;

  /// Pinned `xkbcomp` binary, verified present for `Xvfb`'s keyboard maps.
  final String xkbcompBinary;

  /// Scratch parent for the run's config, cache and runtime homes.
  final String baseTempDir;

  /// Pinned `fonts.conf`, used when the sysroot ships no fonts.
  final String? fontconfigFile;

  Directory? _scratchDir;
  Process? _xvfbProcess;
  String? _displayNumber;

  @override
  String get platformName => 'linux';

  @override
  String get suiteRuntime => 'vm';

  @override
  String get suiteCompiler => 'kernel';

  /// Creates the scratch tree for a Linux run: runtime and fontconfig homes
  /// plus the empty GTK/GIO override directories. The XDG home keys point
  /// at the scratch root itself (see buildLinuxAppEnvironment), so no
  /// `.config`/`.cache` subdirs are needed.
  Directory _prepareLinuxScratch() {
    final scratch = Directory(
      '$baseTempDir/linux_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    Directory('${scratch.path}/xdg-runtime').createSync(recursive: true);
    Directory('${scratch.path}/fontconfig-cache').createSync(recursive: true);
    Directory('${scratch.path}/empty-gio-modules').createSync(recursive: true);
    Directory('${scratch.path}/empty-gtk-path').createSync(recursive: true);
    return scratch;
  }

  /// Points fontconfig at the sysroot's fonts when it ships any, falling
  /// back to the pinned `fonts.conf`.
  String? _writeScratchFontsConf(Directory scratch, String sysrootDir) {
    final sysrootFontsDir = Directory('$sysrootDir/usr/share/fonts');
    if (!sysrootFontsDir.existsSync()) return fontconfigFile;
    final localFontsConf = File('${scratch.path}/fonts.conf');
    localFontsConf.writeAsStringSync('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${sysrootFontsDir.path}</dir>
  <cachedir>${scratch.path}/fontconfig-cache</cachedir>
</fontconfig>
''');
    return localFontsConf.path;
  }

  /// Starts the patched `Xvfb` and waits for its `-displayfd` number.
  Future<String> _bootXvfb(
    String patchedXvfb,
    List<String> xvfbArgs,
    Map<String, String> xvfbEnv,
  ) async {
    final xvfb = await Process.start(
      patchedXvfb,
      xvfbArgs,
      environment: xvfbEnv,
      includeParentEnvironment: false,
    );
    _xvfbProcess = xvfb;

    final xvfbStderr = <String>[];
    xvfb.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      if (xvfbStderr.length < 50) {
        xvfbStderr.add(line);
      }
    });

    final displayCompleter = Completer<String>();
    final stdoutSub = xvfb.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isNotEmpty && !displayCompleter.isCompleted) {
              displayCompleter.complete(trimmed);
            }
          },
          onDone: () {
            if (!displayCompleter.isCompleted) {
              displayCompleter.completeError(
                StateError(
                  'Xvfb exited before reporting a display number on -displayfd:\n'
                  '${xvfbStderr.join("\n")}',
                ),
              );
            }
          },
        );

    try {
      return await displayCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for Xvfb to report a display number:\n'
          '${xvfbStderr.join("\n")}',
        ),
      );
    } finally {
      await stdoutSub.cancel();
    }
  }

  @override
  Future<Process> startTarget(HarnessBinding binding) async {
    if (!File(xvfbBinary).existsSync()) {
      throw StateError('Pinned Xvfb binary not found at "$xvfbBinary".');
    }
    if (!File(xkbcompBinary).existsSync()) {
      throw StateError('Pinned xkbcomp binary not found at "$xkbcompBinary".');
    }
    if (!Directory(bundleDir).existsSync()) {
      throw StateError(
        'Built Linux bundle directory not found at "$bundleDir".',
      );
    }
    final appBinary = '$bundleDir/$binaryName';
    if (!File(appBinary).existsSync()) {
      throw StateError(
        'Built Linux application binary not found at "$appBinary".',
      );
    }

    // xvfbBinary is at <repoRoot>/sysroot/usr/bin/Xvfb.
    final sysrootDir = File(xvfbBinary).parent.parent.parent.path;

    final scratch = _prepareLinuxScratch();
    final effectiveFontconfig = _writeScratchFontsConf(scratch, sysrootDir);

    final patchedXvfb = prepareHermeticXvfbBinary(
      sourceXvfbBinary: xvfbBinary,
      scratchDir: scratch.path,
    );
    final xvfbArgs = buildXvfbArguments(
      xkbDir: '$sysrootDir/usr/share/X11/xkb',
    );
    final xvfbEnv = buildXvfbEnvironment(
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
    );

    final displayNumber = await _bootXvfb(patchedXvfb, xvfbArgs, xvfbEnv);
    _displayNumber = displayNumber;

    final harnessUrl = binding.url;
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final appEnv = buildLinuxAppEnvironment(
      bundleDir: bundleDir,
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
      display: ':$displayNumber',
      harnessUrl: harnessUrl,
      forwarding: EnvForwarding(
        env: declaredEnv,
        tz: tz,
        fontconfigFile: effectiveFontconfig,
      ),
    );

    return Process.start(
      appBinary,
      const <String>[],
      workingDirectory: bundleDir,
      environment: appEnv,
      includeParentEnvironment: false,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    final xvfb = _xvfbProcess;
    _xvfbProcess = null;
    if (xvfb != null) {
      xvfb.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => xvfb.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 0,
        ),
      );
    }

    final display = _displayNumber;
    _displayNumber = null;
    if (display != null) {
      cleanupQuietly(() {
        final lockFile = File('/tmp/.X$display-lock');
        if (lockFile.existsSync()) lockFile.deleteSync();
      });
      cleanupQuietly(() {
        final sockFile = File('/tmp/.X11-unix/X$display');
        if (sockFile.existsSync()) sockFile.deleteSync();
      });
    }

    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Everything needed for one integration suite run.
///
/// Built once from the environment in [main] and passed down to
/// [runIntegrationSuite], so the values that travel together stay in one
/// object instead of a long parameter list.
class IntegrationSuiteRun {
  const IntegrationSuiteRun({
    required this.launcher,
    required this.testPath,
    required this.selection,
    this.libraryTags = const {},
    required this.xmlOutput,
    required this.bazelTestTimeout,
    this.dialBackBound = const Duration(seconds: 45),
  });

  /// Target launcher (web, Linux desktop or Android emulator) the suite
  /// runs against.
  final PlatformLauncher launcher;

  /// Integration test file the target executes.
  final String testPath;

  /// Name filter selecting which cases run.
  final TestSelection selection;

  /// The suite's library-level `@Tags`, sent in the handshake so the test
  /// isolate's root group carries them.
  final Set<String> libraryTags;

  /// JUnit XML output file, null when Bazel asked for none.
  final String? xmlOutput;

  /// Raw `TEST_TIMEOUT` seconds naming the per-test ceiling.
  final String? bazelTestTimeout;

  /// How long the harness waits for the target to dial back before failing.
  final Duration dialBackBound;
}

/// Runs the integration test suite end-to-end using [run.launcher].
///
/// Mints a random per-run token ([harnessToken] overrides it for tests) and
/// hands it to the launcher inside the harness binding; only a dial-back
/// carrying it is adopted.
Future<int> runIntegrationSuite(
  IntegrationSuiteRun run, {
  String? harnessToken,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final harness = _IntegrationHarness(
    server: server,
    launcher: run.launcher,
    dialBackBound: run.dialBackBound,
    harnessToken: harnessToken ?? generateHarnessToken(),
  );
  try {
    return await harness.run(
      testPath: run.testPath,
      selection: run.selection,
      libraryTags: run.libraryTags,
      xmlOutput: run.xmlOutput,
      bazelTestTimeout: run.bazelTestTimeout,
    );
  } finally {
    await harness.dispose();
  }
}

class _IntegrationHarness {
  _IntegrationHarness({
    required HttpServer server,
    required PlatformLauncher launcher,
    required Duration dialBackBound,
    required String harnessToken,
  }) : _server = server,
       _launcher = launcher,
       _dialBackBound = dialBackBound,
       _harnessToken = harnessToken;

  final HttpServer _server;
  final PlatformLauncher _launcher;
  final Duration _dialBackBound;

  /// This run's token: only a dial-back carrying it is adopted.
  final String _harnessToken;

  Process? _process;
  WebSocket? _ws;
  bool _socketClosed = false;
  StreamSubscription<HttpRequest>? _httpSub;
  final Completer<WebSocket> _wsConnected = Completer<WebSocket>();

  final Map<int, void Function(Object?)> _inbound = {};
  final Map<int, Completer<void>> _pendingTests = {};
  int _nextId = 1;

  ({int outputId, int inputId}) _allocChannel() {
    final out = _nextId;
    final inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_socketClosed || _ws == null) return;
    _ws!.add(json.encode([outputId, data]));
  }

  Future<void> dispose() async {
    await teardownQuietly(() async => await _ws?.close());
    await teardownQuietly(() async => await _httpSub?.cancel());
    _process?.kill(ProcessSignal.sigkill);
    await teardownQuietly(() => _server.close(force: true));
    await _launcher.dispose();
  }

  /// Serves the harness HTTP endpoint: upgrades the bootstrap's dial-back
  /// to a WebSocket, and defers every other request to the launcher.
  void _serveHttp() {
    _httpSub = _server.listen((HttpRequest request) async {
      if (request.uri.path == integrationWebSocketPath &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        await _upgradeDialBack(request);
        return;
      }
      await _launcher.handleHttpRequest(request);
    });
  }

  /// Adopts the bootstrap's dial-back socket, keeping the first legitimate
  /// one and refusing any later one.
  ///
  /// Only a dial-back carrying this run's token is adopted. Any other
  /// upgrade on the integration path (no token, or a wrong one — e.g.
  /// another run's app on the same machine) is refused without adopting it,
  /// so the run still adopts the legitimate dial-back and reports only its
  /// results.
  Future<void> _upgradeDialBack(HttpRequest request) async {
    if (harnessTokenOf(request.uri) != _harnessToken) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!_wsConnected.isCompleted) {
        _wsConnected.complete(socket);
      } else {
        await socket.close();
      }
    } catch (e) {
      if (!_wsConnected.isCompleted) {
        _wsConnected.completeError(e);
      }
    }
  }

  /// Starts the target and tails its output into [processLogs].
  ///
  /// Returns the run's exit code when the target never started, or null
  /// once it is running.
  Future<int?> _launchTarget(List<String> processLogs) async {
    void recordProcessLine(String streamName, String line) {
      if (processLogs.length < 200) {
        processLogs.add('[$streamName] $line');
      }
    }

    try {
      _process = await _launcher.startTarget(
        HarnessBinding(port: _server.port, token: _harnessToken),
      );
    } catch (e) {
      stderr.writeln(
        'flutter_integration_test: failed to start ${_launcher.platformName} '
        'target: $e',
      );
      return 1;
    }

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stdout', line));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stderr', line));
    return null;
  }

  /// Waits for the target's dial-back and adopts the suite socket.
  ///
  /// Returns the run's exit code when the suite will not run because the
  /// target exited or stayed silent, or null once connected.
  Future<int?> _settleTargetDialBack(List<String> processLogs) async {
    switch (await _awaitDialBack()) {
      case _TargetExited(:final exitCode):
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target exited '
          'with code $exitCode before connecting to the test harness.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return exitCode == 0 ? 1 : exitCode;
      case _DialBackTimedOut():
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target did not '
          'connect to the harness within ${_dialBackBound.inSeconds}s; '
          'killing it.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return 1;
      case _BootstrapConnected(:final socket):
        _ws = socket;
        return null;
    }
  }

  /// Handles one message on the default channel: the suite tree plus
  /// print/error events. Resolves [suiteReady] once the in-app suite
  /// finishes registering tests (or surfaces a load failure).
  static void _onSuiteChannel(
    Object? data,
    _Results results,
    Completer<Map<String, dynamic>?> suiteReady,
  ) {
    final msg = (data as Map).cast<String, dynamic>();
    switch (msg['type']) {
      case 'success':
        if (!suiteReady.isCompleted) {
          suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
        }
      case 'loadException':
        results.recordError('load failure — ${msg['message']}');
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'error':
        final err = (msg['error'] as Map).cast<String, dynamic>();
        results.recordError(
          'uncaught error — ${err['message']}\n${err['stackChain']}',
        );
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'uncaughtError':
        results.recordError(
          'uncaught error — ${msg['message']}\n${msg['stack'] ?? ''}',
        );
        if (!suiteReady.isCompleted) suiteReady.complete(null);
      case 'print':
        stdout.writeln(msg['line']);
    }
  }

  /// Watches the suite socket: a close mid-suite surfaces as a failure on
  /// every outstanding test so nothing hangs waiting on a `complete` event
  /// that will never arrive.
  void _watchTargetSocket(Completer<Map<String, dynamic>?> suiteReady) {
    _ws!.listen(
      _onSocketMessage,
      onDone: () {
        _socketClosed = true;
        if (!suiteReady.isCompleted) suiteReady.complete(null);
        for (final c in _pendingTests.values) {
          if (!c.isCompleted) c.complete();
        }
        _pendingTests.clear();
      },
    );
  }

  /// Runs the registered suite under [selection], bounded by [ceiling].
  Future<void> _driveSelectedTests(
    Map<String, dynamic> root,
    TestSelection selection,
    _Results results,
    Duration ceiling,
  ) async {
    Map<String, dynamic>? selected;
    try {
      selected = selection.select(root);
    } on FormatException catch (e) {
      // An `include_tags` attribute selection that matches no test: a tag
      // name nobody carries is a typo, and passing an empty suite would
      // hide it.
      results.recordError(e.message);
    }
    if (selected != null) {
      await _runGroup(selected, results, ceiling);
    } else if (!results.hasFailure && selection.narrows) {
      stdout.writeln(
        'flutter_integration_test: no test case in this suite matches '
        'this run\'s --test_filter, tags or shard.',
      );
    }
  }

  /// Tells the suite to close, closes the socket, and waits out the target.
  Future<void> _shutdownTarget() async {
    _send(0, {'type': 'close'});
    await teardownQuietly(() async => await _ws?.close());

    _process?.kill(ProcessSignal.sigkill);
    await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
  }

  Future<int> run({
    required String testPath,
    required TestSelection selection,
    Set<String> libraryTags = const {},
    required String? xmlOutput,
    required String? bazelTestTimeout,
  }) async {
    _serveHttp();

    final processLogs = <String>[];
    final launchExit = await _launchTarget(processLogs);
    if (launchExit != null) return launchExit;

    final dialBackExit = await _settleTargetDialBack(processLogs);
    if (dialBackExit != null) return dialBackExit;

    final results = _Results();
    final suiteReady = Completer<Map<String, dynamic>?>();

    _inbound[0] = (data) => _onSuiteChannel(data, results, suiteReady);
    _watchTargetSocket(suiteReady);

    _send(0, _initialMessage(testPath, bazelTestTimeout, libraryTags));

    final ceiling = testCeiling(bazelTestTimeout);
    final root = await suiteReady.future.timeout(
      ceiling,
      onTimeout: () => null,
    );

    if (root != null) {
      await _driveSelectedTests(root, selection, results, ceiling);
    } else {
      results.recordError('suite did not load');
      for (final line in processLogs) {
        stderr.writeln('  $line');
      }
    }

    if (xmlOutput != null) {
      await File(
        xmlOutput,
      ).writeAsString(junitXml(results.cases, suiteName: testPath));
    }

    await _shutdownTarget();

    stdout.writeln(results.summary());
    return results.hasFailure ? 1 : 0;
  }

  Future<_DialBack> _awaitDialBack() async {
    final outcome = await Future.any<_DialBack?>([
      _wsConnected.future.then<_DialBack?>(_BootstrapConnected.new),
      _process!.exitCode.then<_DialBack?>(_TargetExited.new),
    ]).timeout(_dialBackBound, onTimeout: () => null);
    return outcome ?? const _DialBackTimedOut();
  }

  void _onSocketMessage(dynamic raw) {
    final decoded = json.decode(raw as String);
    if (decoded is Map && decoded['type'] == 'uncaughtError') {
      final handler = _inbound[0];
      if (handler != null) {
        handler(decoded);
      }
      for (final c in _pendingTests.values) {
        if (!c.isCompleted) c.complete();
      }
      return;
    }
    final list = decoded as List;
    final id = (list[0] as num).toInt();
    if (list.length == 1) {
      _inbound.remove(id);
      return;
    }
    final handler = _inbound[id];
    if (handler != null) {
      handler(list[1]);
    }
  }

  Future<void> _runGroup(
    Map<String, dynamic> group,
    _Results results,
    Duration ceiling,
  ) async {
    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(
        setUpAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }

    final entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, results, ceiling);
      } else {
        await _runTest(m, results, ceiling);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }
  }

  Future<void> _runTest(
    Map<String, dynamic> test,
    _Results results,
    Duration ceiling, {
    bool fixture = false,
  }) async {
    final testChannelId = (test['channel'] as num).toInt();
    final reportName = test['name'] as String? ?? '';

    if (fileUnstartedTest(
      test: test,
      reportName: reportName,
      fixture: fixture,
      socketClosed: _socketClosed,
      disconnectMessage:
          '${_launcher.platformName} target disconnected before this test ran',
      results: results,
    )) {
      return;
    }

    TestFailureSummary? failure;
    void noteFailure(TestFailureSummary summary) => failure ??= summary;
    final tracked = trackTestRun(
      channel: _allocChannel(),
      pending: _pendingTests,
      inbound: _inbound,
      noteFailure: noteFailure,
    );

    _send(testChannelId + 1, {'command': 'run', 'channel': tracked.outputId});

    await _awaitIntegrationTest(
      completer: tracked.completer,
      ceiling: ceiling,
      reportName: reportName,
      noteFailure: noteFailure,
    );
    _pendingTests.remove(tracked.inputId);
    _inbound.remove(tracked.inputId);

    failure = resolveTestFailure(
      failure: failure,
      socketClosed: _socketClosed,
      disconnectMessage:
          '${_launcher.platformName} target disconnected mid-test '
          '(or crashed)',
    );

    tracked.started.stop();
    if (failure != null) {
      results.recordFailure(
        reportName,
        failure!,
        tracked.started.elapsed,
        tracked.output.toString(),
      );
    } else if (!fixture) {
      results.recordSuccess(
        reportName,
        tracked.started.elapsed,
        tracked.output.toString(),
      );
    }
  }

  /// Waits out one test's [ceiling], killing the target when a wedged test
  /// never yields so the remaining tests bail out fast.
  Future<void> _awaitIntegrationTest({
    required Completer<void> completer,
    required Duration ceiling,
    required String reportName,
    required void Function(TestFailureSummary) noteFailure,
  }) async {
    await completer.future.timeout(
      ceiling,
      onTimeout: () {
        final msg =
            'test "$reportName" timed out after ${ceiling.inSeconds}s; '
            'killing ${_launcher.platformName} target.';
        stderr.writeln('flutter_integration_test: $msg');
        noteFailure(
          TestFailureSummary(
            message: msg,
            type: 'TimeoutException',
            stackChain: '',
          ),
        );
        _socketClosed = true;
        _process?.kill(ProcessSignal.sigkill);
      },
    );
  }

  Map<String, dynamic> _initialMessage(
    String testPath,
    String? bazelTestTimeout,
    Set<String> libraryTags,
  ) {
    return {
      'type': 'initial',
      'metadata': defaultSuiteMetadata(
        suiteTimeout(bazelTestTimeout),
        libraryTags,
      ),
      'platform': {
        'runtime': _launcher.suiteRuntime,
        'compiler': _launcher.suiteCompiler,
        'os': _launcher.suiteRuntime == 'chrome' ? 'none' : _osIdentifier(),
        'inGoogle': false,
      },
      'platformVariables': const <String>[],
      'collectTraces': true,
      'noRetry': true,
      'allowDuplicateTestNames': true,
      'foldTraceExcept': const <String>[],
      'foldTraceOnly': const <String>[],
      'path': testPath,
      'asciiGlyphs': !stdout.supportsAnsiEscapes,
      'ignoreTimeouts': false,
    };
  }

  static String _osIdentifier() {
    if (Platform.isMacOS) return 'mac-os';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'none';
  }
}

sealed class _DialBack {
  const _DialBack();
}

final class _BootstrapConnected extends _DialBack {
  const _BootstrapConnected(this.socket);
  final WebSocket socket;
}

final class _TargetExited extends _DialBack {
  const _TargetExited(this.exitCode);
  final int exitCode;
}

final class _DialBackTimedOut extends _DialBack {
  const _DialBackTimedOut();
}

/// Whether an integration run must be reported as a failure, given its counts.
///
/// A run that executes zero cases (nothing passed and nothing failed) is a
/// broken harness, not a pass, so it fails even without a suite error.
bool integrationRunFailed({
  required int passed,
  required int failed,
  required bool suiteError,
}) {
  return failed > 0 || suiteError || passed + failed == 0;
}

class _Results implements TestResultSink {
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  final List<TestCaseResult> cases = [];

  void recordSuccess(String name, Duration elapsed, String output) {
    passed++;
    cases.add(TestCaseResult.passed(name, elapsed, output));
    stdout.writeln('  PASS  $name');
  }

  void recordFailure(
    String name,
    TestFailureSummary summary,
    Duration elapsed,
    String output,
  ) {
    failed++;
    final formatted = summary.toString();
    cases.add(
      TestCaseResult.failed(
        name,
        elapsed,
        output,
        failureType: summary.type,
        message: summary.message,
        detail: formatted,
      ),
    );
    stdout.writeln('  FAIL  $name');
    stdout.writeln(_indent(formatted, '        '));
  }

  void recordSkipped(String name, String? reason) {
    skipped++;
    cases.add(TestCaseResult.skipped(name));
    stdout.writeln(
      reason == null ? '  SKIP  $name' : '  SKIP  $name (${reason.trim()})',
    );
  }

  void recordError(String message) {
    _suiteError = true;
    stdout.writeln('  FAIL  (suite error): $message');
    stderr.writeln('flutter_integration_test: $message');
  }

  bool get hasFailure => integrationRunFailed(
    passed: passed,
    failed: failed,
    suiteError: _suiteError,
  );

  String summary() => summarizeTestResults(
    passed: passed,
    failed: failed,
    skipped: skipped,
    suiteError: _suiteError,
  );
}

String _indent(String body, String prefix) {
  return body.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');
}
