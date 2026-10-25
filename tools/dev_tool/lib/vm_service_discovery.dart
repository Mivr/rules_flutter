/// Waiting for the VM-service announcement while the launched app is alive.
///
/// The Flutter engine prints the VM-service URI on the app's console output,
/// so discovery is a *reader* of the app's log stream: it never owns the
/// underlying subscriptions. What this library adds over a bare read is the
/// waiting policy around it:
///
/// * While the launched app is alive, discovery keeps waiting past the point
///   the old fixed 30 s timeout would have given up, logging a `still waiting
///   for the VM service` progress line through the run's logger every
///   [VmDiscoveryConfig.progressInterval] (after an initial
///   [_firstProgressAfter] grace period, so a fast announcement stays quiet).
/// * When the app exits first, discovery fails at once with the device name,
///   the exit code (or the fact that none was reported), and the app's last
///   log lines.
/// * An overall [VmDiscoveryConfig.bound] remains, so a hung app cannot wait
///   forever. It is the `dev_tool run --vm-service-timeout` value, and
///   hitting it names the bound, the option, and the last log lines.
/// * [waitForVmServiceUri]'s abandoned signal ends a wait at once — with a
///   [VmDiscoveryCancelled] — when the run is shutting down (`daemon.shutdown`,
///   the run's SIGINT/SIGTERM handling, or the app being stopped). An in-flight
///   discovery must never outlive the run: whatever bound was configured, no
///   timer or subscription it left behind may keep the process alive past
///   shutdown.
///
/// ## Which devices observe their app
///
/// Liveness travels as [waitForVmServiceUri]'s [appExit]: a future completing
/// with the exit code, with null when the platform reports no code, and a
/// null future where the platform offers no signal at all. Those devices rely
/// on the bound alone and still log progress lines.
///
/// Physical iOS is not a bound device at all: its URI never crosses a log
/// stream, so it is found through the app's mDNS advertisement on its own
/// budget (5 minutes wired, 15 minutes wireless), and `--vm-service-timeout`
/// does not apply to it.
///
/// | Device          | Signal                                                        |
/// | --------------- | ------------------------------------------------------------- |
/// | macOS           | the app is a child process: its `exitCode`                    |
/// | Linux           | the app is a child process: its `exitCode`                    |
/// | Windows         | the app is a child process: its `exitCode`                    |
/// | iOS simulator   | the pid `simctl launch` reports ([parseSimctlLaunchPid]),     |
/// |                 | polled with `ps` ([watchHostPid])                             |
/// | Android         | none: `logcat` is a helper, the app runs on the device        |
/// | Physical iOS    | none here: mDNS discovery with its own budget, outside this   |
/// |                 | library (see `mdns_vm_service_discovery.dart`)                |
/// | Web / `attach`  | no log discovery runs at all                                  |
///
/// ## Fake time
///
/// Discovery takes its clock and timers from [VmDiscoveryConfig.clock], so
/// unit tests run in fake time without real sleeps: a test double advances a
/// virtual clock past the progress points, the exit, or the bound, and
/// asserts on what discovery did at each virtual instant.
library;

import 'dart:async';
import 'dart:io';

import 'app_log.dart';
import 'logging.dart';

/// Pattern matching Dart VM service URI announcements from Flutter apps.
/// Matches Flutter's own `kVMServiceMessageRegExp` from globals.dart.
final vmServiceUriPattern = RegExp(
  r'The Dart VM service is listening on ((http|//)[a-zA-Z0-9:/=_\-\.\[\]]+)',
);

/// How long `dev_tool run` waits for the app's VM-service announcement.
///
/// Three minutes: a freshly booted iOS simulator can take well past the old
/// fixed 30 s to announce, and failing there turned a slow first launch into
/// an error. Raise it per run with `--vm-service-timeout`.
const defaultVmServiceDiscoveryBound = Duration(minutes: 3);

/// The `dev_tool run` option that overrides [defaultVmServiceDiscoveryBound].
///
/// `attach` launches nothing and runs no discovery, so it offers no such
/// option.
const vmServiceTimeoutOption = '--vm-service-timeout';

/// How long discovery stays quiet before its first progress line.
///
/// An announcement inside this window returns with no progress line at all;
/// the line exists for a wait that has outlasted the point the old fixed
/// timeout would have given up, not for a healthy launch.
const _firstProgressAfter = Duration(seconds: 30);

/// The clock discovery reads and the timers it waits on.
///
/// A parameter object rather than direct `DateTime.now()` /
/// `Future.delayed` calls, so unit tests run discovery in fake time without
/// real sleeps: the fake advances a virtual clock past the progress points,
/// the app exit, or the bound.
abstract class VmDiscoveryClock {
  /// The current time.
  DateTime now();

  /// A future completing after [duration] on this clock.
  Future<void> sleep(Duration duration);

  /// A cancellable one-shot timer firing [onFire] after [duration].
  ///
  /// Discovery waits race several timers against each other and against the
  /// app exiting; the losers must be cancellable, or the one firing last —
  /// the bound, minutes out — keeps its Dart [Timer] pending and holds the
  /// dev tool process alive after the run that started it has shut down.
  VmDiscoveryTimer startTimer(Duration duration, void Function() onFire);
}

/// A one-shot timer from [VmDiscoveryClock.startTimer].
///
/// Cancelling stops the callback from firing. The discovery waits cancel
/// every timer they started that has not fired by the time the wait ends,
/// whatever the outcome, so nothing pending can keep the process alive.
abstract class VmDiscoveryTimer {
  /// Prevents the callback from firing. Safe to call after it fired.
  void cancel();
}

/// The system timer behind [SystemVmDiscoveryClock.startTimer].
class _SystemVmDiscoveryTimer implements VmDiscoveryTimer {
  /// The system timer behind [SystemVmDiscoveryClock.startTimer].
  _SystemVmDiscoveryTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// The production clock: wall time and real delays.
class SystemVmDiscoveryClock implements VmDiscoveryClock {
  /// The production clock: wall time and real delays.
  const SystemVmDiscoveryClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);

  @override
  VmDiscoveryTimer startTimer(Duration duration, void Function() onFire) =>
      _SystemVmDiscoveryTimer(Timer(duration, onFire));
}

/// The values one VM-service wait tunes together.
///
/// One object for the bound, the option that sets it, the progress cadence,
/// the liveness poll, and the clock — every wait threads all of them, so
/// they travel as one rather than as five arguments at each call site.
class VmDiscoveryConfig {
  /// The wait ends here even when the app is still alive, so a hung app
  /// cannot wait forever. The `--vm-service-timeout` value in production.
  final Duration bound;

  /// The option that sets [bound], named in the bound error so the fix is
  /// next to the failure.
  final String boundOption;

  /// Progress lines go out this often once the grace period has passed.
  final Duration progressInterval;

  /// How often [watchHostPid] re-probes the simulator pid.
  final Duration livenessPollInterval;

  /// How long discovery waits for a racing app exit after its log source
  /// ends before deciding the app is still alive.
  ///
  /// `dart:io` does not order a process's pipes closing against its
  /// `exitCode` completing, so a crash can close the source a breath before
  /// the exit lands; without the grace that exit reads as "the app had not
  /// exited" instead of reporting its code.
  final Duration sourceEndGrace;

  /// Where time comes from; the system clock in production, a fake in tests.
  final VmDiscoveryClock clock;

  /// The values one VM-service wait tunes together.
  const VmDiscoveryConfig({
    this.bound = defaultVmServiceDiscoveryBound,
    this.boundOption = vmServiceTimeoutOption,
    this.progressInterval = const Duration(seconds: 10),
    this.livenessPollInterval = const Duration(seconds: 1),
    this.sourceEndGrace = const Duration(seconds: 2),
    this.clock = const SystemVmDiscoveryClock(),
  });
}

/// Parse a `--vm-service-timeout` value: seconds.
///
/// Null or empty means the default. Anything else must be a positive integer;
/// anything else is a [FormatException] whose message names the option, for
/// the caller to report as a usage error.
Duration parseVmServiceTimeoutOption(String? raw) {
  if (raw == null || raw.isEmpty) return defaultVmServiceDiscoveryBound;
  final seconds = int.tryParse(raw);
  if (seconds == null || seconds <= 0) {
    throw FormatException(
      '$vmServiceTimeoutOption must be a positive number of seconds, '
      'got "$raw".',
    );
  }
  return Duration(seconds: seconds);
}

/// Parse the pid `xcrun simctl launch` reports.
///
/// On success it prints `<bundle-id>: <pid>`; the pid is the handle the
/// simulator launch is watched through. Null when the output carries no pid
/// (an Apple format change, a failure answered elsewhere): the caller then
/// waits without liveness rather than refusing a launch over a parse.
int? parseSimctlLaunchPid(String output) {
  final match = RegExp(r':\s*(\d+)\s*$').firstMatch(output.trim());
  if (match == null) return null;
  return int.parse(match.group(1)!);
}

/// Watch a simulator app's host pid until it is gone.
///
/// Completes with null: a `ps` probe reports alive or not, never an exit
/// code, and the unknown code is part of the contract (the exit error says
/// so). Polls on [VmDiscoveryConfig.livenessPollInterval] through
/// [VmDiscoveryConfig.clock], so fake-time tests drive it without sleeps.
///
/// [stop] ends the watch early: the launch site completes it when discovery
/// ends, whatever the outcome, so no `ps` outlives the wait. Every wait
/// between probes is a cancellable timer the watch cancels on its way out —
/// watched or stopped — so no pending probe gap can keep the process alive.
/// No probe runs after [stop]; one already in flight finishes, and then the
/// watch returns.
Future<int?> watchHostPid({
  required int pid,
  required Future<bool> Function(int pid) isAlive,
  required VmDiscoveryConfig config,
  Future<void>? stop,
}) async {
  var stopped = false;
  final watchStop = stop?.then((_) {
    stopped = true;
  });
  while (await isAlive(pid)) {
    final gap = Completer<void>();
    final timer = config.clock.startTimer(config.livenessPollInterval, () {
      gap.complete();
    });
    try {
      if (watchStop != null) {
        await Future.any([gap.future, watchStop]);
        if (stopped) return null;
      } else {
        await gap.future;
      }
    } finally {
      timer.cancel();
    }
  }
  return null;
}

/// What one [waitForVmServiceUri] call concluded.
///
/// A record rather than a bare URI because giving up on a living app is not
/// the launch failing: the run continues without a URI (aborting, or warning
/// on under `--allow-no-vm-service`), and the decision needs to know why.
typedef VmServiceDiscovery = ({
  /// The announced URI, or null when discovery gave up without one.
  Uri? uri,

  /// Why discovery gave up while the app was still alive: the bound text, or
  /// the ended-source text — the bound, the option that raises it, and the
  /// last log lines in either case. Null when discovery announced a URI, or
  /// never waited on a living app (no liveness signal).
  String? gaveUpNote,
});

/// Watch [logs] for the VM-service announcement while the app is alive.
///
/// Returns the announced URI, or a null URI when discovery gave up: the
/// bound expired on a living app, the log source ended on one, or the source
/// ended where nothing observes the app (an `adb logcat` that went away).
/// The launch continues without a URI and the caller decides what a missing
/// one means — aborting, or warning on under `--allow-no-vm-service` — with
/// [VmServiceDiscovery.gaveUpNote] as the reason.
///
/// Only "the app exited before announcing" throws, whatever the flag says: a
/// [StateError] naming the device, with its exit code (or the fact that the
/// platform reported none) plus the last 20 log lines.
///
/// [abandoned] ends the wait at once, with a [VmDiscoveryCancelled], when the
/// run is shutting down or the app is being stopped — before the bound, before
/// the next progress point, before a racing exit's grace. The launch site
/// completes it, and discovery cancels every timer it started that has not
/// fired by the time the wait ends, so nothing pending keeps the process
/// alive past shutdown.
///
/// Progress goes through [logger] (the run's logger in production) as
/// `still waiting for the VM service ... (<n>s elapsed)` lines, the first
/// after 30 s and then every [VmDiscoveryConfig.progressInterval].
Future<VmServiceDiscovery> waitForVmServiceUri({
  required AppLogStream logs,
  required String deviceName,
  Future<int?>? appExit,
  required VmDiscoveryConfig config,
  Logger? logger,
  Future<void>? abandoned,
}) async {
  final wait = _VmServiceWait(
    logs: logs,
    deviceName: deviceName,
    appExit: appExit,
    config: config,
    log: logger ?? Logger('dev_tool.device'),
    start: config.clock.now(),
    abandoned: abandoned,
  );
  return wait.run();
}

/// Watch a log-emitting helper process for the announcement while the app is
/// alive.
///
/// For sources where the helper exists *only* to find the URI (the iOS
/// simulator's discovery stream); app output comes from a separate stream.
/// Owns only its own subscription, like [waitForVmServiceUri] itself.
/// Completing [abandoned] ends the wait at once, as in [waitForVmServiceUri];
/// the relaunch path shuts the tool down through here, so a wait stranded
/// inside a restart's relaunch must not hold the process open either.
Future<VmServiceDiscovery> waitForVmServiceUriFromProcess(
  Process log, {
  required String deviceName,
  Future<int?>? appExit,
  required VmDiscoveryConfig config,
  Logger? logger,
  Future<void>? abandoned,
}) async {
  final logs = AppLogStream();
  final pump = pumpProcessLines(log, logs, transform: (l) {
    stderr.writeln('DIAG ${DateTime.now().toUtc().toIso8601String()} discovery.line pid=${log.pid} $l');
    return l;
  });
  // The helper is this stream's only source, so a helper that dies takes the
  // stream with it and the wait ends at once instead of sitting out its bound
  // on a process that will never say anything again.
  logs.closeWhen([pump.done]);
  try {
    return await waitForVmServiceUri(
      logs: logs,
      deviceName: deviceName,
      appExit: appExit,
      config: config,
      logger: logger,
      abandoned: abandoned,
    );
  } finally {
    await pump.dispose();
    await logs.close();
  }
}

/// One wait's three ways to wake up.
sealed class _DiscoveryOutcome {
  const _DiscoveryOutcome();
}

/// The log stream announced a URI, or ended with [uri] null.
class _LogOutcome extends _DiscoveryOutcome {
  /// The announced URI, or null when the log source ended first.
  final Uri? uri;

  /// The log stream announced a URI, or ended with [uri] null.
  const _LogOutcome(this.uri);
}

/// The app exited with [code], null when the platform reported none.
class _ExitOutcome extends _DiscoveryOutcome {
  /// The exit code, null when the platform reported none.
  final int? code;

  /// The app exited with [code], null when the platform reported none.
  const _ExitOutcome(this.code);
}

/// A clock sleep fired: a progress point or the bound.
class _TickOutcome extends _DiscoveryOutcome {
  /// A clock sleep fired: a progress point or the bound.
  const _TickOutcome();
}

/// The run is ending (or the app is being stopped) while discovery waits.
class _AbandonedOutcome extends _DiscoveryOutcome {
  /// The run is ending (or the app is being stopped) while discovery waits.
  const _AbandonedOutcome();
}

/// Discovery's wait was abandoned because the run is shutting down.
///
/// A [StateError] subclass, so a wait abandoned mid-flight reads as the launch
/// failing — like the app exiting before it announced — and never as a quiet
/// null: callers that catch the exit failure catch this too. The device name
/// travels in the message; the last log lines are not attached, because at
/// shutdown the launch reports the cancellation, it does not diagnose the app.
class VmDiscoveryCancelled extends StateError {
  /// Discovery's wait was abandoned because the run is shutting down.
  VmDiscoveryCancelled(String deviceName)
    : super(
        'The launch on $deviceName was cancelled because the run is shutting '
        'down or the app was stopped while discovery was still waiting for '
        'the VM service. The launch ends here: nothing more starts after the '
        'cancellation.',
      );
}

/// The state one [waitForVmServiceUri] call loops on.
///
/// A class rather than seven loop arguments: the log stream, the device name,
/// the liveness future, the config, the logger, the start instant and the
/// announcement all travel together through every iteration.
class _VmServiceWait {
  /// The app's console output, read for the announcement.
  final AppLogStream logs;

  /// Named in every progress line and every failure.
  final String deviceName;

  /// Completes with the exit code when the app exits, null without one, and
  /// is itself null where the platform offers no signal.
  final Future<int?>? appExit;

  /// Bound, progress cadence, and clock.
  final VmDiscoveryConfig config;

  /// The run's logger in production; the progress lines go through it.
  final Logger log;

  /// When the wait started, on [VmDiscoveryClock].
  final DateTime start;

  /// Whether [appExit] has completed, and with what. The log source usually
  /// ends a breath after the app does, so an `ended` arrival with these set
  /// is still an app exit, not a dead helper.
  bool _exitSeen = false;

  /// The exit code [appExit] completed with, once [_exitSeen].
  int? _exitCode;

  /// What [appExit] failed with, once [_exitSeen]. A liveness probe is I/O
  /// and can fail; the failure is reported, never swallowed.
  Object? _exitError;

  /// The next progress line's elapsed mark. Starts past the grace period so
  /// a fast announcement stays quiet.
  Duration _nextProgress = _firstProgressAfter;

  /// Completes when the run is shutting down or the app is being stopped.
  /// Null where the caller offers no signal. The wait then ends at once with
  /// a [VmDiscoveryCancelled] instead of sitting out its bound.
  final Future<void>? abandoned;

  /// The state one [waitForVmServiceUri] call loops on.
  _VmServiceWait({
    required this.logs,
    required this.deviceName,
    required this.appExit,
    required this.config,
    required this.log,
    required this.start,
    required this.abandoned,
  });

  /// Wait for the announcement, the app exit, or the bound.
  ///
  /// Giving up on a living app returns a null URI with the note; only the
  /// app exiting first throws — and the wait being abandoned throws a
  /// [VmDiscoveryCancelled], promptly, whatever point of the bound it reached.
  /// An exit racing the abandonment still reads as the cancellation when the
  /// abandonment landed first: the launch site completes the signal before it
  /// stops anything, so a shutdown that kills the app reports the
  /// cancellation, while an app that already exited on its own keeps its exit
  /// report. Completion order decides, deterministically.
  Future<VmServiceDiscovery> run() async {
    final announced = Completer<Uri?>();
    _watchExit();
    final sub = logs.lines.listen(
      (line) {
        if (announced.isCompleted) return;
        final match = vmServiceUriPattern.firstMatch(line.text);
        if (match != null) announced.complete(Uri.parse(match.group(1)!));
      },
      onDone: () {
        if (!announced.isCompleted) announced.complete(null);
      },
    );
    try {
      while (true) {
        final elapsed = config.clock.now().difference(start);
        if (elapsed >= config.bound) {
          return (uri: null, gaveUpNote: _boundNote());
        }
        final untilProgress = _nextProgress - elapsed;
        if (untilProgress <= Duration.zero) {
          _logProgress(elapsed);
          _nextProgress += config.progressInterval;
          continue;
        }
        var wait = config.bound - elapsed;
        var tickIsProgress = false;
        if (untilProgress < wait) {
          wait = untilProgress;
          tickIsProgress = true;
        }
        switch (await _waitForOutcome(announced.future, wait)) {
          case _LogOutcome(:final uri):
            if (uri != null) return (uri: uri, gaveUpNote: null);
            return await _onSourceEnded();
          case _ExitOutcome(:final code):
            throw _exitFailure(code);
          case _AbandonedOutcome():
            throw VmDiscoveryCancelled(deviceName);
          case _TickOutcome():
            if (tickIsProgress) {
              _logProgress(config.clock.now().difference(start));
              _nextProgress += config.progressInterval;
            } else {
              return (uri: null, gaveUpNote: _boundNote());
            }
        }
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Race the announcement, the app exit, the clock tick, and the abandonment.
  ///
  /// The tick rides a cancellable timer, not a bare sleep: whichever way this
  /// returns, the timer is cancelled before it does, so the wait never leaves
  /// a pending timer behind — the bound-length sleep that used to lose this
  /// race is what kept the dev tool process alive after `daemon.shutdown`.
  Future<_DiscoveryOutcome> _waitForOutcome(
    Future<Uri?> announced,
    Duration wait,
  ) async {
    final tick = Completer<_DiscoveryOutcome>();
    final timer = config.clock.startTimer(wait, () {
      if (!tick.isCompleted) tick.complete(const _TickOutcome());
    });
    try {
      // A local: the field is public, so it cannot be promoted.
      final exitFuture = appExit;
      final abandonFuture = abandoned;
      return await Future.any<_DiscoveryOutcome>([
        announced.then<_DiscoveryOutcome>(_LogOutcome.new),
        if (exitFuture != null)
          exitFuture.then<_DiscoveryOutcome>(_ExitOutcome.new),
        if (abandonFuture != null)
          abandonFuture.then<_DiscoveryOutcome>(
            (_) => const _AbandonedOutcome(),
          ),
        tick.future,
      ]);
    } finally {
      timer.cancel();
    }
  }

  /// Record the app exit for [_onSourceEnded].
  ///
  /// A second subscription beside the race's own: an `ended` arrival cannot
  /// otherwise tell an app that just exited from a helper that just died.
  /// Failures are recorded, not swallowed — the race rethrows them too.
  void _watchExit() {
    appExit?.then(
      (code) {
        _exitSeen = true;
        _exitCode = code;
      },
      onError: (Object e) {
        _exitSeen = true;
        _exitError = e;
      },
    );
  }

  /// The log source ended without announcing.
  ///
  /// A null URI where nothing observes the app, as before. Otherwise the app
  /// exit wins when it already landed; when it has not, the exit gets a
  /// short grace — `dart:io` does not order the pipes closing against
  /// `exitCode` completing — and only then does the wait give up on a living
  /// app, with the note the run's abort-or-continue decision reports.
  /// Abandonment during the grace ends it at once with a
  /// [VmDiscoveryCancelled], like anywhere else in the wait.
  Future<VmServiceDiscovery> _onSourceEnded() async {
    // A local: `appExit` is a public field, which never promotes, so the
    // null check has to live on the copy the grace below awaits.
    final exitFuture = appExit;
    if (exitFuture == null) return (uri: null, gaveUpNote: null);
    final error = _exitError;
    if (error != null) throw error;
    if (_exitSeen) throw _exitFailure(_exitCode);
    if (await _waitForGraceExit(exitFuture)) throw _exitFailure(_exitCode);
    return (uri: null, gaveUpNote: _sourceEndedNote());
  }

  /// Give a racing app exit [config]'s grace to land after the source ended.
  ///
  /// True when the exit landed; false when the grace expired on a living app.
  /// Throws [VmDiscoveryCancelled] when the run is abandoned first. The grace
  /// rides a cancellable timer like the main loop's ticks, so abandonment
  /// leaves no pending timer behind.
  Future<bool> _waitForGraceExit(Future<int?> exitFuture) async {
    final grace = Completer<bool>();
    final timer = config.clock.startTimer(config.sourceEndGrace, () {
      if (!grace.isCompleted) grace.complete(_exitSeen);
    });
    try {
      // A local: the field is public, so it cannot be promoted.
      final abandonFuture = abandoned;
      // An exit failure propagates to the caller, reported, never swallowed.
      return await Future.any([
        exitFuture.then((_) => true),
        if (abandonFuture != null)
          abandonFuture.then((_) => throw VmDiscoveryCancelled(deviceName)),
        grace.future,
      ]);
    } finally {
      timer.cancel();
    }
  }

  /// The app exited before announcing: device, exit code or its absence, and
  /// the last log lines.
  StateError _exitFailure(int? code) {
    final exit = code == null
        ? 'exited before announcing its VM service (the platform did not '
              'report an exit code)'
        : 'exited (exit code $code) before announcing its VM service';
    return StateError(
      'The app on $deviceName $exit. ${_lastLinesText()}',
    );
  }

  /// The bound expired while the app was still alive: the bound, the option
  /// that raises it, and the last log lines.
  String _boundNote() {
    final bound = config.bound;
    final option = config.boundOption;
    return 'Still no VM service on $deviceName after ${bound.inSeconds}s (the '
        '$option bound). To wait longer, pass $option=<seconds> with a larger '
        'value. ${_lastLinesText()}';
  }

  /// The log source ended on a living app: the bound the wait would have
  /// kept going to, the option that raises it, and the last log lines.
  String _sourceEndedNote() {
    final bound = config.bound;
    final option = config.boundOption;
    final elapsed = config.clock.now().difference(start).inSeconds;
    return 'The log source on $deviceName ended after ${elapsed}s while the '
        'app was still running, before it announced a VM service. The wait '
        'would have kept going to ${bound.inSeconds}s (the $option bound); '
        'to wait longer, pass $option=<seconds> with a larger value. '
        '${_lastLinesText()}';
  }

  /// One progress line: the required `still waiting` text and elapsed seconds.
  void _logProgress(Duration elapsed) {
    log.info({
      'message': 'vm_service_still_waiting',
      'text':
          'still waiting for the VM service on $deviceName '
          '(${elapsed.inSeconds}s elapsed). The app is still running; will '
          'keep waiting up to ${config.bound.inSeconds}s.',
      'device': deviceName,
      'elapsed_s': elapsed.inSeconds,
    });
  }

  /// The app's last log lines, up to 20, for a failure message.
  String _lastLinesText() {
    final lines = logs.read(-20).lines;
    if (lines.isEmpty) return 'No app output was captured.';
    return 'Last app output:\n${lines.map((l) => l.text).join('\n')}';
  }
}
