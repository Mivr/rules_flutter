/// [RunPlan] — what a `run` invocation resolves to before anything happens.
///
/// Resolution is where a run is refused: a mode no device can execute, devices
/// that cannot share one build. Each of those failures is silent if it gets
/// past here, which is why they are checked before a build is spent on them.
import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/bazel.dart' show bazelBuildArgs;
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim.dart';
import 'package:flutter_bazel_dev_tool/device_desktop.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart' show RunCommand;
import 'package:flutter_bazel_dev_tool/run_plan.dart';
import 'package:test/test.dart';

/// The parsed flags a plan is resolved from. Goes through the real parser, so a
/// default that changes there changes here too.
ArgResults parse(List<String> args) =>
    RunCommand.parser.parse(['-t', '//:app', ...args]);

void main() {
  group('assertModeCanRun', () {
    // The failure this guards is silent — an AOT bundle installs and launches
    // on a simulator, returns 0, and renders blank forever — so the test is
    // that the tool refuses rather than that anything reports an error.
    test('refuses opt on an iOS simulator', () {
      expect(
        () => assertModeCanRun('opt', [IOSSimulatorDevice(udid: 'booted')]),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('kernel_blob.bin'), contains('-d ios')),
          ),
        ),
      );
    });

    test('allows dbg on an iOS simulator', () {
      expect(
        () => assertModeCanRun('dbg', [IOSSimulatorDevice(udid: 'booted')]),
        returnsNormally,
      );
    });

    test('allows opt on every other device', () {
      expect(
        () => assertModeCanRun('opt', [MacOSDevice(), IOSDevice()]),
        returnsNormally,
      );
    });

    test('refuses when a simulator is one of several devices', () {
      expect(
        () => assertModeCanRun('opt', [
          MacOSDevice(),
          IOSSimulatorDevice(udid: 'booted'),
        ]),
        throwsA(isA<DevToolException>()),
      );
    });
  });
  // The run's own intent, asked once and answered everywhere the flag governs.
  group('hotReloadOffReason', () {
    test('a run that asked for hot reload has no reason to refuse it', () {
      expect(
        RunPlan.hotReloadOffReason(profileMode: false, hotFlag: true),
        isNull,
      );
    });

    test('--no-hot names itself, and how to undo it', () {
      final reason = RunPlan.hotReloadOffReason(
        profileMode: false,
        hotFlag: false,
      );
      expect(reason, contains('--no-hot'));
      expect(reason, contains('drop'));
    });

    test(
      'profile mode names the build, not the flag it shares with --no-hot',
      () {
        final reason = RunPlan.hotReloadOffReason(
          profileMode: true,
          hotFlag: true,
        );
        expect(reason, contains('AOT'));
        expect(reason, isNot(contains('--no-hot')));
      },
    );

    // `--hot` defaults to true and profile mode never clears it, so a profile
    // run reaches this with both set. AOT is the stronger fact — there is no
    // hot reload to have turned off — so it is the one the user is told.
    test('profile wins over --no-hot when both are given', () {
      expect(
        RunPlan.hotReloadOffReason(profileMode: true, hotFlag: false),
        contains('AOT'),
      );
    });
  });

  group('compilationModeFor', () {
    test('profile is opt', () {
      expect(RunPlan.compilationModeFor(parse(['--profile'])), 'opt');
    });

    test('hot reload is dbg — it needs a JIT kernel', () {
      expect(RunPlan.compilationModeFor(parse([])), 'dbg');
    });

    test('with neither, the user\'s -c stands', () {
      expect(
        RunPlan.compilationModeFor(parse(['--no-hot', '-c', 'fastbuild'])),
        'fastbuild',
      );
    });

    // Null is not `fastbuild`: it means "say nothing to bazel", which is how a
    // workspace's own default config gets to apply. Substituting a mode here
    // would silently override a .bazelrc.
    test('no -c and no mode resolves to nothing, not to a default', () {
      expect(RunPlan.compilationModeFor(parse(['--no-hot'])), isNull);
    });

    // An explicit `-c` that the run cannot honour is refused by name rather
    // than quietly swapped for the mode that works.
    test('an explicit -c that cannot hot reload is refused, not replaced', () {
      expect(
        () => RunPlan.compilationModeFor(parse(['-c', 'opt'])),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('-c opt'), contains('--no-hot'), contains('-c dbg')),
          ),
        ),
      );
    });

    // fastbuild is not a debug build here: every engine select in the rules is
    // `//flutter/private:dbg` -> debug engine, `//conditions:default` ->
    // release, and flutter_compile adds `--enable-asserts` only for `dbg`. So
    // fastbuild takes the release branch and has no JIT kernel to reload into
    // — it contradicts hot reload exactly as `opt` does.
    test('fastbuild cannot hot reload either', () {
      expect(
        () => RunPlan.compilationModeFor(parse(['-c', 'fastbuild'])),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('-c fastbuild'), contains('--no-hot')),
          ),
        ),
      );
    });

    // Only a contradiction is an error. Agreeing with hot reload stays silent.
    test('an explicit -c dbg agrees with hot reload and is not refused', () {
      expect(RunPlan.compilationModeFor(parse(['-c', 'dbg'])), 'dbg');
    });

    // --profile hard-codes `opt` ahead of everything, so a contradicting `-c`
    // is refused by name rather than silently overridden.
    test('an explicit -c that contradicts --profile is refused', () {
      expect(
        () => RunPlan.compilationModeFor(parse(['--profile', '-c', 'dbg'])),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('-c dbg'),
              contains('--profile'),
              contains('-c opt'),
            ),
          ),
        ),
      );
    });

    test('an explicit -c opt agrees with --profile and is not refused', () {
      expect(
        RunPlan.compilationModeFor(parse(['--profile', '-c', 'opt'])),
        'opt',
      );
    });
  });

  group('watchEnabledFor', () {
    test('terminal mode watches, machine mode does not', () {
      expect(RunPlan.watchEnabledFor(parse([]), isMachine: false), isTrue);
      expect(RunPlan.watchEnabledFor(parse([]), isMachine: true), isFalse);
    });

    test('an explicit flag beats the mode default either way', () {
      expect(
        RunPlan.watchEnabledFor(parse(['--watch']), isMachine: true),
        isTrue,
      );
      expect(
        RunPlan.watchEnabledFor(parse(['--no-watch']), isMachine: false),
        isFalse,
      );
    });
  });

  // Profile is `-c opt` plus a flag, and the flag only helps if every bazel
  // invocation that carries the run's `-c` also carries it: they travel in
  // `RunPlan.extraArgs`, so the build, its cquery and the toolchain fetch agree.
  group('modeBuildFlags', () {
    test('a profile run carries the profile flag', () {
      expect(modeBuildFlags(profileMode: true), [
        '--@rules_flutter//flutter:profile=true',
      ]);
    });

    test('every other run carries nothing', () {
      expect(modeBuildFlags(profileMode: false), isEmpty);
    });

    test('the flag reaches the build argv next to -c opt', () {
      final args = bazelBuildArgs(
        '//app',
        compilationMode: 'opt',
        extraArgs: modeBuildFlags(profileMode: true),
      );
      expect(
        args,
        containsAllInOrder(['-c', 'opt', profileBuildFlag + '=true']),
      );
    });

    test('a non-profile build argv does not mention it', () {
      final args = bazelBuildArgs(
        '//app',
        compilationMode: 'opt',
        extraArgs: modeBuildFlags(profileMode: false),
      );
      expect(args.any((a) => a.contains('flutter:profile')), isFalse);
    });
  });

  group('BuildMode.servesVmService', () {
    test('debug and profile serve one, release never does', () {
      expect(BuildMode.debug.servesVmService, isTrue);
      expect(BuildMode.profile.servesVmService, isTrue);
      expect(BuildMode.release.servesVmService, isFalse);
    });

    test('a --profile run expects one, as buildModeFor derives it', () {
      expect(
        buildModeFor(profileMode: true, compilationMode: 'opt').servesVmService,
        isTrue,
      );
      expect(
        buildModeFor(
          profileMode: false,
          compilationMode: 'opt',
        ).servesVmService,
        isFalse,
      );
    });
  });

  // A launch that knows only "AOT or not" cannot tell a profile app, which
  // may serve a VM service, from a release one, which never does. Only `dbg`
  // compiles a JIT kernel, so every other mode is AOT.
  group('buildModeFor', () {
    test('--profile is profile', () {
      expect(
        buildModeFor(profileMode: true, compilationMode: 'opt'),
        BuildMode.profile,
      );
    });

    test('dbg is debug', () {
      expect(
        buildModeFor(profileMode: false, compilationMode: 'dbg'),
        BuildMode.debug,
      );
    });

    test('opt, fastbuild and no -c are release', () {
      for (final mode in ['opt', 'fastbuild', null]) {
        expect(
          buildModeFor(profileMode: false, compilationMode: mode),
          BuildMode.release,
          reason: '-c $mode',
        );
      }
    });
  });

  // The command list is a statement about this run. `flutter_compile_kernel`
  // bakes the record in as a dart define on `-c dbg` native builds only, so a
  // web run advertising `app.buildInfo` could answer nothing but "this app
  // carries no rules_flutter.build_info".
  group('carriesBuildInfoFor', () {
    test('a dbg native run carries it', () {
      expect(
        carriesBuildInfoFor(isWebDevice: false, compilationMode: 'dbg'),
        isTrue,
      );
    });

    test('a web run does not, whatever the mode says', () {
      expect(
        carriesBuildInfoFor(isWebDevice: true, compilationMode: 'dbg'),
        isFalse,
      );
    });

    test('an AOT or unspecified native run does not', () {
      expect(
        carriesBuildInfoFor(isWebDevice: false, compilationMode: 'opt'),
        isFalse,
      );
      expect(
        carriesBuildInfoFor(isWebDevice: false, compilationMode: null),
        isFalse,
      );
    });
  });

  // The `app.*` commands proxy to `ext.rules_flutter.*` over a VM service.
  // Every native run has one; on a browser only the DDC dev loop does, so a
  // `--wasm` or `--profile` run advertising the whole surface could answer
  // every call only with `no VM service for <appId>`.
  group('hasAgentSurfaceFor', () {
    test('a native run has it, DDC or not', () {
      expect(hasAgentSurfaceFor(isWebDevice: false, isDdcWeb: false), isTrue);
    });

    test('the DDC dev loop has it', () {
      expect(hasAgentSurfaceFor(isWebDevice: true, isDdcWeb: true), isTrue);
    });

    test('a web run serving a built bundle does not', () {
      expect(hasAgentSurfaceFor(isWebDevice: true, isDdcWeb: false), isFalse);
    });
  });
}
