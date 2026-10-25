/// Web device: Chrome over CDP and DWDS.
///
/// [WebDevice] launches Chrome against the module server, discovers the CDP
/// port from the browser's stderr, and drives viewport and screenshots over
/// [CdpPageConnection]. [ChromeSession] owns one launched browser;
/// [applyViewportOverCdp] sizes its page and [pressKeyOverCdp] sends it a key
/// chord. [BrowserKeyPress] encodes one such chord.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'cdp_console.dart';
import 'compiler_config.dart';
import 'device.dart';
import 'host_tools.dart';
import 'key_press.dart';
import 'logging.dart';
import 'reload_strategy.dart';
import 'teardown.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'web_module_server.dart';
import 'web_options.dart';

final _logger = Logger('dev_tool.device');

/// How long [ChromeSession.launch] waits for the browser to come up.
///
/// One object for the three waits a launch tunes in tests: the debugging-port
/// announcement, the app page appearing, and the poll interval between looks.
typedef ChromeLaunchWaits = ({
  Duration portTimeout,
  Duration pageTimeout,
  Duration pollInterval,
});

/// The browser page [applyViewportOverCdp] drives, by CDP port and app URL.
///
/// One object for the two values every viewport call threads together: the
/// debugging port discovered from Chrome's stderr, and the localhost URL of
/// the launched tab.
typedef CdpPageTarget = ({int cdpPort, String appUrl});

/// Chrome launch flags matching Flutter's defaults for web dev mode.
///
/// These ensure predictable behavior during development:
/// - No extensions/popups that could interfere with the app
/// - Background timer throttling disabled for accurate async behavior
/// - No first-run/default-browser prompts
const chromeDebugFlags = [
  '--disable-extensions',
  '--disable-popup-blocking',
  '--bwsi',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-translate',
  '--disable-search-engine-choice-screen',
  '--disable-background-timer-throttling',
  // The rest cut startup work that varies with machine load and buys nothing
  // the run tests. The window, the sandbox and rendering stay exactly as the
  // user runs them: a headed browser that still paints the app.
  //
  // `--disable-dev-shm-usage`: /dev/shm is tiny on many CI and container
  // runners, and a renderer that cannot get shared memory stalls or crashes
  // around the time the browser would announce its debugging port. Backing it
  // with disk under the profile directory instead removes that shape.
  '--disable-dev-shm-usage',
  // `--disable-background-networking`: no component-update, variations-seed
  // or safebrowsing fetches at startup — the cold-start network variance on a
  // shared runner. The app itself is served from localhost, which this does
  // not touch.
  '--disable-background-networking',
  // `--password-store=basic`: no D-Bus secret-service negotiation for a
  // keyring that does not exist under xvfb/CI, which otherwise blocks startup
  // before falling back.
  '--password-store=basic',
];

/// One launched Chrome, owned end to end: the process, the throwaway profile
/// it runs against, its diagnostics, and the choice of which page target the
/// dev tool drives.
///
/// Both web launch paths (DDC module server and static/WASM) go through here,
/// so a flag, a profile cleanup or a timeout is fixed in one place rather than
/// in two copies where a change to one silently misses the other.
class ChromeSession {
  final Process process;

  /// The fresh, empty Chrome profile this launch runs against.
  ///
  /// A throwaway profile is what makes a run reproducible — no extensions, no
  /// restored tabs, no saved sign-ins. The cost is a real directory Chrome
  /// fills with caches, so on success it goes into the instance's
  /// [AppInstance.scratchDirs] and dies with the launch, and a failed launch
  /// deletes it before rethrowing. Left behind they are not inert: a stale
  /// profile belongs to a browser a `--user-data-dir` scan can still find, and
  /// an orphaned window can serve a screenshot that makes a broken run look
  /// fine.
  final Directory userDataDir;

  /// The CDP debugging port announced on Chrome's stderr.
  final int cdpPort;

  /// The localhost URL the launched tab serves the app from — the URL every
  /// page-target lookup matches against.
  final String appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the launch
  /// finished — what the run announces so a client can drive the page itself.
  ///
  /// A snapshot, not a handle anything here keeps using: every consumer in
  /// this tool re-resolves the target per use, because the listing is not a
  /// settled fact (see [resolveCdpPageTarget]).
  final String pageWebSocketDebuggerUrl;

  ChromeSession._({
    required this.process,
    required this.userDataDir,
    required this.cdpPort,
    required this.appUrl,
    required this.pageWebSocketDebuggerUrl,
  });

  /// The command line a launch on [url] with [options] runs.
  ///
  /// Pulled out so the argument order can be asserted without a browser: the
  /// user's own switches go last, immediately before the URL, which is where
  /// upstream puts them and therefore how a switch Chrome resolves by position
  /// behaves. The switches this tool owns are refused at flag-resolution time
  /// rather than being allowed to collide here.
  static List<String> launchArgs(
    String url,
    BrowserLaunchOptions options, {
    required String userDataDir,
  }) => [
    // 0 means "any free port"; either way the port is learned from the
    // browser's own announcement, never assumed.
    '--remote-debugging-port=${options.debugPort ?? 0}',
    ...chromeDebugFlags,
    '--user-data-dir=$userDataDir',
    if (options.headless) ...BrowserLaunchOptions.headlessFlags,
    ...options.scaleFlags,
    ...options.browserFlags,
    url,
  ];

  /// Launch Chrome on [url] and wait until it is observably up: debugging
  /// port announced *and* the tab navigated to the app. A failed launch
  /// leaves nothing behind — no browser, no profile directory.
  ///
  /// [portTimeout] is generous on purpose: a headed first run with a virgin
  /// profile does real initialization work before it announces anything, and
  /// on a loaded shared runner that sometimes takes far longer than the
  /// second-or-two a warm browser needs. A browser that refuses to start
  /// still fails fast — its output ending fails the wait before the timeout.
  static Future<ChromeSession> launch({
    required String url,
    required ProcessStarter startProcess,
    BrowserLaunchOptions options = const BrowserLaunchOptions(),
    String? chromePath,
    ChromeLaunchWaits waits = const (
      portTimeout: Duration(seconds: 60),
      pageTimeout: Duration(seconds: 15),
      pollInterval: Duration(milliseconds: 50),
    ),
  }) async {
    final exe = chromePath ?? findChrome();
    if (exe == null) {
      throw StateError(
        'Chrome not found. Install Chrome or use -d macos for desktop.',
      );
    }
    final userDataDir = await createTempDir('flutter_chrome_');
    // How long a healthy browser takes to announce is the number the port
    // timeout has to clear, so every launch reports it: the next slow start
    // then arrives with measurements instead of a bare "within Ns".
    final launchClock = Stopwatch()..start();
    final Process chrome;
    try {
      chrome = await startProcess(
        exe,
        launchArgs(url, options, userDataDir: userDataDir.path),
      );
    } catch (_) {
      await deleteTempDir(userDataDir);
      rethrow;
    }

    // Chrome's own process output — browser diagnostics, not app output.
    // Kept drained for the browser's lifetime so its pipes can never fill
    // (an unread stderr on a browser this chatty is the likeliest place for
    // a full-pipe stall), and read once for the CDP port announcement.
    // Deliberately *not* surfaced as app output: the app's console lives
    // inside the page, and Chrome's own chatter would bury it.
    final diagnostics = AppLogStream(capacity: 200);
    diagnostics.closeWhen([pumpProcessLines(chrome, diagnostics).done]);

    try {
      final cdpPort = await _discoverCdpPort(
        diagnostics,
        timeout: waits.portTimeout,
        requestedPort: options.debugPort,
      );
      _logger.info({
        'message': 'chrome_port_announced',
        'text':
            'Chrome announced its DevTools debugging port after '
            '${_secondsText(launchClock.elapsed)}.',
        'elapsed_ms': launchClock.elapsedMilliseconds,
        'port': cdpPort,
      });
      // The announcement is the readiness signal, not merely the number, so
      // it is awaited even when the port was dictated. A browser that takes a
      // different one than it was given is a state nothing here can drive:
      // every CDP consumer would dial the port that was asked for.
      if (options.debugPort != null && cdpPort != options.debugPort) {
        chrome.kill();
        await chrome.exitCode;
        await deleteTempDir(userDataDir);
        throw StateError(
          'Chrome was asked for --web-browser-debug-port '
          '${options.debugPort} and announced $cdpPort instead.',
        );
      }
      // The same wait [resolveAppPage] does, done before the session exists
      // so the page it found can be part of it.
      final page = await resolveCdpPageTarget(
        cdpPort,
        appUrl: url,
        timeout: waits.pageTimeout,
        pollInterval: waits.pollInterval,
      );
      final session = ChromeSession._(
        process: chrome,
        userDataDir: userDataDir,
        cdpPort: cdpPort,
        appUrl: url,
        pageWebSocketDebuggerUrl: page,
      );
      final viewport = options.viewport;
      if (viewport != null) await session.applyViewport(viewport);
      return session;
    } catch (_) {
      // A launch with no debugging port or no app page produced nothing
      // usable; don't leave the browser and its throwaway profile running
      // behind the error.
      chrome.kill();
      await chrome.exitCode;
      await deleteTempDir(userDataDir);
      rethrow;
    }
  }

  /// Wait until the launched tab is serving [appUrl] and return its CDP
  /// WebSocket debugger URL.
  ///
  /// Right after launch the tab is still an `about:blank` that has not
  /// navigated, and `/json` can list nothing at all, so this waits rather than
  /// failing on the first look — see [pickCdpPageTarget] for why nothing less
  /// than the app's own page will do. [launch] awaits it before declaring the
  /// browser up: a session whose app page never appeared is a failed launch,
  /// not a running one that every CDP consumer — screenshots, page reloads,
  /// the console — then mis-drives.
  ///
  /// The waiting itself is [resolveCdpPageTarget]'s, not a second copy of it:
  /// the states this rides out at launch are the same ones those consumers hit
  /// mid-session.
  Future<String> resolveAppPage({
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) => resolveCdpPageTarget(
    cdpPort,
    appUrl: appUrl,
    timeout: timeout,
    pollInterval: pollInterval,
  );

  /// Lay the app out at [viewport], and prove that it did.
  ///
  /// `Emulation.setDeviceMetricsOverride` is sent once, right after the page
  /// is first resolved, on a connection that then stays open in
  /// [viewportHold] for as long as the browser runs: Chrome 154 scopes the
  /// override to the CDP session that set it and clears it the moment that
  /// socket closes. It does survive the `Page.reload` a web hot restart
  /// performs, so nothing has to be re-applied while the connection lives.
  ///
  /// **Read the result back on a *fresh* connection.** While the setting
  /// client is still attached the page reports metrics it has not settled at,
  /// so a verification folded into that socket to save a round trip would fail
  /// against a browser that is behaving correctly.
  ///
  /// Verified rather than assumed because the failure it guards is invisible:
  /// an override that did not take leaves every later screenshot and layout
  /// measurement quietly describing the wrong viewport.
  Future<void> applyViewport(WebViewport viewport) async {
    viewportHold = await applyViewportOverCdp(
      page: (cdpPort: cdpPort, appUrl: appUrl),
      viewport: viewport,
      asked: '--web-viewport',
      hold: viewportHold,
    );
  }

  /// The CDP connection that set this launch's viewport, kept open for as long
  /// as the browser runs, or null when no viewport was asked for. The caller
  /// that takes over the session owns closing it. See [applyViewportOverCdp]
  /// for why it cannot be closed early.
  CdpPageConnection? viewportHold;
}

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// The app page's CDP WebSocket URL as listed at launch. See
  /// [ChromeSession.pageWebSocketDebuggerUrl].
  String? _pageWebSocketDebuggerUrl;

  /// The CDP connection holding this run's viewport override open — see
  /// [applyViewportOverCdp]. Null until a viewport is set, and again after
  /// [stop], which closes it.
  CdpPageConnection? _viewportHold;

  /// Takes over [hold], watching it so that losing the viewport is loud: the
  /// override goes with the connection, and nothing else would say so.
  void _holdViewport(CdpPageConnection? hold) {
    // The same connection again, as `app.setViewport` reuses it: already
    // watched.
    if (identical(_viewportHold, hold)) return;
    _viewportHold = hold;
    if (hold == null) return;
    hold.done.then((_) {
      if (_viewportHold != hold) return;
      _viewportHold = null;
      _logger.severe({
        'message': 'web_viewport_lost',
        'text':
            'The browser closed the CDP connection that held the viewport, '
            'and the viewport went with it: screenshots from here on show the '
            'browser window\'s own size. Call app.setViewport to set it '
            'again, or relaunch.',
      });
    });
  }

  /// Module server for DDC dev mode. Set by RunCommand before launch.
  WebModuleServer? _moduleServer;

  /// What this run's web flags resolved to. Set by [RunPlan.resolve], which is
  /// where the flags are read — the device itself is built from a `-d` string,
  /// before there are any.
  ///
  /// The DDC path reads only the browser half here: its server is the module
  /// server, which the assembler builds from `server` of this same value.
  /// Both paths are therefore configured by one object, which is what stops a
  /// web flag from meaning something on one and nothing on the other.
  WebOptions? webOptions;

  /// Forwards the page's console when there is no DWDS to do it (WASM and
  /// production JS builds). Null in DDC dev mode, where `run_command` wires
  /// the DWDS VM service instead — see the one-source-per-platform note in the
  /// library docs.
  CdpConsoleClient? _consoleClient;

  WebDevice({ProcessStarter? startProcess})
    : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Chrome';

  @override
  Future<List<HostTool>> requiredHostTools() async => [chromeTool()];

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the browser came
  /// up, if launched. Announced for clients that drive Chrome themselves;
  /// nothing in this tool dials it, since every consumer here re-resolves the
  /// page per use.
  String? get pageWebSocketDebuggerUrl => _pageWebSocketDebuggerUrl;

  @override
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, [
    CompilerConfigInputs? inputs,
  ]) {
    // Web builds its own filesystem roots (synthetic entrypoint dir + workspace)
    // in run_command; the native roots/scheme args are not used here. The
    // registrant URI is ignored too — the web synthetic main calls
    // registerPlugins() directly and re-runs on page-reload restart.
    final webToolchain = inputs?.webToolchain;
    if (webToolchain == null) return null;
    return WebCompilerConfig(
      webToolchain: webToolchain,
      dartDefines: inputs?.dartDefines ?? const [],
      enableExperiments: inputs?.enableExperiments ?? const [],
    );
  }

  /// Refused, rather than answered.
  ///
  /// [Device.createReloadStrategy] is asked by `NativePipelineAssembler` and
  /// by nothing else, and that assembler is only built for a native run — so
  /// this is unreachable. What it must not do is *inherit*: the base answer is
  /// [VmServiceReloadStrategy], and a browser run given the native strategy
  /// would send every reload looking for a VM service the browser does not
  /// have and report its absence as the fault. That is what
  /// `ReloadPipeline.strategy` is non-defaulting to prevent.
  ///
  /// A browser's strategy is built by the assembler that owns the run's shape:
  /// `WebPipelineAssembler` (DWDS, from the module server it just started) or
  /// `WasmPipelineAssembler` (CDP, from the port Chrome announced). Neither is
  /// derivable from a device that has not been told which run it is in.
  @override
  ReloadStrategy createReloadStrategy() {
    throw StateError(
      'A Chrome run does not get its reload strategy from the device: '
      'WebPipelineAssembler builds the DWDS one from the module server, and '
      'WasmPipelineAssembler the CDP one from the browser\'s debugging '
      'port. Reaching here means a native assembler was pointed at a web '
      'device.',
    );
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    if (_moduleServer != null) {
      return _launchWithModuleServer(onLog);
    }
    return _launchStaticServer(appPath, onLog);
  }

  /// What this run's web flags resolved to, or a failure naming what was
  /// never wired.
  ///
  /// Not a default: a `WebDevice` launching without them would run the browser
  /// with none of the flags the user typed, which is the exact silence these
  /// options exist to prevent.
  WebOptions get _webOptions {
    final options = webOptions;
    if (options == null) {
      throw StateError(
        'This WebDevice was never told how to serve or how to launch a '
        'browser (RunPlan.resolve sets webOptions). Without it none of the '
        'web flags would apply to this run.',
      );
    }
    return options;
  }

  /// Launch using DDC module server (dev mode with hot restart).
  Future<AppInstance> _launchWithModuleServer(AppLogListener? onLog) async {
    final options = _webOptions;
    // `--web-launch-url` if given, the server's own URL otherwise — and
    // checked against the server that actually bound, which is the first
    // moment its port is known.
    final url = options.launchUrlFor(_moduleServer!.uri!).toString();
    _appUrl = url;

    final session = await ChromeSession.launch(
      url: url,
      startProcess: _startProcess,
      options: options.browser,
    );
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;

    // No CDP console client here: DDC mode gets the app's output from the DWDS
    // VM service, and running both would print every line twice.
    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      // The app's own output has its own source — DWDS, wired by the caller —
      // so it does not close with the browser process.
      logs: newAppLogs(onLog),
      scratchDirs: [session.userDataDir],
    );
  }

  /// Launch using static file server (production/WASM mode).
  Future<AppInstance> _launchStaticServer(
    String appPath,
    AppLogListener? onLog,
  ) async {
    final options = _webOptions;
    final staticServer = StaticWebServer(
      rootPath: appPath,
      options: options.server,
    );
    final serverBase = await staticServer.start();

    final String url;
    final ChromeSession session;
    try {
      url = _appUrl = options.launchUrlFor(serverBase).toString();
      session = await ChromeSession.launch(
        url: url,
        startProcess: _startProcess,
        options: options.browser,
      );
    } catch (_) {
      // The session cleans up after its own failures; this path additionally
      // owns the static file server.
      await staticServer.stop();
      rethrow;
    }
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;
    final logs = newAppLogs(onLog);

    // No DWDS on this path (WASM / production JS), so CDP is the only source
    // of the app's console output.
    _consoleClient = CdpConsoleClient(
      cdpPort: _cdpPort!,
      appUrl: _appUrl,
      logs: logs,
      // Its own default sink writes straight to stderr, which a `--machine`
      // client reading JSON lines cannot parse. The give-up warning already
      // says what is lost; this only gives it a level and an envelope.
      warn: (message) => _logger.warning({
        'message': 'browser_console_forwarding_stopped',
        'text': message,
      }),
    );
    try {
      await _consoleClient!.start();
    } catch (e) {
      // Console forwarding is not worth failing a launch over, but a silent
      // loss of all app output would be worse than the noise.
      _logger.warning({
        'message': 'browser_console_attach_failed',
        'text':
            'Could not attach to the browser console ($e). The app runs, '
            'but nothing it prints will appear in this run.',
        'error': '$e',
      });
      _consoleClient = null;
    }

    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      server: staticServer.server,
      logs: logs,
      scratchDirs: [session.userDataDir],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Unbounded on purpose. A client-side `WebSocket.close()` returns the
    // *outbound* sink's future and never waits for the peer's answering close
    // frame, so neither a peer that never answers nor one wedged so hard it
    // reads nothing can hold it. The one shape that does hang is a wedged peer
    // with a full send buffer, and this client writes a single small
    // `Runtime.enable` per connection, so it cannot build that backlog. The
    // SDK's own 5s close timer does NOT rescue that shape, so this decision
    // expires if the client ever grows chatty outbound traffic.
    await _consoleClient?.close();
    _consoleClient = null;
    // Taken off first, so closing it is not reported as the viewport lost.
    final viewportHold = _viewportHold;
    _viewportHold = null;
    await viewportHold?.close();
    final moduleServer = _moduleServer;
    if (moduleServer != null) {
      // dwds is third-party and its `stop()` reaches peer-dependent awaits —
      // `DebugService.close()` waits on a DDS shutdown, `DwdsVmClient.close()`
      // on a VM-service client dispose. This sits *before* the kill, so an
      // unbounded wait here means the browser is never even asked to exit.
      await boundedTeardownStep(
        'the web module server to shut down',
        moduleServer.stop(),
        teardownBound,
      );
    }
    // Unbounded: `HttpServer.close(force: false)` returns promptly against an
    // idle keep-alive connection, a held streaming response and an open
    // WebSocket upgrade alike.
    await instance.server?.close();
    // Before the profile goes: a browser that is still shutting down is still
    // writing its caches, and deleting the tree under it leaves a half-removed
    // directory and an error naming a file nobody asked about.
    await stopProcess('browser', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }

  /// Press [chord] in the app's page — `app.pressKey`'s browser route. See
  /// [pressKeyOverCdp].
  Future<BrowserKeyPress> pressKey(
    KeyChord chord, {
    required bool macCommands,
  }) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to press keys in yet: its DevTools '
        'port has not been discovered, so the page cannot be reached.',
      );
    }
    return pressKeyOverCdp(
      cdpPort: port,
      appUrl: url,
      chord: chord,
      macCommands: macCommands,
    );
  }

  /// Re-lay the running app out at [viewport] — what `app.setViewport` does.
  ///
  /// The same override `--web-viewport` applies at launch, sent again to the
  /// page that is already up, so a caller sweeping form factors does not have
  /// to relaunch between them.
  Future<void> setViewport(WebViewport viewport) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to resize yet: its CDP port has not been '
        'discovered, so the page cannot be reached.',
      );
    }
    _holdViewport(
      await applyViewportOverCdp(
        page: (cdpPort: port, appUrl: url),
        viewport: viewport,
        asked: 'app.setViewport',
        hold: _viewportHold,
      ),
    );
  }
}

/// Chrome's announcement of its debugging port, printed to stderr when
/// launched with `--remote-debugging-port=0`:
/// `DevTools listening on ws://127.0.0.1:PORT/devtools/browser/...`
final cdpPortPattern = RegExp(r'DevTools listening on ws://\S+?:(\d+)/');

/// Discover the CDP debugging port from Chrome's own diagnostic output.
///
/// Reads [browserDiagnostics] rather than subscribing to Chrome's pipes
/// directly, so finding the port doesn't stop those pipes being drained — an
/// unread stderr on a browser as chatty as Chrome is the likeliest place for a
/// full-pipe stall.
///
/// Throws a [StateError] rather than returning null when the port never
/// arrives. It is not optional equipment: DDC dev mode dials CDP to give DWDS
/// its Chrome connection, and every web path uses it for screenshots and page
/// reloads, so accepting null here would buy a run with none of that and no
/// message. Upstream tool-exits in the same situation (`chrome.dart`'s "Unable to
/// connect to Chrome debug port"). The two causes are reported separately
/// because they call for different fixes.
///
/// The timeout error quotes how long the wait ran and what the browser
/// printed: a browser still working through a slow first run is otherwise
/// indistinguishable from one that was never going to announce.
Future<int> _discoverCdpPort(
  AppLogStream browserDiagnostics, {
  Duration timeout = const Duration(seconds: 60),
  int? requestedPort,
}) async {
  // Measured, not assumed: the timeout error below quotes how long the wait
  // actually ran, so a failure says whether the browser was moments or an
  // eternity from announcing.
  final waited = Stopwatch()..start();
  final completer = Completer<int>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError(
          'Chrome did not announce a DevTools debugging port within '
          '${timeout.inSeconds}s of launch '
          '(waited ${_secondsText(waited.elapsed)}). '
          'Without it there is no debugging '
          'connection: no DWDS VM service, no hot restart, no screenshots.'
          // A dictated port is the one thing about this launch that can be
          // wrong before Chrome even starts, and Chrome says nothing when it
          // cannot take one.
          '${requestedPort == null ? '' : ' --web-browser-debug-port '
                    '$requestedPort may already be in use.'}'
          // Reaching the timeout means the browser's output never ended: had
          // it exited, the stream closing would have failed this wait first.
          // So the browser was still starting up, and what it printed is
          // where the reason lives.
          ' Its output had not ended; the browser was still starting up. '
          '${_browserLastWords(browserDiagnostics, ended: false)}',
        ),
      );
    }
  });

  final sub = browserDiagnostics.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = cdpPortPattern.firstMatch(line.text);
      if (match != null) completer.complete(int.parse(match.group(1)!));
    },
    onDone: () {
      // Chrome's output is this stream's only source, so it ending means the
      // browser is gone — a different failure from a browser that is up and
      // silent, and worth saying so.
      //
      // With Chrome's own last words attached, because on its own that
      // sentence names a symptom and no cause. The causes that actually occur
      // are all things Chrome says on the way out — a sandbox it will not run
      // under, a profile directory it cannot write, a missing shared library —
      // and on a CI runner the alternative to quoting them here is reproducing
      // the failure somewhere the log can be reached.
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Chrome exited before announcing a DevTools debugging port. '
            '${_browserLastWords(browserDiagnostics)}',
          ),
        );
      }
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// The tail of what the browser printed, phrased for the end of an error.
///
/// Read back off [AppLogStream] rather than accumulated by the listener above:
/// the buffer survives the stream closing, so the lines are still there at the
/// moment the launch is known to have failed, and there is no second copy of
/// the same output to keep in step with the first.
///
/// Says so explicitly when there is nothing to quote. "Chrome exited and
/// printed nothing" is a real and different diagnosis from "Chrome exited" —
/// it rules out every cause that announces itself, and says the search belongs
/// somewhere other than the browser's output. An empty tail rendered as
/// nothing at all would instead read as if the quoting had been forgotten.
///
/// [ended] selects the phrasing: the browser that exited printed "on the way
/// out", while one still starting up when the wait ran out has printed
/// "so far".
String _browserLastWords(
  AppLogStream browserDiagnostics, {
  int lines = 20,
  bool ended = true,
}) {
  final tail = browserDiagnostics.read(-lines).lines;
  if (tail.isEmpty) {
    return ended
        ? 'It printed nothing at all on the way out, so its own output does '
              'not hold the reason.'
        : 'It had printed nothing at all so far, so its own output does not '
              'yet hold a reason.';
  }
  return 'It last said:\n${tail.map((l) => '  ${l.text}').join('\n')}';
}

/// Seconds with one decimal, for launch timings in errors and logs.
String _secondsText(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

/// Lay the app's page out at [viewport], and prove that it did.
///
/// Shared by the two things that set a viewport: `--web-viewport` at launch
/// ([ChromeSession.applyViewport]) and the `app.setViewport` command
/// mid-session ([WebDevice.setViewport]). [asked] names whichever one it was,
/// so the failure says which input was not honoured.
///
/// `Emulation.setDeviceMetricsOverride` is sent on one connection and **that
/// connection is returned, still open, for the caller to keep for as long as
/// the viewport should hold.** Chrome 154 ties the override to the CDP session
/// that set it: when the socket closes the page goes back to the window's own
/// size, and every screenshot and layout read after that describes a viewport
/// nobody asked for. (Earlier Chromes kept it after the socket closed, which is
/// what this used to rely on.) The override does survive the `Page.reload` a
/// web hot restart performs.
///
/// Pass the connection back as [hold] to change the viewport on it, so a
/// sweep across form factors replaces the override rather than stacking
/// sessions; a [hold] that has closed is replaced by a fresh one. On failure a
/// connection this call opened is closed again, and the caller's own is left
/// as it was.
///
/// **The read-back needs its own connection.** While the setting client is
/// still attached the page reports metrics it has not settled at, so folding
/// the check into that socket to save a round trip would fail against a
/// browser behaving correctly — the read below deliberately opens its own,
/// and it sees the override because the held one is still open. It is
/// repeated until the page reports the size or [settleTimeout] runs out.
///
/// Verified rather than assumed because the failure it guards is invisible: an
/// override that did not take leaves every later screenshot and layout
/// measurement quietly describing the wrong viewport.
Future<CdpPageConnection> applyViewportOverCdp({
  required CdpPageTarget page,
  required WebViewport viewport,
  required String asked,
  CdpPageConnection? hold,
  Duration settleTimeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
}) async {
  final reuse = hold != null && !hold.isClosed;
  final connection = reuse
      ? hold
      : await CdpPageConnection.open(page.cdpPort, appUrl: page.appUrl);
  try {
    await connection.send('Emulation.setDeviceMetricsOverride', {
      'width': viewport.width,
      'height': viewport.height,
      // 0 means "keep the browser's own ratio" — see WebViewport.
      'deviceScaleFactor': viewport.deviceScaleFactor ?? 0,
      // Not a mobile emulation: Chrome lays a mobile page out at its 980px
      // default until the page declares a viewport, and a Flutter app does
      // that only once its engine has started — after the launch that
      // verifies this. Without it the layout viewport is the size asked for
      // from the first read, whatever the page has or has not run.
      'mobile': false,
    });
    // Polled, because a read straight after the override can still describe
    // the page as it was laid out a moment ago.
    final stopwatch = Stopwatch()..start();
    Object? width;
    Object? height;
    Object? ratio;
    while (true) {
      final got = await _sendCdpToPage(
        page.cdpPort,
        page.appUrl,
        'Runtime.evaluate',
        {
          'expression':
              '({w: window.innerWidth, h: window.innerHeight, '
              'r: window.devicePixelRatio})',
          'returnByValue': true,
        },
      );
      final value = got['result']?['result']?['value'];
      width = value is Map ? value['w'] : null;
      height = value is Map ? value['h'] : null;
      ratio = value is Map ? value['r'] : '?';
      if (width == viewport.width && height == viewport.height) break;
      if (stopwatch.elapsed >= settleTimeout) {
        throw StateError(
          'The browser did not take the viewport $asked asked for. Wanted '
          '${viewport.width}x${viewport.height}, and after '
          '${settleTimeout.inSeconds}s the page still reports '
          '${width}x$height (devicePixelRatio $ratio).\n'
          'Every screenshot and every layout measurement taken from here on '
          'would describe a viewport nobody asked for.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  } catch (_) {
    if (!reuse) await connection.close();
    rethrow;
  }
  return connection;
}

/// Send one CDP command to the page serving [appUrl] and return its reply.
///
/// A connection per command, and the page target re-resolved each time rather
/// than cached, because the target listing is not a settled fact — see
/// [pickCdpPageTarget].
Future<Map<String, dynamic>> _sendCdpToPage(
  int cdpPort,
  String appUrl,
  String method,
  Map<String, dynamic> params,
) async {
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    return await page.send(method, params);
  } finally {
    await page.close();
  }
}

/// One connection to the app page's CDP endpoint, for commands that have to
/// arrive in order on the same session — a key chord's downs and ups.
///
/// The target is resolved when the connection opens and not after, so hold
/// one only for a single operation: see [pickCdpPageTarget].
class CdpPageConnection {
  final WebSocket _ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _nextId = 1;
  Object? _closedBy;
  final _done = Completer<void>();

  /// Whether the socket has closed, from either end.
  bool get isClosed => _closedBy != null;

  /// Completes when the socket closes, from either end — what a holder of a
  /// long-lived connection waits on to learn it lost the session.
  Future<void> get done => _done.future;

  CdpPageConnection._(this._ws) {
    _ws.listen(
      (data) {
        final msg = json.decode(data as String) as Map<String, dynamic>;
        final id = msg['id'];
        if (id is int) _pending.remove(id)?.complete(msg);
      },
      // A page that navigates away or a browser that exits closes the socket;
      // every command still waiting would otherwise spend its whole timeout
      // to report the same thing.
      onDone: () => _fail(StateError('the page\'s CDP connection closed')),
      onError: _fail,
    );
  }

  void _fail(Object error) {
    _closedBy ??= error;
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
  }

  /// Connect to the page serving [appUrl] on [cdpPort].
  static Future<CdpPageConnection> open(
    int cdpPort, {
    required String appUrl,
  }) async => CdpPageConnection._(
    await WebSocket.connect(
      await resolveCdpPageTarget(cdpPort, appUrl: appUrl),
    ),
  );

  /// Send [method] and return the whole reply; a CDP error is a [StateError]
  /// naming the method.
  ///
  /// Bounded: a browser that stops answering would otherwise hold the
  /// command pool's only slot for the rest of the run.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closedBy case final error?) throw error;
    final id = _nextId++;
    final reply = _pending[id] = Completer<Map<String, dynamic>>();
    _ws.add(json.encode({'id': id, 'method': method, 'params': params}));
    final response = await reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw StateError(
          'CDP $method did not answer within ${timeout.inSeconds}s',
        );
      },
    );
    final error = response['error'];
    if (error != null) throw StateError('CDP $method failed: $error');
    return response;
  }

  Future<void> close() {
    _fail(StateError('the page\'s CDP connection was closed here'));
    return _ws.close();
  }
}

/// What pressing a key chord in the browser did: the events it sent, and the
/// two facts about the page that decide what they could reach.
class BrowserKeyPress {
  /// The `Input.dispatchKeyEvent` parameters, in the order sent.
  final List<Map<String, Object>> sent;

  /// What had the browser's focus when the keys went in, as the path of tag
  /// names through any shadow roots, e.g. `flutter-view > input`.
  final String focus;

  /// Whether that element takes typed text: an `<input>`, a `<textarea>` or
  /// an editable element. Flutter's web engine gives its focused text field
  /// a real one, so this is what says typing will land.
  final bool focusIsEditable;

  /// Whether the page was visible. A hidden page draws no frames, so what the
  /// keys changed does not repaint until it is shown.
  final bool pageVisible;

  const BrowserKeyPress({
    required this.sent,
    required this.focus,
    required this.focusIsEditable,
    required this.pageVisible,
  });
}

/// Page state [pressKeyOverCdp] reads before dispatching: the focused element
/// through shadow roots, whether it is editable, and the page's visibility.
const _focusProbe = '''
(() => {
  let e = document.activeElement;
  const path = [];
  let editable = false;
  while (e) {
    path.push(e.tagName.toLowerCase());
    editable = e.tagName === 'INPUT' || e.tagName === 'TEXTAREA' ||
        e.isContentEditable;
    e = e.shadowRoot ? e.shadowRoot.activeElement : null;
  }
  return {
    focus: path.join(' > ') || 'nothing',
    editable,
    visible: document.visibilityState === 'visible',
  };
})()''';

/// Press [chord] in the page serving [appUrl]: real, trusted key events,
/// dispatched by the browser to whatever has its focus.
///
/// [macCommands] attaches the Cocoa editing commands a Mac browser would —
/// see [macEditingCommandsFor], and the measurement there: without them
/// Control+K deletes nothing.
///
/// Everything goes over one connection, in order, and the focus and
/// visibility are read on it first. Coordinates are never involved: the
/// browser routes a key to the focused element, which is what makes this safe
/// to run against a page whose size changed since launch.
Future<BrowserKeyPress> pressKeyOverCdp({
  required int cdpPort,
  required String appUrl,
  required KeyChord chord,
  required bool macCommands,
}) async {
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    final probe = await page.send('Runtime.evaluate', {
      'expression': _focusProbe,
      'returnByValue': true,
    });
    final state = probe['result']?['result']?['value'];
    final sent = <Map<String, Object>>[];
    for (final stroke in chord.strokes) {
      final params = stroke.cdpParams(
        macCommands: macCommands ? macEditingCommandsFor(stroke) : const [],
      );
      await page.send('Input.dispatchKeyEvent', params);
      sent.add(params);
    }
    return BrowserKeyPress(
      sent: sent,
      focus: state is Map ? '${state['focus']}' : 'unknown',
      focusIsEditable: state is Map && state['editable'] == true,
      pageVisible: state is! Map || state['visible'] != false,
    );
  } finally {
    await page.close();
  }
}

/// Capture a screenshot via Chrome DevTools Protocol.
///
/// Connects to `http://127.0.0.1:<port>/json` to discover the app tab's
/// WebSocket URL, then sends `Page.captureScreenshot` over CDP.
/// If [appUrl] is provided, selects the tab matching that URL.
Future<void> _cdpScreenshot(
  int cdpPort,
  String outputPath, {
  String? appUrl,
}) async {
  // Same target selection every CDP consumer uses — see `cdp_console.dart`.
  final wsUrl = await resolveCdpPageTarget(cdpPort, appUrl: appUrl);

  // Connect WebSocket and send Page.captureScreenshot.
  final ws = await WebSocket.connect(wsUrl);
  try {
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(
      json.encode({
        'id': 1,
        'method': 'Page.captureScreenshot',
        'params': {'format': 'png'},
      }),
    );

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
    );

    final result = response['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] == null) {
      throw StateError('CDP screenshot returned no data');
    }

    // Decode base64 PNG and write to file.
    final bytes = base64.decode(result['data'] as String);
    await File(outputPath).writeAsBytes(bytes);
  } finally {
    await ws.close();
  }
}

/// Find the Chrome executable path, or null if not found.
///
/// One definition of where Chrome lives, shared with the preflight that reports
/// its absence — see [chromeTool].
String? findChrome() => chromeTool().find();
