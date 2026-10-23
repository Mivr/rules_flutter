#!/usr/bin/env python3
"""Speed-of-light (SOL) cost for the iOS perf bench.

For each bench configuration (``device_release``, ``sim_debug``) and each
scenario (``clean``, ``app_edit``, ``core_edit``) this tool measures two
numbers in the same unit:

- the Bazel cost: the whole ``bazel --batch build`` process tree, timed
  with ``/usr/bin/time -l`` (instructions retired where the VM exposes
  them, otherwise user+sys CPU seconds);
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs) and run by hand in order under the same measurement.

Steps whose outputs did not change for an edit are skipped as a person
would skip them: the execution log records executed spawns only, so
replaying the log replays exactly the work the edit required.

Proof the SOL did the same work: the scenario's final outputs are hashed
before and after the chain (the App.framework binary for
device_release; the app's kernel blob and the App.framework binary for
sim_debug). A scenario whose outputs differ is reported with
``identical`` false and no SOL number. Verify files are backed up before
the chain and restored after, so a chain can never perturb the next
incremental build's action cache.

Subcommands: ``run`` measures repeats, ``chain`` runs one chain (the
measured child process), ``summarize`` writes medians into ios-sol.json.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from execlog import load_spawns  # noqa: E402
from replay import (  # noqa: E402
    TIME_BIN,
    parse_time_l_output,
    replay_all,
    select_spawns,
    tail_lines,
)
from run_rep import (  # noqa: E402
    CONFIG_ORDER,
    CONFIGS,
    DEFAULT_MIN_CLEAN_ACTIONS,
    SCENARIOS,
    apply_edit,
    check_clean_actions,
    make_writable_tree,
    real_run,
    reset_work,
)
from summarize import summarize_values  # noqa: E402

_FLOW_PREFIX = {"device_release": "ios-release", "sim_debug": "ios-debug"}
_FLOW_SUFFIX = {"clean": "clean", "app_edit": "app", "core_edit": "body"}
_EDITS = dict(SCENARIOS)
_CHAIN_REPORT = "chain.json"
_RECORD = "record.json"


def flow_id(config, scenario):
    """ios-sol.json flow id, e.g. device_release+core_edit=ios-release-body."""
    return "%s-%s" % (_FLOW_PREFIX[config], _FLOW_SUFFIX[scenario])


def out_base_of(args, config):
    """Per-config output base: no shared server between configs."""
    return os.path.join(args.out_base, config)


def select_sol_spawns(spawns, include_exec_config=False):
    """Runnable SOL chain: every executed spawn with a command.

    Unlike the instruction-replay allowlist, the SOL chain covers every
    mnemonic Bazel executed (kernel compiles included): it is the whole
    minimal chain, so its outputs must equal Bazel's. Selection itself
    reuses the status filtering (exit code, cache hits, exec-config host
    tools); only the mnemonic filter is "everything executed".
    """
    mnemonics = {s.get("mnemonic", "") for s in spawns if isinstance(s, dict)}
    return select_spawns(spawns, mnemonics,
                         include_exec_config=include_exec_config)


def cpu_seconds(cost):
    """user+sys CPU seconds of a measurement, or None when unreported."""
    if cost.get("user_s") is None or cost.get("sys_s") is None:
        return None
    return cost["user_s"] + cost["sys_s"]


def pick_cost(cost):
    """The comparable numbers kept per repeat (unit is chosen at summary)."""
    return {"instructions": cost.get("instructions"),
            "cpu_s": cpu_seconds(cost),
            "real_s": cost.get("real_s")}


def sha256_file(path):
    """Hex digest of a file, or None when it is missing/unreadable.

    None is not swallowed: callers record it and any mismatch (including
    a missing file) reports identical=false.
    """
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def snapshot_hashes(paths):
    """{path: hex digest} over the verify files, in sorted order."""
    return {path: sha256_file(path) for path in sorted(paths)}


def hashes_match(before, after):
    """Whether two snapshots prove the chain reproduced Bazel's outputs."""
    return (bool(before) and before == after
            and all(v is not None for v in before.values()))


def backup_files(paths, backup_dir):
    """Copies verify files aside; returns {original: backup}."""
    shutil.rmtree(backup_dir, ignore_errors=True)
    os.makedirs(backup_dir, exist_ok=True)
    mapping = {}
    for index, path in enumerate(sorted(paths)):
        dst = os.path.join(backup_dir, "%d%s" % (
            index, os.path.splitext(path)[1]))
        try:
            shutil.copy2(path, dst)
        except OSError as exc:
            raise RuntimeError("sol backup of %s failed (%s)" % (path, exc))
        mapping[path] = dst
    return mapping


def restore_files(mapping):
    """Restores verify files from a backup_files mapping."""
    for path in sorted(mapping):
        try:
            shutil.copy2(mapping[path], path)
        except OSError as exc:
            raise RuntimeError("sol restore of %s failed (%s)" % (path, exc))


def bazel_info(run, work, out_base, key):
    """One `bazel --batch info` value (execroot, bazel-bin, ...)."""
    proc = run(["bazel", "--batch", "--output_base=" + out_base,
                "info", key], cwd=work, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("bazel info %s failed (exit %s)"
                           % (key, proc.returncode))
    return proc.stdout.strip()


def query_target_files(run, work, out_base, target, build_flags):
    """Absolute output paths of a target via `cquery --output=files`."""
    proc = run(["bazel", "--batch", "--output_base=" + out_base,
                "cquery", "--output=files", target] + list(build_flags),
               cwd=work, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("bazel cquery %s failed (exit %s)"
                           % (target, proc.returncode))
    execroot = bazel_info(run, work, out_base, "execution_root")
    files = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            files.append(line if os.path.isabs(line)
                         else os.path.join(execroot, line))
    return files


def device_verify_files(target_files):
    """The App.framework binary among a framework target's outputs."""
    return sorted(p for p in target_files
                  if p.endswith("App.framework/App"))


def sim_bundle_roots(target_files):
    """App bundle roots among an ios_application's listed outputs."""
    roots = set()
    for path in target_files:
        if os.path.isdir(path) or path.endswith(".app"):
            roots.add(path)
        elif ".app/" in path:
            roots.add(path.split(".app/")[0] + ".app")
    return sorted(roots)


def find_under(root, wanted):
    """Absolute paths of files named in wanted under root, sorted."""
    found = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name in wanted:
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def sim_verify_files(bundles):
    """Kernel blob plus App.framework binary inside app bundles."""
    verify = []
    for bundle in bundles:
        for path in find_under(bundle, ("App", "kernel_blob.bin")):
            if "App.framework" in path:
                verify.append(path)
    return sorted(verify)


def glob_framework_binaries(bazel_out):
    """Fallback discovery: every App.framework/App under bazel-out."""
    found = []
    for dirpath, dirnames, filenames in os.walk(bazel_out):
        if os.path.basename(dirpath) == "App.framework" and "App" in filenames:
            found.append(os.path.join(dirpath, "App"))
            del dirnames[:]
    return sorted(found)


def kernel_beside(framework_binaries):
    """kernel_blob.bin files sitting next to framework binaries."""
    blobs = []
    for binary in framework_binaries:
        blob = os.path.join(os.path.dirname(binary), "flutter_assets",
                            "kernel_blob.bin")
        if os.path.isfile(blob):
            blobs.append(blob)
    return sorted(blobs)


def fallback_verify_files(execroot, config):
    """Verify files by glob when cquery lists nothing usable."""
    binaries = glob_framework_binaries(os.path.join(execroot, "bazel-out"))
    if config == "device_release":
        return binaries
    return sorted(binaries + kernel_beside(binaries))


def verify_paths_for_config(run, work, out_base, config):
    """Final-output files whose hashes prove the SOL chain's work."""
    spec = CONFIGS[config]
    listed = query_target_files(run, work, out_base, spec["target"],
                                spec["build_flags"])
    if config == "device_release":
        found = device_verify_files(listed)
    else:
        found = sim_verify_files(sim_bundle_roots(listed))
    if not found:
        execroot = bazel_info(run, work, out_base, "execution_root")
        found = fallback_verify_files(execroot, config)
    if not found:
        raise RuntimeError("sol found no verify files for %s" % config)
    return found


def measure_with_time(argv, cwd, time_bin=TIME_BIN):
    """Times argv's whole process tree with time -l.

    Falls back to getrusage (direct children only) where time_bin is
    absent, which is the Linux CI case; SOL mode itself runs on macOS
    where /usr/bin/time always exists.
    """
    if time_bin is None or not os.path.isfile(time_bin):
        return measure_with_getrusage(argv, cwd)
    proc = subprocess.run(
        [time_bin, "-l"] + list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    instructions, real_s, user_s, sys_s = parse_time_l_output(proc.stderr)
    return {"instructions": instructions, "real_s": real_s,
            "user_s": user_s, "sys_s": sys_s,
            "returncode": proc.returncode, "method": "time -l"}


def measure_with_getrusage(argv, cwd):
    """Fallback measurement: user+sys CPU of waited-for children."""
    import resource
    start = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.run(
        list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    record = {"instructions": None, "real_s": time.monotonic() - start,
              "user_s": after.ru_utime - before.ru_utime,
              "sys_s": after.ru_stime - before.ru_stime,
              "returncode": proc.returncode, "method": "getrusage"}
    if proc.returncode != 0:
        record["stderr_tail"] = tail_lines(proc.stderr)
    return record


def bazel_batch_build(args, config, log_path):
    """Builds one scenario with `bazel --batch`, measured as one unit."""
    spec = CONFIGS[config]
    argv = (["bazel", "--batch", "--output_base=" + out_base_of(args, config),
             "build"] + list(spec["build_flags"]) + [spec["target"],
             "--execution_log_json_file=" + log_path,
             "--materialize_param_files"])
    cost = args.measure(argv, args.work)
    if cost["returncode"] != 0:
        raise RuntimeError("bazel --batch build %s failed (exit %s)"
                           % (spec["target"], cost["returncode"]))
    return cost


def run_chain(log_path, execroot, report_path, timeout, runner=None):
    """Runs an execution log's SOL chain in order; writes its report."""
    spawns = load_spawns(log_path)
    mnemonics = {s.get("mnemonic", "") for s in spawns if isinstance(s, dict)}
    report = replay_all(spawns, mnemonics, execroot, timeout,
                        budget_seconds=None, runner=runner)
    with open(report_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("replayed=%d skipped=%s" % (report["n_replayed"],
                                      report["skipped_by_mnemonic"]))
    return report


def measure_sol_chain(args, log_path, execroot, report_path):
    """Runs the chain subcommand as the measured child process."""
    argv = [sys.executable, os.path.abspath(__file__), "chain",
            "--log", log_path, "--execroot", execroot,
            "--report", report_path, "--timeout", str(args.timeout)]
    cost = args.measure(argv, args.work)
    if cost["returncode"] != 0:
        raise RuntimeError("sol chain driver failed (exit %s)"
                           % cost["returncode"])
    return cost


def chain_replayed(report_path):
    """Replayed-action count from a chain report (loud when missing)."""
    try:
        with open(report_path, encoding="utf-8") as fh:
            return json.load(fh).get("n_replayed", 0)
    except (OSError, ValueError) as exc:
        raise RuntimeError("sol chain report %s unreadable (%s)"
                           % (report_path, exc))


def run_sol_scenario(args, config, scenario):
    """Builds one scenario, replays its SOL chain, proves the outputs."""
    spec = CONFIGS[config]
    edit = _EDITS[scenario]
    if edit is not None:
        apply_edit(args.run, args.tools, args.work, edit)
    log_path = os.path.join(args.work, "execlog-sol-%s.json" % scenario)
    bazel_cost = bazel_batch_build(args, config, log_path)
    if scenario == "clean":
        check_clean_actions(log_path, spec["target"],
                            args.min_clean_actions)
    out_base = out_base_of(args, config)
    execroot = bazel_info(args.run, args.work, out_base, "execution_root")
    bazel_out = os.path.join(execroot, "bazel-out")
    if os.path.isdir(bazel_out):
        make_writable_tree(bazel_out)
    verify = verify_paths_for_config(args.run, args.work, out_base, config)
    before = snapshot_hashes(verify)
    backup = backup_files(verify, os.path.join(args.work,
                                               "sol-backup-" + scenario))
    record_dir = os.path.join(args.results, "sol", config, scenario,
                              "rep%d" % args.rep)
    os.makedirs(record_dir, exist_ok=True)
    sol_cost = measure_sol_chain(args, log_path, execroot,
                                 os.path.join(record_dir, _CHAIN_REPORT))
    after = snapshot_hashes(verify)
    restore_files(backup)
    record = {"flow": flow_id(config, scenario), "config": config,
              "scenario": scenario, "bazel": pick_cost(bazel_cost),
              "sol": pick_cost(sol_cost),
              "identical": hashes_match(before, after),
              "n_sol_actions": chain_replayed(
                  os.path.join(record_dir, _CHAIN_REPORT)),
              "verify": {"before": before, "after": after}}
    with open(os.path.join(record_dir, _RECORD), "w", encoding="utf-8",
              newline="\n") as fh:
        fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def run_sol_rep(args, rep, configs):
    """One repeat: fresh workspace per config, cumulative edits per config."""
    args.rep = rep
    records = {}
    for config in configs:
        reset_work(args.pristine, args.work)
        shutil.rmtree(out_base_of(args, config), ignore_errors=True)
        flows = {}
        for scenario, _ in SCENARIOS:
            flows[scenario] = run_sol_scenario(args, config, scenario)
        records[config] = flows
    return records


def load_sol_records(results_dir, config, scenario):
    """Per-repeat record dicts for one config and scenario."""
    scenario_dir = os.path.join(results_dir, "sol", config, scenario)
    records = []
    if not os.path.isdir(scenario_dir):
        return records
    for rep in sorted(os.listdir(scenario_dir)):
        path = os.path.join(scenario_dir, rep, _RECORD)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            records.append(json.load(fh))
    return records


def pick_unit(collected):
    """One unit for the artifact: instructions iff every repeat has them."""
    for records in collected.values():
        for record in records:
            for key in ("bazel", "sol"):
                if record[key].get("instructions") is None:
                    return "cpu_seconds"
    return "instructions"


def summarize_flow(records, unit):
    """Median costs over repeats; no SOL number unless all repeats match."""
    key = "instructions" if unit == "instructions" else "cpu_s"
    identical = all(record["identical"] for record in records)
    bazel = summarize_values([record["bazel"][key] for record in records
                              if record["bazel"][key] is not None])
    sol = summarize_values([record["sol"][key] for record in records
                            if record["sol"][key] is not None])
    return {"bazel": bazel["median"],
            "sol": sol["median"] if identical else None,
            "identical": identical,
            "spread": {"n": len(records),
                       "bazel": [bazel["min"], bazel["max"]],
                       "sol": [sol["min"], sol["max"]] if identical else None}}


def collect_runner_info():
    """Runner fingerprint; the Xcode probe fails open (Linux CI)."""
    info = {"system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "cpu_count": os.cpu_count()}
    try:
        proc = subprocess.run(
            ["xcodebuild", "-version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=60,
            check=False,
            text=True,
        )
    except (OSError, subprocess.SubprocessError):
        return info
    if proc.returncode == 0 and proc.stdout.strip():
        info["xcode"] = proc.stdout.strip().splitlines()[0]
    return info


def summarize_sol(results_dir, meta):
    """ios-sol.json dict: medians per flow in one unit, proof flags."""
    collected = {}
    for config in CONFIG_ORDER:
        for scenario, _ in SCENARIOS:
            records = load_sol_records(results_dir, config, scenario)
            if records:
                collected[flow_id(config, scenario)] = records
    unit = pick_unit(collected)
    flows = {}
    for config in CONFIG_ORDER:
        for scenario, _ in SCENARIOS:
            flow = flow_id(config, scenario)
            if flow in collected:
                flows[flow] = summarize_flow(collected[flow], unit)
            else:
                flows[flow] = {"error": "missing repeats"}
    return {"rules_flutter": meta["sha"], "unit": unit,
            "runner": collect_runner_info(), "flows": flows,
            "meta": {"repeats": meta["repeats"],
                     "target_loc": meta["target_loc"], "seed": meta["seed"]}}


def main_run(cmd):
    cmd.run = real_run
    cmd.measure = lambda argv, cwd: measure_with_time(
        argv, cwd, cmd.time_bin)
    configs = list(cmd.config) if cmd.config else list(CONFIG_ORDER)
    unknown = [c for c in configs if c not in CONFIGS]
    if unknown:
        raise ValueError("unknown config(s): %s" % ", ".join(unknown))
    records = run_sol_rep(cmd, cmd.rep, configs)
    for config, flows in records.items():
        for scenario, record in flows.items():
            print("flow=%s identical=%s n_sol_actions=%d"
                  % (record["flow"], record["identical"],
                     record["n_sol_actions"]))
    return 0


def main_chain(cmd):
    run_chain(cmd.log, cmd.execroot, cmd.report, cmd.timeout)
    return 0


def main_summarize(cmd):
    meta = {"sha": cmd.sha, "repeats": cmd.repeats,
            "target_loc": cmd.target_loc, "seed": cmd.seed}
    summary = summarize_sol(cmd.results, meta)
    with open(cmd.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    for flow in sorted(summary["flows"]):
        entry = summary["flows"][flow]
        if "error" in entry:
            print("flow=%s error=%s" % (flow, entry["error"]))
            continue
        print("flow=%s unit=%s bazel=%s sol=%s identical=%s" % (
            flow, summary["unit"], entry["bazel"], entry["sol"],
            entry["identical"]))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        description="Measure iOS speed-of-light costs (see module docstring).")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="measure one repeat over configs")
    run.add_argument("--tools", required=True)
    run.add_argument("--pristine", required=True)
    run.add_argument("--work", required=True,
                     help="scratch workspace dir (reset per config)")
    run.add_argument("--out-base", required=True,
                     help="output base root; per-config base is <root>/<config>")
    run.add_argument("--results", required=True)
    run.add_argument("--rep", type=int, required=True)
    run.add_argument("--config", action="append", default=[],
                     choices=sorted(CONFIGS),
                     help="repeatable; default is all configs in order")
    run.add_argument("--timeout", type=float, default=1800.0,
                     help="per-action SOL replay timeout in seconds")
    run.add_argument("--min-clean-actions", type=int,
                     default=DEFAULT_MIN_CLEAN_ACTIONS,
                     help="clean builds executing fewer actions fail")
    run.add_argument("--time-bin", default=TIME_BIN,
                     help="time binary for whole-tree measurement")
    chain = sub.add_parser("chain", help="run one SOL chain (measured child)")
    chain.add_argument("--log", required=True, help="execution log path")
    chain.add_argument("--execroot", required=True,
                       help="build execroot to replay in")
    chain.add_argument("--report", required=True, help="chain report path")
    chain.add_argument("--timeout", type=float, default=1800.0)
    summ = sub.add_parser("summarize", help="write ios-sol.json medians")
    summ.add_argument("--results", required=True)
    summ.add_argument("--sha", required=True,
                      help="full rules_flutter commit sha being measured")
    summ.add_argument("--repeats", type=int, required=True)
    summ.add_argument("--target-loc", type=int, required=True)
    summ.add_argument("--seed", type=int, required=True)
    summ.add_argument("--out", required=True, help="ios-sol.json path")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "run":
        return main_run(args)
    if args.command == "chain":
        return main_chain(args)
    return main_summarize(args)


if __name__ == "__main__":
    sys.exit(main())
