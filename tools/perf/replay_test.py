#!/usr/bin/env python3
"""Unit tests for replay.py."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import replay
from replay import (
    DEFAULT_IOS_MNEMONICS,
    aggregate_replays,
    parse_time_l_output,
    replay_all,
    replay_argv,
    replay_env,
    select_spawns,
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
    def test_instructions_and_real(self):
        instructions, real_s = parse_time_l_output(TIME_L_FIXTURE)
        self.assertEqual(instructions, 123456789)
        self.assertAlmostEqual(real_s, 3.21)

    def test_commas_accepted(self):
        instructions, _ = parse_time_l_output("  1,234,567  instructions retired\n")
        self.assertEqual(instructions, 1234567)

    def test_missing_counter_is_none(self):
        instructions, real_s = parse_time_l_output("  3.21 real\n")
        self.assertIsNone(instructions)
        self.assertAlmostEqual(real_s, 3.21)

    def test_empty_is_none(self):
        self.assertEqual(parse_time_l_output(""), (None, None))
        self.assertEqual(parse_time_l_output(None), (None, None))


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
             "real_s": 1.0, "exit_code": 0},
            {"mnemonic": "SwiftCompile", "instructions": 50,
             "real_s": 2.0, "exit_code": 1},
        ]
        by_mnemonic = aggregate_replays(records)
        entry = by_mnemonic["SwiftCompile"]
        self.assertEqual(entry["count"], 2)
        self.assertEqual(entry["failures"], 1)
        self.assertEqual(entry["instructions_missing"], 1)
        self.assertEqual(entry["instructions_total"], 50)
        self.assertAlmostEqual(entry["real_s_total"], 3.0)

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
                stderr = "  7  instructions retired\n  1.5 real\n"

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


if __name__ == "__main__":
    unittest.main()
