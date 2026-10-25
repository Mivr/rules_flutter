/// LLDB debugging for a physical iOS device.
///
/// [IOSDeviceLldb] attaches the debugger to the launched app, issues lldb
/// commands, and finds the app's process id; [LldbStops] consumes lldb's
/// output and resumes the routine breakpoint stops so the app keeps running.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'device.dart';
import 'logging.dart';
import 'temp_dir.dart';
import 'vm_service_discovery.dart';

final _logger = Logger('dev_tool.device');

/// Python script for the JIT page notification breakpoint.
///
/// Matches flutter_tools' `LLDB._pythonScript`. It returns nothing, so lldb
/// stops after running it and [LldbStops] resumes the app.
const _jitBreakpointScript = '''
"""Intercept NOTIFY_DEBUGGER_ABOUT_RX_PAGES and touch the pages."""
base = frame.register["x0"].GetValueAsAddress()
page_len = frame.register["x1"].GetValueAsUnsigned()
data = bytearray(page_len)
data[0:8] = b'IHELPED!'
error = lldb.SBError()
frame.GetThread().GetProcess().WriteMemory(base, data, error)
if not error.Success():
  print(f'Failed to write into {base}[+{page_len}]', error)
  return
''';

/// The last line of every stop lldb reports: `Target 0: (Runner) stopped.`
final _lldbTargetStopped = RegExp(r'^Target \d+: .* stopped\.$');

/// Native/engine logs arrive prefixed with a timestamp and process metadata:
///
///     2020-09-15 19:15:10.931434-0700 Runner[541:226276] Did finish launching.
///
/// Dart `print()` output has no such prefix. Strip it so both read alike —
/// same handling as flutter_tools' `_debuggerLineHandler`.
final _deviceLogPrefix = RegExp(r'^\S* \S* \S*\[[0-9:]*\] (.*)');

String _stripDeviceLogPrefix(String line) =>
    _deviceLogPrefix.firstMatch(line)?.group(1) ?? line;

/// lldb's own prompt/echo and disassembly, as opposed to app output.
///
/// Only unambiguous markers are filtered; anything unrecognised is treated as
/// app output, since losing a real line is worse than showing a noisy one.
bool _isLldbCommandEcho(String line) {
  final t = line.trim();
  if (t.isEmpty) return true;
  if (t.startsWith('(lldb)') ||
      t.startsWith('Breakpoint ') ||
      t.startsWith('Target ') ||
      t == 'DONE' ||
      t.startsWith('Available devices:') ||
      t.startsWith('Enter your Python command')) {
    return true;
  }
  if (t.startsWith('Process ') &&
      (t.contains(' stopped') ||
          t.contains(' resuming') ||
          t.contains(' exited') ||
          t.contains(' launched'))) {
    return true;
  }
  // Disassembly and frame dumps from a breakpoint stop.
  return t.startsWith('* thread #') ||
      t.startsWith('frame #') ||
      t.startsWith('->') ||
      RegExp(r'^0x[0-9a-f]+ <\+\d+>:').hasMatch(t) ||
      RegExp(r'^\d+ location(s)? added to breakpoint').hasMatch(t);
}

/// LLDB debugging for [IOSDevice]: attaching to the app on a physical
/// device, driving the debugger, and resuming its routine stops.
///
/// Split out of [IOSDevice] so the device itself stays under the file size
/// limit; every member here runs against the device it extends.
extension IOSDeviceLldb on IOSDevice {
  /// Attach lldb to the stopped app, set the JIT page breakpoint, and resume.
  ///
  /// Matches flutter_tools LLDB._selectDevice, _setBreakpoint,
  /// _attachToAppProcess, _resumeProcess.
  Future<Process> attachDebugger({
    required IOSDeviceInfo info,
    required int processId,
    required AppLogStream logs,
    required Future<void> consoleDone,
  }) async {
    final lldb = await startHelper('lldb', []);
    lldbProcess = lldb;
    // lldb is a log source, not just a control channel — see [_startLldbOutput].
    final lldbDone = _startLldbOutput(lldb, appLogs: logs);

    // Both sources are now known, so the stream's life can be settled in one
    // place. They are not ordered — devicectl exits when the app terminates,
    // which is exactly when lldb starts reporting why — so the stream outlives
    // whichever ends first.
    logs.closeWhen([consoleDone, lldbDone]);
    await _lldbCommand(lldb, 'device select ${info.udid}');
    final bpOutput = await _lldbCommand(
      lldb,
      r"breakpoint set --func-regex '^NOTIFY_DEBUGGER_ABOUT_RX_PAGES$'",
      waitFor: RegExp(r'Breakpoint (\d+):'),
      returnMatch: true,
    );
    final bpId =
        RegExp(r'Breakpoint (\d+):').firstMatch(bpOutput ?? '')?.group(1) ??
        '1';
    // The script-input lines take [_lldbCommand]'s no-`waitFor` path: lldb
    // reads its stdin in order, and the `device process attach` below waits on
    // its own output, which is what actually orders the sequence. No delay
    // between them is needed; flutter_tools writes these three the same way
    // (`ios/lldb.dart` `_setBreakpoint`).
    await _lldbCommand(
      lldb,
      'breakpoint command add --script-type python $bpId',
    );
    await _lldbCommand(lldb, _jitBreakpointScript);
    await _lldbCommand(lldb, 'DONE');
    // Synchronous, and every breakpoint stop resumed by [LldbStops] rather
    // than by lldb itself. Letting lldb auto-continue the JIT breakpoint loses
    // hits when two threads allocate code at once (llvm/llvm-project#190956):
    // the app then runs a page the debugger never wrote and stops on
    // EXC_BAD_ACCESS (code=50). flutter_tools made the same change for the
    // same reason (af06e99a29, flutter/flutter#190307).
    await _lldbCommand(lldb, 'script lldb.debugger.SetAsync(False)');
    // The whole stop block, so the stop handling below starts after it and
    // never reads the attach's own SIGSTOP as a stop of the running app.
    await _lldbCommand(
      lldb,
      'device process attach --pid $processId',
      waitFor: _lldbTargetStopped,
    );
    throwIfLaunchAbandoned();
    lldbStops = LldbStops(
      from: lldbOutput!.nextCursor,
      lldb: lldb,
      appLogs: logs,
      deviceName: name,
    );
    // A debug app hits the JIT breakpoint as soon as it runs, and lldb in
    // synchronous mode then reports that stop instead of the resume.
    await _lldbCommand(
      lldb,
      'process continue',
      waitFor: RegExp(r'location added to breakpoint|Process \d+ resuming'),
    );
    return lldb;
  }

  /// Start draining [lldb] into [lldbOutput]. Both channels are captured:
  /// lldb reports real failures (a breakpoint that resolved nowhere, a refused
  /// attach) on stderr, and dropping that channel turns an explainable failure
  /// into a 30-second timeout with no reason attached.
  ///
  /// [appLogs], when given, additionally receives everything lldb prints that
  /// is not lldb's own command chatter. Current flutter_tools treats
  /// `devicectl` **and lldb** as one combined log source on CoreDevices under
  /// Xcode 26+ (`ios/devices.dart` `logSources` → `devicectlAndLldb`), because
  /// the debugger carries output the console stream may not.
  ///
  /// Returns when lldb has finished feeding [appLogs] — the caller pairs it
  /// with the console channel's to settle when the shared stream closes.
  Future<void> _startLldbOutput(Process lldb, {AppLogStream? appLogs}) {
    final out = AppLogStream();
    lldbOutput = out;
    final pump = pumpProcessLines(lldb, out, stderrIsError: true);
    out.closeWhen([pump.done]);

    if (appLogs == null) return pump.done;

    // Completed from the bridge's own `onDone`, not from [pump], so the last
    // lines lldb wrote are in [appLogs] before it is reported finished.
    final forwarded = Completer<void>();
    out.lines.listen(
      (line) {
        final stops = lldbStops;
        if (stops != null && stops.lldb == lldb && stops.consume(line)) return;
        if (_isLldbCommandEcho(line.text)) return;
        appLogs.add(_stripDeviceLogPrefix(line.text), isError: line.isError);
      },
      onDone: forwarded.complete,
    );
    return forwarded.future;
  }

  /// Send a command to lldb stdin and optionally wait for expected output.
  /// If [returnMatch] is true, returns the matched line; otherwise returns null.
  Future<String?> _lldbCommand(
    Process lldb,
    String command, {
    RegExp? waitFor,
    bool returnMatch = false,
  }) async {
    throwIfLaunchAbandoned();
    final output = lldbOutput;
    if (output == null) {
      throw StateError(
        'lldb output is not being drained; '
        'call _startLldbOutput before issuing commands.',
      );
    }

    if (waitFor == null) {
      // Fire-and-forget commands (`device select`, the breakpoint script
      // lines) produce no distinctive output to wait on. Yield rather than
      // sleeping a fixed interval: the following command's own wait is what
      // actually orders this sequence, and lldb reads its stdin in order.
      lldb.stdin.writeln(command);
      await Future<void>.delayed(Duration.zero);
      return null;
    }

    // Subscribe before writing so a fast reply cannot land first. The stream
    // replays everything buffered, so only lines from here on can answer: a
    // stop or a breakpoint id lldb printed for an earlier command matches the
    // same pattern and would otherwise be taken for this one's reply.
    final from = output.nextCursor;
    final completer = Completer<String>();
    final sub = output.lines.listen(
      (line) {
        if (line.index < from) return;
        if (!completer.isCompleted && waitFor.hasMatch(line.text)) {
          completer.complete(line.text);
        }
      },
      // lldb exited, or the launch was abandoned and reaped it: no answer is
      // coming, so say so now rather than after the timeout.
      onDone: () {
        if (completer.isCompleted) return;
        completer.completeError(
          launchAbandoned
              ? VmDiscoveryCancelled(name)
              : StateError(
                  'lldb exited before answering "$command".\nlldb said:\n'
                  '${output.read(-40).lines.map((l) => '  ${l.text}').join('\n')}',
                ),
        );
      },
    );

    try {
      lldb.stdin.writeln(command);
      final matched = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError(
          'lldb did not answer "$command" within 30s (waiting for '
          '${waitFor.pattern}).\nlldb said:\n'
          '${output.read(-40).lines.map((l) => '  ${l.text}').join('\n')}',
        ),
      );
      return returnMatch ? matched : null;
    } finally {
      await sub.cancel();
    }
  }

  /// The process id of the app just installed and launched.
  ///
  /// Matched on the install step's `installationURL` and nothing else: an iOS
  /// executable path is `file://…/<uuid>/Runner.app/Runner`, which contains
  /// the installation URL and never the bundle id, so a bundle-id match behind
  /// it would be dead code that made a broken URL match look recoverable.
  Future<int> findAppProcessId(String installationUrl) {
    return withTempDir('flutter_proc_', (jsonDir) async {
      final jsonPath = p.join(jsonDir.path, 'processes.json');

      final result = await runProcess('xcrun', [
        'devicectl',
        'device',
        'info',
        'processes',
        '--device',
        addressedUdid,
        '--json-output',
        jsonPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'devicectl could not list the processes running on '
          '$name, so the launched app cannot be attached to: '
          '${result.stderr}',
        );
      }

      final jsonFile = File(jsonPath);
      if (!jsonFile.existsSync()) {
        throw StateError(
          'devicectl reported the processes on $name but wrote '
          'no JSON to $jsonPath.',
        );
      }

      final Object? decoded;
      try {
        decoded = json.decode(jsonFile.readAsStringSync());
      } on FormatException catch (e) {
        throw StateError(
          'devicectl wrote a process list this could not read '
          '($e), so the launched app cannot be attached to.',
        );
      }
      final processes = decoded is Map<String, dynamic>
          ? (decoded['result']?['runningProcesses'] as List?) ?? const []
          : const [];

      for (final proc in processes) {
        if (proc is! Map) continue;
        final executable = proc['executable'] as String? ?? '';
        final pid = proc['processIdentifier'] as int?;
        if (pid == null) continue;
        if (!executable.contains(installationUrl)) continue;
        // App extensions live *inside* the bundle, so a widget extension's
        // executable contains the installation URL too — and attaching the
        // debugger to one leaves the app itself waiting forever for a
        // debugger that went elsewhere. Upstream hit exactly this:
        // flutter/flutter#183263.
        if (executable.contains('.appex')) continue;
        return pid;
      }

      throw StateError(
        'None of the ${processes.length} process(es) running on $name is the '
        'app installed at $installationUrl. devicectl reported launching it, '
        'so it should be among them; an app that crashed on launch will not '
        'be.',
      );
    });
  }
}

/// What a physical iOS device launch does with each stop lldb reports once the
/// app is running.
///
/// lldb runs synchronously and the JIT breakpoint does not auto-continue (see
/// the launch), so every page notification arrives as a stop. A stop at a
/// breakpoint is routine: it is resumed and not shown. Any other stop is the
/// app itself stopping — an EXC_BAD_ACCESS, an abort — and left alone it hangs
/// the app under the debugger while the VM service goes silent. So it is
/// reported as app output, backtraced, and the debugger detaches and quits,
/// which ends the session the way an exited app does on every other platform.
class LldbStops {
  /// The first line of lldb's output that can belong to a stop of the running
  /// app; everything earlier is the launch's own.
  final int from;

  /// The debugger whose stops [consume] reads; sent `quit` when the app exits.
  final Process lldb;

  /// Where a reported stop's lines go once the debugger detaches.
  final AppLogStream appLogs;

  /// The device name stop and exit reports are attributed to.
  final String deviceName;

  /// Set while the tool is ending the app itself, whose stops are not news.
  bool stopping = false;

  final List<String> _stop = [];
  bool _inStop = false;
  bool _reported = false;

  LldbStops({
    required this.from,
    required this.lldb,
    required this.appLogs,
    required this.deviceName,
  });

  static final _processStopped = RegExp(r'^Process \d+ stopped$');
  static final _processExited = RegExp(r'^Process \d+ exited with status');

  /// Whether [line] was this handler's to deal with, so it is not forwarded as
  /// ordinary output.
  bool consume(AppLogLine line) {
    if (line.index < from) return false;
    final text = line.text;
    if (_reported) {
      // The backtrace and detach that follow a reported stop are the report.
      if (text.trim().isEmpty || text.startsWith('(lldb)')) return true;
      appLogs.add(text, isError: true);
      return true;
    }
    if (!_inStop) {
      if (_processExited.hasMatch(text.trim())) {
        if (stopping) return true;
        // Nothing is left to debug; quitting lldb ends the session.
        _reported = true;
        _logger.info({
          'message': 'ios_app_exited',
          'text': 'The app on $deviceName exited ($text).',
          'device': deviceName,
          'line': text,
        });
        appLogs.add(text);
        lldb.stdin.writeln('quit');
        return true;
      }
      if (!_processStopped.hasMatch(text.trim())) return false;
      _inStop = true;
      _stop.clear();
    }
    _stop.add(text);
    if (!_lldbTargetStopped.hasMatch(text.trim())) return true;

    _inStop = false;
    if (_stop.any((l) => l.contains('stop reason = breakpoint'))) {
      lldb.stdin.writeln('process continue');
      return true;
    }
    if (stopping) return true;

    _reported = true;
    final reason = _stop
        .firstWhere(
          (l) => l.contains('stop reason = '),
          orElse: () => _stop.first,
        )
        .trim();
    _logger.warning({
      'message': 'ios_app_stopped',
      'text':
          'The app stopped under the debugger on $deviceName ($reason). '
          'Reporting its backtrace and detaching.',
      'device': deviceName,
      'reason': reason,
    });
    for (final l in _stop) {
      appLogs.add(l, isError: true);
    }
    lldb.stdin
      ..writeln('thread backtrace all')
      ..writeln('detach')
      ..writeln('quit');
    return true;
  }
}
