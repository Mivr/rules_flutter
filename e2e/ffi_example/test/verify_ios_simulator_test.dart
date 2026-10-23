/// Runtime verification on an iOS simulator: installs the app, launches it,
/// and asserts all three native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    embedded, signed `add.framework/add`.
///  * native_deps: `mul()` raw-opens the conventional framework partial path
///    `mul.framework/mul`, proving the loose-library pipeline bundles where
///    the loader expects.
///  * curated code asset: sqlite3's `@Native` bindings resolve against the
///    embedded, signed `sqlite3.framework`, which nothing in this workspace
///    names — the app depends on drift, and the registry attaches the
///    library to package:sqlite3.
///
/// Tagged "manual" (like the Android runtime test) because it needs a usable
/// iOS simulator. Run explicitly:
///   bazel test :verify_ios_simulator_test --test_tag_filters=
///
/// A cold CI simulator boots for minutes, so the target carries Bazel
/// `timeout = "eternal"`. Every `simctl` call below carries its own shorter
/// deadline instead: a hang fails with the step name and its elapsed time
/// rather than consuming the Bazel timeout as a bare `TIMEOUT`.
///
/// Pass criteria: after launch the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO` to
/// `tmp/ffi_result.txt` in its sandbox — written in main() only if all three
/// calls succeeded via the bundled native libraries. The test reads the file
/// back through `simctl get_app_container` (a deterministic signal that
/// doesn't depend on scraping iOS log output).
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _bundleId = 'com.example.ffi';
const _marker = 'ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO';
const _resultFile = 'tmp/ffi_result.txt';

/// One step's own deadline, sized from a healthy cold CI runner (boot ~13 s,
/// `bootstatus -b` ~136 s, uninstall ~18 s, install ~30 s, first launch past
/// a minute): each budget clears its healthy cost several times over, so only
/// a real hang hits one. Together they stay under the target's Bazel
/// `eternal` timeout (3600 s) even when every step runs its full budget, so
/// the slowest CI failure is still a named step failure, never a bare
/// TIMEOUT.
const _findBudget = Duration(seconds: 30);
const _unzipBudget = Duration(seconds: 60);
const _listBudget = Duration(seconds: 60);
const _bootBudget = Duration(seconds: 120);
const _bootStatusBudget = Duration(seconds: 300);
const _uninstallBudget = Duration(seconds: 60);
const _installBudget = Duration(seconds: 180);
const _launchBudget = Duration(seconds: 240);
const _containerBudget = Duration(seconds: 30);
const _terminateBudget = Duration(seconds: 60);

/// How long the test waits, in total, for the app to write its result file.
const _resultBudget = Duration(minutes: 3);

/// How long the test waits between result-file polls.
const _pollInterval = Duration(seconds: 2);

/// The outcome of one bounded step: its exit code, its captured output, the
/// deadline it ran under, how long it took, and whether the deadline fired.
typedef _StepOutcome = ({
  int exitCode,
  String stdout,
  String stderr,
  Duration budget,
  Duration elapsed,
  bool timedOut,
});

/// A simulator deliberate enough for CI: an iPhone on a specific iOS
/// runtime, naming whether it was already booted.
typedef _Simulator = ({String udid, String runtime, String name, bool booted});

/// An iOS runtime version parsed off a `simctl list` runtime key.
typedef _IosVersion = ({int major, int minor});

Future<void> main() async {
  final wallClock = Stopwatch()..start();
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipaPath = '$testSrcDir/$testWorkspace/ffi_ios.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('FAIL: expected the iOS app at $ipaPath, found nothing');
    exit(1);
  }

  final simctl = await _runStep('find simctl', [
    'xcrun',
    '--find',
    'simctl',
  ], _findBudget);
  _requireOk(simctl, 'xcrun --find simctl');
  print('simctl: ${simctl.stdout.trim()}');

  // Extract Payload/<app>.app from the .ipa.
  final tmp = Directory.systemTemp.createTempSync('ffi_ios_sim');
  try {
    final unzip = await _runStep('unzip ipa', [
      'unzip',
      '-q',
      ipaPath,
      '-d',
      tmp.path,
    ], _unzipBudget);
    _requireOk(unzip, 'unzip ipa');
    final payload = Directory('${tmp.path}/Payload');
    if (!payload.existsSync()) {
      stderr.writeln(
        'FAIL: no Payload/ inside $ipaPath; the archive holds: '
        '${tmp.listSync(recursive: true).map((e) => e.path)}',
      );
      exit(1);
    }
    final apps = payload
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('.app'))
        .toList();
    if (apps.length != 1) {
      stderr.writeln('FAIL: expected one .app inside $ipaPath, found $apps');
      exit(1);
    }
    final appDir = apps.single;
    print('App: ${appDir.path}');

    final udid = await _bootPickedSimulator();
    print('Simulator: $udid');

    // Uninstall first so a stale result file from a previous run can't be
    // read. Best effort: a missing install is not a failure.
    await _simctl('uninstall stale app', [
      'uninstall',
      udid,
      _bundleId,
    ], _uninstallBudget);

    final install = await _simctl('install app', [
      'install',
      udid,
      appDir.path,
    ], _installBudget);
    _requireOk(install, 'simctl install');

    final launch = await _simctl('launch app', [
      'launch',
      '--terminate-running-process',
      udid,
      _bundleId,
    ], _launchBudget);
    _requireOk(launch, 'simctl launch');
    print('Launched pid: ${launch.stdout.trim()}');

    final contents = await _waitForResult(udid);

    await _simctl('terminate app', [
      'terminate',
      udid,
      _bundleId,
    ], _terminateBudget);

    if (contents == null) {
      stderr.writeln(
        'FAIL: app never wrote $_resultFile within '
        '${_resultBudget.inSeconds}s — it likely crashed '
        'before main() completed (native library failed to load?).',
      );
      exit(1);
    }
    print('App recorded: "$contents"');
    if (contents != _marker) {
      stderr.writeln('FAIL: expected "$_marker" but got "$contents".');
      exit(1);
    }
    print(
      'PASS: @Native asset bind (add), raw framework open (mul) and '
      'the curated sqlite3 code asset all worked at runtime '
      '(in ${wallClock.elapsed.inSeconds}s).',
    );
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Lists the simulators, picks a deliberate iPhone on the newest available
/// iOS runtime, and returns its UDID booted and waited-for. Fails, never
/// skips, when no simulator runtime qualifies.
Future<String> _bootPickedSimulator() async {
  final listed = await _simctl('list devices', [
    'list',
    'devices',
    '-j',
  ], _listBudget);
  _requireOk(listed, 'simctl list devices');
  final decoded = jsonDecode(listed.stdout);
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln(
      'FAIL: `simctl list devices -j` printed no JSON object: $decoded',
    );
    exit(1);
  }
  final simulator = _pickSimulator(decoded);
  if (simulator == null) {
    stderr.writeln(
      'FAIL: no available iPhone simulator on any iOS runtime; '
      '`simctl list devices -j` saw runtimes: ${_runtimeKeys(decoded)}',
    );
    exit(1);
  }
  print(
    'Picked ${simulator.name} (${simulator.udid}) on ${simulator.runtime} '
    '${simulator.booted ? '(already booted)' : '(booting)'}',
  );

  if (!simulator.booted) {
    final boot = await _simctl('boot simulator', [
      'boot',
      simulator.udid,
    ], _bootBudget);
    _requireNoTimeout(boot, 'simctl boot ${simulator.udid}');
    // Exit code 149 == "already booted"; anything else non-zero is fatal.
    if (boot.exitCode != 0 &&
        boot.exitCode != 149 &&
        !boot.stderr.contains('Booted')) {
      stderr.writeln(
        'FAIL: `simctl boot ${simulator.udid}` exited ${boot.exitCode}: '
        '${boot.stderr}',
      );
      exit(1);
    }
  }
  // `-b` waits for the boot to finish; without it the call returns while the
  // device is still coming up and install/launch race it and hang.
  final ready = await _simctl('wait for boot', [
    'bootstatus',
    simulator.udid,
    '-b',
  ], _bootStatusBudget);
  _requireOk(ready, 'simctl bootstatus -b ${simulator.udid}');
  return simulator.udid;
}

/// Polls the app sandbox for the result file the app writes in main(), one
/// bounded `get_app_container` call at a time. Returns the file's contents,
/// or null when the budget runs out.
Future<String?> _waitForResult(String udid) async {
  print('Waiting up to ${_resultBudget.inSeconds}s for $_resultFile ...');
  final deadline = DateTime.now().add(_resultBudget);
  while (DateTime.now().isBefore(deadline)) {
    final container = await _simctl('read app container', [
      'get_app_container',
      udid,
      _bundleId,
      'data',
    ], _containerBudget);
    if (!container.timedOut && container.exitCode == 0) {
      final candidate = File('${container.stdout.trim()}/$_resultFile');
      if (candidate.existsSync()) return candidate.readAsStringSync().trim();
    }
    await Future<void>.delayed(_pollInterval);
  }
  return null;
}

/// Runs [argv] with the hard deadline [budget]. Prints the command before it
/// runs and its exit code and elapsed time after. Never throws: a step that
/// cannot even start reports exit code 127 with the error as stderr.
Future<_StepOutcome> _runStep(
  String step,
  List<String> argv,
  Duration budget,
) async {
  final stopwatch = Stopwatch()..start();
  print('STEP $step: ${argv.join(' ')} (budget ${budget.inSeconds}s)');
  Process process;
  try {
    process = await Process.start(argv.first, argv.sublist(1));
  } on ProcessException catch (e) {
    stopwatch.stop();
    print('STEP $step: could not start in ${stopwatch.elapsed.inSeconds}s');
    return (
      exitCode: 127,
      stdout: '',
      stderr: '$e',
      budget: budget,
      elapsed: stopwatch.elapsed,
      timedOut: false,
    );
  }
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  final exitCode = await process.exitCode.timeout(
    budget,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    },
  );
  // A killed step's pipes can stay open when an orphaned child inherited
  // them, so drain those only briefly: the step's deadline bounds the step,
  // not the orphan.
  final drain = timedOut ? const Duration(seconds: 10) : budget;
  final stdout = await stdoutFuture.timeout(
    drain,
    onTimeout: () => '<stdout cut off: a child held the pipe open>',
  );
  final stderr = await stderrFuture.timeout(
    drain,
    onTimeout: () => '<stderr cut off: a child held the pipe open>',
  );
  final outcome = (
    exitCode: exitCode,
    stdout: stdout,
    stderr: stderr,
    budget: budget,
    elapsed: stopwatch.elapsed,
    timedOut: timedOut,
  );
  print(
    'STEP $step: exit ${outcome.exitCode} in ${outcome.elapsed.inSeconds}s',
  );
  return outcome;
}

/// Runs `xcrun simctl [simctlArgs]` as the step [step] with deadline [budget].
Future<_StepOutcome> _simctl(
  String step,
  List<String> simctlArgs,
  Duration budget,
) {
  return _runStep(step, ['xcrun', 'simctl', ...simctlArgs], budget);
}

/// Fails the test when [outcome] hit its deadline, naming the step and the
/// elapsed time. Check this before the exit code of a step whose non-zero
/// exits are partly tolerable.
void _requireNoTimeout(_StepOutcome outcome, String step) {
  if (outcome.timedOut) {
    stderr.writeln(
      'FAIL: `$step` hung and hit its ${outcome.budget.inSeconds}s '
      'deadline after ${outcome.elapsed.inSeconds}s; stderr so far: '
      '${outcome.stderr}',
    );
    exit(1);
  }
}

/// Fails the test when [outcome] timed out or exited non-zero, naming the
/// step and how long it took. Best-effort steps skip this and inspect the
/// outcome themselves.
void _requireOk(_StepOutcome outcome, String step) {
  _requireNoTimeout(outcome, step);
  if (outcome.exitCode != 0) {
    stderr.writeln(
      'FAIL: `$step` exited ${outcome.exitCode}: ${outcome.stderr}',
    );
    exit(1);
  }
}

/// Picks a deliberate simulator out of `simctl list devices -j`: an iPhone on
/// the newest available iOS runtime, preferring one already booted. Returns
/// null when no available iPhone exists on any iOS runtime — never the
/// first entry in the JSON.
_Simulator? _pickSimulator(Map<String, dynamic> devicesJson) {
  final byRuntime = devicesJson['devices'];
  if (byRuntime is! Map) return null;
  final candidates = <String, List<Map<String, dynamic>>>{};
  for (final entry in byRuntime.entries) {
    final runtime = entry.key.toString();
    if (_iosVersion(runtime) == null) continue;
    if (entry.value is! List) continue;
    for (final device in entry.value as List) {
      if (device is! Map<String, dynamic>) continue;
      if (device['isAvailable'] != true) continue;
      if (!(device['name']?.toString().contains('iPhone') ?? false)) {
        continue;
      }
      candidates.putIfAbsent(runtime, () => []).add(device);
    }
  }
  if (candidates.isEmpty) return null;
  var bestRuntime = candidates.keys.first;
  var bestVersion = _iosVersion(bestRuntime)!;
  for (final runtime in candidates.keys.skip(1)) {
    final version = _iosVersion(runtime)!;
    if (_compareVersions(version, bestVersion) > 0) {
      bestRuntime = runtime;
      bestVersion = version;
    }
  }
  final phones = candidates[bestRuntime]!;
  var chosen = phones.first;
  for (final phone in phones) {
    if (phone['state'] == 'Booted') {
      chosen = phone;
      break;
    }
  }
  return (
    udid: chosen['udid'].toString(),
    runtime: bestRuntime,
    name: chosen['name'].toString(),
    booted: chosen['state'] == 'Booted',
  );
}

/// Runtime keys `simctl list` knows, for the failure message when no iPhone
/// qualifies.
String _runtimeKeys(Map<String, dynamic> devicesJson) {
  final byRuntime = devicesJson['devices'];
  if (byRuntime is! Map) return 'unparseable device list';
  final keys = byRuntime.keys.map((k) => k.toString()).toList()..sort();
  return keys.isEmpty ? 'no runtimes at all' : keys.join(', ');
}

/// Parses the `iOS-<major>-<minor>` suffix of a runtime key, or null when the
/// key names another platform.
_IosVersion? _iosVersion(String runtime) {
  final match = RegExp(r'iOS-(\d+)-(\d+)').firstMatch(runtime);
  if (match == null) return null;
  return (major: int.parse(match.group(1)!), minor: int.parse(match.group(2)!));
}

/// Compares two runtime versions: negative, zero, or positive.
int _compareVersions(_IosVersion a, _IosVersion b) {
  if (a.major != b.major) return a.major.compareTo(b.major);
  return a.minor.compareTo(b.minor);
}
