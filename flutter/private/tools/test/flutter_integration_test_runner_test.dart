@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bazel_test_protocol.dart';
import '../flutter_integration_test_runner.dart' as runner;
import '../test_support.dart' as support;

class _FakePlatformLauncher implements runner.PlatformLauncher {
  _FakePlatformLauncher({required this.onStart});

  final Future<Process> Function(runner.HarnessBinding binding) onStart;
  bool disposed = false;

  @override
  String get platformName => 'web';

  @override
  String get suiteRuntime => 'chrome';

  @override
  String get suiteCompiler => 'dart2js';

  @override
  Future<Process> startTarget(runner.HarnessBinding binding) =>
      onStart(binding);

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('buildChromeArguments & buildChromeEnvironment', () {
    test('includes sandbox-safe flags and clears PATH so no host browser can run', () {
      final args = runner.buildChromeArguments(
        url: 'http://127.0.0.1:12345/',
        userDataDir: '/tmp/profile',
      );
      expect(args, contains('--headless'));
      expect(args, contains('--no-sandbox'));
      expect(args, contains('--disable-dev-shm-usage'));
      expect(args.last, 'http://127.0.0.1:12345/');

      final env = runner.buildChromeEnvironment(
        browserBinary: '/runfiles/flutter_chrome_headless_shell/browser/chrome-headless-shell',
        scratchDir: '/tmp/scratch',
        forwarding: const support.EnvForwarding(
          fontconfigFile:
              '/runfiles/flutter_chrome_headless_shell/fonts/fonts.conf',
        ),
      );
      expect(env['PATH'], isEmpty);
      expect(
        env['LD_LIBRARY_PATH'],
        '/runfiles/flutter_chrome_headless_shell/browser:'
        '/runfiles/flutter_chrome_headless_shell/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_chrome_headless_shell/sysroot/lib/x86_64-linux-gnu',
      );
      expect(
        env['FONTCONFIG_FILE'],
        '/runfiles/flutter_chrome_headless_shell/fonts/fonts.conf',
      );
    });
  });

  group('Linux Xvfb & app environment helpers', () {
    test('builds hermetic Xvfb and Linux app environments', () {
      final xvfbArgs = runner.buildXvfbArguments(
        xkbDir: '/runfiles/flutter_linux_headless_runtime/sysroot/usr/share/X11/xkb',
      );
      expect(xvfbArgs, containsAllInOrder(['-displayfd', '1']));
      expect(xvfbArgs, contains('-nolisten'));
      expect(
        xvfbArgs,
        contains(
          '/runfiles/flutter_linux_headless_runtime/sysroot/usr/share/X11/xkb',
        ),
      );

      final xvfbEnv = runner.buildXvfbEnvironment(
        sysrootDir: '/runfiles/flutter_linux_headless_runtime/sysroot',
        scratchDir: '/tmp/scratch',
      );
      expect(
        xvfbEnv['PATH'],
        '/runfiles/flutter_linux_headless_runtime/sysroot/usr/bin',
      );
      expect(
        xvfbEnv['LD_LIBRARY_PATH'],
        '/runfiles/flutter_linux_headless_runtime/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_linux_headless_runtime/sysroot/lib/x86_64-linux-gnu',
      );

      final appEnv = runner.buildLinuxAppEnvironment(
        bundleDir: '/runfiles/ws/app_linux',
        sysrootDir: '/runfiles/flutter_linux_headless_runtime/sysroot',
        scratchDir: '/tmp/scratch',
        display: ':0',
        harnessUrl: 'ws://127.0.0.1:43210/__flutter_integration_ws__',
        forwarding: const support.EnvForwarding(
          fontconfigFile: '/tmp/scratch/fonts.conf',
        ),
      );
      expect(appEnv['DISPLAY'], ':0');
      expect(appEnv['GDK_BACKEND'], 'x11');
      expect(appEnv['LIBGL_ALWAYS_SOFTWARE'], '1');
      expect(appEnv['GALLIUM_DRIVER'], 'llvmpipe');
      expect(
        appEnv['LIBGL_DRIVERS_PATH'],
        '/runfiles/flutter_linux_headless_runtime/sysroot/usr/lib/x86_64-linux-gnu/dri',
      );
      expect(
        appEnv['LD_LIBRARY_PATH'],
        '/runfiles/ws/app_linux/lib:'
        '/runfiles/flutter_linux_headless_runtime/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_linux_headless_runtime/sysroot/lib/x86_64-linux-gnu',
      );
      expect(
        appEnv['FLUTTER_INTEGRATION_TEST_HARNESS_URL'],
        'ws://127.0.0.1:43210/__flutter_integration_ws__',
      );
      expect(appEnv['FONTCONFIG_FILE'], '/tmp/scratch/fonts.conf');
    });

    test(
      'prepareHermeticXvfbBinary zeroes out XkbBinDirectory /usr/bin literal',
      () {
        final tmpDir = Directory.systemTemp.createTempSync('xvfb_patch_test_');
        try {
          final fakeXvfb = File('${tmpDir.path}/Xvfb');
          final payload = <int>[
            ...utf8.encode('HEADER'),
            ...utf8.encode('/usr/bin'),
            0,
            0,
            0,
            ...utf8.encode('/usr/share/X11/xkb'),
            0,
            ...utf8.encode('TRAILER'),
          ];
          fakeXvfb.writeAsBytesSync(payload);
          final patchedPath = runner.prepareHermeticXvfbBinary(
            sourceXvfbBinary: fakeXvfb.path,
            scratchDir: tmpDir.path,
          );
          final patchedBytes = File(patchedPath).readAsBytesSync();
          expect(patchedBytes.length, payload.length);
          // "/usr/bin" (8 bytes after "HEADER") is replaced by 8 zero bytes.
          expect(patchedBytes.sublist(6, 14), List<int>.filled(8, 0));
          // "/usr/share/X11/xkb" remains intact.
          expect(
            utf8.decode(patchedBytes.sublist(17, 17 + 18)),
            '/usr/share/X11/xkb',
          );
        } finally {
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );
  });

  group('serveWebBundleRequest', () {
    late Directory tmpDir;
    late HttpServer server;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('web_bundle_test_');
      Directory('${tmpDir.path}/assets').createSync(recursive: true);
      File('${tmpDir.path}/index.html').writeAsStringSync('<html>ok</html>');
      File('${tmpDir.path}/main.dart.wasm').writeAsBytesSync([0, 97, 115, 109]);
      File('${tmpDir.path}/assets/FontManifest.json').writeAsStringSync('[]');
      File('${tmpDir.path}/Roboto-Regular.ttf').writeAsBytesSync([1, 2, 3, 4]);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        runner.serveWebBundleRequest(
          req,
          webDir: tmpDir.path,
          robotoFontFile: '${tmpDir.path}/Roboto-Regular.ttf',
        );
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test(
      'serves index.html, wasm MIME type, and injects local Roboto fallback',
      () async {
        final client = HttpClient();
        try {
          final indexReq = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/'),
          );
          final indexRes = await indexReq.close();
          expect(indexRes.statusCode, HttpStatus.ok);
          expect(
            await utf8.decoder.bind(indexRes).join(),
            '<html>ok</html>',
          );

          final wasmReq = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/main.dart.wasm'),
          );
          final wasmRes = await wasmReq.close();
          expect(wasmRes.statusCode, HttpStatus.ok);
          expect(
            wasmRes.headers.value(HttpHeaders.contentTypeHeader),
            'application/wasm',
          );
          await wasmRes.drain<void>();

          final fontManifestReq = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${server.port}/assets/FontManifest.json',
            ),
          );
          final fontManifestRes = await fontManifestReq.close();
          final manifestJson = json.decode(
            await utf8.decoder.bind(fontManifestRes).join(),
          ) as List<dynamic>;
          expect(
            manifestJson.any((e) => e is Map && e['family'] == 'Roboto'),
            isTrue,
          );

          final robotoReq = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${server.port}/assets/fonts/Roboto-Regular.ttf',
            ),
          );
          final robotoRes = await robotoReq.close();
          expect(robotoRes.statusCode, HttpStatus.ok);
          expect(
            await robotoRes.fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
            [1, 2, 3, 4],
          );
        } finally {
          client.close(force: true);
        }
      },
    );

    test('answers 500 when FontManifest.json is corrupted', () async {
      File(
        '${tmpDir.path}/assets/FontManifest.json',
      ).writeAsStringSync('{not json');
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/assets/FontManifest.json',
          ),
        );
        final res = await req.close();
        expect(res.statusCode, HttpStatus.internalServerError);
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    });

    test('answers 500 when the bundle entry cannot be read', () async {
      final secret = File('${tmpDir.path}/secret.txt')
        ..writeAsStringSync('secret');
      Process.runSync('chmod', ['000', secret.path]);
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/secret.txt'),
        );
        final res = await req.close();
        expect(res.statusCode, HttpStatus.internalServerError);
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    });
  });

  group('runIntegrationSuite', () {
    test(
      'reports pass and writes JUnit XML when in-app suite succeeds',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('integration_xml_');
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (binding) async {
              clientWs = await WebSocket.connect(binding.url);
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [
                            {
                              'type': 'test',
                              'name': 'counter increments to 3',
                              'channel': 2,
                              'metadata': {'skip': false},
                            },
                          ],
                        },
                      },
                    ]),
                  );
                } else if (id == 3 && payload['command'] == 'run') {
                  final replyChannel = (payload['channel'] as num).toInt() + 1;
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {'type': 'complete'},
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            runner.IntegrationSuiteRun(
              launcher: launcher,
              testPath: 'integration_test/app_test.dart',
              selection: TestSelection(),
              xmlOutput: xmlFile.path,
              bazelTestTimeout: '60',
            ),
          );
          expect(code, 0);
          expect(launcher.disposed, isTrue);
          expect(
            xmlFile.readAsStringSync(),
            contains('counter increments to 3'),
          );
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );

    test(
      'fails with non-zero exit and records expected/actual on test failure',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('integration_fail_');
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (binding) async {
              clientWs = await WebSocket.connect(binding.url);
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [
                            {
                              'type': 'test',
                              'name': 'counter increments to 3',
                              'channel': 2,
                              'metadata': {'skip': false},
                            },
                          ],
                        },
                      },
                    ]),
                  );
                } else if (id == 3 && payload['command'] == 'run') {
                  final replyChannel = (payload['channel'] as num).toInt() + 1;
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {
                        'type': 'error',
                        'error': {
                          'type': 'TestFailure',
                          'message': "Expected: '3'\n  Actual: '2'",
                          'stackChain': 'test/app_test.dart 15:5',
                        },
                      },
                    ]),
                  );
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {'type': 'complete'},
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            runner.IntegrationSuiteRun(
              launcher: launcher,
              testPath: 'integration_test/app_test.dart',
              selection: TestSelection(),
              xmlOutput: xmlFile.path,
              bazelTestTimeout: '60',
            ),
          );
          expect(code, 1);
          final xml = xmlFile.readAsStringSync();
          expect(xml, contains('counter increments to 3'));
          expect(xml, contains("Expected: '3'"));
          expect(xml, contains("Actual: '2'"));
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );

    test(
      'fails with non-zero exit when the in-app suite executes zero cases',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('integration_zero_');
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (binding) async {
              clientWs = await WebSocket.connect(binding.url);
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [],
                        },
                      },
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            runner.IntegrationSuiteRun(
              launcher: launcher,
              testPath: 'integration_test/app_test.dart',
              selection: TestSelection(),
              xmlOutput: xmlFile.path,
              bazelTestTimeout: '60',
            ),
          );
          expect(code, 1);
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );

    test(
      'refuses a tokenless and a wrong-token dial-back, adopts the legitimate one',
      () async {
        const token = '0123456789abcdef0123456789abcdef';
        final tmpDir = Directory.systemTemp.createTempSync(
          'integration_token_',
        );
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (binding) async {
              final base =
                  'ws://127.0.0.1:${binding.port}${runner.integrationWebSocketPath}';
              // Another run's app (no token, then a wrong one) dials first:
              // both upgrades are refused and never adopted.
              await expectLater(
                WebSocket.connect(base),
                throwsA(isA<WebSocketException>()),
              );
              await expectLater(
                WebSocket.connect('$base?token=wrong-token'),
                throwsA(isA<WebSocketException>()),
              );
              clientWs = await WebSocket.connect(binding.url);
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [
                            {
                              'type': 'test',
                              'name': 'token run reports only its app',
                              'channel': 2,
                              'metadata': {'skip': false},
                            },
                          ],
                        },
                      },
                    ]),
                  );
                } else if (id == 3 && payload['command'] == 'run') {
                  final replyChannel = (payload['channel'] as num).toInt() + 1;
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {'type': 'complete'},
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            runner.IntegrationSuiteRun(
              launcher: launcher,
              testPath: 'integration_test/app_test.dart',
              selection: TestSelection(),
              xmlOutput: xmlFile.path,
              bazelTestTimeout: '60',
            ),
            harnessToken: token,
          );
          expect(code, 0);
          expect(
            xmlFile.readAsStringSync(),
            contains('token run reports only its app'),
          );
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );

    test('mints a random 128-bit token per run by default', () {
      final first = runner.generateHarnessToken();
      final second = runner.generateHarnessToken();
      expect(first, hasLength(32));
      expect(RegExp('^[0-9a-f]{32}\$').hasMatch(first), isTrue);
      expect(second, isNot(first));
      final binding = runner.HarnessBinding(port: 4242, token: first);
      expect(
        binding.url,
        'ws://127.0.0.1:4242'
        '${runner.integrationWebSocketPath}?token=$first',
      );
      expect(runner.harnessTokenOf(Uri.parse(binding.url)), first);
      expect(
        runner.harnessTokenOf(
          Uri.parse('ws://127.0.0.1:4242${runner.integrationWebSocketPath}'),
        ),
        isNull,
      );
    });
  });

  group('integrationRunFailed', () {
    test(
      'passes with executed cases, fails on failure, suite error, or zero executed cases',
      () {
        expect(
          runner.integrationRunFailed(
            passed: 3,
            failed: 0,
            suiteError: false,
          ),
          isFalse,
        );
        expect(
          runner.integrationRunFailed(
            passed: 2,
            failed: 1,
            suiteError: false,
          ),
          isTrue,
        );
        expect(
          runner.integrationRunFailed(
            passed: 3,
            failed: 0,
            suiteError: true,
          ),
          isTrue,
        );
        // Zero executed cases (including the all-skipped shape) is a broken
        // harness, not a pass.
        expect(
          runner.integrationRunFailed(
            passed: 0,
            failed: 0,
            suiteError: false,
          ),
          isTrue,
        );
      },
    );
  });

  group('env forwarding', () {
    test(
      'forwards declared env and TZ in chrome, linux and android environments',
      () {
        final chromeEnv = runner.buildChromeEnvironment(
          browserBinary: '/runfiles/flutter_chrome_headless_shell/browser/chrome-headless-shell',
          scratchDir: '/tmp/scratch',
          forwarding: const support.EnvForwarding(
            env: {'MY_VAR': 'declared'},
          ),
        );
        expect(chromeEnv['MY_VAR'], 'declared');
        expect(chromeEnv['TZ'], 'UTC');

        final appEnv = runner.buildLinuxAppEnvironment(
          bundleDir: '/runfiles/ws/app_linux',
          sysrootDir: '/runfiles/flutter_linux_headless_runtime/sysroot',
          scratchDir: '/tmp/scratch',
          display: ':0',
          harnessUrl: 'ws://127.0.0.1:43210/__flutter_integration_ws__',
          forwarding: const support.EnvForwarding(
            env: {'MY_VAR': 'declared'},
            tz: 'UTC',
          ),
        );
        expect(appEnv['MY_VAR'], 'declared');
        expect(appEnv['TZ'], 'UTC');

        final androidEnv = runner.buildAndroidRuntimeEnvironment(
          sdkRoot: '/runfiles/flutter_android_headless_runtime/sdk',
          sysrootDir: '/runfiles/flutter_android_headless_runtime/sysroot',
          scratchDir: '/tmp/android_scratch',
          avdHomeDir: '/tmp/android_scratch/.android/avd',
          adbServerPort: 15037,
          forwarding: const support.EnvForwarding(
            env: {'MY_VAR': 'declared'},
            tz: 'UTC',
          ),
        );
        expect(androidEnv['MY_VAR'], 'declared');
        expect(androidEnv['TZ'], 'UTC');
      },
    );
  });

  group('decodeDeclaredEnv', () {
    test('decodes a JSON object map and treats missing input as empty', () {
      expect(
        runner.decodeDeclaredEnv('{"MY_VAR": "declared", "N": 42}'),
        {'MY_VAR': 'declared', 'N': '42'},
      );
      expect(runner.decodeDeclaredEnv(null), isEmpty);
      expect(runner.decodeDeclaredEnv('  '), isEmpty);
    });

    test('treats malformed or non-object payloads as no declared env', () {
      expect(runner.decodeDeclaredEnv('{not json'), isEmpty);
      expect(runner.decodeDeclaredEnv('[1, 2]'), isEmpty);
    });
  });

  group('cleanupQuietly', () {
    test('runs the action and swallows a filesystem race', () {
      var ran = false;
      support.cleanupQuietly(() {
        ran = true;
        throw const FileSystemException('gone', '/tmp/.X9-lock');
      });
      expect(ran, isTrue);
    });

    test('lets a bug in the cleanup itself propagate', () {
      expect(
        () => support.cleanupQuietly(() => throw StateError('bug')),
        throwsStateError,
      );
    });

    test('deletes a real temp file', () {
      final tmpDir = Directory.systemTemp.createTempSync('cleanup_test_');
      try {
        final file = File('${tmpDir.path}/scratch')..writeAsStringSync('x');
        support.cleanupQuietly(file.deleteSync);
        expect(file.existsSync(), isFalse);
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });
  });

  group('teardownQuietly', () {
    test('swallows a peer-gone I/O race and an already-closed race', () async {
      await support.teardownQuietly(() async {
        throw const FileSystemException('connection reset');
      });
      await support.teardownQuietly(() async => throw StateError('closed'));
    });

    test('lets an unexpected teardown error propagate', () async {
      await expectLater(
        support.teardownQuietly(() async => throw ArgumentError('bug')),
        throwsArgumentError,
      );
    });
  });

  group('serveInternalError', () {
    test('swallows answering an already-closed response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handled = Completer<Object?>();
      server.listen((req) async {
        final response = req.response;
        response.statusCode = HttpStatus.ok;
        await response.close();
        try {
          await runner.serveInternalError(response);
          if (!handled.isCompleted) handled.complete(null);
        } catch (e) {
          if (!handled.isCompleted) handled.complete(e);
        }
      });
      try {
        final client = HttpClient();
        try {
          final req = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/'),
          );
          final res = await req.close();
          expect(res.statusCode, HttpStatus.ok);
          await res.drain<void>();
        } finally {
          client.close(force: true);
        }
        expect(
          await handled.future.timeout(const Duration(seconds: 10)),
          isNull,
        );
      } finally {
        await server.close(force: true);
      }
    });
  });
}
