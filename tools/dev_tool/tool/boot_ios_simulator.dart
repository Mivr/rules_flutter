/// Boots one iOS simulator and waits until it has finished booting.
///
/// Picks the newest *available* iOS runtime in `xcrun simctl`'s JSON listing
/// (version components compared numerically, so 26.10 beats 26.5; watchOS,
/// tvOS and visionOS runtimes never qualify, nor does anything whose
/// `isAvailable` is false), then an available iPhone on that runtime — one
/// already `Booted` when there is one, otherwise the first `Shutdown` iPhone
/// in the order listed. Boots it unless it is already booted, then always
/// waits on `bootstatus -b`, so a 0 exit means the device is usable now.
///
/// Runtime availability is read from the `runtimes` array of the same listing
/// call the devices come from (`xcrun simctl list -j`, unfiltered: `list`
/// takes at most one type, so the devices and runtimes sections only arrive
/// together in the full listing). The `devices` map carries no runtime-level
/// flag — a devices-only listing would treat an unavailable newest runtime
/// as a candidate.
///
/// Run it locally before the dev tool's iOS simulator e2e cases:
///
/// ```sh
/// dart run tools/dev_tool/tool/boot_ios_simulator.dart [--timeout=<seconds>]
/// ```
///
/// `--timeout` sets the `bootstatus` deadline in seconds (default 600); the
/// `list` and `boot` calls retry with growing bounds inside an overall bound
/// (see [BootOptions]). `xcrun` is resolved
/// from `PATH` and the host OS is never inspected: on a machine without Xcode
/// the script simply fails like any other missing tool.
///
/// Exit codes: 0 once `bootstatus` has returned 0. Anything else is non-zero
/// with a one-line reason on stderr — no `xcrun`, an unparsable listing, no
/// available iOS runtime, no available iPhone on the newest runtime (devices
/// are never created), a failed `boot`, a `list` or `boot` silent past its
/// overall bound, or a failed or timed-out `bootstatus`.
/// The script never skips. On success the last stdout line is exactly
/// `booted <udid>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The bounds one retrying `simctl` call runs inside: the first attempt's
/// deadline, and the overall deadline the attempts share.
///
/// The first bound is the generous single-call deadline the script always had
/// (`list` enumerates from disk, `boot` hands over to `bootstatus`); the
/// overall bound is what makes a slow call a wait rather than a failure. Kept
/// in one place so [BootOptions] can carry a pair per call, and tests can
/// shrink a pair to milliseconds.
class RetryBounds {
  /// How long the first attempt may take; each retry doubles it.
  final Duration first;

  /// How long all attempts together may take before the call fails.
  final Duration overall;

  const RetryBounds({required this.first, required this.overall});
}

/// The `bootstatus` deadline when `--timeout` is not given.
const _defaultBootstatusTimeout = Duration(seconds: 600);

/// A simulator the listing described, with the fields the choice needs.
class SimulatorDevice {
  /// The device name, e.g. `iPhone 17 Pro`.
  final String name;

  /// The `simctl` identifier every command addresses.
  final String udid;

  /// The lifecycle state the listing reported: `Booted`, `Shutdown`, ...
  final String state;

  /// Whether the listing marks it available.
  final bool available;

  const SimulatorDevice({
    required this.name,
    required this.udid,
    required this.state,
    required this.available,
  });
}

/// An iOS runtime key from the listing with its version parsed out.
class SimulatorRuntime {
  /// The `devices`-map key, e.g. `com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
  final String key;

  /// The numeric version components, e.g. `[26, 5]`.
  final List<int> version;

  const SimulatorRuntime({required this.key, required this.version});

  /// `iOS 26.5`, for the progress line.
  String get label => 'iOS ${version.join('.')}';
}

/// The device the script booted (or found already booted) and waited for.
class SimulatorChoice {
  /// The picked device.
  final SimulatorDevice device;

  /// The runtime it was picked from.
  final SimulatorRuntime runtime;

  const SimulatorChoice({required this.device, required this.runtime});

  /// Whether the device was already booted when picked.
  bool get wasBooted => device.state == 'Booted';
}

/// Everything [bootSimulator] needs, grouped so callers never thread six
/// arguments through.
class BootOptions {
  /// How children are started; inject a stub to test without `xcrun`.
  final CommandSpawner spawner;

  /// How long `bootstatus` may take before the child is killed.
  final Duration bootstatusTimeout;

  /// Where the choice (`booting ...` / `chose ...`) is reported.
  final void Function(String line) log;

  /// Bounds for `simctl list -j`: a minute for the first attempt (simulators
  /// enumerate from disk, and a loaded runner is slow, not stuck), five
  /// minutes overall.
  final RetryBounds listBounds;

  /// Bounds for `simctl boot`: three minutes for the first attempt, five
  /// minutes overall. `bootstatus` takes over the wait once `boot` returns.
  final RetryBounds bootBounds;

  /// Clock used to measure the attempt bounds. Defaults to [DateTime.now];
  /// tests pass a fake clock for deterministic bounds.
  final DateTime Function() now;

  const BootOptions({
    required this.spawner,
    required this.bootstatusTimeout,
    required this.log,
    this.listBounds = const RetryBounds(
      first: Duration(seconds: 60),
      overall: Duration(minutes: 5),
    ),
    this.bootBounds = const RetryBounds(
      first: Duration(seconds: 180),
      overall: Duration(minutes: 5),
    ),
    this.now = DateTime.now,
  });
}

/// A failure with its one-line stderr text attached. Every exit path of this
/// script is one of these; nothing else escapes [bootSimulator].
class BootFailure implements Exception {
  /// The one line the script prints on stderr for this failure.
  final String reason;

  const BootFailure(this.reason);

  @override
  String toString() => reason;
}

/// Compares dotted version component lists numerically: 26.10 beats 26.5, and
/// a longer tail beats its prefix.
int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// The version in a `devices`-map runtime key, or null when the key is not an
/// iOS runtime. Keys look like
/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5`, with `-` (not `.`) between
/// the components; anything naming another platform never matches.
List<int>? parseRuntimeVersion(String key) {
  final match = RegExp(r'\.([A-Za-z]+OS)[- ]([\d._-]+)').firstMatch(key);
  if (match == null || match.group(1) != 'iOS') return null;
  final parts = match.group(2)!.split(RegExp(r'[._-]+'));
  final version = <int>[];
  for (final part in parts) {
    if (part.isEmpty) continue;
    final number = int.tryParse(part);
    if (number == null) return null;
    version.add(number);
  }
  return version.isEmpty ? null : version;
}

/// Whether a device entry counts as available. `simctl` writes a JSON boolean;
/// anything else-shaped (including absent) does not qualify.
bool _deviceAvailable(Map<String, dynamic> entry) {
  final flag = entry['isAvailable'];
  return flag == true || (flag is String && flag.toUpperCase() == 'YES');
}

/// Runtime identifiers the listing's `runtimes` array marks unavailable, so
/// the devices map (which carries no runtime-level flag) can honor them. When
/// the array is absent every key counts as available.
Set<String> _unavailableRuntimes(Map<String, dynamic> listing) {
  final runtimes = listing['runtimes'];
  if (runtimes is! List) return const {};
  return {
    for (final entry in runtimes)
      if (entry is Map<String, dynamic> &&
          entry['isAvailable'] == false &&
          entry['identifier'] is String)
        entry['identifier'] as String,
  };
}

/// Every available iOS runtime in the listing, oldest first in listing order.
List<SimulatorRuntime> _availableRuntimes(Map<String, dynamic> listing) {
  final devices = listing['devices'];
  if (devices is! Map) return const [];
  final unavailable = _unavailableRuntimes(listing);
  final found = <SimulatorRuntime>[];
  for (final key in devices.keys) {
    if (key is! String || unavailable.contains(key)) continue;
    final version = parseRuntimeVersion(key);
    if (version != null)
      found.add(SimulatorRuntime(key: key, version: version));
  }
  return found;
}

/// The available iPhones of one runtime's device list, in listed order.
List<SimulatorDevice> _availableIPhones(List<dynamic> entries) {
  final found = <SimulatorDevice>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    final udid = entry['udid'];
    if (name is! String || !name.startsWith('iPhone')) continue;
    if (udid is! String || udid.isEmpty) continue;
    if (!_deviceAvailable(entry)) continue;
    final state = entry['state'];
    found.add(
      SimulatorDevice(
        name: name,
        udid: udid,
        state: state is String ? state : '',
        available: true,
      ),
    );
  }
  return found;
}

/// Picks the simulator to boot: the newest available iOS runtime, and on it
/// an already-booted iPhone when there is one, else the first shutdown one.
SimulatorChoice selectSimulator(Map<String, dynamic> listing) {
  final runtimes = _availableRuntimes(listing);
  if (runtimes.isEmpty) {
    throw const BootFailure('no available iOS runtime in the simctl listing');
  }
  runtimes.sort((a, b) => compareVersions(a.version, b.version));
  final newest = runtimes.last;
  final devices = listing['devices'] as Map;
  final entries = devices[newest.key];
  final candidates = entries is List ? _availableIPhones(entries) : const [];
  SimulatorDevice? booted;
  SimulatorDevice? shutdown;
  for (final device in candidates) {
    if (device.state == 'Booted') {
      booted ??= device;
    } else if (device.state == 'Shutdown') {
      shutdown ??= device;
    }
    if (booted != null && shutdown != null) break;
  }
  final chosen = booted ?? shutdown;
  if (chosen == null) {
    throw BootFailure(
      'no available iPhone on ${newest.label} (not creating devices)',
    );
  }
  return SimulatorChoice(device: chosen, runtime: newest);
}

/// Decodes the `simctl list` stdout into the map [selectSimulator] reads.
Map<String, dynamic> decodeListing(String stdoutText) {
  try {
    final decoded = json.decode(stdoutText);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Falls through to the failure below.
  }
  throw const BootFailure(
    'the simctl device listing was not valid JSON',
  );
}

/// One finished child: its exit code and whatever it printed.
class CommandResult {
  /// The child's exit code.
  final int exitCode;

  /// Everything it wrote to stdout.
  final String stdoutText;

  /// Everything it wrote to stderr.
  final String stderrText;

  const CommandResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });
}

/// One running child: its eventual output and a way to stop it.
class SpawnedCommand {
  /// Completes with the exit code, or never when the child hangs.
  final Future<int> exitCode;

  /// The collected stdout.
  final Future<String> stdoutText;

  /// The collected stderr.
  final Future<String> stderrText;

  /// Stops the child; called when its deadline expires.
  final void Function() kill;

  const SpawnedCommand({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
    required this.kill,
  });
}

/// Starts children. Injected (rather than called directly) so tests can stub
/// `xcrun` without a shell script in the tree.
abstract class CommandSpawner {
  Future<SpawnedCommand> start(String executable, List<String> args);
}

/// The real thing: `Process.start`, with output collected to strings.
class ProcessCommandSpawner implements CommandSpawner {
  @override
  Future<SpawnedCommand> start(String executable, List<String> args) async {
    final process = await Process.start(executable, args);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    return SpawnedCommand(
      exitCode: process.exitCode,
      stdoutText: stdoutFuture,
      stderrText: stderrFuture,
      kill: process.kill,
    );
  }
}

/// Runs one `xcrun simctl ...` call to completion: kills the child when its
/// deadline expires and fails naming the call and the elapsed time.
Future<CommandResult> runSimctl(
  CommandSpawner spawner,
  List<String> args, {
  required Duration timeout,
}) async {
  final label = 'xcrun ${args.join(' ')}';
  final waited = Stopwatch()..start();
  final result = await _runSimctlAttempt(spawner, args, timeout);
  if (result == null) {
    throw BootFailure('`$label` timed out after ${waited.elapsed.inSeconds}s');
  }
  return result;
}

/// Runs one `xcrun simctl ...` call with load-tolerant bounds: an attempt that
/// overruns its bound is killed and retried with a doubled bound, inside the
/// overall bound the attempts share.
///
/// Each retry logs a line naming the call, the attempt that overran and the
/// elapsed time, and the attempt that follows it. A call that answers —
/// including a non-zero exit — returns (or fails, through
/// [_requireSimctlSuccess]) at once: only silence is retried, never a refusal.
///
/// A retried `simctl boot` is the exception when [retryAcceptBooting] is set:
/// a killed first attempt can still be working when the retry runs, and the
/// retry then exits non-zero saying the device is already Booting or Booted.
/// That refusal means the boot happened, so it is logged and returned as done
/// for `bootstatus` to take over; any other non-zero exit still fails at once.
Future<CommandResult> runSimctlWithRetries(
  CommandSpawner spawner,
  List<String> args, {
  required RetryBounds bounds,
  required void Function(String line) log,
  DateTime Function() now = DateTime.now,
  bool retryAcceptBooting = false,
}) async {
  final label = 'xcrun ${args.join(' ')}';
  final started = now();
  var elapsed = Duration.zero;
  var attempt = 0;
  var attemptBound = bounds.first;
  while (true) {
    final left = bounds.overall - elapsed;
    if (left <= Duration.zero) break;
    attempt++;
    final bound = attemptBound < left ? attemptBound : left;
    final result = await _runSimctlAttempt(spawner, args, bound);
    if (result != null) {
      if (retryAcceptBooting &&
          attempt > 1 &&
          result.exitCode != 0 &&
          _bootAlreadyUnderway.hasMatch(result.stderrText)) {
        log(
          '`$label` reports the device is already booting '
          '(attempt $attempt); treating the boot as done',
        );
        return CommandResult(
          exitCode: 0,
          stdoutText: result.stdoutText,
          stderrText: result.stderrText,
        );
      }
      return result;
    }
    elapsed = now().difference(started);
    // The overall bound expired with this overrun: fail without logging a
    // retry for an attempt that will never run.
    if (bounds.overall - elapsed <= Duration.zero) break;
    log(
      '`$label` timed out after ${_formatElapsed(elapsed)} '
      '(attempt $attempt); retrying as attempt ${attempt + 1}',
    );
    attemptBound *= 2;
  }
  throw BootFailure(
    '`$label` timed out after ${_formatElapsed(elapsed)} '
    'over $attempt attempt${attempt == 1 ? '' : 's'}',
  );
}

/// Elapsed times print in seconds at production bounds and in milliseconds
/// below a second, so ms-scale test bounds never report a bare `0s`.
String _formatElapsed(Duration elapsed) => elapsed >= const Duration(seconds: 1)
    ? '${elapsed.inSeconds}s'
    : '${elapsed.inMilliseconds}ms';

/// A `simctl boot` refusal that means the boot already happened: the attempt
/// this retry replaces was killed for slowness while still working.
final _bootAlreadyUnderway = RegExp(
  r'Unable to boot device in current state: Boot(?:ing|ed)',
);

/// One attempt at a `simctl` call: starts the child and waits up to [bound]
/// for its exit, killing it past the bound.
///
/// Returns null when the child was killed for overrunning; anything else —
/// including a missing `xcrun` — throws, because only silence is retried.
Future<CommandResult?> _runSimctlAttempt(
  CommandSpawner spawner,
  List<String> args,
  Duration bound,
) async {
  SpawnedCommand child;
  try {
    child = await spawner.start('xcrun', args);
  } on ProcessException {
    throw const BootFailure(
      'no xcrun on PATH (the Xcode command line tools are required)',
    );
  }
  int exitCode;
  try {
    exitCode = await child.exitCode.timeout(bound);
  } on TimeoutException {
    child.kill();
    return null;
  }
  return CommandResult(
    exitCode: exitCode,
    stdoutText: await child.stdoutText,
    stderrText: await child.stderrText,
  );
}

/// The first non-blank stderr line, or null when there is none — the most that
/// fits on the failure's one stderr line.
String? _firstStderrLine(String stderrText) {
  for (final line in const LineSplitter().convert(stderrText)) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return null;
}

/// Fails when [result] is not a 0 exit, quoting the call and its stderr.
void _requireSimctlSuccess(CommandResult result, String label) {
  if (result.exitCode == 0) return;
  final detail = _firstStderrLine(result.stderrText);
  throw BootFailure(
    detail == null
        ? '`$label` exited ${result.exitCode}'
        : '`$label` exited ${result.exitCode}: $detail',
  );
}

/// Boots the selected simulator and waits for it, logging the choice.
Future<SimulatorChoice> bootSimulator(BootOptions options) async {
  final list = await runSimctlWithRetries(
    options.spawner,
    const ['simctl', 'list', '-j'],
    bounds: options.listBounds,
    log: options.log,
    now: options.now,
  );
  _requireSimctlSuccess(list, 'xcrun simctl list -j');
  final choice = selectSimulator(decodeListing(list.stdoutText));
  final device = choice.device;
  if (choice.wasBooted) {
    options.log(
      'chose ${device.name} (${device.udid}) on ${choice.runtime.label} '
      '(already booted)',
    );
  } else {
    options.log(
      'booting ${device.name} (${device.udid}) on ${choice.runtime.label}...',
    );
    final boot = await runSimctlWithRetries(
      options.spawner,
      ['simctl', 'boot', device.udid],
      bounds: options.bootBounds,
      log: options.log,
      now: options.now,
      retryAcceptBooting: true,
    );
    _requireSimctlSuccess(boot, 'xcrun simctl boot ${device.udid}');
  }
  final status = await runSimctl(
    options.spawner,
    ['simctl', 'bootstatus', device.udid, '-b'],
    timeout: options.bootstatusTimeout,
  );
  _requireSimctlSuccess(
    status,
    'xcrun simctl bootstatus ${device.udid} -b',
  );
  return choice;
}

/// Boots and prints the final `booted <udid>` line through [out], so tests can
/// pin the stdout contract without a subprocess.
Future<String> bootAndReport(
  BootOptions options,
  void Function(String line) out,
) async {
  final choice = await bootSimulator(options);
  out('booted ${choice.device.udid}');
  return choice.device.udid;
}

/// Reads `--timeout=<seconds>` (the `=` form only); anything else is a usage
/// error carrying the one-line usage text.
Duration parseBootTimeout(List<String> args) {
  var timeout = _defaultBootstatusTimeout;
  for (final arg in args) {
    const prefix = '--timeout=';
    if (!arg.startsWith(prefix)) {
      throw const BootFailure(
        'usage: boot_ios_simulator.dart [--timeout=<seconds>]',
      );
    }
    final seconds = int.tryParse(arg.substring(prefix.length));
    if (seconds == null || seconds <= 0) {
      throw const BootFailure(
        'usage: boot_ios_simulator.dart [--timeout=<seconds>]',
      );
    }
    timeout = Duration(seconds: seconds);
  }
  return timeout;
}

Future<void> main(List<String> args) async {
  final Duration bootstatusTimeout;
  try {
    bootstatusTimeout = parseBootTimeout(args);
  } on BootFailure catch (e) {
    stderr.writeln(e.reason);
    exit(2);
  }
  try {
    await bootAndReport(
      BootOptions(
        spawner: ProcessCommandSpawner(),
        bootstatusTimeout: bootstatusTimeout,
        log: print,
      ),
      print,
    );
  } on BootFailure catch (e) {
    stderr.writeln(e.reason);
    exit(1);
  }
}
