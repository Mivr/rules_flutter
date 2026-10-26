#!/usr/bin/env python3
"""Record loading and flow/profile summarization for ios-sol.json."""

import json
import os
import platform
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_rep import (
    CONFIG_ORDER,
    SCENARIOS,
)
from summarize import summarize_values
import warm_server

_FLOW_PREFIX = {"device_release": "ios-release", "sim_debug": "ios-debug"}
_FLOW_SUFFIX = {"clean": "clean", "app_edit": "app", "core_edit": "body"}
_RECORD = "record.json"

BATCH_METHOD = "batch"
WARM_METHOD = warm_server.METHOD

def flow_id(config, scenario):
    """ios-sol.json flow id, e.g. device_release+core_edit=ios-release-body."""
    return "%s-%s" % (_FLOW_PREFIX[config], _FLOW_SUFFIX[scenario])


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


def summarize_jvm(rep_jvms):
    """Median jvm record over repeats: total and per-phase CPU."""
    totals = [jvm.get("total") for jvm in rep_jvms
              if jvm.get("total") is not None]
    names = set()
    for jvm in rep_jvms:
        names.update((jvm.get("phases") or {}).keys())
    phases = {}
    for name in sorted(names):
        vals = [jvm["phases"][name] for jvm in rep_jvms
                if name in (jvm.get("phases") or {})]
        phases[name] = summarize_values(vals)["median"]
    return {"total": summarize_values(totals)["median"], "phases": phases}


def summarize_host_tools(rep_hosts):
    """Median host_tools record over repeats (no command lines)."""
    totals = [host.get("total") for host in rep_hosts
              if host.get("total") is not None]
    names = set()
    for host in rep_hosts:
        names.update((host.get("by_mnemonic") or {}).keys())
    by_mnemonic = {}
    for name in sorted(names):
        vals = [host["by_mnemonic"][name] for host in rep_hosts
                if name in (host.get("by_mnemonic") or {})]
        by_mnemonic[name] = summarize_values(vals)["median"]
    labels = set()
    for host in rep_hosts:
        labels.update((host.get("by_target") or {}).keys())
    medians = {}
    for label in labels:
        vals = [host["by_target"][label] for host in rep_hosts
                if label in (host.get("by_target") or {})]
        medians[label] = summarize_values(vals)["median"]
    top = sorted(medians.items(),
                 key=lambda item: (-item[1], item[0]))[:10]
    failed = []
    for host in rep_hosts:
        for entry in host.get("failed") or []:
            if entry not in failed and len(failed) < 10:
                failed.append(entry)
    return {"total": summarize_values(totals)["median"],
            "by_mnemonic": by_mnemonic,
            "top_targets": [[label, cpu] for label, cpu in top],
            "failed": failed}


def summarize_profile(records, bazel_median, sol_median, identical):
    """Per-flow profile: jvm/host medians, gap SOL, raw residual.

    The gap SOL is the flow SOL number; a flow without one uses the
    chain's measured CPU in its place (sol_source says which). residual
    is the raw bazel - jvm - sol - host_tools value, never clamped, so
    the parts always sum to the Bazel number; None while any part is
    missing.
    """
    jvms = []
    hosts = []
    chain_cpus = []
    for record in records:
        profile = record.get("profile") or {}
        jvm = profile.get("jvm") or {}
        jvms.append({"total": jvm.get("total"),
                     "phases": jvm.get("phases") or {}})
        host = profile.get("host_tools") or {}
        hosts.append({"total": host.get("total"),
                      "by_mnemonic": host.get("by_mnemonic") or {},
                      "by_target": host.get("by_target") or {},
                      "failed": host.get("failed") or []})
        if profile.get("sol_cpu_s") is not None:
            chain_cpus.append(profile["sol_cpu_s"])
    if identical and sol_median is not None:
        gap, source = sol_median, "sol"
    else:
        gap, source = summarize_values(chain_cpus)["median"], "chain-cpu"
    parts = [bazel_median, summarize_jvm(jvms)["total"], gap,
             summarize_host_tools(hosts)["total"]]
    residual = None
    if all(part is not None for part in parts):
        residual = parts[0] - parts[1] - parts[2] - parts[3]
    return {"jvm": summarize_jvm(jvms), "host_tools": summarize_host_tools(
        hosts), "sol_cpu_s": gap, "sol_source": source,
        "residual": residual}


def summarize_bazel_parts(records):
    """Median per-part CPU over repeats for a warm-server flow.

    Each part's median is over the repeats' user+sys CPU for that part
    (client / server_self / server_reaped / descendants); parts with no
    sample stay out.
    """
    parts = {}
    for name in ("client", "server_self", "server_reaped",
                 "descendants"):
        vals = []
        for record in records:
            breakdown = record.get("bazel_parts") or {}
            part = breakdown.get(name) or {}
            if (part.get("user_s") is not None
                    and part.get("sys_s") is not None):
                vals.append(part["user_s"] + part["sys_s"])
        if vals:
            parts[name] = summarize_values(vals)["median"]
    return parts


def summarize_worker_steps(records):
    """Merged worker-step counts over repeats (first value per mnemonic)."""
    merged = {}
    for record in records:
        for mnemonic, count in (
                record.get("worker_steps") or {}).items():
            if mnemonic not in merged:
                merged[mnemonic] = count
    return merged


def summarize_flow(records, unit):
    """Median costs over repeats; no SOL number unless all repeats match."""
    del unit
    identical = all(record["identical"] for record in records)
    methods = {record.get("method") for record in records}
    if len(methods) == 1 and None not in methods:
        method = records[0]["method"]
    elif records[0].get("scenario") == "clean":
        method = BATCH_METHOD
    else:
        method = WARM_METHOD
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
    flow = {"method": method,
            "bazel": bazel["median"],
            "sol": sol["median"] if identical else None,
            "identical": identical,
            "reason": "ok" if identical else "; ".join(reasons),
            "chain": records[0].get("chain"),
            "worker_steps": summarize_worker_steps(records),
            "profile": summarize_profile(records, bazel["median"],
                                         sol["median"] if identical else None,
                                         identical),
            "spread": {"n": len(records),
                       "bazel": [bazel["min"], bazel["max"]],
                       "sol": [sol["min"], sol["max"]] if identical else None}}
    if method == WARM_METHOD:
        flow["bazel_parts"] = summarize_bazel_parts(records)
    return flow


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
    flags = meta.get("bazel_flags", [])
    return {"rules_flutter": meta["sha"], "unit": unit,
            "runner": collect_runner_info(), "flows": flows,
            "meta": {"repeats": meta["repeats"],
                     "target_loc": meta["target_loc"], "seed": meta["seed"],
                     "bazel_flags": list(flags),
                     "lockfile": meta.get("lockfile", "none")}}
