#!/usr/bin/env python3
"""Unit tests for sol.py (iOS speed-of-light costs, Linux fixtures)."""

import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sol
from sol import (
    backup_files,
    bazel_info,
    capture_bazel_output,
    chain_replayed,
    check_under_base,
    collect_runner_info,
    cpu_seconds,
    device_verify_files,
    fallback_verify_files,
    flow_id,
    hashes_match,
    kernel_beside,
    load_sol_records,
    measure_with_time,
    pick_unit,
    restore_files,
    run_chain,
    select_sol_spawns,
    sha256_file,
    sim_bundle_roots,
    sim_verify_files,
    snapshot_hashes,
    summarize_flow,
    summarize_sol,
)


def kernel_spawn():
    return {
        "commandArgs": ["frontend_server", "--target=flutter", "main.dart"],
        "environmentVariables": [],
        "mnemonic": "FlutterKernelCompile",
        "exitCode": 0,
        "targetLabel": "//packages/pkg0:pkg0",
    }


def aot_spawn():
    return {
        "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
        "environmentVariables": [],
        "mnemonic": "FlutterAotMacho",
        "exitCode": 0,
        "targetLabel": "//app:app",
    }


def exec_spawn():
    return {
        "commandArgs": [
            "clang", "-c",
            "bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/x/y.cc",
        ],
        "environmentVariables": [],
        "mnemonic": "CppCompile",
        "exitCode": 0,
        "targetLabel": "@@abseil-cpp+//x:y",
    }


class FlowIdTest(unittest.TestCase):
    def test_all_six_flows(self):
        self.assertEqual(flow_id("device_release", "clean"),
                         "ios-release-clean")
        self.assertEqual(flow_id("device_release", "app_edit"),
                         "ios-release-app")
        self.assertEqual(flow_id("device_release", "core_edit"),
                         "ios-release-body")
        self.assertEqual(flow_id("sim_debug", "clean"), "ios-debug-clean")
        self.assertEqual(flow_id("sim_debug", "app_edit"), "ios-debug-app")
        self.assertEqual(flow_id("sim_debug", "core_edit"), "ios-debug-body")

    def test_unknown_raises(self):
        with self.assertRaises(KeyError):
            flow_id("nope", "clean")


class SelectSolTest(unittest.TestCase):
    def test_every_executed_mnemonic_is_chain(self):
        genrule = {
            "commandArgs": ["merge_plists", "a.plist"],
            "environmentVariables": [],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
        runnable, skipped = select_sol_spawns(
            [kernel_spawn(), aot_spawn(), genrule])
        self.assertEqual(len(runnable), 3)
        self.assertEqual(skipped, {})

    def test_host_tools_cached_failed_and_bare_skipped(self):
        cached = dict(aot_spawn(), cacheHit=True)
        failed = dict(kernel_spawn(), exitCode=1)
        bare = dict(aot_spawn(), commandArgs=[])
        runnable, skipped = select_sol_spawns(
            [exec_spawn(), cached, failed, bare, aot_spawn()])
        self.assertEqual(runnable, [aot_spawn()])
        self.assertEqual(skipped["host tools (not replayed)"], 1)
        self.assertEqual(sum(skipped.values()), 4)


class HashTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-hash-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_snapshot_and_match(self):
        first = self.write("a.bin", b"framework-bytes")
        second = self.write("b.bin", b"kernel-bytes")
        before = snapshot_hashes([first, second])
        self.assertTrue(hashes_match(before, snapshot_hashes([first, second])))
        self.assertEqual(len(before), 2)
        self.assertTrue(all(len(v) == 64 for v in before.values()))

    def test_changed_bytes_mismatch(self):
        path = self.write("a.bin", b"v1")
        before = snapshot_hashes([path])
        self.write("a.bin", b"v2")
        self.assertFalse(hashes_match(before, snapshot_hashes([path])))

    def test_missing_file_is_none_and_mismatch(self):
        path = os.path.join(self.tmp, "absent.bin")
        snap = snapshot_hashes([path])
        self.assertIsNone(snap[path])
        self.assertFalse(hashes_match(snap, snapshot_hashes([path])))

    def test_empty_snapshot_never_matches(self):
        self.assertFalse(hashes_match({}, {}))

    def test_cpu_seconds(self):
        self.assertAlmostEqual(
            cpu_seconds({"user_s": 1.1, "sys_s": 0.2}), 1.3)
        self.assertIsNone(cpu_seconds({"user_s": None, "sys_s": 0.2}))
        self.assertIsNone(cpu_seconds({}))

    def test_backup_and_restore(self):
        first = self.write("App", b"original")
        second = self.write("kernel_blob.bin", b"kernel")
        mapping = backup_files([first, second],
                               os.path.join(self.tmp, "backup"))
        self.write("App", b"corrupted")
        os.remove(second)
        restore_files(mapping)
        with open(first, "rb") as fh:
            self.assertEqual(fh.read(), b"original")
        with open(second, "rb") as fh:
            self.assertEqual(fh.read(), b"kernel")

    def test_backup_missing_raises(self):
        with self.assertRaises(RuntimeError):
            backup_files([os.path.join(self.tmp, "absent")],
                         os.path.join(self.tmp, "backup"))


class VerifyFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-verify-")
        self.bundle = os.path.join(self.tmp, "out", "Bench.app")
        fw = os.path.join(self.bundle, "Frameworks", "App.framework")
        assets = os.path.join(fw, "flutter_assets")
        os.makedirs(assets)
        with open(os.path.join(fw, "App"), "wb") as fh:
            fh.write(b"app-binary")
        with open(os.path.join(assets, "kernel_blob.bin"), "wb") as fh:
            fh.write(b"kernel")
        with open(os.path.join(assets, "AssetManifest.json"), "w",
                  encoding="utf-8") as fh:
            fh.write("{}")
        other = os.path.join(self.bundle, "Frameworks", "Other.framework")
        os.makedirs(other)
        with open(os.path.join(other, "Other"), "wb") as fh:
            fh.write(b"decoy")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_device_picks_framework_binary(self):
        listed = [
            "/exec/bazel-out/x/bin/app/Info.plist",
            "/exec/bazel-out/x/bin/app/__app_framework_framework/"
            "App.framework/App",
        ]
        self.assertEqual(device_verify_files(listed), [listed[1]])
        self.assertEqual(device_verify_files(["/exec/other.o"]), [])

    def test_bundle_roots(self):
        bundle = self.bundle
        listed = [bundle, bundle + "/Info.plist",
                  "/exec/bazel-out/x/bin/app/app.dill"]
        self.assertEqual(sim_bundle_roots(listed), [bundle])

    def test_sim_finds_binary_and_kernel(self):
        found = sim_verify_files([self.bundle])
        self.assertEqual(len(found), 2)
        self.assertTrue(found[0].endswith("App.framework/App"))
        self.assertTrue(found[1].endswith("flutter_assets/kernel_blob.bin"))

    def test_fallback_glob(self):
        bazel_out = os.path.join(self.tmp, "bazel-out")
        shutil.copytree(os.path.join(self.tmp, "out"), bazel_out)
        fw_bin = os.path.join(
            bazel_out, "Bench.app", "Frameworks", "App.framework", "App")
        found = fallback_verify_files(self.tmp, "sim_debug")
        self.assertIn(fw_bin, found)
        self.assertTrue(any(p.endswith("kernel_blob.bin") for p in found))
        device = fallback_verify_files(self.tmp, "device_release")
        self.assertEqual(device, [fw_bin])

    def test_kernel_beside(self):
        binary = os.path.join(
            self.bundle, "Frameworks", "App.framework", "App")
        self.assertEqual(kernel_beside([binary]),
                         [os.path.join(
                             self.bundle, "Frameworks", "App.framework",
                             "flutter_assets", "kernel_blob.bin")])
        self.assertEqual(kernel_beside(["/nonexistent/App"]), [])


class MeasureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-measure-")
        self.fake_time = os.path.join(self.tmp, "time")
        with open(self.fake_time, "w", encoding="utf-8",
                  newline="\n") as fh:
            fh.write("#!/bin/sh\n"
                     'if [ "$1" = "-l" ]; then shift; fi\n'
                     'echo "  2.50 real         2.00 user         0.30 sys" >&2\n'
                     'echo "  987,654,321  instructions retired" >&2\n'
                     'exec "$@"\n')
        os.chmod(self.fake_time, os.stat(self.fake_time).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_time_l_parses_instructions_and_cpu(self):
        cost = measure_with_time(
            [sys.executable, "-c", "pass"], self.tmp,
            time_bin=self.fake_time)
        self.assertEqual(cost["instructions"], 987654321)
        self.assertAlmostEqual(cost["user_s"], 2.00)
        self.assertAlmostEqual(cost["sys_s"], 0.30)
        self.assertEqual(cost["returncode"], 0)
        self.assertEqual(cost["method"], "time -l")

    def test_exit_code_passes_through(self):
        cost = measure_with_time(
            [sys.executable, "-c", "import sys; sys.exit(3)"], self.tmp,
            time_bin=self.fake_time)
        self.assertEqual(cost["returncode"], 3)
        self.assertEqual(cost["instructions"], 987654321)

    def test_missing_time_bin_falls_back_to_getrusage(self):
        cost = measure_with_time(
            [sys.executable, "-c", "pass"], self.tmp,
            time_bin=os.path.join(self.tmp, "absent"))
        self.assertIsNone(cost["instructions"])
        self.assertEqual(cost["method"], "getrusage")
        self.assertEqual(cost["returncode"], 0)
        self.assertGreaterEqual(cost["user_s"], 0.0)
        self.assertGreaterEqual(cost["sys_s"], 0.0)

    def test_fallback_records_stderr_tail_on_failure(self):
        cost = measure_with_time(
            [sys.executable, "-c",
             "import sys; sys.stderr.write('boom\\n'); sys.exit(2)"],
            self.tmp, time_bin=os.path.join(self.tmp, "absent"))
        self.assertEqual(cost["returncode"], 2)
        self.assertIn("boom", cost["stderr_tail"])


class ChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-chain-")
        self.log = os.path.join(self.tmp, "execlog.json")
        with open(self.log, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(aot_spawn()) + "\n")
            fh.write(json.dumps(dict(kernel_spawn(), cacheHit=True)) + "\n")
        self.report = os.path.join(self.tmp, "chain.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fake_runner(self, spawn):
        return {"mnemonic": spawn["mnemonic"], "target": "",
                "instructions": 42, "real_s": 0.1, "user_s": 0.08,
                "sys_s": 0.02, "exit_code": 0, "command": []}

    def test_chain_runs_executed_only_and_writes_report(self):
        report = run_chain(self.log, self.tmp, self.report, 60.0,
                           runner=self.fake_runner)
        self.assertEqual(report["n_replayed"], 1)
        self.assertFalse(report["truncated"])
        self.assertEqual(chain_replayed(self.report), 1)
        with open(self.report, encoding="utf-8") as fh:
            saved = json.load(fh)
        self.assertEqual(
            saved["by_mnemonic"]["FlutterAotMacho"]["instructions_total"], 42)

    def test_missing_report_raises(self):
        with self.assertRaises(RuntimeError):
            chain_replayed(os.path.join(self.tmp, "absent.json"))


JVM_WARNING = (
    "OpenJDK 64-Bit Server VM warning: Options -Xverify:none and "
    "-noverify were deprecated in JDK 13 and will likely be removed in "
    "a future release.")


class FakeCapture:
    """Canned stdout for info/cquery, like capture_bazel_output."""

    def __init__(self, execroot, files):
        self.execroot = execroot
        self.files = files

    def __call__(self, argv, cwd=None):
        if "cquery" in argv:
            return "\n".join(self.files) + "\n"
        if "info" in argv:
            return self.execroot + "\n"
        return ""


class QueryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-query-")
        self.out_base = os.path.join(self.tmp, "out")
        self.execroot = os.path.join(self.out_base, "execroot", "ws")
        self.rel = ("bazel-out/x/bin/app/__app_framework_framework/"
                    "App.framework/App")
        abs_path = os.path.join(self.execroot, self.rel)
        os.makedirs(os.path.dirname(abs_path))
        with open(abs_path, "wb") as fh:
            fh.write(b"app")
        self.abs_path = abs_path

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_cquery_relative_paths_resolve_against_execroot(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [self.rel])
        files = sol_mod.query_target_files(
            fake, self.tmp, self.out_base, "//app:__app_framework_framework",
            ["-c", "opt"])
        self.assertEqual(files, [self.abs_path])

    def test_absolute_paths_accepted(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [self.abs_path])
        self.assertEqual(
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", []),
            [self.abs_path])

    def test_cquery_failure_propagates(self):
        import sol as sol_mod

        def fail(argv, cwd=None):
            raise RuntimeError("bazel cquery //app:x failed (exit 1): boom")

        with self.assertRaises(RuntimeError):
            sol_mod.query_target_files(fail, self.tmp, self.out_base,
                                       "//app:x", [])

    def test_warning_line_in_stdout_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [JVM_WARNING, self.rel])
        with self.assertRaises(RuntimeError):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [])

    def test_missing_path_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(
            self.execroot, ["bazel-out/x/absent.o"])
        with self.assertRaisesRegex(RuntimeError, "does not exist"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [])

    def test_path_outside_base_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, ["/etc/hostname"])
        with self.assertRaisesRegex(RuntimeError, "not under output base"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [])

    def test_empty_listing_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [])
        with self.assertRaisesRegex(RuntimeError, "no files"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [])

    def test_info_validates_single_line(self):
        self.assertEqual(
            bazel_info(FakeCapture(self.execroot, []), self.tmp,
                       self.out_base, "execution_root"),
            self.execroot)
        with self.assertRaises(RuntimeError):
            bazel_info(FakeCapture(self.execroot + "\n" + self.execroot, []),
                       self.tmp, self.out_base, "execution_root")

    def test_check_under_base(self):
        self.assertEqual(
            check_under_base(self.abs_path, self.out_base, "test"),
            self.abs_path)
        with self.assertRaises(RuntimeError):
            check_under_base("/elsewhere/x", self.out_base, "test")


class NoisyStderrTest(unittest.TestCase):
    """A JVM warning on stderr must never corrupt parsed Bazel output.

    Runs the real capture (separate pipes) against a fake `bazel` that
    reproduces the dispatch failure: the warning on stderr, paths on
    stdout. With a merged capture the warning becomes a bogus path.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-noisy-")
        self.out_base = os.path.join(self.tmp, "out")
        self.execroot = os.path.join(self.out_base, "execroot", "ws")
        self.rel = "bazel-out/x/bin/app/App.framework/App"
        abs_path = os.path.join(self.execroot, self.rel)
        os.makedirs(os.path.dirname(abs_path))
        with open(abs_path, "wb") as fh:
            fh.write(b"app")
        self.bazel = os.path.join(self.tmp, "bazel")
        with open(self.bazel, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#!/bin/sh\n"
                     "echo '%s' >&2\n"
                     "if [ \"$SOL_BAZEL_FAIL\" = \"1\" ]; then\n"
                     "  echo 'BUILD FAILED: missing input' >&2\n"
                     "  exit 1\n"
                     "fi\n"
                     "for arg in \"$@\"; do\n"
                     "  case \"$arg\" in\n"
                     "    cquery) printf '%%s\\n' \"$SOL_CQUERY_OUT\";;\n"
                     "    info) printf '%%s\\n' \"$SOL_INFO_OUT\";;\n"
                     "  esac\n"
                     "done\n" % JVM_WARNING)
        os.chmod(self.bazel, os.stat(self.bazel).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def swap(self, argv, cwd):
        """capture_bazel_output with the fake script as argv[0]."""
        swapped = [self.bazel if a == "bazel" else a for a in argv]
        return capture_bazel_output(swapped, cwd)

    def test_info_stdout_excludes_warning(self):
        with mock.patch.dict(os.environ, {"SOL_INFO_OUT": self.execroot}):
            out = self.swap(
                ["bazel", "--batch", "--output_base=" + self.out_base,
                 "info", "execution_root"], self.tmp)
        self.assertEqual(out.strip(), self.execroot)
        self.assertNotIn("OpenJDK", out)

    def test_cquery_resolves_despite_warning(self):
        import sol as sol_mod
        with mock.patch.dict(os.environ, {"SOL_INFO_OUT": self.execroot,
                                           "SOL_CQUERY_OUT": self.rel}):
            files = sol_mod.query_target_files(
                self.swap, self.tmp, self.out_base, "//app:x", [])
        self.assertEqual(files, [os.path.join(self.execroot, self.rel)])

    def test_failure_shows_stderr(self):
        with mock.patch.dict(os.environ, {"SOL_BAZEL_FAIL": "1"}):
            with self.assertRaisesRegex(RuntimeError, "BUILD FAILED"):
                self.swap(["bazel", "--batch", "info", "execution_root"],
                          self.tmp)


def sol_record(flow, bazel_instr, sol_instr, identical, bazel_cpu=1.0,
               sol_cpu=0.9):
    return {"flow": flow, "identical": identical,
            "bazel": {"instructions": bazel_instr, "cpu_s": bazel_cpu,
                      "real_s": 1.0},
            "sol": {"instructions": sol_instr, "cpu_s": sol_cpu,
                    "real_s": 0.9}}


class SummarizeSolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-summary-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_records(self, config, scenario, records):
        for rep, record in enumerate(records, start=1):
            rep_dir = os.path.join(self.tmp, "sol", config, scenario,
                                   "rep%d" % rep)
            os.makedirs(rep_dir)
            with open(os.path.join(rep_dir, "record.json"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(json.dumps(record) + "\n")

    def test_unit_instructions_and_medians(self):
        self.write_records("device_release", "clean", [
            sol_record("ios-release-clean", 300, 250, True),
            sol_record("ios-release-clean", 100, 150, True),
            sol_record("ios-release-clean", 200, 200, True),
        ])
        records = load_sol_records(self.tmp, "device_release", "clean")
        self.assertEqual(len(records), 3)
        self.assertEqual(pick_unit({"ios-release-clean": records}),
                         "instructions")
        flow = summarize_flow(records, "instructions")
        self.assertEqual(flow["bazel"], 200)
        self.assertEqual(flow["sol"], 200)
        self.assertTrue(flow["identical"])
        self.assertEqual(flow["spread"]["n"], 3)
        self.assertEqual(flow["spread"]["bazel"], [100, 300])

    def test_missing_instructions_falls_back_to_cpu(self):
        records = [sol_record("f", 100, 90, True),
                   sol_record("f", None, 80, True)]
        self.assertEqual(pick_unit({"f": records}), "cpu_seconds")
        flow = summarize_flow(records, "cpu_seconds")
        self.assertAlmostEqual(flow["bazel"], 1.0)
        self.assertAlmostEqual(flow["sol"], 0.9)

    def test_mismatch_drops_sol_number(self):
        records = [sol_record("f", 100, 90, True),
                   sol_record("f", 110, 95, False)]
        flow = summarize_flow(records, "instructions")
        self.assertFalse(flow["identical"])
        self.assertIsNone(flow["sol"])
        self.assertIsNone(flow["spread"]["sol"])
        self.assertEqual(flow["bazel"], 110)

    def test_summarize_sol_shape(self):
        self.write_records("device_release", "clean",
                           [sol_record("ios-release-clean", 100, 90, True)])
        self.write_records("sim_debug", "app_edit",
                           [sol_record("ios-debug-app", 50, 40, True)])
        summary = summarize_sol(
            self.tmp, {"sha": "0" * 40, "repeats": 1, "target_loc": 20000,
                       "seed": 1})
        self.assertEqual(summary["rules_flutter"], "0" * 40)
        self.assertEqual(summary["unit"], "instructions")
        self.assertIn("system", summary["runner"])
        self.assertIn("cpu_count", summary["runner"])
        self.assertEqual(summary["flows"]["ios-release-clean"]["bazel"], 100)
        self.assertEqual(summary["flows"]["ios-debug-app"]["sol"], 40)
        self.assertEqual(summary["flows"]["ios-debug-clean"],
                         {"error": "missing repeats"})
        self.assertEqual(summary["meta"]["repeats"], 1)

    def test_empty_results(self):
        summary = summarize_sol(
            self.tmp, {"sha": "abc", "repeats": 3, "target_loc": 1,
                       "seed": 1})
        self.assertIn("ios-release-clean", summary["flows"])


class RunnerInfoTest(unittest.TestCase):
    def test_base_keys(self):
        info = collect_runner_info()
        self.assertTrue(info["system"])
        self.assertTrue(info["machine"])
        self.assertIn("cpu_count", info)


if __name__ == "__main__":
    unittest.main()
