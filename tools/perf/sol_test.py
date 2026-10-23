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
    bazel_info,
    capture_bazel_output,
    chain_replayed,
    check_under_base,
    collect_runner_info,
    covered_by,
    cpu_seconds,
    describe_chain,
    device_verify_files,
    fallback_verify_files,
    flow_id,
    flow_reason,
    hashes_match,
    kernel_beside,
    load_sol_records,
    measure_process_tree,
    measure_with_time,
    move_aside_chain,
    output_drift,
    path_depth,
    pick_unit,
    read_chain_report,
    rep_sort_key,
    restore_tree,
    run_chain,
    select_sol_spawns,
    sha256_file,
    sim_bundle_roots,
    sim_verify_files,
    snapshot_hashes,
    summarize_flow,
    summarize_sol,
    verify_differences,
)


def kernel_spawn():
    # Runs an exec-built frontend server (argv[0] under -exec-) to
    # produce target-configuration outputs: it belongs in the chain.
    return {
        "commandArgs": ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/"
                        "frontend_server",
                        "--target=flutter", "main.dart"],
        "environmentVariables": [],
        "listedOutputs": ["bazel-out/darwin_arm64-dbg/bin/app/app.dill"],
        "mnemonic": "FlutterKernelCompile",
        "exitCode": 0,
        "targetLabel": "//packages/pkg0:pkg0",
    }


def aot_spawn():
    return {
        "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
        "environmentVariables": [],
        "listedOutputs": ["bazel-out/darwin_arm64-opt/bin/app/App.dill"],
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
        "listedOutputs": ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/"
                          "x/y.o"],
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
    def test_exec_tool_argv_with_target_outputs_is_chain(self):
        # The defect: the old argv-based classifier dropped every action
        # that runs an exec-built tool (the kernel compile above), so the
        # SOL never did the dominant step. Output-based selection keeps it.
        runnable, skipped = select_sol_spawns([kernel_spawn(), aot_spawn()])
        self.assertEqual(len(runnable), 2)
        self.assertEqual(skipped, {})

    def test_host_tool_builds_skipped(self):
        runnable, skipped = select_sol_spawns(
            [exec_spawn(), aot_spawn()])
        self.assertEqual(runnable, [aot_spawn()])
        self.assertEqual(skipped, {"host-tool build": 1})

    def test_cached_failed_and_bare_skipped(self):
        cached = dict(aot_spawn(), cacheHit=True)
        failed = dict(kernel_spawn(), exitCode=1)
        bare = dict(aot_spawn(), commandArgs=[])
        runnable, skipped = select_sol_spawns(
            [cached, failed, bare, aot_spawn()])
        self.assertEqual(runnable, [aot_spawn()])
        self.assertEqual(skipped["cache hit"], 1)
        self.assertEqual(skipped["bazel exit 1"], 1)
        self.assertEqual(sum(skipped.values()), 3)


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


class MoveAsideChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-aside-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_files_moved_and_back(self):
        first = self.write("out/App", b"original")
        second = self.write("out/kernel_blob.bin", b"kernel")
        backup_dir = os.path.join(self.tmp, "backup")
        mapping = move_aside_chain([first, second], backup_dir)
        self.assertFalse(os.path.lexists(first))
        self.assertFalse(os.path.lexists(second))
        # The chain writes fresh files in their place.
        self.write("out/App", b"chain-wrote-this")
        restore_tree(mapping)
        with open(first, "rb") as fh:
            self.assertEqual(fh.read(), b"original")
        with open(second, "rb") as fh:
            self.assertEqual(fh.read(), b"kernel")
        self.assertFalse(os.path.exists(backup_dir + "/0"))

    def test_directory_output_travels_whole(self):
        bundle = self.write("out/App.framework/App", b"original")
        tree = os.path.join(self.tmp, "out", "App.framework")
        mapping = move_aside_chain(
            [tree, os.path.join(tree, "App")],
            os.path.join(self.tmp, "backup"))
        # The directory moved whole; the inner path was not moved twice.
        self.assertEqual(list(mapping), [tree])
        self.assertFalse(os.path.lexists(tree))
        # The step failed before recreating its directory (the round-3
        # crash): restore still brings Bazel's tree back.
        restore_tree(mapping)
        with open(bundle, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_restore_recreates_parent_dirs(self):
        target = self.write("out/dir/App", b"original")
        mapping = move_aside_chain([target],
                                   os.path.join(self.tmp, "backup"))
        # The chain removed the whole directory and failed: moving the
        # file back must recreate its parents, not crash.
        shutil.rmtree(os.path.join(self.tmp, "out"))
        self.assertFalse(os.path.exists(os.path.dirname(target)))
        restore_tree(mapping)
        with open(target, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_missing_output_raises_and_restores_partial(self):
        first = self.write("a/App", b"original")
        with self.assertRaises(RuntimeError):
            move_aside_chain([os.path.join(self.tmp, "a", "App"),
                              os.path.join(self.tmp, "absent")],
                             os.path.join(self.tmp, "backup"))
        with open(first, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_restore_with_missing_backup_raises(self):
        with self.assertRaises(RuntimeError):
            restore_tree({os.path.join(self.tmp, "App"):
                          os.path.join(self.tmp, "gone")})

    def test_covered_by(self):
        self.assertTrue(covered_by("/a/b", ["/a"]))
        self.assertTrue(covered_by("/a", ["/a"]))
        self.assertFalse(covered_by("/a", ["/a/b"]))
        self.assertFalse(covered_by("/ab", ["/a"]))

    def test_path_depth_parents_first(self):
        paths = ["/a/b/c", "/a", "/a/b"]
        self.assertEqual(sorted(paths, key=path_depth),
                         ["/a", "/a/b", "/a/b/c"])


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

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_whole_tree_cpu_without_time_bin(self):
        cost = measure_process_tree(
            [sys.executable, "-c", "pass"], self.tmp)
        self.assertIsNone(cost["instructions"])
        self.assertEqual(cost["returncode"], 0)
        self.assertEqual(cost["method"], "rusage-children")
        self.assertGreaterEqual(cost["user_s"], 0.0)
        self.assertGreaterEqual(cost["sys_s"], 0.0)

    def test_time_bin_flag_ignored_same_method(self):
        cost = measure_with_time(
            [sys.executable, "-c", "pass"], self.tmp,
            time_bin=os.path.join(self.tmp, "absent"))
        self.assertEqual(cost["method"], "rusage-children")
        self.assertGreaterEqual(cost["user_s"], 0.0)

    def test_exit_code_passes_through(self):
        cost = measure_process_tree(
            [sys.executable, "-c", "import sys; sys.exit(3)"], self.tmp)
        self.assertEqual(cost["returncode"], 3)

    def test_grandchild_cpu_included(self):
        child = ("import subprocess, sys\n"
                 "subprocess.run([sys.executable, '-c',\n"
                 " 'import time\\n'\n"
                 " 's=time.perf_counter()\\n'\n"
                 " 'while time.perf_counter()-s<0.5:\\n'\n"
                 " ' pass'])")
        cost = measure_process_tree(
            [sys.executable, "-c", child], self.tmp)
        self.assertEqual(cost["returncode"], 0)
        self.assertGreater(cost["user_s"] + cost["sys_s"], 0.1)


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
                "instructions": None, "real_s": 0.1, "user_s": 0.08,
                "sys_s": 0.02, "exit_code": 0, "stderr_tail": None,
                "command": []}

    def test_chain_runs_executed_only_and_writes_report(self):
        report = run_chain(self.log, self.tmp, self.report, 60.0,
                           runner=self.fake_runner)
        self.assertEqual(report["n_replayed"], 1)
        self.assertFalse(report["stopped_early"])
        self.assertEqual(report["failed"], [])
        self.assertEqual(report["skipped"], {"cache hit": 1})
        self.assertAlmostEqual(report["sol_cpu_s"], 0.1)
        self.assertEqual(chain_replayed(self.report), 1)
        with open(self.report, encoding="utf-8") as fh:
            saved = json.load(fh)
        self.assertEqual(
            saved["by_mnemonic"]["FlutterAotMacho"]["count"], 1)

    def test_kernel_with_exec_tool_argv_is_in_chain(self):
        log = os.path.join(self.tmp, "kernel.json")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(kernel_spawn()) + "\n")
        report = run_chain(log, self.tmp, self.report, 60.0,
                           runner=self.fake_runner)
        self.assertEqual(report["n_replayed"], 1)
        self.assertEqual(report["skipped"], {})

    def test_missing_report_raises(self):
        with self.assertRaises(RuntimeError):
            chain_replayed(os.path.join(self.tmp, "absent.json"))

    def test_read_chain_report_none_when_absent(self):
        self.assertIsNone(read_chain_report(
            os.path.join(self.tmp, "absent.json")))

    def test_main_chain_exit_codes(self):
        ok_log = os.path.join(self.tmp, "ok.json")
        with open(ok_log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(aot_spawn()) + "\n")
        import types
        cmd = types.SimpleNamespace(log=ok_log, execroot=self.tmp,
                                    report=self.report, timeout=60.0)
        with mock.patch("sol.chain_all",
                        return_value={"failed": [], "n_replayed": 1,
                                      "skipped": {}}):
            self.assertEqual(sol.main_chain(cmd), 0)
        with mock.patch("sol.chain_all",
                        return_value={"failed": [{"mnemonic": "X"}],
                                      "n_replayed": 1, "skipped": {}}):
            self.assertEqual(sol.main_chain(cmd), 1)


class ChainRecordTest(unittest.TestCase):
    def report(self):
        return {
            "n_replayed": 2,
            "by_mnemonic": {"Genrule": {"count": 2, "failures": 0,
                                        "user_s_total": 1.0,
                                        "sys_s_total": 0.5,
                                        "cpu_s_missing": 0}},
            "skipped": {"host-tool build": 3},
            "failed": [],
            "sol_cpu_s": 1.5,
            "sol_real_s": 2.0,
        }

    def test_describe_chain_shape(self):
        chain = describe_chain(self.report(), [])
        self.assertEqual(chain["steps"],
                         {"Genrule": {"count": 2, "cpu_s": 1.5}})
        self.assertEqual(chain["skipped"], {"host-tool build": 3})
        self.assertEqual(chain["failed"], [])
        self.assertEqual(chain["verify_differ"], [])
        self.assertEqual(chain["output_drift"], {"n": 0, "paths": []})
        self.assertEqual(chain["sol_cpu_s"], 1.5)
        self.assertEqual(chain["status"], "ok")
        self.assertNotIn("command", json.dumps(chain))

    def test_describe_chain_missing_cpu(self):
        report = self.report()
        report["by_mnemonic"] = {"Genrule": {"count": 1}}
        chain = describe_chain(report, [])
        self.assertEqual(chain["steps"],
                         {"Genrule": {"count": 1, "cpu_s": None}})

    def test_describe_chain_no_report(self):
        chain = describe_chain(None, [{"path": "a", "before": "b",
                                       "after": None}])
        self.assertEqual(chain["status"], "no report")
        self.assertIsNone(chain["sol_cpu_s"])

    def test_verify_differences_relative(self):
        before = {"/exec/a": "1", "/exec/b": "2"}
        after = {"/exec/a": "1", "/exec/b": "3", "/exec/c": "4"}
        differ = verify_differences(before, after, "/exec")
        self.assertEqual(
            differ,
            [{"path": "b", "before": "2", "after": "3"},
             {"path": "c", "before": None, "after": "4"}])

    def test_flow_reason_ok(self):
        self.assertEqual(flow_reason(describe_chain(self.report(), []), 0),
                         "ok")

    def test_flow_reason_names_step_and_files(self):
        report = self.report()
        report["failed"] = [{"mnemonic": "Genrule", "exit": 3,
                             "stderr_tail": "boom"}]
        chain = describe_chain(
            report, [{"path": "b/App", "before": "1", "after": None}])
        reason = flow_reason(chain, 1)
        self.assertIn("Genrule", reason)
        self.assertIn("exit 3", reason)
        self.assertIn("b/App", reason)

    def test_flow_reason_no_report(self):
        chain = describe_chain(None, [])
        self.assertIn("no report", flow_reason(chain, 1))

    def test_rep_sort_key_numeric(self):
        names = ["rep10", "rep2", "rep1", "other"]
        self.assertEqual(sorted(names, key=rep_sort_key),
                         ["rep1", "rep2", "rep10", "other"])


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


CHAIN_OK = {"steps": {"Genrule": {"count": 1, "cpu_s": 0.9}},
            "skipped": {}, "failed": [], "verify_differ": [],
            "output_drift": {"n": 0, "paths": []},
            "sol_cpu_s": 0.9, "status": "ok"}


def sol_record(flow, bazel_cpu, sol_cpu, identical, reason="ok", chain=None):
    return {"flow": flow, "config": "device_release", "scenario": "clean",
            "identical": identical, "reason": reason,
            "bazel": {"cpu_s": bazel_cpu, "real_s": 1.0},
            "sol": (None if sol_cpu is None
                    else {"cpu_s": sol_cpu, "real_s": 0.9}),
            "n_sol_actions": 1,
            "chain": dict(CHAIN_OK) if chain is None else chain}


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

    def test_unit_always_cpu_seconds(self):
        self.assertEqual(pick_unit({}), "cpu_seconds")
        records = [sol_record("f", 1.0, 0.9, True)]
        self.assertEqual(pick_unit({"f": records}), "cpu_seconds")

    def test_medians_and_chain_passthrough(self):
        self.write_records("device_release", "clean", [
            sol_record("ios-release-clean", 3.0, 2.5, True),
            sol_record("ios-release-clean", 1.0, 1.5, True),
            sol_record("ios-release-clean", 2.0, 2.0, True),
        ])
        records = load_sol_records(self.tmp, "device_release", "clean")
        self.assertEqual(len(records), 3)
        flow = summarize_flow(records, "cpu_seconds")
        self.assertEqual(flow["bazel"], 2.0)
        self.assertEqual(flow["sol"], 2.0)
        self.assertTrue(flow["identical"])
        self.assertEqual(flow["reason"], "ok")
        self.assertEqual(flow["chain"], CHAIN_OK)
        self.assertEqual(flow["spread"]["n"], 3)
        self.assertEqual(flow["spread"]["bazel"], [1.0, 3.0])

    def test_mismatch_drops_sol_number(self):
        failed_chain = dict(CHAIN_OK, status="failed",
                            failed=[{"mnemonic": "Genrule", "exit": 1,
                                     "stderr_tail": "boom"}])
        records = [sol_record("f", 1.0, 0.9, True),
                   sol_record("f", 1.1, None, False,
                              reason="step Genrule failed (exit 1)",
                              chain=failed_chain)]
        flow = summarize_flow(records, "cpu_seconds")
        self.assertFalse(flow["identical"])
        self.assertIsNone(flow["sol"])
        self.assertIsNone(flow["spread"]["sol"])
        self.assertEqual(flow["bazel"], 1.1)
        self.assertIn("failed (exit 1)", flow["reason"])
        self.assertEqual(flow["chain"], CHAIN_OK)

    def test_summarize_sol_shape(self):
        self.write_records("device_release", "clean",
                           [sol_record("ios-release-clean", 1.0, 0.9, True)])
        self.write_records("sim_debug", "app_edit",
                           [sol_record("ios-debug-app", 0.5, 0.4, True)])
        summary = summarize_sol(
            self.tmp, {"sha": "0" * 40, "repeats": 1, "target_loc": 20000,
                       "seed": 1})
        self.assertEqual(summary["rules_flutter"], "0" * 40)
        self.assertEqual(summary["unit"], "cpu_seconds")
        self.assertIn("system", summary["runner"])
        self.assertIn("cpu_count", summary["runner"])
        self.assertEqual(summary["flows"]["ios-release-clean"]["bazel"], 1.0)
        self.assertEqual(summary["flows"]["ios-debug-app"]["sol"], 0.4)
        self.assertEqual(summary["flows"]["ios-release-clean"]["chain"],
                         CHAIN_OK)
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


FAKE_BAZEL = """\
#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import sys

out_base = ""
log = ""
mode = ""
for arg in sys.argv[1:]:
    if arg.startswith("--output_base="):
        out_base = arg.split("=", 1)[1]
    elif arg.startswith("--execution_log_json_file="):
        log = arg.split("=", 1)[1]
    elif arg == "info":
        mode = "info"
    elif arg == "cquery":
        mode = "cquery"
    elif arg == "build":
        mode = "build"


def actual(rel, dst):
    with open(dst, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    return [{"path": rel, "digest": {"hash": digest}}]


execroot = os.path.join(out_base, "execroot")
case = os.environ.get("SOL_CASE", "")
fail_config = os.environ.get("SOL_FAIL_CONFIG", "")
rel = "bazel-out/x/App.framework/App"
if mode == "info":
    print(execroot)
elif mode == "cquery":
    if case == "dirfail":
        print("bazel-out/x/App.framework/App")
    else:
        print(rel)
elif mode == "build":
    if fail_config and fail_config in out_base:
        sys.stderr.write("fake bazel: simulated build failure\\n")
        sys.exit(1)
    if case == "dirfail":
        # The verify file lives inside a directory the step declares:
        # the step fails before recreating it (the round-3 restore
        # crash shape).
        fw = os.path.join(execroot, "bazel-out", "x", "App.framework")
        os.makedirs(fw, exist_ok=True)
        dst = os.path.join(fw, "App")
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write("framework-bytes")
        spawn = {
            "commandArgs": ["sh", "-c", "exit 3"],
            "environmentVariables": [],
            "listedOutputs": ["bazel-out/x/App.framework"],
            "actualOutputs": [],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
    else:
        dst = os.path.join(execroot, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.environ["SOL_SRC"]
        if os.environ.get("SOL_FAIL") == "1":
            with open(dst, "w", encoding="utf-8") as fh:
                fh.write("stale-bytes")
            cmd = ["sh", "-c", "exit 3"]
        elif case == "drift":
            shutil.copyfile(src, dst)
            cmd = ["sh", "-c", 'echo drift > "$SOL_DST"']
        else:
            shutil.copyfile(src, dst)
            cmd = ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"']
        spawn = {
            "commandArgs": cmd,
            "environmentVariables": [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": dst},
            ],
            "listedOutputs": [rel],
            "actualOutputs": actual(rel, dst),
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
    with open(log, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(spawn) + "\\n")
else:
    sys.stderr.write("fake bazel: unknown mode\\n")
    sys.exit(1)
"""

STUB_GEN = """\
#!/usr/bin/env python3
import sys
work = sys.argv[sys.argv.index("--workspace") + 1]
with open(work + "/src.txt", "a", encoding="utf-8") as fh:
    fh.write("edit:%s\\n" % sys.argv[1])
"""


class SolEndToEndTest(unittest.TestCase):
    """run -> chain -> summarize without macOS or a real Bazel.

    A fake `bazel` on PATH answers build/info/cquery: the build copies
    a source file to a framework-style output and logs one spawn whose
    command reproduces that copy. The real chain subprocess replays it
    (with per-step output removal and move-aside proof), and summarize
    writes ios-sol.json. --time-bin points nowhere to prove measurement
    never needs it.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-e2e-")
        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        bazel = os.path.join(self.bindir, "bazel")
        with open(bazel, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(FAKE_BAZEL)
        os.chmod(bazel, os.stat(bazel).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.tools = os.path.join(self.tmp, "tools")
        os.makedirs(self.tools)
        with open(os.path.join(self.tools, "gen_monorepo.py"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(STUB_GEN)
        self.pristine = os.path.join(self.tmp, "pristine")
        os.makedirs(self.pristine)
        with open(os.path.join(self.pristine, "src.txt"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("v1\n")
        self.work = os.path.join(self.tmp, "work")
        self.out_base = os.path.join(self.tmp, "out")
        self.results = os.path.join(self.tmp, "results")
        self.env = {"PATH": self.bindir + os.pathsep + os.environ["PATH"],
                    "SOL_SRC": os.path.join(self.work, "src.txt")}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_argv(self, configs):
        argv = ["run", "--tools", self.tools, "--pristine", self.pristine,
                "--work", self.work, "--out-base", self.out_base,
                "--results", self.results, "--rep", "1",
                "--min-clean-actions", "1",
                "--time-bin", os.path.join(self.tmp, "absent")]
        for config in configs:
            argv += ["--config", config]
        return argv

    def summarize_argv(self, out):
        return ["summarize", "--results", self.results, "--sha", "a" * 40,
                "--repeats", "1", "--target-loc", "100", "--seed", "7",
                "--out", out]

    def test_run_chain_summarize_identical(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release", "sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(summary["unit"], "cpu_seconds")
        self.assertEqual(summary["rules_flutter"], "a" * 40)
        expected = ["ios-debug-app", "ios-debug-body", "ios-debug-clean",
                    "ios-release-app", "ios-release-body",
                    "ios-release-clean"]
        self.assertEqual(sorted(summary["flows"]), expected)
        for flow in expected:
            entry = summary["flows"][flow]
            self.assertTrue(entry["identical"], flow)
            self.assertEqual(entry["reason"], "ok", flow)
            self.assertGreaterEqual(entry["bazel"], 0.0, flow)
            self.assertGreaterEqual(entry["sol"], 0.0, flow)
            self.assertEqual(entry["chain"]["steps"]["Genrule"]["count"],
                             1, flow)
            self.assertGreaterEqual(
                entry["chain"]["steps"]["Genrule"]["cpu_s"], 0.0, flow)
            self.assertEqual(entry["chain"]["failed"], [], flow)
            self.assertEqual(entry["chain"]["status"], "ok", flow)
            self.assertEqual(entry["chain"]["output_drift"],
                             {"n": 0, "paths": []}, flow)
        # Bazel's outputs are back in place after the move-aside proof.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\nedit:apply-app-edit"))

    def test_failed_chain_is_not_identical(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_FAIL="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in ["ios-release-clean", "ios-release-app",
                     "ios-release-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("Genrule", entry["reason"], flow)
            self.assertIn("exit 3", entry["reason"], flow)
            self.assertIn("verify differ", entry["reason"], flow)
            self.assertEqual(entry["chain"]["failed"][0]["exit"], 3)
            differ = entry["chain"]["verify_differ"]
            self.assertEqual(len(differ), 1)
            self.assertEqual(differ[0]["path"],
                             "bazel-out/x/App.framework/App")
            self.assertIsNone(differ[0]["after"])

    def test_directory_output_failure_restores_and_continues(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="dirfail")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in ["ios-release-clean", "ios-release-app",
                     "ios-release-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("Genrule", entry["reason"], flow)
            self.assertIn("exit 3", entry["reason"], flow)
        # Bazel's directory is back with its own bytes for the next build.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "framework-bytes")

    def test_drifted_bytes_restore_and_report(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="drift")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-release-clean"]
        self.assertFalse(entry["identical"])
        self.assertIsNone(entry["sol"])
        self.assertIn("verify differ", entry["reason"])
        self.assertEqual(entry["chain"]["output_drift"]["n"], 1)
        self.assertEqual(entry["chain"]["output_drift"]["paths"],
                         ["bazel-out/x/App.framework/App"])
        # Bazel's bytes are back even though the chain wrote different
        # ones, so the next scenario still measures a clean increment.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\n"))

    def test_config_error_keeps_other_config(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_FAIL_CONFIG="sim_debug")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release", "sim_debug"])),
                1)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertTrue(summary["flows"]["ios-release-clean"]["identical"])
        for flow in ["ios-debug-clean", "ios-debug-app", "ios-debug-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("sim_debug", entry["reason"], flow)
            self.assertEqual(entry["chain"]["status"], "error", flow)


if __name__ == "__main__":
    unittest.main()


class OutputDriftTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-drift-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, data):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def spawn(self, rel, digest):
        spawn = {"commandArgs": ["tool"], "environmentVariables": [],
                 "listedOutputs": [rel], "mnemonic": "Genrule",
                 "exitCode": 0, "targetLabel": "//app:app"}
        if digest is not None:
            spawn["actualOutputs"] = [
                {"path": rel, "digest": {"hash": digest}}]
        return spawn

    def test_matching_digest_no_drift(self):
        rel = "bazel-out/x/o.bin"
        self.write(rel, b"bytes")
        digest = sha256_file(os.path.join(self.tmp, rel))
        self.assertEqual(output_drift([self.spawn(rel, digest)], self.tmp),
                         {"n": 0, "paths": []})

    def test_differing_digest_counted(self):
        rel = "bazel-out/x/o.bin"
        self.write(rel, b"chain-wrote-this")
        spawn = self.spawn(rel, "0" * 64)
        self.assertEqual(output_drift([spawn], self.tmp),
                         {"n": 1, "paths": ["bazel-out/x/o.bin"]})

    def test_missing_and_unrecorded_skipped(self):
        spawns = [self.spawn("bazel-out/x/absent.bin", "0" * 64),
                  self.spawn("bazel-out/x/plain.bin", None)]
        self.write("bazel-out/x/plain.bin", b"x")
        self.assertEqual(output_drift(spawns, self.tmp),
                         {"n": 0, "paths": []})

    def test_paths_capped_at_ten(self):
        spawns = []
        for n in range(12):
            rel = "bazel-out/x/o%02d.bin" % n
            self.write(rel, b"drifted")
            spawns.append(self.spawn(rel, "0" * 64))
        drift = output_drift(spawns, self.tmp)
        self.assertEqual(drift["n"], 12)
        self.assertEqual(len(drift["paths"]), 10)
