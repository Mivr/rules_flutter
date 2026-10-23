#!/usr/bin/env python3
"""Unit tests for replay.py."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import replay
from replay import (
    CHAIN_ORDERING_FAILED,
    CHAIN_SKIP_CACHED,
    CHAIN_SKIP_HOST_TOOL,
    CHAIN_SKIP_NOT_RUN,
    DEFAULT_IOS_MNEMONICS,
    HOST_TOOLS_SKIPPED_KEY,
    aggregate_replays,
    apple_env,
    blocked_input,
    builds_host_tool,
    chain_all,
    is_exec_config,
    order_chain_spawns,
    parse_time_l_output,
    remove_outputs,
    replay_all,
    replay_argv,
    replay_env,
    run_chain_step,
    run_tree,
    select_chain_spawns,
    select_spawns,
    spawn_input_paths,
    spawn_input_strings,
    spawn_output_paths,
)

# macOS /usr/bin/time -l stderr shape (abridged).
TIME_L_FIXTURE = """\
        3.21 real         2.90 user         0.11 sys
   123456789  instructions retired
"""

AOT_SPAWN = {
    "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
    "environmentVariables": [{"name": "FOO", "value": "bar"}],
    "mnemonic": "FlutterAotMacho",
    "exitCode": 0,
    "targetLabel": "//app:app_ios",
}

SWIFT_SPAWN = {
    "commandArgs": ["swiftc", "-c", "AppDelegate.swift"],
    "environmentVariables": [],
    "mnemonic": "SwiftCompile",
    "exitCode": 0,
    "targetLabel": "//app:app_ios",
}


class ParseTimeTest(unittest.TestCase):
    def test_instructions_real_and_cpu(self):
        instructions, real_s, user_s, sys_s = parse_time_l_output(
            TIME_L_FIXTURE)
        self.assertEqual(instructions, 123456789)
        self.assertAlmostEqual(real_s, 3.21)
        self.assertAlmostEqual(user_s, 2.90)
        self.assertAlmostEqual(sys_s, 0.11)

    def test_commas_accepted(self):
        instructions, _, _, _ = parse_time_l_output(
            "  1,234,567  instructions retired\n")
        self.assertEqual(instructions, 1234567)

    def test_missing_counter_is_none(self):
        instructions, real_s, user_s, sys_s = parse_time_l_output(
            "  3.21 real\n")
        self.assertIsNone(instructions)
        self.assertAlmostEqual(real_s, 3.21)
        self.assertIsNone(user_s)
        self.assertIsNone(sys_s)

    def test_empty_is_none(self):
        self.assertEqual(parse_time_l_output(""),
                         (None, None, None, None))
        self.assertEqual(parse_time_l_output(None),
                         (None, None, None, None))

    def test_gnu_time_verbose_cpu(self):
        out = ("\tUser time (seconds): 1.10\n"
               "\tSystem time (seconds): 0.20\n")
        instructions, real_s, user_s, sys_s = parse_time_l_output(out)
        self.assertIsNone(instructions)
        self.assertIsNone(real_s)
        self.assertAlmostEqual(user_s, 1.10)
        self.assertAlmostEqual(sys_s, 0.20)


class SelectTest(unittest.TestCase):
    def test_ios_mnemonics_selected(self):
        replayable, skipped = select_spawns(
            [AOT_SPAWN, SWIFT_SPAWN,
             dict(AOT_SPAWN, mnemonic="Genrule")],
            DEFAULT_IOS_MNEMONICS)
        self.assertEqual(len(replayable), 2)
        self.assertEqual(skipped, {"Genrule": 1})

    def test_failures_and_cache_skipped(self):
        bad = dict(AOT_SPAWN, exitCode=1)
        cached = dict(AOT_SPAWN, cacheHit=True)
        replayable, skipped = select_spawns(
            [bad, cached], DEFAULT_IOS_MNEMONICS)
        self.assertEqual(replayable, [])
        self.assertEqual(sum(skipped.values()), 2)

    def test_kernel_mnemonics_opt_in_not_default(self):
        # Platform-agnostic kernel actions are measured by the Linux bench;
        # replaying them here would blow the job budget.
        for mnemonic in ["FlutterKernelCompile", "FlutterToolKernel",
                         "FlutterAssetBundle"]:
            self.assertNotIn(mnemonic, DEFAULT_IOS_MNEMONICS)
        self.assertIn("FlutterAotMacho", DEFAULT_IOS_MNEMONICS)
        self.assertIn("FlutterIOSNativeAssetFramework",
                      DEFAULT_IOS_MNEMONICS)

    def test_framework_assemble_mnemonics_in_default(self):
        # Every action the App.framework assembly emits
        # (flutter_ios_application.bzl) must replay by default: release
        # uses RetagDylib/CopyAssets, debug uses StubDylib/DebugAssets.
        for mnemonic in ["FlutterAotMacho", "FlutterIOSRetagDylib",
                         "FlutterIOSCopyAssets", "FlutterIOSStubDylib",
                         "FlutterIOSDebugAssets"]:
            self.assertIn(mnemonic, DEFAULT_IOS_MNEMONICS)


class ReplayHelpersTest(unittest.TestCase):
    def test_argv_prefixes_time(self):
        self.assertEqual(replay_argv(AOT_SPAWN)[:2],
                         ["/usr/bin/time", "-l"])
        self.assertEqual(replay_argv(AOT_SPAWN)[2:],
                         ["gen_snapshot", "--macho", "out.dill"])

    def test_env_overlay(self):
        self.assertEqual(replay_env(AOT_SPAWN), {"FOO": "bar"})
        self.assertEqual(replay_env(SWIFT_SPAWN), {})

    def test_replay_all_with_fake_runner(self):
        def fake_runner(spawn):
            return {
                "mnemonic": spawn["mnemonic"],
                "target": spawn["targetLabel"],
                "instructions": 100,
                "real_s": 1.0,
                "exit_code": 0,
                "command": spawn["commandArgs"],
            }

        report = replay_all([AOT_SPAWN, SWIFT_SPAWN],
                            DEFAULT_IOS_MNEMONICS, "/nonexistent",
                            60.0, runner=fake_runner)
        self.assertEqual(report["n_replayed"], 2)
        self.assertEqual(
            report["by_mnemonic"]["FlutterAotMacho"]["instructions_total"],
            100)
        self.assertEqual(len(report["actions"]), 2)

    def test_aggregate_missing_counter(self):
        records = [
            {"mnemonic": "SwiftCompile", "instructions": None,
             "real_s": 1.0, "user_s": 0.8, "sys_s": 0.1, "exit_code": 0},
            {"mnemonic": "SwiftCompile", "instructions": 50,
             "real_s": 2.0, "user_s": None, "sys_s": None, "exit_code": 1,
             "target": "//app:app_ios", "stderr_tail": "clang: error: x"},
        ]
        by_mnemonic = aggregate_replays(records)
        entry = by_mnemonic["SwiftCompile"]
        self.assertEqual(entry["count"], 2)
        self.assertEqual(entry["failures"], 1)
        self.assertEqual(entry["instructions_missing"], 1)
        self.assertEqual(entry["instructions_total"], 50)
        self.assertAlmostEqual(entry["real_s_total"], 3.0)
        self.assertAlmostEqual(entry["user_s_total"], 0.8)
        self.assertAlmostEqual(entry["sys_s_total"], 0.1)
        self.assertEqual(entry["cpu_s_missing"], 1)
        self.assertEqual(entry["sample_failure"], {
            "target": "//app:app_ios", "exit_code": 1,
            "stderr_tail": "clang: error: x"})

    def test_success_has_no_sample_failure(self):
        records = [{"mnemonic": "Lipo", "instructions": 9,
                    "real_s": 0.5, "user_s": 0.4, "sys_s": 0.1,
                    "exit_code": 0}]
        entry = aggregate_replays(records)["Lipo"]
        self.assertEqual(entry["failures"], 0)
        self.assertIsNone(entry["sample_failure"])

    def test_stderr_tail_keeps_last_lines(self):
        import replay as replay_mod
        text = "\n".join("line %d" % n for n in range(30))
        tail = replay_mod.tail_lines(text)
        self.assertEqual(tail.splitlines(),
                         ["line %d" % n for n in range(10, 30)])

    def test_timeout_exit_counts_as_failure(self):
        records = [{"mnemonic": "Lipo", "instructions": None,
                    "real_s": None, "exit_code": "timeout"}]
        self.assertEqual(
            aggregate_replays(records)["Lipo"]["failures"], 1)


class BudgetTest(unittest.TestCase):
    def test_budget_truncates_and_skips(self):
        ticks = [0.0]

        def fake_clock():
            return ticks[0]

        def fake_runner(spawn):
            ticks[0] += 100.0
            return {
                "mnemonic": spawn["mnemonic"],
                "target": spawn.get("targetLabel", ""),
                "instructions": 10,
                "real_s": 1.0,
                "exit_code": 0,
                "command": spawn["commandArgs"],
            }

        report = replay.replay_all(
            [AOT_SPAWN, SWIFT_SPAWN, AOT_SPAWN], DEFAULT_IOS_MNEMONICS,
            "/nonexistent", 60.0, budget_seconds=150.0,
            runner=fake_runner, clock=fake_clock)
        self.assertTrue(report["truncated"])
        self.assertEqual(report["n_replayed"], 2)
        self.assertEqual(report["budget_seconds"], 150.0)
        skipped = report["skipped_by_mnemonic"]
        self.assertEqual(sum(skipped.values()), 1)
        self.assertIn("FlutterAotMacho (budget-exhausted)", skipped)

    def test_no_budget_runs_everything(self):
        report = replay.replay_all(
            [AOT_SPAWN], DEFAULT_IOS_MNEMONICS, "/nonexistent", 60.0,
            budget_seconds=None,
            runner=lambda spawn: {
                "mnemonic": spawn["mnemonic"], "target": "",
                "instructions": 1, "real_s": 0.1, "exit_code": 0,
                "command": []})
        self.assertFalse(report["truncated"])
        self.assertEqual(report["n_replayed"], 1)


class ExecConfigTest(unittest.TestCase):
    def exec_spawn(self, mnemonic="CppCompile"):
        return {
            "commandArgs": [
                "clang", "-c",
                "bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/external/"
                "abseil-cpp+/absl/base/base.cc",
                "-o",
                "bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/external/"
                "abseil-cpp+/absl/base/_objs/base/base.pic.o",
            ],
            "environmentVariables": [],
            "mnemonic": mnemonic,
            "exitCode": 0,
            "targetLabel": "@@abseil-cpp+//absl/base:base",
        }

    def test_exec_config_detected(self):
        self.assertTrue(is_exec_config(self.exec_spawn()))
        self.assertFalse(is_exec_config(AOT_SPAWN))
        self.assertFalse(is_exec_config(SWIFT_SPAWN))

    def test_target_config_bazel_out_not_exec(self):
        spawn = dict(self.exec_spawn(), commandArgs=[
            "clang", "-c",
            "bazel-out/darwin_arm64-opt/bin/app/app.o",
        ])
        self.assertFalse(is_exec_config(spawn))

    def test_inputs_never_trigger(self):
        spawn = dict(AOT_SPAWN, inputs={
            "bazel-out/darwin_arm64-opt-exec-1234/bin/foo": {}})
        self.assertFalse(is_exec_config(spawn))

    def test_exec_config_skipped_by_default(self):
        replayable, skipped = select_spawns(
            [self.exec_spawn(), AOT_SPAWN], DEFAULT_IOS_MNEMONICS)
        self.assertEqual(replayable, [AOT_SPAWN])
        self.assertEqual(skipped, {HOST_TOOLS_SKIPPED_KEY: 1})
        self.assertEqual(HOST_TOOLS_SKIPPED_KEY,
                         "host tools (not replayed)")

    def test_include_exec_config_replays(self):
        replayable, skipped = select_spawns(
            [self.exec_spawn()], DEFAULT_IOS_MNEMONICS,
            include_exec_config=True)
        self.assertEqual(len(replayable), 1)
        self.assertEqual(skipped, {})

    def test_replay_all_buckets_host_tools(self):
        report = replay_all(
            [self.exec_spawn(), self.exec_spawn("CppLink"), AOT_SPAWN],
            DEFAULT_IOS_MNEMONICS, "/nonexistent", 60.0,
            runner=lambda spawn: {
                "mnemonic": spawn["mnemonic"], "target": "",
                "instructions": 1, "real_s": 0.1, "exit_code": 0,
                "command": []})
        self.assertEqual(report["n_replayed"], 1)
        self.assertEqual(report["skipped_by_mnemonic"],
                         {HOST_TOOLS_SKIPPED_KEY: 2})


class AppleEnvTest(unittest.TestCase):
    def apple_spawn(self, platform="iphoneos"):
        return {
            "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
            "environmentVariables": [
                {"name": "APPLE_SDK_PLATFORM", "value": platform},
                {"name": "APPLE_SDK_VERSION_OVERRIDE", "value": "17.2"},
                {"name": "XCODE_VERSION_OVERRIDE", "value": "15.1"},
            ],
            "mnemonic": "FlutterAotMacho",
            "exitCode": 0,
            "targetLabel": "//app:app_ios",
        }

    def xcode_runner(self, calls):
        def run(argv):
            calls.append(argv)

            class Proc:
                returncode = 0
                stdout = ("Xcode.app/Contents/Developer\n"
                          if argv[0] == "xcode-select"
                          else "iPhoneOS.sdk\n")

            return Proc()
        return run

    def test_no_platform_no_probe(self):
        calls = []
        self.assertEqual(
            apple_env(AOT_SPAWN, cache={}, runner=self.xcode_runner(calls)),
            {})
        self.assertEqual(calls, [])

    def test_synthesizes_developer_dir_and_sdkroot(self):
        calls = []
        env = apple_env(self.apple_spawn(), cache={},
                        runner=self.xcode_runner(calls))
        self.assertEqual(env, {
            "DEVELOPER_DIR": "Xcode.app/Contents/Developer",
            "SDKROOT": "iPhoneOS.sdk",
        })
        self.assertEqual(calls[0], ["xcode-select", "-p"])
        self.assertEqual(calls[1],
                         ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])

    def test_platform_lowercased(self):
        calls = []
        apple_env(self.apple_spawn(platform="iPhoneOS"), cache={},
                  runner=self.xcode_runner(calls))
        self.assertIn("iphoneos", calls[1])

    def test_cached_per_platform(self):
        cache = {}
        calls = []
        runner = self.xcode_runner(calls)
        first = apple_env(self.apple_spawn(), cache=cache, runner=runner)
        second = apple_env(self.apple_spawn(), cache=cache, runner=runner)
        self.assertEqual(first, second)
        self.assertEqual(len(calls), 2)
        other = apple_env(self.apple_spawn(platform="iphonesimulator"),
                          cache=cache, runner=runner)
        self.assertEqual(other, first)
        self.assertEqual(len(calls), 4)

    def test_probe_failure_is_fail_open(self):
        def failing(argv):
            class Proc:
                returncode = 1
                stdout = ""

            return Proc()
        self.assertEqual(
            apple_env(self.apple_spawn(), cache={}, runner=failing), {})
        self.assertEqual(
            apple_env(self.apple_spawn(), cache=None, runner=failing), {})

    def test_run_replay_applies_apple_env(self):
        import subprocess as subprocess_mod
        seen = {}
        real_run = subprocess_mod.run

        def fake_run(argv, **kwargs):
            seen.update(kwargs)
            seen["argv"] = argv

            class Proc:
                returncode = 0
                stderr = ("  1.5 real         1.1 user         0.2 sys\n"
                          "  7  instructions retired\n")

            return Proc()

        subprocess_mod.run = fake_run
        try:
            record = replay.run_replay(
                self.apple_spawn(), "/execroot", 600.0,
                apple_cache={},
                xcode_runner=self.xcode_runner([]))
        finally:
            subprocess_mod.run = real_run
        self.assertEqual(record["instructions"], 7)
        self.assertEqual(
            seen["env"]["DEVELOPER_DIR"], "Xcode.app/Contents/Developer")
        self.assertEqual(seen["env"]["SDKROOT"], "iPhoneOS.sdk")
        # Logged Apple overrides still overlay the host environment.
        self.assertEqual(seen["env"]["APPLE_SDK_PLATFORM"], "iphoneos")


class SubprocessArgsTest(unittest.TestCase):
    def test_stdin_closed_and_timeout_passed(self):
        import subprocess as subprocess_mod
        seen = {}
        real_run = subprocess_mod.run

        def fake_run(argv, **kwargs):
            seen.update(kwargs)
            seen["argv"] = argv

            class Proc:
                returncode = 0
                stderr = ("  1.5 real         1.1 user         0.2 sys\n"
                          "  7  instructions retired\n")

            return Proc()

        subprocess_mod.run = fake_run
        try:
            record = replay.run_replay(AOT_SPAWN, "/execroot", 600.0)
        finally:
            subprocess_mod.run = real_run
        self.assertIs(seen.get("stdin"), subprocess_mod.DEVNULL)
        self.assertEqual(seen.get("timeout"), 600.0)
        self.assertEqual(record["instructions"], 7)
        self.assertAlmostEqual(record["real_s"], 1.5)
        self.assertAlmostEqual(record["user_s"], 1.1)
        self.assertAlmostEqual(record["sys_s"], 0.2)
        self.assertIsNone(record["stderr_tail"])

    def test_failed_replay_records_stderr_tail(self):
        import subprocess as subprocess_mod
        real_run = subprocess_mod.run

        def fake_run(argv, **kwargs):
            seen_argv = argv

            class Proc:
                returncode = 1
                stderr = "\n".join(
                    "err %d" % n for n in range(25))

            return Proc()

        subprocess_mod.run = fake_run
        try:
            record = replay.run_replay(AOT_SPAWN, "/execroot", 600.0)
        finally:
            subprocess_mod.run = real_run
        self.assertEqual(record["exit_code"], 1)
        self.assertIsNone(record["instructions"])
        self.assertEqual(record["stderr_tail"].splitlines(),
                         ["err %d" % n for n in range(5, 25)])


TARGET_OUTPUTS = ["bazel-out/darwin_arm64-dbg/bin/app/app.dill"]
EXEC_OUTPUTS = ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/tool/tool"]


def chain_spawn(outputs, argv=None, mnemonic="FlutterKernelCompile"):
    return {
        "commandArgs": list(argv) if argv is not None else ["tool", "a"],
        "environmentVariables": [],
        "listedOutputs": list(outputs),
        "mnemonic": mnemonic,
        "exitCode": 0,
        "targetLabel": "//app:app",
    }


class ChainSelectTest(unittest.TestCase):
    def test_exec_tool_argv_with_target_outputs_runs(self):
        # The kernel compile runs an exec-built frontend server (argv[0]
        # under -exec-) to produce target outputs: it belongs in the
        # chain. The old argv-based classifier dropped it.
        spawn = chain_spawn(
            TARGET_OUTPUTS,
            ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/frontend_server",
             "--target=flutter"])
        self.assertFalse(builds_host_tool(spawn))
        chainable, skipped = select_chain_spawns([spawn])
        self.assertEqual(chainable, [spawn])
        self.assertEqual(skipped, {})

    def test_exec_outputs_are_host_tool_builds(self):
        spawn = chain_spawn(EXEC_OUTPUTS, ["clang", "-c", "x.cc"],
                            mnemonic="CppCompile")
        self.assertTrue(builds_host_tool(spawn))
        chainable, skipped = select_chain_spawns([spawn, chain_spawn(
            TARGET_OUTPUTS)])
        self.assertEqual(len(chainable), 1)
        self.assertEqual(skipped, {CHAIN_SKIP_HOST_TOOL: 1})

    def test_inputs_never_classify(self):
        spawn = chain_spawn(TARGET_OUTPUTS)
        spawn["inputs"] = {
            "bazel-out/darwin_arm64-opt-exec-1234/bin/foo": {}}
        self.assertFalse(builds_host_tool(spawn))

    def test_target_label_never_classifies(self):
        spawn = chain_spawn(TARGET_OUTPUTS)
        spawn["targetLabel"] = "@@abseil-cpp+//absl/base:base"
        self.assertFalse(builds_host_tool(spawn))

    def test_unrecorded_outputs_stay_in_chain(self):
        spawn = dict(AOT_SPAWN)
        self.assertFalse(builds_host_tool(spawn))
        chainable, _ = select_chain_spawns([spawn])
        self.assertEqual(chainable, [spawn])

    def test_cache_failure_and_bare_skipped_per_reason(self):
        cached = dict(chain_spawn(TARGET_OUTPUTS), cacheHit=True)
        failed = dict(chain_spawn(TARGET_OUTPUTS), exitCode=3)
        bare = dict(chain_spawn(TARGET_OUTPUTS), commandArgs=[])
        chainable, skipped = select_chain_spawns(
            [cached, failed, bare, chain_spawn(TARGET_OUTPUTS)])
        self.assertEqual(len(chainable), 1)
        self.assertEqual(skipped[CHAIN_SKIP_CACHED], 1)
        self.assertEqual(skipped["bazel exit 3"], 1)
        self.assertEqual(sum(skipped.values()), 3)


if __name__ == "__main__":
    unittest.main()


class OutputPathsTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        import shutil
        self.tmp = tempfile.mkdtemp(prefix="chain-paths-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_relative_resolves_against_execroot(self):
        paths = spawn_output_paths(chain_spawn(["bazel-out/x/o.dill"]),
                                   self.tmp)
        self.assertEqual(paths, [os.path.join(self.tmp, "bazel-out/x/o.dill")])

    def test_absolute_under_base_kept(self):
        absolute = os.path.join(self.tmp, "bazel-out", "o.dill")
        self.assertEqual(spawn_output_paths(chain_spawn([absolute]),
                                            self.tmp),
                         [absolute])

    def test_outside_base_dropped(self):
        paths = spawn_output_paths(chain_spawn(["/etc/hostname",
                                                "../escape.o"]),
                                   self.tmp)
        self.assertEqual(paths, [])

    def test_remove_outputs_removes_files_dirs_and_links(self):
        import tempfile
        target = os.path.join(self.tmp, "out.bin")
        with open(target, "wb") as fh:
            fh.write(b"stale")
        tree = os.path.join(self.tmp, "tree")
        os.makedirs(os.path.join(tree, "sub"))
        with open(os.path.join(tree, "sub", "f"), "wb") as fh:
            fh.write(b"x")
        link = os.path.join(self.tmp, "link.bin")
        os.symlink(target, link)
        removed = remove_outputs([target, tree, link,
                                  os.path.join(self.tmp, "absent")])
        self.assertEqual(removed, 3)
        self.assertFalse(os.path.lexists(target))
        self.assertFalse(os.path.lexists(tree))
        self.assertFalse(os.path.lexists(link))

    def test_remove_failure_raises(self):
        from unittest import mock
        with mock.patch.object(replay.os, "remove",
                               side_effect=OSError("denied")):
            target = os.path.join(self.tmp, "out.bin")
            with open(target, "wb") as fh:
                fh.write(b"x")
            with self.assertRaises(RuntimeError):
                remove_outputs([target])


class RunTreeTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        import shutil
        self.tmp = tempfile.mkdtemp(prefix="run-tree-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_success_reports_whole_tree_cpu(self):
        import sys
        exit_code, user_s, sys_s, real_s, stderr = run_tree(
            [sys.executable, "-c", "pass"], self.tmp, dict(os.environ), 60.0)
        self.assertEqual(exit_code, 0)
        self.assertGreaterEqual(user_s, 0.0)
        self.assertGreaterEqual(sys_s, 0.0)
        self.assertGreaterEqual(real_s, 0.0)

    def test_failure_keeps_exit_and_stderr(self):
        import sys
        exit_code, _, _, _, stderr = run_tree(
            [sys.executable, "-c",
             "import sys; sys.stderr.write('boom\\n'); sys.exit(2)"],
            self.tmp, dict(os.environ), 60.0)
        self.assertEqual(exit_code, 2)
        self.assertIn("boom", stderr)

    def test_timeout_kills_and_reports(self):
        import sys
        exit_code, user_s, sys_s, _, _ = run_tree(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            self.tmp, dict(os.environ), 0.5)
        self.assertEqual(exit_code, "timeout")
        self.assertGreaterEqual(user_s, 0.0)
        self.assertGreaterEqual(sys_s, 0.0)

    def test_unstartable_reports(self):
        exit_code, _, _, _, stderr = run_tree(
            [os.path.join(self.tmp, "no-such-tool")], self.tmp,
            dict(os.environ), 60.0)
        self.assertEqual(exit_code, "unstartable")
        self.assertTrue(stderr)


class ChainStepTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        import shutil
        self.tmp = tempfile.mkdtemp(prefix="chain-step-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def append_spawn(self, output):
        return {
            "commandArgs": ["sh", "-c", "echo fresh >> \"$CHAIN_OUT\""],
            "environmentVariables": [{"name": "CHAIN_OUT", "value": output}],
            "listedOutputs": [output],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }

    def test_declared_outputs_removed_before_run(self):
        output = os.path.join(self.tmp, "out.txt")
        with open(output, "w", encoding="utf-8") as fh:
            fh.write("stale\n")
        record = run_chain_step(self.append_spawn(output), self.tmp, 60.0)
        self.assertEqual(record["exit_code"], 0)
        self.assertIsNotNone(record["user_s"])
        self.assertIsNotNone(record["sys_s"])
        with open(output, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "fresh\n")

    def test_failed_step_recorded_not_raised(self):
        import sys
        spawn = chain_spawn([os.path.join(self.tmp, "o")],
                            [sys.executable, "-c", "import sys; sys.exit(4)"])
        record = run_chain_step(spawn, self.tmp, 60.0)
        self.assertEqual(record["exit_code"], 4)
        self.assertTrue(replay.is_failure(record))


class ChainAllTest(unittest.TestCase):
    def ok_runner(self, user=0.5, sys_=0.25):
        def run(spawn):
            return {
                "mnemonic": spawn["mnemonic"],
                "target": spawn.get("targetLabel", ""),
                "instructions": None,
                "real_s": 0.75,
                "user_s": user,
                "sys_s": sys_,
                "exit_code": 0,
                "stderr_tail": None,
                "command": [],
            }
        return run

    def test_sol_cpu_sums_step_trees(self):
        report = chain_all(
            [chain_spawn(TARGET_OUTPUTS),
             chain_spawn(TARGET_OUTPUTS, mnemonic="FlutterAotMacho")],
            "/execroot", 60.0, runner=self.ok_runner())
        self.assertEqual(report["n_replayed"], 2)
        self.assertFalse(report["stopped_early"])
        self.assertEqual(report["failed"], [])
        self.assertAlmostEqual(report["sol_cpu_s"], 1.5)
        self.assertAlmostEqual(report["sol_real_s"], 1.5)
        self.assertEqual(report["by_mnemonic"]["FlutterAotMacho"]["count"], 1)

    def test_stops_after_first_failure(self):
        def run(spawn):
            if spawn["mnemonic"] == "Bad":
                return {
                    "mnemonic": "Bad", "target": "", "instructions": None,
                    "real_s": 0.1, "user_s": 0.1, "sys_s": 0.0,
                    "exit_code": 1, "stderr_tail": "clang: error",
                    "command": [],
                }
            return self.ok_runner()(spawn)

        spawns = [chain_spawn(TARGET_OUTPUTS),
                  chain_spawn(TARGET_OUTPUTS, mnemonic="Bad"),
                  chain_spawn(TARGET_OUTPUTS, mnemonic="Later")]
        report = chain_all(spawns, "/execroot", 60.0, runner=run)
        self.assertEqual(report["n_replayed"], 2)
        self.assertTrue(report["stopped_early"])
        self.assertEqual(report["failed"],
                         [{"mnemonic": "Bad", "exit": 1,
                           "stderr_tail": "clang: error"}])
        self.assertEqual(report["skipped"], {CHAIN_SKIP_NOT_RUN: 1})

    def test_real_commands_run_on_linux_without_time_bin(self):
        import sys
        import tempfile
        import shutil
        tmp = tempfile.mkdtemp(prefix="chain-real-")
        self.addCleanup(shutil.rmtree, tmp, True)
        target = os.path.join(tmp, "made.txt")
        spawn = chain_spawn([target],
                            [sys.executable, "-c",
                             "open(%r, 'w').write('made')" % target])
        report = chain_all([spawn], tmp, 60.0)
        self.assertEqual(report["n_replayed"], 1)
        self.assertEqual(report["failed"], [])
        self.assertGreaterEqual(report["sol_cpu_s"], 0.0)
        with open(target, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "made")


class RecordedOutputsTest(unittest.TestCase):
    def spawn(self):
        return {
            "commandArgs": ["tool"],
            "environmentVariables": [],
            "listedOutputs": ["bazel-out/x/o.dill"],
            "actualOutputs": [
                {"path": "bazel-out/x/o.dill",
                 "digest": {"hash": "abc", "sizeBytes": "3"},
                 "isTool": False, "symlinkTargetPath": ""},
                {"path": "bazel-out/x/extra.bin",
                 "digest": {"hash": "def", "sizeBytes": "1"},
                 "isTool": False, "symlinkTargetPath": ""},
                {"path": "bazel-out/x/nodigest.bin", "isTool": False},
            ],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }

    def test_output_strings_include_actual_paths(self):
        import replay as replay_mod
        found = replay_mod.spawn_output_strings(self.spawn())
        self.assertIn("bazel-out/x/o.dill", found)
        self.assertIn("bazel-out/x/extra.bin", found)
        self.assertIn("bazel-out/x/nodigest.bin", found)
        self.assertNotIn("abc", found)

    def test_recorded_digests(self):
        import replay as replay_mod
        self.assertEqual(
            replay_mod.spawn_recorded_digests(self.spawn()),
            {"bazel-out/x/o.dill": "abc",
             "bazel-out/x/extra.bin": "def"})

    def test_recorded_digests_absent(self):
        import replay as replay_mod
        self.assertEqual(
            replay_mod.spawn_recorded_digests(AOT_SPAWN), {})

    def test_exec_actual_outputs_are_host_tool_builds(self):
        import replay as replay_mod
        spawn = {
            "commandArgs": ["tool"],
            "environmentVariables": [],
            "listedOutputs": [],
            "actualOutputs": [
                {"path": EXEC_OUTPUTS[0],
                 "digest": {"hash": "9" * 64}, "isTool": True}],
            "mnemonic": "CppCompile",
            "exitCode": 0,
            "targetLabel": "@@abseil-cpp+//x:y",
        }
        self.assertTrue(replay_mod.builds_host_tool(spawn))
        chainable, skipped = select_chain_spawns([spawn])
        self.assertEqual(chainable, [])
        self.assertEqual(skipped, {CHAIN_SKIP_HOST_TOOL: 1})


class SpawnInputsTest(unittest.TestCase):
    def test_map_keys_are_paths(self):
        spawn = dict(AOT_SPAWN, inputs={
            "bazel-out/x/a.dill": {"path": "bazel-out/x/a.dill"},
            "bazel-out/x/b.h": {}})
        self.assertEqual(sorted(spawn_input_strings(spawn)),
                         ["bazel-out/x/a.dill", "bazel-out/x/b.h"])

    def test_list_and_string_forms(self):
        spawn = dict(AOT_SPAWN, inputs=["a.o", {"path": "b.o"}])
        self.assertEqual(sorted(spawn_input_strings(spawn)), ["a.o", "b.o"])
        spawn = dict(AOT_SPAWN, inputs="only.o")
        self.assertEqual(spawn_input_strings(spawn), ["only.o"])

    def test_missing_inputs_is_empty(self):
        self.assertEqual(spawn_input_strings(AOT_SPAWN), [])
        self.assertEqual(spawn_input_strings(dict(AOT_SPAWN, inputs=None)),
                         [])

    def test_digests_never_collected(self):
        spawn = dict(AOT_SPAWN, inputs={
            "bazel-out/x/a.dill": {"digest": {"hash": "abc"}}})
        found = spawn_input_strings(spawn)
        self.assertIn("bazel-out/x/a.dill", found)
        self.assertNotIn("abc", found)

    def test_input_paths_resolve_and_filter(self):
        import tempfile
        import shutil
        tmp = tempfile.mkdtemp(prefix="chain-inputs-")
        self.addCleanup(shutil.rmtree, tmp, True)
        spawn = dict(AOT_SPAWN, inputs={
            "bazel-out/x/a.o": {}, "/etc/hostname": {}})
        self.assertEqual(spawn_input_paths(spawn, tmp),
                         [os.path.join(tmp, "bazel-out/x/a.o")])


class ChainOrderTest(unittest.TestCase):
    """Dependency order for edges the execution log never records."""

    def setUp(self):
        import tempfile
        import shutil
        self.tmp = tempfile.mkdtemp(prefix="chain-order-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        out = os.path.join(self.tmp, "bazel-out", "x")
        os.makedirs(out)
        self.src = os.path.join(out, "src.txt")
        with open(self.src, "w", encoding="utf-8") as fh:
            fh.write("linked-bytes")
        self.target = os.path.join(out, "linked.bin")
        with open(self.target, "w", encoding="utf-8") as fh:
            fh.write("linked-bytes")
        # A non-spawn file (a symlink the log never links to the link
        # step, like the ios-debug-clean lipobin): no chain step
        # declares it, yet the use step reads through it.
        self.alias = os.path.join(out, "app_lipobin")
        os.symlink(self.target, self.alias)
        self.final = os.path.join(out, "final.bin")

    def rel(self, path):
        return os.path.relpath(path, self.tmp)

    def link_spawn(self):
        return {
            "commandArgs": [
                sys.executable, "-c",
                "open(%r, 'w').write(open(%r).read())"
                % (self.target, self.src)],
            "environmentVariables": [],
            "inputs": {self.rel(self.src): {}},
            "listedOutputs": [self.rel(self.target)],
            "mnemonic": "CppLink",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }

    def use_spawn(self):
        return {
            "commandArgs": [
                sys.executable, "-c",
                "open(%r, 'w').write(open(%r).read())"
                % (self.final, self.alias)],
            "environmentVariables": [],
            "inputs": {self.rel(self.alias): {}},
            "listedOutputs": [self.rel(self.final)],
            "mnemonic": "SwiftStdlibCopy",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }

    def test_consumer_after_producer_despite_log_order(self):
        # The link step's output is moved aside before the chain (as
        # sol.py does), leaving the alias dangling. In log order the
        # use step would read through the dangling link and fail; in
        # dependency order the link step re-creates its output first.
        os.remove(self.target)
        report = chain_all([self.use_spawn(), self.link_spawn()],
                           self.tmp, 60.0)
        self.assertEqual(report["ordering_failed"], None)
        self.assertEqual(report["failed"], [])
        self.assertEqual(report["n_replayed"], 2)
        self.assertEqual([a["mnemonic"] for a in report["actions"]],
                         ["CppLink", "SwiftStdlibCopy"])
        with open(self.final, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "linked-bytes")

    def test_ties_keep_log_order(self):
        first = chain_spawn(["bazel-out/x/a.o"], mnemonic="First")
        second = chain_spawn(["bazel-out/x/b.o"], mnemonic="Second")
        order = order_chain_spawns([first, second], self.tmp)
        self.assertEqual([s["mnemonic"] for s in order],
                         ["First", "Second"])

    def test_cycle_is_ordering_failure(self):
        first = chain_spawn(["bazel-out/x/a.o"], mnemonic="A")
        first["inputs"] = {"bazel-out/x/b.o": {}}
        second = chain_spawn(["bazel-out/x/b.o"], mnemonic="B")
        second["inputs"] = {"bazel-out/x/a.o": {}}
        report = chain_all([first, second], self.tmp, 60.0,
                           runner=lambda spawn: {
                               "mnemonic": spawn["mnemonic"], "target": "",
                               "instructions": None, "real_s": 0.1,
                               "user_s": 0.1, "sys_s": 0.0, "exit_code": 0,
                               "stderr_tail": None, "command": []})
        self.assertEqual(report["n_replayed"], 0)
        self.assertEqual(report["ordering_failed"]["mnemonic"], "A")
        self.assertTrue(
            report["ordering_failed"]["input"].endswith("b.o"))
        self.assertEqual(report["failed"],
                         [{"mnemonic": "A", "exit": CHAIN_ORDERING_FAILED,
                           "stderr_tail": report["failed"][0]
                           ["stderr_tail"]}])
        self.assertIn("b.o", report["failed"][0]["stderr_tail"])
        self.assertEqual(report["skipped"], {CHAIN_SKIP_NOT_RUN: 2})

    def test_own_outputs_never_block(self):
        spawn = chain_spawn(["bazel-out/x/a.o"], mnemonic="Merge")
        spawn["inputs"] = {"bazel-out/x/a.o": {}}
        report = chain_all([spawn], self.tmp, 60.0,
                           runner=lambda s: {
                               "mnemonic": s["mnemonic"], "target": "",
                               "instructions": None, "real_s": 0.1,
                               "user_s": 0.1, "sys_s": 0.0, "exit_code": 0,
                               "stderr_tail": None, "command": []})
        self.assertIsNone(report["ordering_failed"])
        self.assertEqual(report["n_replayed"], 1)

    def test_blocked_input_names_missing(self):
        spawn = chain_spawn(["bazel-out/x/a.o"], mnemonic="Use")
        spawn["inputs"] = {"bazel-out/x/other.o": {}}
        maker = chain_spawn(["bazel-out/x/other.o"], mnemonic="Make")
        moved = {os.path.join(self.tmp, "bazel-out/x/other.o")}
        self.assertTrue(blocked_input(
            spawn, self.tmp, moved, set()).endswith("other.o"))
        self.assertIsNone(blocked_input(spawn, self.tmp, moved, moved))
        self.assertIsNone(blocked_input(maker, self.tmp, set(), set()))
