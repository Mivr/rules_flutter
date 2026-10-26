/// Static web-bundle HTTP serving for `flutter_integration_test`.
///
/// Moved out of `flutter_integration_test_runner.dart` so the harness keeps
/// its shape while the web launcher serves the built bundle: the runner
/// re-exports this file, so `serveWebBundleRequest`, `serveInternalError`
/// and `contentTypeForPath` keep their `flutter_integration_test_runner`
/// paths.
library;

import 'dart:convert';
import 'dart:io';

/// Serves a single static file request from [webDir].
///
/// Injects a local `Roboto` fallback entry into `assets/FontManifest.json` when
/// [robotoFontFile] is provided and the app's manifest does not already define
/// `Roboto`, so CanvasKit and Skwasm never attempt to fetch Roboto from
/// `fonts.gstatic.com` inside the network-isolated Bazel test sandbox.
Future<void> serveWebBundleRequest(
  HttpRequest request, {
  required String webDir,
  String? robotoFontFile,
}) async {
  final response = request.response;
  try {
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final relPath = _bundleRelativePath(request);
    if (relPath == null) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    if (await _serveFontManifest(request, webDir, robotoFontFile)) return;

    var file = File('$webDir/$relPath');
    if (!file.existsSync() &&
        relPath == 'assets/fonts/Roboto-Regular.ttf' &&
        robotoFontFile != null) {
      file = File(robotoFontFile);
    }

    if (!file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    await _serveBundleFile(request, file, relPath);
  } on FileSystemException {
    // The bundle file vanished or became unreadable mid-serve.
    await serveInternalError(response);
  } on FormatException {
    // A corrupted FontManifest.json fails the request, not the server.
    await serveInternalError(response);
  } catch (e) {
    // Containment for anything unexpected: answer 500 and keep serving so
    // one bad request cannot wedge the whole integration run.
    stderr.writeln('flutter_integration_test: web bundle serve failed: $e');
    await serveInternalError(response);
  }
}

/// Answers [response] with a 500, swallowing the races of answering a
/// response the failed write already closed: the original failure is the one
/// that matters.
///
/// Public, like [contentTypeForPath], because the test reaches it directly.
Future<void> serveInternalError(HttpResponse response) async {
  try {
    response.statusCode = HttpStatus.internalServerError;
    await response.close();
  } on StateError {
    // The failed write already answered or closed the response.
  }
}

/// Normalizes the request path to a bundle-relative path, or null when it
/// tries to escape the bundle.
String? _bundleRelativePath(HttpRequest request) {
  var relPath = Uri.decodeComponent(request.uri.path);
  if (relPath == '/' || relPath.isEmpty) {
    return 'index.html';
  }
  if (relPath.startsWith('/')) {
    relPath = relPath.substring(1);
  }
  final segments = relPath.split('/');
  if (segments.contains('..') || segments.contains('.')) {
    return null;
  }
  return relPath;
}

/// Serves `assets/FontManifest.json` with the local Roboto fallback injected,
/// when the app needs one. Returns whether the request was answered.
Future<bool> _serveFontManifest(
  HttpRequest request,
  String webDir,
  String? robotoFontFile,
) async {
  final relPath = _bundleRelativePath(request);
  final response = request.response;
  if (relPath != 'assets/FontManifest.json' ||
      robotoFontFile == null ||
      !File(robotoFontFile).existsSync()) {
    return false;
  }
  final manifestFile = File('$webDir/assets/FontManifest.json');
  List<dynamic> families = <dynamic>[];
  if (manifestFile.existsSync()) {
    final decoded = json.decode(manifestFile.readAsStringSync());
    if (decoded is List) {
      families = List<dynamic>.from(decoded);
    }
  }
  final hasRoboto = families.any(
    (entry) => entry is Map && entry['family'] == 'Roboto',
  );
  if (!hasRoboto) {
    families.add(<String, Object>{
      'family': 'Roboto',
      'fonts': <Map<String, String>>[
        <String, String>{'asset': 'fonts/Roboto-Regular.ttf'},
      ],
    });
  }
  final body = utf8.encode(json.encode(families));
  response.statusCode = HttpStatus.ok;
  response.headers.set(
    HttpHeaders.contentTypeHeader,
    'application/json; charset=utf-8',
  );
  response.headers.contentLength = body.length;
  if (request.method != 'HEAD') {
    response.add(body);
  }
  await response.close();
  return true;
}

/// Serves one bundle file with its MIME type and no caching.
Future<void> _serveBundleFile(
  HttpRequest request,
  File file,
  String relPath,
) async {
  final response = request.response;
  final bytes = file.readAsBytesSync();
  response.statusCode = HttpStatus.ok;
  response.headers.set(
    HttpHeaders.contentTypeHeader,
    contentTypeForPath(relPath),
  );
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  response.headers.contentLength = bytes.length;
  if (request.method != 'HEAD') {
    response.add(bytes);
  }
  await response.close();
}

/// MIME type for a served bundle asset path.
///
/// Public, like [serveWebBundleRequest], because the test reaches it
/// directly.
String contentTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'application/javascript; charset=utf-8';
  }
  if (lower.endsWith('.wasm')) return 'application/wasm';
  if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
  if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.ttf')) return 'font/ttf';
  if (lower.endsWith('.otf')) return 'font/otf';
  if (lower.endsWith('.woff2')) return 'font/woff2';
  return 'application/octet-stream';
}
