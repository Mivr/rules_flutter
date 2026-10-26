/// Shared platform-launcher interface for `flutter_integration_test`.
///
/// Imported by the runner harness and by each platform launcher, so no
/// platform launcher ever imports the runner's main library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'test_support.dart';

/// WebSocket upgrade path the in-app bootstrap dials on the harness server.
///
/// The run's token travels as its `token` query parameter; a dial-back
/// without this run's token is refused and never adopted.
const String integrationWebSocketPath = '/__flutter_integration_ws__';

/// Query parameter carrying the run's token on the harness WebSocket URL.
const String integrationTokenQueryParam = 'token';

/// Everything a platform launcher needs to reach this run's harness: the
/// server's loopback port plus the run's random token.
///
/// The values travel together so launchers never take a bare port (whose URL
/// would miss the token) or a bare token (whose server they could not find).
class HarnessBinding {
  const HarnessBinding({required this.port, required this.token});

  /// The harness HTTP/WebSocket server's loopback port.
  final int port;

  /// The run's random token; only a dial-back carrying it is adopted.
  final String token;

  /// The WebSocket URL the target dials, carrying [token] for the harness.
  String get url =>
      'ws://127.0.0.1:$port$integrationWebSocketPath?$integrationTokenQueryParam=$token';
}

/// Generates a random per-run harness token: 128 bits from [Random.secure],
/// hex-encoded.
///
/// Public, like [decodeDeclaredEnv], because the runner and its tests reach
/// it directly: the runner mints one token per run, and the tests mint fixed
/// ones for deterministic dial-backs.
String generateHarnessToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The harness token carried by [uri]'s query, or null when absent.
///
/// Public, like [decodeDeclaredEnv], because the runner's dial-back check and
/// its tests reach it directly.
String? harnessTokenOf(Uri uri) =>
    uri.queryParameters[integrationTokenQueryParam];

/// Decodes the JSON-encoded declared environment forwarded by
/// `flutter_integration_test.bzl` (`FLUTTER_INTEGRATION_TEST_DECLARED_ENV`).
/// Decodes the JSON map stored in a `*_DECLARED_ENV` launcher variable.
///
/// Public, like [buildChromeArguments], because the test reaches it
/// directly. A missing variable or a malformed payload decodes to an empty
/// map: a build that received no usable declared environment falls back to
/// inherited-environment-only resolution, and a missing variable surfaces
/// later as a concrete lookup error instead.
Map<String, String> decodeDeclaredEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, String>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
  } on FormatException {
    // Corrupted declared environment behaves like none at all.
  }
  return const <String, String>{};
}

/// Resolves the forwarded ambient values for the `build*Environment`
/// helpers: the declared entries (empty when nothing was forwarded) and the
/// effective timezone, where a declared `TZ` entry wins.
///
/// One helper for all three builders, so the resolution they used to copy
/// stays identical everywhere.
({Map<String, String> declared, String timeZone, String? fontconfigFile})
resolveForwarding(EnvForwarding forwarding) {
  final declared = forwarding.env ?? const <String, String>{};
  return (
    declared: declared,
    timeZone: declared['TZ'] ?? forwarding.tz ?? 'UTC',
    fontconfigFile: forwarding.fontconfigFile,
  );
}

/// Abstraction over how a target platform starts the compiled app and serves
/// any platform-specific HTTP endpoints on the harness [HttpServer].
abstract class PlatformLauncher {
  /// Platform identifier (`'web'`, `'linux'`, `'android'`, `'ios'`).
  String get platformName;

  /// Runtime identifier for `package:test_api` `SuitePlatform`.
  String get suiteRuntime;

  /// Compiler identifier for `package:test_api` `SuitePlatform`.
  String get suiteCompiler;

  /// Handles a non-WebSocket HTTP request arriving on the harness server.
  Future<void> handleHttpRequest(HttpRequest request);

  /// Starts the target process against [binding]'s harness, dialling back
  /// over its token-carrying URL.
  Future<Process> startTarget(HarnessBinding binding);

  /// Cleans up any temporary directories created for the target process.
  Future<void> dispose();
}
