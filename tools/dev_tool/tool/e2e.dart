/// Runs the dev_tool e2e suite and refuses to call a run that did not happen a
/// pass.
///
/// ```sh
/// dart run tools/dev_tool/tool/e2e.dart                      # the whole suite
/// dart run tools/dev_tool/tool/e2e.dart --plain-name="macOS" # scoped
/// dart run tools/dev_tool/tool/e2e.dart test/e2e/agent_e2e_test.dart
/// ```
///
/// Arguments are forwarded to `dart test`; any positional one replaces the
/// default `test/e2e/` path. The one exception is `--require-ran=<substring>`
/// (repeatable, `=` form only): the runner consumes it, and it is never
/// forwarded to `dart test`.
///
/// ## What `--require-ran` guarantees
///
/// Each `--require-ran=<substring>` names tests that must have run for the run
/// to count as a pass: at least one test whose full name contains the
/// substring (case-sensitive) passed, and no test whose name contains it
/// skipped or failed. A failing run still names every failed test with its
/// error; an unmet requirement adds its own lines and never hides those. A
/// bare `--require-ran` or an empty value is a usage error and exits non-zero
/// before anything runs. Without the flag behaviour is unchanged.
///
/// ## Why this exists rather than a bare `dart test`
///
/// `dart test` has three ways to finish without running the suite, and only two
/// of them are loud:
///
/// | condition                                     | exit | verdict    |
/// |---|---|---|
/// | version solving fails (a dep cannot resolve)  | 65   | loud       |
/// | nothing selected (`--tags`/`-n` match none)   | 79   | loud       |
/// | **every selected test skipped**               | **0**| **silent** |
///
/// The third is the hole. `dart test` prints `All tests skipped.` and exits 0,
/// so a suite that ran nothing is indistinguishable — to CI, to a sweep script,
/// to an agent — from one that passed. It is reachable rather than theoretical:
/// most of the e2e files are `skip:`-gated on `Platform.isMacOS`, so the whole
/// of each one "passes" having executed nothing on any other host.
///
/// This runner closes the hole by reading the machine-readable result stream
/// rather than the exit code: it counts the tests that actually *ran* and fails
/// when that count is zero, when any test failed, or when the runner never
/// reached its own verdict.
///
/// It also removes the reason the exit code gets lost in the first place. The
/// documented recipes are long pipelines (`caffeinate -d dart test … | tee`),
/// and a shell reports the *tail* of a pipeline: `dart test … | head -3` after
/// either loud failure leaves `$?` at 0 with `PIPESTATUS` at `65 0`. A reader
/// who judges by what scrolled past sees no failing test names and calls it
/// green. Here the verdict is the last thing printed, in words.
///
/// ## Too old a `dart` never reaches this script
///
/// The suite is executed by whatever `dart` invoked this script, and that is
/// not a property of this repo. `pubspec.yaml` requires `sdk: ^3.13.0`, the SDK
/// this repo pins, and an older SDK refuses to compile *any* library in the
/// package:
///
/// ```
/// tool/e2e.dart:1:1: Error: The language version 3.13 specified for the
/// package 'flutter_bazel_dev_tool' is too high. The highest supported
/// language version is 3.12.
/// ```
///
/// It exits **254**, so it is loud by this file's own standard: no sweep
/// script, CI job or agent can read it as a pass. What it does not name is the
/// fix — see `docs/TESTING.md` for the `export PATH=…` that supplies a new
/// enough `dart`.
///
/// That is the whole guard, and it fires before `main` runs. This script used
/// to check [Platform.version] against the same floor itself, to name the wrong
/// `dart` and the fix rather than let `package:test` hit a version-solving
/// wall. The check cannot fire while `pubspec.yaml` states a real floor — an
/// SDK below the floor fails to parse the
/// package, and one above it passes the check — so it was dead code promising
/// a message nobody could see, and it is gone. Restoring it would mean moving
/// this script out of the package so an old SDK can still parse it.
///
/// The suite runs on [Platform.resolvedExecutable] — this very VM, the one that
/// got far enough to run this — so `PATH` is never consulted for the run and
/// cannot disagree with what is reported in the banner below.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The path used when the caller names none.
const _defaultPath = 'test/e2e/';

/// Flags the suite always needs. `--concurrency=1` because every test drives
/// real builds, devices and windows; `--tags=e2e` because those are the only
/// tagged files and the unit tests already have Bazel targets.
const _alwaysArgs = ['--tags=e2e', '--concurrency=1'];

/// The usage line printed when `--require-ran` is misused.
const _requireRanUsage =
    'usage: e2e.dart [--require-ran=<substring>]... [<dart test args>]';

/// A misused `--require-ran`: bare, empty, or any other non-`=` shape.
class RequireRanUsage implements Exception {
  /// The usage text the runner prints for this misuse.
  final String usage;

  const RequireRanUsage([this.usage = _requireRanUsage]);

  @override
  String toString() => usage;
}

/// The runner's own arguments, split from the ones `dart test` gets.
///
/// Every `--require-ran=<substring>` is consumed here (repeatable; the `=`
/// form only) and the rest is forwarded to `dart test` verbatim and in order.
({List<String> forwarded, List<String> requireRan}) splitRunnerArgs(
  List<String> args,
) {
  final forwarded = <String>[];
  final requireRan = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--require-ran')) {
      const prefix = '--require-ran=';
      if (!arg.startsWith(prefix) || arg.substring(prefix.length).isEmpty) {
        throw const RequireRanUsage();
      }
      requireRan.add(arg.substring(prefix.length));
    } else {
      forwarded.add(arg);
    }
  }
  return (forwarded: forwarded, requireRan: requireRan);
}

Future<void> main(List<String> args) async {
  final List<String> forwarded;
  final List<String> requireRan;
  try {
    final split = splitRunnerArgs(args);
    forwarded = split.forwarded;
    requireRan = split.requireRan;
  } on RequireRanUsage catch (e) {
    stderr.writeln(e.usage);
    exit(2);
  }
  final packageDir = _packageDir();
  // Forwarded verbatim and in order — splitting flags from positionals would
  // tear `--plain-name occluded` in half, since the value carries no leading
  // dash. The default path is supplied only when the caller named nothing that
  // could be one; when they did, `dart test` resolves it, and when they passed
  // a flag value that merely looks positional it falls back to `test/`, where
  // `--tags=e2e` still selects these files and nothing else.
  final testArgs = [
    'test',
    if (!forwarded.any((a) => !a.startsWith('-'))) _defaultPath,
    ..._alwaysArgs,
    ...forwarded,
  ];

  // `Platform.version` is `<semver> (<channel>) (<date>) on "<os>"`; the
  // banner wants the semver.
  final runner = Platform.version.split(' ').first;
  stderr.writeln('e2e: ${Platform.resolvedExecutable} ($runner)');
  stderr.writeln('e2e: ${packageDir.path}\$ dart ${testArgs.join(' ')}');

  final outcome = await _runSuite(packageDir, testArgs, requireRan);
  outcome.report();
  exit(outcome.ok ? 0 : 1);
}

/// The directory holding `pubspec.yaml`, derived from this script's own
/// location so the runner works from any cwd.
Directory _packageDir() {
  final dir = File(Platform.script.toFilePath()).parent.parent;
  final pubspec = File('${dir.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    _fail(
      'expected ${pubspec.path} to exist — this script has to stay in '
      'tools/dev_tool/tool/.',
    );
  }
  return dir;
}

Future<Outcome> _runSuite(
  Directory packageDir,
  List<String> testArgs,
  List<String> requireRan,
) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    [...testArgs, '--reporter', 'json'],
    workingDirectory: packageDir.path,
  );
  // The runner's own diagnostics — version solving, load errors, a test's own
  // prints — arrive here, and when the JSON stream stops early this is the only
  // place that says why. Relayed line by line rather than with `addStream`,
  // which would bind `stderr` and make this runner's own writes throw
  // `StreamSink is bound to a stream` the moment a test reported anything.
  final outcome = Outcome(requireRan: requireRan);
  await Future.wait([
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(stderr.writeln),
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(outcome.consume),
  ]);
  outcome.runnerExitCode = await process.exitCode;
  return outcome;
}

/// Accumulates the `package:test` JSON event stream into a verdict.
///
/// The contract used here, from `package:test`'s json reporter: every test
/// emits `testStart` then `testDone`; `testDone` carries
/// `result` (`success` / `failure` / `error`), `skipped` (true for both a
/// declaration-time `skip:` and a runtime `markTestSkipped`), and `hidden`
/// (true for the synthetic "loading <file>" entries, which are not tests). A
/// `done` event closes a run that reached its own end — note it reports
/// `success: true` for both of the run-nothing cases, which is exactly why the
/// counts below, and not `done`, decide the verdict.
class Outcome {
  /// Substrings that must have run for this run to count: for each one, some
  /// test whose full name contains it passed, and none containing it skipped
  /// or failed. From `--require-ran=`; empty means no requirement.
  final List<String> requireRan;

  Outcome({Iterable<String> requireRan = const []})
    : requireRan = List<String>.unmodifiable(requireRan);

  final _names = <int, String>{};
  final _errors = <String, List<String>>{};

  /// Why each test skipped, keyed by test id while the run is in flight and
  /// re-keyed by name once it finishes.
  ///
  /// The reporter says this twice and in two shapes, so both are read: a
  /// declaration-time `skip: '<reason>'` arrives on `testStart` as
  /// `test.metadata.skipReason`, and both that and a runtime
  /// `markTestSkipped` arrive as a `print` event carrying
  /// `messageType: "skip"`. Metadata wins where there is one, because the
  /// print prefixes it with `Skip: `.
  final _skipReasons = <int, String>{};
  final _skipReasonByName = <String, String>{};

  /// Tests that executed and reported success. **Not** "tests that ran" — a
  /// test that ran and failed is in [failed], and the two together are
  /// [executed]. The distinction is not cosmetic: reading this list as
  /// "everything that ran" makes a run whose only test failed report itself as
  /// a selection mistake.
  final passed = <String>[];
  final skipped = <String>[];
  final failed = <String>[];

  /// Null when the runner never emitted its terminal `done` event — it died,
  /// or never started, partway through. That is a failure whatever the counts
  /// say, because the counts are then a prefix of an unknown whole.
  bool? runnerVerdict;
  int runnerExitCode = -1;

  void consume(String line) {
    if (!line.startsWith('{')) {
      // Not JSON: the runner is talking to a human — a version-solving wall, a
      // load error. Relay it; the stream is usually about to stop and this text
      // is the only reason given.
      if (line.trim().isNotEmpty) stderr.writeln(line);
      return;
    }
    final Object? decoded;
    try {
      decoded = json.decode(line);
    } on FormatException {
      stderr.writeln(line);
      return;
    }
    if (decoded is! Map<String, dynamic>) return;

    switch (decoded['type']) {
      case 'testStart':
        final test = decoded['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        _names[id] = test['name'] as String;
        final metadata = test['metadata'];
        if (metadata is Map<String, dynamic>) {
          final reason = metadata['skipReason'];
          if (reason is String) _skipReasons[id] = reason;
        }
      case 'testDone':
        if (decoded['hidden'] == true) return;
        final id = decoded['testID'] as int;
        final name = _names[id] ?? '<unnamed>';
        if (decoded['skipped'] == true) {
          skipped.add(name);
          final reason = _skipReasons[id];
          if (reason != null) _skipReasonByName[name] = reason;
          stderr.writeln('  ~ $name');
        } else if (decoded['result'] == 'success') {
          passed.add(name);
          stderr.writeln('  + $name');
        } else {
          failed.add(name);
          stderr.writeln('  ! $name (${decoded['result']})');
        }
      case 'print':
        // A test's own `print` is zone-captured by the runner and delivered
        // here, not on the child's stderr, so it is invisible unless relayed.
        // These are the lines that explain a long silent stretch between two
        // `+`s, which on a suite whose tests take minutes each is most of what
        // there is to watch.
        //
        // A `markTestSkipped` reason arrives only here — there is no metadata
        // for it, because the test was not declared skipped — so it is picked
        // up on the way past.
        final printedFor = decoded['testID'];
        if (decoded['messageType'] == 'skip' && printedFor is int) {
          final said = decoded['message'];
          if (said is String) _skipReasons.putIfAbsent(printedFor, () => said);
        }
        stderr.writeln('    ${decoded['message']}');
      case 'error':
        // What a failure actually *said*. The `testDone` event carries only a
        // verdict, so without this a failing test reduces to its name — less
        // than the default reporter gives.
        final name = _names[decoded['testID'] as int] ?? '<unnamed>';
        _errors
            .putIfAbsent(name, () => [])
            .add(
              '${decoded['error']}\n${decoded['stackTrace']}'.trimRight(),
            );
      case 'done':
        runnerVerdict = decoded['success'] as bool?;
    }
  }

  /// How many tests actually executed, whatever they then reported.
  ///
  /// This — not [passed] — is what says whether the suite *ran*. A failing
  /// test executed just as much as a passing one; only a skip did not.
  int get executed => passed.length + failed.length;

  /// A run counts only when the runner reached its own verdict, nothing failed,
  /// at least one test passed, and every `--require-ran` substring is met.
  ///
  /// That last clause matters: `dart test` exits 0 when every
  /// selected test skipped, so "no failures" alone cannot tell a pass from a
  /// suite that never ran.
  bool get ok =>
      runnerVerdict == true &&
      failed.isEmpty &&
      passed.isNotEmpty &&
      _unmetRequirements.isEmpty;

  /// The `--require-ran` substrings no passing run satisfied: each names tests
  /// that either never matched, or matched only in skips and failures.
  List<String> get _unmetRequirements => [
    for (final required in requireRan)
      if (!_requirementMet(required)) required,
  ];

  /// One substring is met when some test containing it passed and none
  /// containing it skipped or failed. A matching skip poisons the requirement
  /// even beside a matching pass: the suite did not run what was asked.
  bool _requirementMet(String required) =>
      passed.any((name) => name.contains(required)) &&
      !skipped.any((name) => name.contains(required)) &&
      !failed.any((name) => name.contains(required));

  /// Each name followed by whatever it reported, indented under it.
  String _indented(Iterable<String> names) => names
      .map(
        (n) =>
            '  $n\n'
            '${(_errors[n] ?? const <String>[]).map((e) => '${e.split('\n').map((l) => '    $l').join('\n')}\n').join()}',
      )
      .join();

  /// The one count line, always printed.
  String get summary =>
      'e2e: ${passed.length} passed, ${skipped.length} '
      'skipped, ${failed.length} failed (dart test exited $runnerExitCode)';

  /// Why this run is not a pass, or null when it is one — exactly the negation
  /// of [ok], so the two can never disagree.
  ///
  /// Separate from [report] so the verdict can be asserted on: a branch ending
  /// in `exit(1)` would kill the process asserting it.
  ///
  /// Composed of independent sections rather than early returns: a failing run
  /// names every failed test with its error whatever else happened, and an
  /// unmet `--require-ran` adds its own lines instead of hiding those. The
  /// "did anything happen" questions inside [_verdictSection] are asked
  /// against [executed] rather than [passed], because a run whose only test
  /// failed has `passed.isEmpty` — and asking those questions of [passed]
  /// answers "nothing was selected to run … Check the paths, --tags and -n
  /// you passed", with the failure it has just printed sitting directly
  /// above. `1 failed + 2 skipped` reaches the same defect by the other
  /// branch, reporting "all 2 of them skipped".
  String? get diagnosis {
    if (ok) return null;
    final sections = [
      _verdictSection,
      if (failed.isNotEmpty) _failuresSection,
      if (_unmetRequirements.isNotEmpty)
        'required tests did not run as asked:\n'
            '${_unmetRequirements.map(_requirementDiagnosis).join('\n')}',
    ].whereType<String>().join('\n');
    return sections;
  }

  /// The verdict section: why the run as a whole is not a pass. Null when the
  /// failures section carries the run instead — a run with failures names
  /// them, and says nothing else about the verdict.
  String? get _verdictSection {
    if (runnerVerdict == null) {
      return 'the test runner never reported a verdict; it exited '
          '$runnerExitCode partway through. Read its output above — the '
          '$executed test(s) that did run are a prefix of an unknown '
          'whole, and none of this is a pass.';
    }
    if (failed.isNotEmpty) return null;
    if (_unmetRequirements.isNotEmpty) return null;
    if (executed == 0 && skipped.isEmpty) {
      return 'nothing was selected to run (dart test exited '
          '$runnerExitCode). Check the paths, --tags and -n you passed.';
    }
    if (executed == 0) {
      return 'not one test actually ran — all ${skipped.length} of them '
          'skipped. `dart test` exits 0 for this, which is why it needs '
          'saying: this is not a pass, it is a suite that never executed. '
          'The skip reasons are above; on macOS the usual cause is a missing '
          'Screen Recording or Accessibility permission, and off macOS it is '
          'that most of this suite is macOS-only.';
    }
    // The runner declared failure without any test carrying it. A test that
    // throws *after* its own `testDone` — a stray async error, a late
    // teardown — arrives exactly this way: an error event and a failing
    // `done`, with nothing to attribute it to.
    return 'the run failed without a failing test — something threw outside '
        'a test\'s own lifetime:\n${_indented(_errors.keys)}';
  }

  /// Every failed test with what it said.
  String get _failuresSection =>
      '${failed.length} test(s) failed:\n${_indented(failed)}';

  /// Why one `--require-ran` substring is unmet: the matching tests that
  /// skipped (with their reasons) and failed (with what they said), or that
  /// nothing matched at all.
  String _requirementDiagnosis(String required) {
    final matchingSkipped = [
      for (final name in skipped)
        if (name.contains(required)) name,
    ];
    final matchingFailed = [
      for (final name in failed)
        if (name.contains(required)) name,
    ];
    if (matchingSkipped.isEmpty && matchingFailed.isEmpty) {
      return '  --require-ran=$required was not met: '
          'no test name contained "$required".';
    }
    final lines = <String>[
      '  --require-ran=$required was not met: '
          'no test containing "$required" passed '
          'without a skip or failure.',
    ];
    if (matchingFailed.isNotEmpty) {
      lines.add(
        '  ${matchingFailed.length} matching test(s) failed:\n'
        '${_indented(matchingFailed)}',
      );
    }
    for (final name in matchingSkipped) {
      final why = _skipReasonByName[name];
      lines.add('  skipped — $name${why == null ? '' : ' — $why'}');
    }
    return lines.join('\n');
  }

  /// One line per skipped test, each carrying why it skipped.
  ///
  /// The reason is the whole content of a skip. Without it the summary says a
  /// platform's tests did not run and nothing about whether that was a bench
  /// with nothing plugged into it or a detector that had stopped working. The
  /// reasons do appear in the live stream as `Skip:` lines, but on a suite
  /// whose tests take minutes each those are thousands of lines above the
  /// summary, which is the part anyone reads.
  ///
  /// A getter rather than writes inside [report] so it can be asserted on,
  /// for the same reason [diagnosis] is one.
  Iterable<String> get skipReport => skipped.map((name) {
    final why = _skipReasonByName[name];
    return 'e2e: skipped — $name${why == null ? '' : ' — $why'}';
  });

  void report() {
    stderr.writeln('');
    for (final line in skipReport) {
      stderr.writeln(line);
    }
    stderr.writeln(summary);
    final why = diagnosis;
    if (why != null) _fail(why);
  }
}

Never _fail(String message) {
  stderr.writeln('');
  stderr.writeln('e2e: $message');
  exit(1);
}
