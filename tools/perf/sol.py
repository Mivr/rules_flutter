#!/usr/bin/env python3
"""Speed-of-light (SOL) cost for the iOS perf bench.

For each bench configuration (``device_release``, ``sim_debug``) and each
scenario (``clean``, ``app_edit``, ``core_edit``) this tool measures two
numbers in the same unit, whole-tree user+sys CPU seconds:

- the Bazel cost: for ``clean``, the whole ``bazel --batch build``
  process tree (Bazel's own work plus every action), measured with wait4
  rusage deltas, which include reaped descendants on both macOS and
  Linux; for the edit flows, the same cost measured against a warm Bazel
  server (``tools/perf/warm_server.py``): the client plus the server
  tree's growth during the command. A developer edits against a warm
  server, while ``--batch`` pays JVM start and a cold load and analysis
  on every edit, so the edit number follows the developer;
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
(its declared outputs are removed before it starts), steps run in
dependency order even for edges the execution log never records (a
step whose input is, or resolves to, another step's output runs after
it), and the scenario's final outputs are moved aside before the chain
and hashed after. device_release hashes the App.framework binary;
sim_debug hashes every file in the final app bundle's payload (an
.ipa archive's entries, or every file under an .app directory),
compared by entry path and content: archive metadata such as zip
timestamps is not part of the proof. The verify set comes from
declared outputs only, never a glob over bazel-out. A step that exits
non-zero, times out or cannot start — a step that would start while an
input is still a moved-aside output no earlier step re-created — or
any verify entry that differs afterwards — reports ``identical``
false with no SOL number. Bazel's outputs are moved back afterwards
and chain-created files no step declares are removed, so a chain can
never perturb the next incremental build's action cache.

Every flow also carries a small ``profile`` record, always on, with no
command lines: ``jvm`` is Bazel's own CPU from the build's ``--profile``
JSON trace (the "CPU usage (Bazel)" counter integrated over time and
split at the build-phase markers; the counter starts after JVM launch,
so launch CPU lands in ``residual``), ``host_tools`` replays the
chain-excluded host-tool builds under the same wait4 method after the
chain restores Bazel's outputs (a host build that fails to replay is
recorded, not fatal), and ``residual`` is ``bazel - jvm - sol -
host_tools``, never clamped — a failed chain has no SOL number, and
the record says so and substitutes the chain CPU instead. The gzipped
trace profiles and execution logs behind each record are uploaded as
the ``ios-profile`` artifact (no build outputs).

Subcommands: ``run`` measures repeats, ``chain`` runs one chain (an
unmeasured child process), ``summarize`` writes medians into
ios-sol.json.
"""

import argparse
import gzip
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_flags import parse_bazel_flags  # noqa: E402
from bench_flags import validate_bazel_flags  # noqa: E402
from bench_flags import worker_steps as count_worker_steps  # noqa: E402
from execlog import load_spawns  # noqa: E402
from replay import (  # noqa: E402
    TIME_BIN,
    builds_host_tool,
    chain_all,
    order_chain_spawns,
    run_chain_step,
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
    shutdown,
)
from summarize import summarize_values  # noqa: E402
from traceprofile import parse_jvm_profile  # noqa: E402
import warm_server  # noqa: E402

from sol_verify import (
    _drop_chain_file,
    _is_protected,
    _sweep_dir_entries,
    _sweep_dir_files,
    _sweep_dir_links,
    _sweep_empty_dirs,
    app_dir_hashes,
    bazel_info,
    capture_bazel_output,
    check_under_base,
    command_prefix,
    covered_by,
    cquery_argv,
    device_verify_files,
    hashes_match,
    info_argv,
    ipa_entry_hashes,
    move_aside_chain,
    output_drift,
    path_depth,
    plan_verify_snapshot,
    query_target_files,
    read_verify_snapshot,
    restore_tree,
    sha256_file,
    sim_bundle_archives,
    sim_bundle_roots,
    snapshot_hashes,
    snapshot_tree,
    startup_options,
    sweep_chain_side_effects,
    verify_differences,
)
from sol_summary import (
    BATCH_METHOD,
    WARM_METHOD,
    _FLOW_PREFIX,
    _FLOW_SUFFIX,
    _RECORD,
    collect_runner_info,
    flow_id,
    load_sol_records,
    pick_unit,
    rep_sort_key,
    summarize_bazel_parts,
    summarize_flow,
    summarize_host_tools,
    summarize_jvm,
    summarize_profile,
    summarize_sol,
    summarize_worker_steps,
)

_EDITS = dict(SCENARIOS)
_CHAIN_REPORT = "chain.json"

def build_argv(out_base, config, log_path, profile_path, batch):
    """Full ``bazel build`` argv: the warm form drops ``--batch`` only.

    The same target, build flags, execution log, trace profile and
    param-file materialization either way; ``profile_path`` None (the
    unmeasured warm-up build) omits ``--profile``.
    """
    spec = CONFIGS[config]
    argv = (command_prefix(batch) + startup_options(out_base) + ["build"]
            + list(spec["build_flags"])
            + [spec["target"],
               "--execution_log_json_file=" + log_path,
               "--materialize_param_files"])
    if profile_path is not None:
        argv.append("--profile=" + profile_path)
    return argv


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


def bazel_batch_build(args, config, log_path, profile_path):
    """Builds one scenario with `bazel --batch`, measured as one unit.

    The JSON trace profile (--profile) feeds the flow's jvm record; the
    execution log feeds the SOL chain and the host-tools replay.
    """
    spec = CONFIGS[config]
    argv = build_argv(out_base_of(args, config), config, log_path,
                      profile_path, True)
    cost = args.measure(argv, args.work)
    if cost["returncode"] != 0:
        raise RuntimeError("bazel --batch build %s failed (exit %s)"
                           % (spec["target"], cost["returncode"]))
    return cost


def bazel_warm_build(args, config, log_path, profile_path, server_pid):
    """Builds one scenario against the warm server, measured whole-tree.

    The same target, flags, execution log and trace profile as the batch
    form; only `--batch` is dropped, so the build runs on the config's
    server. The cost covers the client plus the server tree's growth
    (warm_server), with the per-part breakdown under "parts".
    """
    spec = CONFIGS[config]
    argv = build_argv(out_base_of(args, config), config, log_path,
                      profile_path, False)
    cost = args.measure_warm(argv, args.work, server_pid)
    if cost["returncode"] != 0:
        raise RuntimeError("bazel build %s failed (exit %s)"
                           % (spec["target"], cost["returncode"]))
    return cost


def server_pid_of(capture_server, work, out_base):
    """Starts (or reuses) the config's server; returns its pid, loudly.

    Any server-mode command starts the server; `info server_pid` also
    reports the pid the warm measurement attributes. A missing or
    non-numeric pid fails closed: without it there is no warm number.
    """
    out = capture_server(info_argv(out_base, "server_pid", False),
                         cwd=work)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError("bazel info server_pid returned %d line(s)"
                           % len(lines))
    try:
        pid = int(lines[0])
    except ValueError:
        raise RuntimeError("bazel info server_pid returned %r"
                           % (lines[0],))
    if pid <= 0:
        raise RuntimeError("bazel info server_pid returned %r"
                           % (lines[0],))
    return pid


def check_warmup_actions(log_path, target):
    """Fails the config when the warm-up build executed any action.

    The warm-up replays the clean build after its chain and replay
    restored every output: zero executed spawns proves the restore left
    the action cache undisturbed. Any spawn means the outputs were
    perturbed and the edit numbers would measure rebuild work the
    developer never pays.
    """
    try:
        n_spawns = len(load_spawns(log_path))
    except OSError as exc:
        raise RuntimeError(
            "warm-up build of %s left no execution log %s (%s)"
            % (target, log_path, exc))
    if n_spawns != 0:
        raise RuntimeError(
            "warm-up build of %s executed %d action(s): "
            "the clean outputs were perturbed" % (target, n_spawns))
    return n_spawns


def warm_up_server_build(args, config):
    """Unmeasured server-mode build proving the clean restore is exact.

    Runs the same target and flags through the config's server (never
    `--batch`) with an execution log that must list zero executed
    spawns; anything else fails the config with that reason.
    """
    spec = CONFIGS[config]
    log_path = os.path.join(args.work,
                            "execlog-sol-warmup-%s.json" % config)
    argv = build_argv(out_base_of(args, config), config, log_path, None,
                      False)
    proc = args.run(argv, cwd=args.work)
    if proc.returncode != 0:
        raise RuntimeError("warm-up bazel build %s failed (exit %s)"
                           % (spec["target"], proc.returncode))
    return check_warmup_actions(log_path, spec["target"])


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


def describe_chain(report, differ, drift=None):
    """Small per-flow chain record for ios-sol.json (no command lines)."""
    if drift is None:
        drift = {"n": 0, "paths": []}
    if report is None:
        return {"steps": {}, "skipped": {}, "failed": [],
                "ordering_failed": None,
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
    status = "failed" if failed else "ok"
    if report.get("ordering_failed") is not None:
        status = "ordering-failed"
    return {"steps": steps, "skipped": dict(report.get("skipped") or {}),
            "failed": [{"mnemonic": entry.get("mnemonic", ""),
                        "exit": entry.get("exit"),
                        "stderr_tail": entry.get("stderr_tail")}
                       for entry in failed],
            "ordering_failed": report.get("ordering_failed"),
            "verify_differ": differ, "output_drift": drift,
            "sol_cpu_s": report.get("sol_cpu_s"),
            "status": status}


def flow_reason(chain, exit_code):
    """One-line verdict reason for the job log and the flow record."""
    if chain["status"] == "no report":
        return "chain wrote no report (exit %s)" % (exit_code,)
    if chain.get("ordering_failed"):
        item = chain["ordering_failed"]
        return ("ordering failure: step %s needs %s (a moved-aside "
                "output no earlier step re-created)"
                % (item.get("mnemonic", ""), item.get("input", "")))
    if chain["failed"]:
        first = chain["failed"][0]
        reason = "step %s failed (exit %s)" % (first["mnemonic"],
                                               first["exit"])
    else:
        reason = "ok"
    differ = chain.get("verify_differ") or {"n": 0, "differ": []}
    if differ.get("n"):
        entries = differ.get("differ") or []
        shown = entries[0]["path"] if entries else "?"
        reason += "; verify differ: %d file(s), e.g. %s" % (
            differ["n"], shown)
    elif chain["failed"] and exit_code != 0:
        reason += "; chain exit %s" % (exit_code,)
    return reason


def chain_replayed(report_path):
    """Replayed-action count from a chain report (loud when missing)."""
    report = read_chain_report(report_path)
    if report is None or not isinstance(report.get("n_replayed"), int):
        raise RuntimeError("sol chain report %s unreadable" % report_path)
    return report["n_replayed"]


def save_gzipped(src, dst):
    """Gzips src to dst for the ios-profile artifact; fails loudly."""
    with open(src, "rb") as fin:
        data = fin.read()
    with open(dst, "wb") as fout:
        fout.write(gzip.compress(data, mtime=0))


def host_tool_spawns(spawns):
    """Splits host-tool builds into (runnable, skipped).

    The spawns the SOL chain leaves out as host-tool builds (declared
    outputs under an exec configuration); only executed spawns with a
    command replay, like the chain's own buckets.
    """
    runnable = []
    skipped = {}
    for spawn in spawns:
        if not builds_host_tool(spawn):
            continue
        if spawn.get("cacheHit"):
            skipped["cache hit"] = skipped.get("cache hit", 0) + 1
            continue
        if spawn.get("exitCode", 0) != 0:
            key = "bazel exit %s" % (spawn.get("exitCode"),)
            skipped[key] = skipped.get(key, 0) + 1
            continue
        if not spawn.get("commandArgs"):
            skipped["no command"] = skipped.get("no command", 0) + 1
            continue
        runnable.append(spawn)
    return (runnable, skipped)


def replay_host_spawns(spawns, execroot, timeout, backup_dir, runner=None):
    """Replays host-tool builds under the chain's CPU method.

    The spawns the SOL chain leaves out as host-tool builds run by hand
    (ordered as the chain orders them), every host-step output moved
    aside before the replay and Bazel's originals moved back after, as
    for the chain. A failed replay is recorded with its step, never
    fatal: the replay continues with the next spawn. Returns the
    ios-sol.json host_tools record (no command lines): the total and
    per-mnemonic CPU, the top 10 target labels by CPU (plus the per-target
    map summarize medians over), and any failed replays.
    """
    runnable, skipped = host_tool_spawns(spawns)
    if not runnable:
        return {"total": 0.0, "by_mnemonic": {}, "top_targets": [],
                "by_target": {}, "failed": [], "count": 0,
                "skipped": skipped}
    ordered = order_chain_spawns(runnable, execroot)
    if runner is None:
        runner = (lambda spawn: run_chain_step(spawn, execroot, timeout))
    step_outputs = []
    for spawn in ordered:
        step_outputs.extend(spawn_output_paths(spawn, execroot))
    bazel_out = os.path.join(execroot, "bazel-out")
    before_tree = snapshot_tree(bazel_out)
    try:
        aside = move_aside_chain(step_outputs, backup_dir)
    except (OSError, RuntimeError) as exc:
        return {"total": None, "by_mnemonic": {}, "top_targets": [],
                "by_target": {}, "failed": [], "count": len(ordered),
                "skipped": skipped,
                "error": "host-tools move-aside failed (%s)" % exc}
    by_mnemonic = {}
    by_target = {}
    failed = []
    try:
        for spawn in ordered:
            record = runner(spawn)
            mnemonic = spawn.get("mnemonic", "")
            target = spawn.get("targetLabel", "")
            if (record.get("user_s") is not None
                    and record.get("sys_s") is not None):
                cpu = record["user_s"] + record["sys_s"]
                by_mnemonic[mnemonic] = by_mnemonic.get(mnemonic, 0.0) + cpu
                by_target[target] = by_target.get(target, 0.0) + cpu
            if record.get("exit_code") != 0:
                failed.append({"mnemonic": mnemonic, "target": target,
                               "exit": record.get("exit_code"),
                               "stderr_tail": record.get("stderr_tail")})
    finally:
        swept = sweep_chain_side_effects(bazel_out, step_outputs,
                                         before_tree)
        restore_tree(aside)
    top = sorted(by_target.items(),
                 key=lambda item: (-item[1], item[0]))[:10]
    return {"total": (sum(by_mnemonic.values()) if by_mnemonic else None),
            "by_mnemonic": by_mnemonic,
            "top_targets": [[label, cpu] for label, cpu in top],
            "by_target": by_target, "failed": failed,
            "count": len(ordered), "skipped": skipped,
            "side_effects_removed": swept}


def read_jvm_cpu(profile_path):
    """Jvm record of a build trace profile; failures stay null, recorded."""
    try:
        return parse_jvm_profile(profile_path)
    except (OSError, ValueError) as exc:
        return {"total": None, "phases": {}, "error": str(exc)}


def build_profile(bazel_cpu, jvm, host, sol, chain):
    """Per-repeat profile: gap SOL (chain CPU when SOL missing), residual.

    A flow without a SOL number uses the chain's measured CPU in its
    place (sol_source says which: "sol" or "chain-cpu"). residual is the
    raw bazel - jvm - sol - host_tools value, never clamped; None while
    any part is missing.
    """
    if sol is not None:
        gap, source = sol["cpu_s"], "sol"
    else:
        gap, source = chain.get("sol_cpu_s"), "chain-cpu"
    parts = [bazel_cpu, jvm.get("total"), gap, host.get("total")]
    residual = None
    if all(part is not None for part in parts):
        residual = parts[0] - parts[1] - parts[2] - parts[3]
    return {"jvm": jvm, "host_tools": host, "sol_cpu_s": gap,
            "sol_source": source, "residual": residual}


def measure_scenario_build(args, config, scenario, batch,
                             server_pid=None):
    """Builds one scenario; returns its costs, paths and verify plan.

    The mode has no default: the clean flow passes batch, edit flows
    pass the server pid. The clean flow stays a `bazel --batch` build;
    edit flows build against the config's warm server. The execution
    log and the JSON trace profile (--profile) are gzipped into the scenario's record
    directory for the ios-profile artifact.
    """
    spec = CONFIGS[config]
    edit = _EDITS[scenario]
    if edit is not None:
        apply_edit(args.run, args.tools, args.work, edit)
    log_path = os.path.join(args.work, "execlog-sol-%s.json" % scenario)
    profile_path = os.path.join(args.work, "trace-sol-%s.json" % scenario)
    if batch:
        bazel_cost = bazel_batch_build(args, config, log_path,
                                       profile_path)
    else:
        bazel_cost = bazel_warm_build(args, config, log_path,
                                      profile_path, server_pid)
    if scenario == "clean":
        check_clean_actions(log_path, spec["target"],
                            args.min_clean_actions)
    out_base = out_base_of(args, config)
    capture = args.capture if batch else args.capture_server
    execroot = bazel_info(capture, args.work, out_base,
                          "execution_root", batch)
    bazel_out = os.path.join(execroot, "bazel-out")
    if os.path.isdir(bazel_out):
        make_writable_tree(bazel_out)
    plan = plan_verify_snapshot(capture, args.work, out_base,
                                execroot, config, batch)
    record_dir = os.path.join(args.results, "sol", config, scenario,
                              "rep%d" % args.rep)
    os.makedirs(record_dir, exist_ok=True)
    save_gzipped(log_path, os.path.join(record_dir, "execlog.json.gz"))
    save_gzipped(profile_path, os.path.join(record_dir, "trace.json.gz"))
    return argparse.Namespace(
        bazel_cost=bazel_cost, log_path=log_path,
        profile_path=profile_path, execroot=execroot, bazel_out=bazel_out,
        plan=plan, record_dir=record_dir,
        report_path=os.path.join(record_dir, _CHAIN_REPORT))


def prove_chain_outputs(args, built, chainable, before, backup_dir):
    """Runs the SOL chain with outputs moved aside; returns the proof.

    Returns (chain, after, exit_code, report): the ios-sol.json chain
    record, the after-chain verify snapshot, the chain exit code and its
    report (None when the chain never wrote one).
    """
    step_outputs = []
    for spawn in chainable:
        step_outputs.extend(spawn_output_paths(spawn, built.execroot))
    before_tree = snapshot_tree(built.bazel_out)
    aside = move_aside_chain(step_outputs, backup_dir)
    try:
        exit_code = run_chain_proc(args, built.log_path, built.execroot,
                                   built.report_path)
        report = read_chain_report(built.report_path)
        drift = output_drift(chainable, built.execroot)
        try:
            after = read_verify_snapshot(built.plan)
            read_error = None
        except RuntimeError as exc:
            # A missing or unreadable verify file or bundle after the
            # chain is a flow verdict, not a config error: a step that
            # failed before the final bundle was written leaves nothing
            # to hash. The empty snapshot differs from every before
            # entry, so the reason names the failed step and the missing
            # file; the run continues with the next scenario. Only a
            # fault in the tool itself escalates to a config error.
            after = {}
            read_error = str(exc)
    finally:
        swept = sweep_chain_side_effects(built.bazel_out, step_outputs,
                                         before_tree)
        restore_tree(aside)
    differ = verify_differences(before, after, built.execroot)
    if read_error is not None and differ["n"] == 0:
        differ = {"n": 1, "differ": [
            {"path": "(unreadable verify set)", "before": None,
             "after": read_error}]}
    chain = describe_chain(report, differ, drift)
    chain["side_effects_removed"] = swept
    return (chain, after, exit_code, report)


def run_sol_scenario(args, config, scenario, batch,
                       server_pid=None):
    """Builds one scenario, runs its SOL chain, proves the outputs.

    The mode has no default: callers pass the flow's mode explicitly."""
    built = measure_scenario_build(args, config, scenario, batch,
                                   server_pid)
    before = read_verify_snapshot(built.plan)
    spawns = load_spawns(built.log_path)
    chainable, _ = select_sol_spawns(spawns)
    chain, after, exit_code, report = prove_chain_outputs(
        args, built, chainable, before,
        os.path.join(args.work, "sol-backup-" + scenario))
    failed = bool(chain["failed"]) or chain["status"] != "ok"
    identical = (hashes_match(before, after) and not failed
                 and not chain["verify_differ"]["n"])
    if identical:
        sol = {"cpu_s": chain["sol_cpu_s"],
               "real_s": (report or {}).get("sol_real_s")}
    else:
        sol = None
    if sol is not None and sol["cpu_s"] is None:
        identical = False
        sol = None
    host = replay_host_spawns(
        spawns, built.execroot, args.timeout,
        os.path.join(args.work, "sol-host-backup-" + scenario))
    bazel_cpu = cpu_seconds(built.bazel_cost)
    profile = build_profile(bazel_cpu, read_jvm_cpu(built.profile_path),
                            host, sol, chain)
    record = {"flow": flow_id(config, scenario), "config": config,
              "scenario": scenario,
              "method": BATCH_METHOD if batch else WARM_METHOD,
              "bazel": {"cpu_s": bazel_cpu,
                        "real_s": built.bazel_cost["real_s"]},
              "sol": sol,
              "identical": identical,
              "reason": flow_reason(chain, exit_code),
              "n_sol_actions": (report or {}).get("n_replayed", 0),
              "worker_steps": count_worker_steps(chainable),
              "verify": {"before": before, "after": after},
              "chain": chain,
              "profile": profile}
    if not batch:
        record["bazel_parts"] = built.bazel_cost["parts"]
    with open(os.path.join(built.record_dir, _RECORD), "w", encoding="utf-8",
              newline="\n") as fh:
        fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def error_record(config, scenario, reason):
    """Flow record for a scenario an unexpected error kept from running."""
    return {"flow": flow_id(config, scenario), "config": config,
            "scenario": scenario,
            "method": (BATCH_METHOD if scenario == "clean"
                       else WARM_METHOD),
            "bazel": {"cpu_s": None, "real_s": None},
            "sol": None,
            "identical": False,
            "reason": reason,
            "n_sol_actions": 0,
            "worker_steps": {},
            "verify": {"before": {}, "after": {}},
            "profile": {"jvm": {"total": None, "phases": {}},
                        "host_tools": {"total": None, "by_mnemonic": {},
                                       "top_targets": [], "failed": []},
                        "sol_cpu_s": None, "sol_source": "none",
                        "residual": None},
            "chain": {"steps": {}, "skipped": {}, "failed": [],
                      "ordering_failed": None,
                      "verify_differ": {"n": 0, "differ": []},
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

    The clean flow stays a `bazel --batch` build. After its chain and
    replay have restored Bazel's outputs, a server starts on the same
    output base (same startup options minus `--batch`); one unmeasured
    warm-up build must execute zero actions, and each edit flow then
    builds against that server. While the server is up every Bazel
    command on the output base goes through it, never `--batch`, and the
    server shuts down after the config's last flow and on every error
    path: no server outlives its config. An unexpected error in one
    config records that config's remaining flows with the error as their
    reason and lets the other config run: one failure never loses the
    rest of the run. Returns (records, had_errors).
    """
    args.rep = rep
    records = {}
    had_errors = False
    for config in configs:
        reset_work(args.pristine, args.work)
        out_base = out_base_of(args, config)
        shutil.rmtree(out_base, ignore_errors=True)
        flows = {}
        server_started = False
        try:
            flows["clean"] = run_sol_scenario(args, config, "clean",
                                                  batch=True)
            server_pid = server_pid_of(args.capture_server, args.work,
                                       out_base)
            server_started = True
            warm_up_server_build(args, config)
            for scenario, _ in SCENARIOS:
                if scenario == "clean":
                    continue
                flows[scenario] = run_sol_scenario(
                    args, config, scenario, batch=False,
                    server_pid=server_pid)
        except Exception as exc:
            had_errors = True
            remaining = [scenario for scenario, _ in SCENARIOS
                         if scenario not in flows]
            flows.update(write_error_records(
                args, config, remaining,
                "config %s failed: %s" % (config, exc)))
            print("config=%s failed: %s" % (config, exc))
        finally:
            if server_started:
                try:
                    shutdown(args.run, args.work, out_base)
                except Exception as exc:
                    had_errors = True
                    print("config=%s shutdown failed: %s" % (config, exc))
        records[config] = flows
    return (records, had_errors)


def main_run(cmd):
    cmd.run = real_run
    cmd.capture = capture_bazel_output
    cmd.capture_server = capture_bazel_output
    cmd.measure = lambda argv, cwd: measure_with_time(
        argv, cwd, cmd.time_bin)
    cmd.measure_warm = (lambda argv, cwd, server_pid:
                        warm_server.measure(argv, cwd, server_pid))
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
    if cmd.lockfile not in ("none", "committed"):
        raise ValueError("invalid lockfile %r: expected none/committed"
                         % (cmd.lockfile,))
    meta = {"sha": cmd.sha, "repeats": cmd.repeats,
            "target_loc": cmd.target_loc, "seed": cmd.seed,
            "bazel_flags": validate_bazel_flags(
                parse_bazel_flags(cmd.bazel_flags)),
            "lockfile": cmd.lockfile}
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
    summ.add_argument("--bazel-flags", default="",
                      help="raw whitespace-separated extra Bazel flags "
                      "for this run (recorded in meta)")
    summ.add_argument("--lockfile", default="none",
                      help="none or committed (recorded in meta)")
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
