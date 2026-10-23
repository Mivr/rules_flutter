#!/usr/bin/env python3
"""Speed-of-light (SOL) cost for the iOS perf bench.

For each bench configuration (``device_release``, ``sim_debug``) and each
scenario (``clean``, ``app_edit``, ``core_edit``) this tool measures two
numbers in the same unit, whole-tree user+sys CPU seconds:

- the Bazel cost: the whole ``bazel --batch build`` process tree (Bazel's
  own work plus every action), measured with wait4 rusage deltas, which
  include reaped descendants on both macOS and Linux;
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs), run by hand in order. The SOL number is the sum of
  the chain steps' own process-tree CPU: the driver's own cost (loading
  the log, hashing, moving files) is never included.

A host-tool build is a spawn whose declared outputs land in an exec
configuration (``bazel-out/*-exec-*/``); those are not part of the chain
(building Bazel's helper tools is part of the gap). Every other executed
spawn runs, whatever tool binary it invokes: an action that runs an
exec-built tool to produce target-configuration outputs (the kernel
compile, for example) belongs in the chain. Steps whose outputs did not
change for an edit are skipped as a person would skip them: the
execution log records executed spawns only.

Proof the SOL did the same work: each chain step runs as Bazel runs it
(its declared outputs are removed before it starts), and the scenario's
final outputs are moved aside before the chain and hashed after (the
App.framework binary for device_release; the app's kernel blob and the
App.framework binary for sim_debug). A step that exits non-zero, times
out or cannot start — or any verify file that differs afterwards —
reports ``identical`` false with no SOL number. Bazel's outputs are
moved back afterwards, so a chain can never perturb the next incremental
build's action cache.

Subcommands: ``run`` measures repeats, ``chain`` runs one chain (an
unmeasured child process), ``summarize`` writes medians into
ios-sol.json.
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
    chain_all,
    select_chain_spawns,
    spawn_output_paths,
    spawn_recorded_digests,
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


def select_sol_spawns(spawns):
    """Runnable SOL chain: every executed spawn that is not a host build.

    Delegates to replay's output-based selection: a spawn is a host-tool
    build only when its declared outputs land in an exec configuration,
    never because its argv names an exec-built tool.
    """
    return select_chain_spawns(spawns)


def cpu_seconds(cost):
    """user+sys CPU seconds of a measurement, or None when unreported."""
    if cost.get("user_s") is None or cost.get("sys_s") is None:
        return None
    return cost["user_s"] + cost["sys_s"]


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


def path_depth(path):
    """Sort key: parents before children (fewer separators first)."""
    return (path.count(os.sep), path)


def covered_by(path, roots):
    """Whether path equals or sits under one of the moved roots."""
    return any(path == root or path.startswith(root + os.sep)
               for root in roots)


def move_aside_chain(step_outputs, backup_dir):
    """Moves every chain-step output aside; returns {original: backup}.

    Parents move before children, so a directory output moves whole. A
    verify file inside a moved directory travels with it; a verify file
    no running step declares is never passed here at all: it stays
    Bazel's own and its unchanged bytes count as proof. A missing path
    fails loudly (after moving back what was moved): the chain must
    recreate exactly what Bazel wrote.
    """
    shutil.rmtree(backup_dir, ignore_errors=True)
    os.makedirs(backup_dir, exist_ok=True)
    mapping = {}
    try:
        for path in sorted(set(step_outputs), key=path_depth):
            if covered_by(path, mapping):
                continue
            dst = os.path.join(backup_dir, "%d%s" % (
                len(mapping), os.path.splitext(path)[1]))
            os.rename(path, dst)
            mapping[path] = dst
    except OSError as exc:
        restore_tree(mapping)
        raise RuntimeError("sol move-aside of %s failed (%s)" % (path, exc))
    return mapping


def restore_tree(mapping):
    """Removes chain-written files and moves Bazel's originals back.

    Parents move back before children, and every parent directory is
    recreated: a step that failed before recreating its output directory
    (e.g. a tree artifact holding a verify file) restores exactly what
    Bazel left. A missing backup fails loudly instead of leaving the
    next build over a hole.
    """
    for path in sorted(mapping, key=path_depth):
        backup = mapping[path]
        if not os.path.exists(backup):
            raise RuntimeError("sol backup for %s is gone" % path)
        try:
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
            parent = os.path.dirname(path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.rename(backup, path)
        except OSError as exc:
            raise RuntimeError("sol restore of %s failed (%s)" % (path, exc))


def capture_bazel_output(argv, cwd):
    """stdout of a Bazel info/query command; stderr stays separate.

    Bazel relays JVM warnings on stderr. Merging the streams (as a
    combined capture does) lets a warning line corrupt parsed output
    paths, so stdout is captured alone and stderr is shown on failure.
    """
    proc = subprocess.run(
        list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError("bazel %s failed (exit %s): %s"
                           % (" ".join(list(argv)[1:]), proc.returncode,
                              tail_lines(proc.stderr)))
    return proc.stdout


def check_under_base(path, out_base, what):
    """Fails closed unless path exists under the output base."""
    abs_path = os.path.abspath(path)
    if not abs_path.startswith(os.path.abspath(out_base) + os.sep):
        raise RuntimeError("sol %s %s is not under output base %s"
                           % (what, path, out_base))
    if not os.path.exists(abs_path):
        raise RuntimeError("sol %s %s does not exist" % (what, path))
    return abs_path


def bazel_info(capture, work, out_base, key):
    """One `bazel --batch info` path (execroot, ...), validated."""
    out = capture(["bazel", "--batch", "--output_base=" + out_base,
                   "info", key], cwd=work)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError("bazel info %s returned %d line(s)"
                           % (key, len(lines)))
    return check_under_base(lines[0], out_base, "info " + key)


def query_target_files(capture, work, out_base, target, build_flags):
    """Absolute output paths of a target via `cquery --output=files`.

    Every non-blank line must resolve to an existing path under the
    output base; anything else (a warning leaked into stdout, a format
    change) fails loudly instead of becoming a bogus verify path.
    """
    out = capture(["bazel", "--batch", "--output_base=" + out_base,
                   "cquery", "--output=files", target] + list(build_flags),
                  cwd=work)
    execroot = bazel_info(capture, work, out_base, "execution_root")
    files = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        path = line if os.path.isabs(line) else os.path.join(execroot, line)
        files.append(check_under_base(path, out_base, "cquery " + target))
    if not files:
        raise RuntimeError("bazel cquery %s listed no files" % target)
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


def verify_paths_for_config(capture, work, out_base, config):
    """Final-output files whose hashes prove the SOL chain's work."""
    spec = CONFIGS[config]
    listed = query_target_files(capture, work, out_base, spec["target"],
                                spec["build_flags"])
    if config == "device_release":
        found = device_verify_files(listed)
    else:
        found = sim_verify_files(sim_bundle_roots(listed))
    if not found:
        execroot = bazel_info(capture, work, out_base, "execution_root")
        found = fallback_verify_files(execroot, config)
    if not found:
        raise RuntimeError("sol found no verify files for %s" % config)
    return found


def measure_process_tree(argv, cwd):
    """Whole-tree user+sys CPU seconds of argv (wait4 rusage deltas).

    The same method on macOS and Linux, with no time binary:
    RUSAGE_CHILDREN includes reaped descendants, so the number covers
    the child plus every process it spawns (Bazel's own work plus every
    action for a build). Per-step instruction counters cannot do this:
    on macOS they describe the timed child alone, never its tree.
    """
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
    return {"instructions": None, "real_s": time.monotonic() - start,
            "user_s": after.ru_utime - before.ru_utime,
            "sys_s": after.ru_stime - before.ru_stime,
            "returncode": proc.returncode, "method": "rusage-children"}


def measure_with_time(argv, cwd, time_bin=TIME_BIN):
    """Measures argv's whole process tree (kept CLI-compatible name).

    time_bin is accepted for compatibility and ignored: both numbers are
    whole-tree user+sys CPU seconds on every host, so there is exactly
    one CPU method and no platform-specific binary to miss.
    """
    del time_bin
    return measure_process_tree(argv, cwd)


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
    report = chain_all(spawns, execroot, timeout, runner=runner)
    with open(report_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("replayed=%d failed=%d skipped=%s" % (
        report["n_replayed"], len(report["failed"]), report["skipped"]))
    return report


def run_chain_proc(args, log_path, execroot, report_path):
    """Runs the chain subcommand as a plain, unmeasured child process.

    The SOL number comes from the chain report (the steps' own CPU),
    never from timing this driver: its stdout and stderr stay attached
    so the job log shows what the chain did.
    """
    argv = [sys.executable, os.path.abspath(__file__), "chain",
            "--log", log_path, "--execroot", execroot,
            "--report", report_path, "--timeout", str(args.timeout)]
    proc = subprocess.run(list(argv), cwd=args.work, stdin=subprocess.DEVNULL,
                          check=False)
    return proc.returncode


def read_chain_report(report_path):
    """Chain report dict, or None when the chain never wrote one.

    None is not swallowed: the caller reports identical=false with a
    reason naming the missing report.
    """
    try:
        with open(report_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def verify_differences(before, after, execroot):
    """Verify files that differ, with execroot-relative paths and digests."""
    differ = []
    for path in sorted(set(before) | set(after)):
        if before.get(path) == after.get(path):
            continue
        try:
            shown = os.path.relpath(path, execroot)
        except ValueError:
            shown = path
        differ.append({"path": shown, "before": before.get(path),
                       "after": after.get(path)})
    return differ


def output_drift(chainable, execroot):
    """Chain-step outputs differing from the log's digests, info only.

    Compares files the chain wrote against the digests the execution
    log recorded in actualOutputs. Missing files (steps never run),
    directories and unrecorded outputs are skipped; the count covers
    every differing file while paths keep the first 10, execroot
    relative. Never fails a flow: reproducibility detail, not proof.
    """
    base = os.path.abspath(execroot)
    differing = []
    for spawn in chainable:
        recorded = spawn_recorded_digests(spawn)
        if not recorded:
            continue
        resolved = {}
        for raw, digest in recorded.items():
            resolved[raw] = digest
            joined = (raw if os.path.isabs(raw)
                      else os.path.join(base, raw))
            resolved[os.path.normpath(joined)] = digest
        for path in spawn_output_paths(spawn, execroot):
            if path not in resolved or not os.path.isfile(path):
                continue
            if sha256_file(path) != resolved[path]:
                differing.append(os.path.relpath(path, base))
    differing = sorted(set(differing))
    return {"n": len(differing), "paths": differing[:10]}


def describe_chain(report, differ, drift=None):
    """Small per-flow chain record for ios-sol.json (no command lines)."""
    if drift is None:
        drift = {"n": 0, "paths": []}
    if report is None:
        return {"steps": {}, "skipped": {}, "failed": [],
                "verify_differ": differ, "output_drift": drift,
                "sol_cpu_s": None, "status": "no report"}
    steps = {}
    for mnemonic, entry in (report.get("by_mnemonic") or {}).items():
        cpu = None
        if (not entry.get("cpu_s_missing")
                and entry.get("user_s_total") is not None
                and entry.get("sys_s_total") is not None):
            cpu = entry["user_s_total"] + entry["sys_s_total"]
        steps[mnemonic] = {"count": entry.get("count", 0), "cpu_s": cpu}
    failed = report.get("failed") or []
    return {"steps": steps, "skipped": dict(report.get("skipped") or {}),
            "failed": [{"mnemonic": entry.get("mnemonic", ""),
                        "exit": entry.get("exit"),
                        "stderr_tail": entry.get("stderr_tail")}
                       for entry in failed],
            "verify_differ": differ, "output_drift": drift,
            "sol_cpu_s": report.get("sol_cpu_s"),
            "status": "failed" if failed else "ok"}


def flow_reason(chain, exit_code):
    """One-line verdict reason for the job log and the flow record."""
    if chain["status"] == "no report":
        return "chain wrote no report (exit %s)" % (exit_code,)
    if chain["failed"]:
        first = chain["failed"][0]
        reason = "step %s failed (exit %s)" % (first["mnemonic"],
                                               first["exit"])
    else:
        reason = "ok"
    if chain["verify_differ"]:
        shown = chain["verify_differ"][0]["path"]
        reason += "; verify differ: %d file(s), e.g. %s" % (
            len(chain["verify_differ"]), shown)
    elif chain["failed"] and exit_code != 0:
        reason += "; chain exit %s" % (exit_code,)
    return reason


def chain_replayed(report_path):
    """Replayed-action count from a chain report (loud when missing)."""
    report = read_chain_report(report_path)
    if report is None or not isinstance(report.get("n_replayed"), int):
        raise RuntimeError("sol chain report %s unreadable" % report_path)
    return report["n_replayed"]


def run_sol_scenario(args, config, scenario):
    """Builds one scenario, runs its SOL chain, proves the outputs."""
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
    execroot = bazel_info(args.capture, args.work, out_base,
                          "execution_root")
    bazel_out = os.path.join(execroot, "bazel-out")
    if os.path.isdir(bazel_out):
        make_writable_tree(bazel_out)
    verify = verify_paths_for_config(args.capture, args.work, out_base,
                                     config)
    record_dir = os.path.join(args.results, "sol", config, scenario,
                              "rep%d" % args.rep)
    os.makedirs(record_dir, exist_ok=True)
    report_path = os.path.join(record_dir, _CHAIN_REPORT)
    before = snapshot_hashes(verify)
    chainable, _ = select_sol_spawns(load_spawns(log_path))
    step_outputs = []
    for spawn in chainable:
        step_outputs.extend(spawn_output_paths(spawn, execroot))
    aside = move_aside_chain(step_outputs, os.path.join(
        args.work, "sol-backup-" + scenario))
    try:
        exit_code = run_chain_proc(args, log_path, execroot, report_path)
        report = read_chain_report(report_path)
        drift = output_drift(chainable, execroot)
        after = snapshot_hashes(verify)
    finally:
        restore_tree(aside)
    differ = verify_differences(before, after, execroot)
    chain = describe_chain(report, differ, drift)
    failed = bool(chain["failed"]) or chain["status"] != "ok"
    identical = hashes_match(before, after) and not failed and not differ
    if identical:
        sol = {"cpu_s": chain["sol_cpu_s"],
               "real_s": (report or {}).get("sol_real_s")}
    else:
        sol = None
    if sol is not None and sol["cpu_s"] is None:
        identical = False
        sol = None
    record = {"flow": flow_id(config, scenario), "config": config,
              "scenario": scenario,
              "bazel": {"cpu_s": cpu_seconds(bazel_cost),
                        "real_s": bazel_cost["real_s"]},
              "sol": sol,
              "identical": identical,
              "reason": flow_reason(chain, exit_code),
              "n_sol_actions": (report or {}).get("n_replayed", 0),
              "verify": {"before": before, "after": after},
              "chain": chain}
    with open(os.path.join(record_dir, _RECORD), "w", encoding="utf-8",
              newline="\n") as fh:
        fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def error_record(config, scenario, reason):
    """Flow record for a scenario an unexpected error kept from running."""
    return {"flow": flow_id(config, scenario), "config": config,
            "scenario": scenario,
            "bazel": {"cpu_s": None, "real_s": None},
            "sol": None,
            "identical": False,
            "reason": reason,
            "n_sol_actions": 0,
            "verify": {"before": {}, "after": {}},
            "chain": {"steps": {}, "skipped": {}, "failed": [],
                      "verify_differ": [],
                      "output_drift": {"n": 0, "paths": []},
                      "sol_cpu_s": None, "status": "error"}}


def write_error_records(args, config, scenarios, reason):
    """Records remaining flows as failed-with-reason, loudly but alive."""
    records = {}
    short = reason if len(reason) <= 300 else reason[:297] + "..."
    for scenario in scenarios:
        record = error_record(config, scenario, short)
        record_dir = os.path.join(args.results, "sol", config, scenario,
                                  "rep%d" % args.rep)
        os.makedirs(record_dir, exist_ok=True)
        with open(os.path.join(record_dir, _RECORD), "w", encoding="utf-8",
                  newline="\n") as fh:
            fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
        records[scenario] = record
    return records


def run_sol_rep(args, rep, configs):
    """One repeat: fresh workspace per config, cumulative edits per config.

    An unexpected error in one config records that config's remaining
    flows with the error as their reason and lets the other config run:
    one failure never loses the rest of the run. Returns (records,
    had_errors).
    """
    args.rep = rep
    records = {}
    had_errors = False
    for config in configs:
        reset_work(args.pristine, args.work)
        shutil.rmtree(out_base_of(args, config), ignore_errors=True)
        flows = {}
        try:
            for scenario, _ in SCENARIOS:
                flows[scenario] = run_sol_scenario(args, config, scenario)
        except Exception as exc:
            had_errors = True
            remaining = [scenario for scenario, _ in SCENARIOS
                         if scenario not in flows]
            flows.update(write_error_records(
                args, config, remaining,
                "config %s failed: %s" % (config, exc)))
            print("config=%s failed: %s" % (config, exc))
        records[config] = flows
    return (records, had_errors)


def rep_sort_key(name):
    """Numeric-aware sort for repN directories (rep10 follows rep9)."""
    if name.startswith("rep") and name[3:].isdigit():
        return (0, int(name[3:]), name)
    return (1, 0, name)


def load_sol_records(results_dir, config, scenario):
    """Per-repeat record dicts for one config and scenario."""
    scenario_dir = os.path.join(results_dir, "sol", config, scenario)
    records = []
    if not os.path.isdir(scenario_dir):
        return records
    for rep in sorted(os.listdir(scenario_dir), key=rep_sort_key):
        path = os.path.join(scenario_dir, rep, _RECORD)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            records.append(json.load(fh))
    return records


def pick_unit(collected):
    """One unit for the artifact: always cpu_seconds.

    Both numbers are whole-tree user+sys CPU seconds on every host (a
    macOS instruction counter describes the timed child alone, never
    its process tree, so it cannot measure a build). Per-step
    instruction detail may live in chain.json; it is never the flow
    number.
    """
    del collected
    return "cpu_seconds"


def summarize_flow(records, unit):
    """Median costs over repeats; no SOL number unless all repeats match."""
    del unit
    identical = all(record["identical"] for record in records)
    bazel = summarize_values([record["bazel"]["cpu_s"] for record in records
                              if record["bazel"]["cpu_s"] is not None])
    sol_vals = [record["sol"]["cpu_s"] for record in records
                if record["sol"] is not None
                and record["sol"].get("cpu_s") is not None]
    sol = summarize_values(sol_vals) if identical else summarize_values([])
    reasons = []
    for record in records:
        if record.get("reason") not in reasons:
            reasons.append(record.get("reason"))
    return {"bazel": bazel["median"],
            "sol": sol["median"] if identical else None,
            "identical": identical,
            "reason": "ok" if identical else "; ".join(reasons),
            "chain": records[0].get("chain"),
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
    cmd.capture = capture_bazel_output
    cmd.measure = lambda argv, cwd: measure_with_time(
        argv, cwd, cmd.time_bin)
    configs = list(cmd.config) if cmd.config else list(CONFIG_ORDER)
    unknown = [c for c in configs if c not in CONFIGS]
    if unknown:
        raise ValueError("unknown config(s): %s" % ", ".join(unknown))
    records, had_errors = run_sol_rep(cmd, cmd.rep, configs)
    for config, flows in records.items():
        for scenario, record in flows.items():
            print("flow=%s identical=%s n_sol_actions=%d reason=%s"
                  % (record["flow"], record["identical"],
                     record["n_sol_actions"], record["reason"]))
    return 1 if had_errors else 0


def main_chain(cmd):
    report = run_chain(cmd.log, cmd.execroot, cmd.report, cmd.timeout)
    return 1 if report.get("failed") else 0


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
        print("flow=%s unit=%s bazel=%s sol=%s identical=%s reason=%s" % (
            flow, summary["unit"], entry["bazel"], entry["sol"],
            entry["identical"], entry.get("reason")))
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
                     help="accepted for compatibility; ignored: measurement "
                     "is whole-tree rusage on every host")
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
