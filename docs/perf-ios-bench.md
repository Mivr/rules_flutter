# iOS perf bench

Manual-only workflow (`.github/workflows/perf-ios.yaml`) measuring iOS build
cost of `rules_flutter` on GitHub's free macOS runners. Linux cannot build
iOS targets, so this is the only signal for the iOS half of the monorepo
perf target; the manager dispatches it per comparison and reads the
artifact.

## What it measures

For each of `base_ref` and `head_ref` (rules_flutter commits, wired through
`local_path_override` in the generated `MODULE.bazel`), in each of two
configurations (fixed table `CONFIGS` in `tools/perf/run_rep.py`, recorded
in the summary metadata):

- `device_release`: the Flutter iOS framework assembly itself —
  `//app:__app_framework_framework` with `-c opt
  --ios_multi_cpus=arm64`. That is the `_flutter_ios_framework` rule
  the generator's public `flutter_ios_framework_gen(name =
  "app_framework")` creates (`__<name>_framework` in
  `flutter/ios.bzl`): with `-c opt` the application is non-debug, so
  `flutter_application` runs AOT gen_snapshot for iOS (`FlutterAotMacho`)
  and the framework rule assembles App.framework (`FlutterIOSRetagDylib`
  + `FlutterIOSCopyAssets`), with no `ios_application`, hence no
  signing and no provisioning profile. The public
  `//app:app_framework` wrapper is an `apple_dynamic_framework_import`
  whose outputs are only consumed when linked into an app — building it
  executes zero actions (as the first dispatch showed), so the bench
  targets the inner rule and the driver fails any clean build that
  executes fewer than 10 actions (`--min-clean-actions`).
- `sim_debug`: the full simulator app — `//app:app_ios` with
  `-c dbg --ios_multi_cpus=sim_arm64` (the developer inner loop; the
  simulator runs debug builds only, and simulator bundles need no
  provisioning profile).

Per configuration the three scenarios run against a freshly reset
workspace copy:

1. `clean`: clean build (fresh workspace copy, fresh per-config output
   base, no caches anywhere).
2. `app_edit`: rebuild after a behaviour-changing top-layer app edit
   (`app/lib/main.dart` shows `value + 1` for the first wired widget).
3. `core_edit`: rebuild after a core body edit (layer 0, highest fan-in
   file; same `var total = 1;` to `var total = 2;` shape as the referee's
   `body_edit`). Cumulative: the app edit stays applied.

Per scenario run it records:

- Executed action count by mnemonic, from
  `bazel build --execution_log_json_file` (only executed spawns are logged).
- Total action CPU time (user+sys from each spawn's metrics) plus wall time.
  The Linux sandbox runner does not populate `userTime`/`systemTime` and
  the macOS runner did not either on the first dispatch;
  `cpu_time_available` says whether any spawn carried them, so missing
  data is never mistaken for zero CPU. Wall time is always reported.
  (`--experimental_execution_log_spawn_metrics` does not exist in the
  pinned Bazel 9.3.0 — `bazel help build` lists only the
  `--execution_log_{binary,compact,json}_file` outputs — so there is no
  extra per-spawn metric to consume.)
- Instructions retired for the iOS-only actions (`FlutterAotMacho`
  gen_snapshot for iOS, the `FlutterIOS*` framework/bundle tools,
  `FlutterStripEngine`, `FlutterPlistMerge`, `FlutterMachOVerifyProbe`,
  assembler/clang and linker steps), by replaying each such action's
  command line under `/usr/bin/time -l` with the host environment
  overlaid by the logged environment, in the build's execroot right
  after the build. Kernel compiles are excluded (the Linux bench
  measures them); pass `--mnemonic` to opt back in. Replays run with
  stdin closed, a 600 s per-action timeout, and an 1800 s whole-log
  budget; on exhaustion the report records `truncated=true` and the
  skipped count.
- Replay CPU seconds (`user_s`/`sys_s` from `time -l`) per action and
  per mnemonic. GitHub's macOS VMs may expose no PMU, in which case no
  replayed action carries an instruction counter; the summary then says
  so plainly and replay CPU is the fallback cost signal.
- Failed replays (non-zero exit or timeout) record the exit code plus
  the last 20 lines of stderr in `replay.json`, and the summary shows
  one sample per failing mnemonic (target, exit, stderr tail), so the
  next run tells us why a replay class failed (missing Xcode env,
  sandbox-only paths) instead of just counting it.
- Executed-but-not-replayed actions are counted per reason in
  `replay.json` (`skipped_by_mnemonic`) and shown in the summary's "Not
  replayed" table. Exec-configuration (host tool) spawns — outputs
  under a `-exec-` configuration directory such as
  `bazel-out/darwin_arm64-opt-exec-*/`, which build host tools (abseil,
  the Swift worker) rather than the iOS app — are skipped by default
  under the single reason "host tools (not replayed)"
  (`--include-exec-config` opts back in).

## Generator v2: a reachable program

The first generator shape wired `main` to top-layer widgets only, with
no package calling its dependencies at run time, so AOT tree-shaking
dropped everything below the top layer: a layer-0 `core_edit`
re-ran the kernel compile but never `gen_snapshot`, and the AOT dill
came out byte-identical. Since generator v2 (same design as the
referee's `flutter-monorepo` v2) the generated program is reachable
like a real app:

- Each package entry (`entryN(x, probe)`) calls every own file's
  helper and value functions — including the value functions the
  bench edits — and constructs every own file's widget, all
  unconditionally, so a `body_edit` at any layer changes the AOT
  program. (`api_edit` keeps its meaning: adding an unused member
  legitimately changes nothing in AOT.)
- Each entry also calls its direct dependencies' entries, and `main`
  calls every top-layer entry. Cross-package calls are guarded by a
  probe `main` reads from a runtime source the compiler cannot fold
  (`int.tryParse('probe') ?? 0`, always zero at run time), so the
  whole transitive closure stays reachable for tree-shaking without
  running if the app ever runs. The DAG repair pass gives every
  package below the top layer at least one dependent, so reachability
  holds through the dependency graph from every seed.
- `bench-workspace-stats.json` records `generator_version: 2` (also
  embedded in the summary metadata as `base_stats`/`head_stats`); the
  summary warns when the two sides differ in shape. Numbers from the
  old shape are never comparable with v2 numbers.

## Apple replay environment

Bazel's darwin spawn runner adds `DEVELOPER_DIR` and `SDKROOT` at
execution time (as `XcodeLocalEnvProvider` does), so the execution log
never records them and naive replays of Apple actions fail with
`Error: DEVELOPER_DIR not set.` When the logged environment names an
Apple SDK platform (`APPLE_SDK_PLATFORM`, alongside
`APPLE_SDK_VERSION_OVERRIDE` / `XCODE_VERSION_OVERRIDE`),
`tools/perf/replay.py` resolves `DEVELOPER_DIR` from `xcode-select -p`
and `SDKROOT` from `xcrun --sdk <platform lowercased>
--show-sdk-path`, cached per platform. Without those tools (e.g.
Linux) it replays with the logged environment alone.

Ordering (enforced by `tools/perf/run_rep.py`): per repeat and per config,
the workspace is reset from the pristine copy, then all three scenario
builds run, then the execroot's `bazel-out` is made user-writable, then
all three logs are summarized and replayed, then the server shuts down.
Each config builds in its own output base under the per-repeat root, so
configs never share a server. No build follows a replay in the same
output base, so replayed outputs cannot perturb incremental builds.
Builds pass `--materialize_param_files` so `@flagfile` inputs exist at
replay time. Results are stored per config:
`results/<ref>/<config>/<scenario>/rep<N>/`, and the summary reports
medians per config.

Each scenario repeats (`repeats`, default 3); the summary reports medians
with [min, max] spread and head-vs-base deltas (`repeats=1` is called out
as a single sample with no spread). The summary also shows per-mnemonic
replay failure counts (non-zero exit or timeout) and truncation warnings,
so a broken replay can never look like a cost drop. One JSON + one
Markdown file are uploaded as a single artifact (`perf-ios-summary`,
3-day retention). Build outputs are never uploaded.

## Dispatching

Actions > "iOS perf bench" > Run workflow. `head_ref` is required;
`base_ref` defaults to `main`. Keep `target_loc` at the default 500000
unless the 5-hour job timeout is hit, then lower it rather than raising the
timeout. Base and head should share the `rules_dart` pin for a clean
comparison; if they drift, the delta mixes both rule sets.

Rough duration guidance (extrapolation, not a measurement): a 20k-line
Linux smoke builds the shared app kernel in about 80 s; compile cost
scales roughly with lines, so a 500k clean compile lands around the
half-hour mark per config, times two configs, plus fast incremental
rebuilds and serial instruction replay (capped at 30 min per log, 3 h
worst case across 2 refs × 2 configs × 3 scenarios, typically far less).
That fits the 5 h timeout with margin; a 100k dispatch should take
roughly a fifth of the full size. The first successful dispatch
calibrates these numbers; if the job times out, lower `target_loc`.

## Speed-of-light (SOL) mode

The performance dashboard compares each developer flow's cost with its best
case: the same SDK tools run by hand for the same edit. Dispatch the same
workflow with `mode=sol` (Actions > "iOS perf bench" > Run workflow >
`mode: sol`); only `head_ref` is checked out, generated and built.

Per configuration (`device_release`, `sim_debug`) and scenario (`clean`,
`app_edit`, `core_edit` — the same edits compare mode applies), `sol`
mode measures two numbers in the same unit, whole-tree user+sys CPU
seconds:

- the Bazel cost: the whole `bazel --batch build` process tree (Bazel's
  own work plus every action), measured with wait4 rusage deltas, which
  include reaped descendants on both macOS and Linux. One unit for the
  whole run. A macOS instruction counter cannot do this: `/usr/bin/time
  -l` reads "instructions retired" for its direct child alone (the JVM
  for a build, the Python driver for a chain), so instructions are never
  the flow number; `unit` in `ios-sol.json` is always `cpu_seconds`.
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs), run by hand in order. The SOL number is the sum of
  the chain steps' own process-tree CPU — the driver's own cost
  (loading the log, hashing, moving files) is never included. Steps
  whose outputs did not change for the edit are skipped as a person
  would skip them: the execution log records executed spawns only, so
  replaying it replays exactly the work the edit required.

Chain selection is output-based: a host-tool build is a spawn whose
declared outputs land in an exec configuration
(`bazel-out/*-exec-*/`), and only those are left out (building Bazel's
helper tools is part of the gap). Every other executed spawn runs,
whatever tool binary it invokes — an action that runs an exec-built
tool to produce target-configuration outputs (the kernel compile, for
example) belongs in the chain. Command arguments never classify: they
name the tool that runs, not what is built. (Compare mode's replay
allowlist is unchanged.)

Proof the SOL did the same work cannot pass by accident: each chain
step runs as Bazel runs it — its declared outputs are removed before
it starts, so merge-style steps cannot see stale inputs — and before
the chain every declared output of every step that will run is moved
aside. After the chain, whatever the chain wrote at those paths is
removed and Bazel's originals move back, recreating any parent
directory the chain removed. This holds whether the chain succeeded,
stopped at a failed step, or wrote different bytes, so the next
incremental build always finds exactly the files Bazel left. The
scenario's verify files (the App.framework binary for device_release;
the app's kernel blob and the App.framework binary for sim_debug,
located via `cquery --output=files` with a bazel-out glob fallback)
are hashed before and after: files inside a moved output directory
travel with it, while a verify file no running step declares stays
Bazel's own and counts as unchanged for that edit. A step that exits
non-zero, times out or cannot start — or any verify file that differs
afterwards — reports `identical: false` with no SOL number, plus the
step (mnemonic, exit, last stderr lines) and the differing files
(execroot-relative paths with before/after digests). An unexpected
error in one config records its remaining flows with the error as
their reason, lets the other config run, and still writes and uploads
`ios-sol.json` (the job may fail afterwards). Bazel info/query output
is captured stdout-only (Bazel's stderr carries JVM warnings that once
corrupted a parsed path), and every parsed line must resolve to an
existing path under the output base.

Medians over `repeats` go to one small artifact, `ios-sol.json`:

```json
{
  "rules_flutter": "<full sha>",
  "unit": "cpu_seconds",
  "runner": {"system": "Darwin", "machine": "arm64"},
  "flows": {
    "ios-release-clean": {"bazel": 1, "sol": 1, "identical": true,
                          "reason": "ok",
                          "chain": {"steps": {"Genrule": {"count": 1,
                                                          "cpu_s": 1}},
                                    "skipped": {"host-tool build": 2},
                                    "failed": [],
                                    "verify_differ": [],
                                    "output_drift": {"n": 0, "paths": []},
                                    "sol_cpu_s": 1,
                                    "status": "ok"},
                          "spread": {"n": 3, "bazel": [1, 1],
                                     "sol": [1, 1]}}
  }
}
```

Flow ids are `ios-release-{clean,app,body}` (device_release; `body` is
the core_edit) and `ios-debug-{clean,app,body}` (sim_debug). Each flow
carries a small `chain` record — steps run per mnemonic with their CPU
seconds, spawns left out per reason, any failed step, any differing
verify files, and (information only) the number of chain-step outputs
whose digest differs from the digest the execution log recorded in
`actualOutputs` (with up to 10 such paths) — with no command lines —
and a one-line `reason`, also printed per flow in the job log, so the
artifact alone explains what the SOL ran and why a flow is not
identical. The driver is `tools/perf/sol.py` (`run` / `chain` /
`summarize`; unit tests in `sol_test.py` run on Linux CI from recorded
fixtures, including a `run` -> `chain` -> `summarize` end-to-end pass
against a fake `bazel`, with no time binary present).

## Cost rules (binding)

`workflow_dispatch` only; `macos-15`; job timeout 300 minutes; artifact
retention 3 days; no caches; never upload build outputs; never touch
`ci.yaml` or `full.yaml`. The generator and measurement scripts are the
tooling in `tools/perf/` (Python 3 stdlib only).

## Calibrating the replay set

`tools/perf/replay.py` replays a mnemonic allowlist
(`DEFAULT_IOS_MNEMONICS`: the iOS `Flutter*` actions verified in
`flutter/`, plus best-effort `CppCompile`, `CppLink`, `ObjcCompile`,
`ObjcLink`, `SwiftCompile`, `Lipo`). Every report includes the
executed-but-not-replayed table, so the first dispatch shows exactly which
Apple-side mnemonics (actool, storyboards, codesign, final bundle/link)
were missed; extend the allowlist with `--mnemonic` (workflow) or in the
default set (follow-up commit).

## Testing without macOS

Everything except the Bazel invocation, the replay execution, and the
`time -l` counter runs on Linux:

- `python3 -m unittest discover -s tools/perf -p '*_test.py'`
- Generate a small workspace and analyze it:
  `python3 tools/perf/gen_monorepo.py generate --target-loc 20000
  --rules-flutter <checkout> --out <dir>`, then
  `bazel build //packages/... //app:app //app:app_lib --nobuild` in it.
  All three bench targets must load:
  `bazel query '//app:app_framework + //app:app_ios +
  //app:__app_framework_framework'`. The device_release target goes
  further: `bazel build //app:__app_framework_framework --nobuild -c opt
  --ios_multi_cpus=arm64` completes analysis on Linux (only execution
  needs the Apple SDK). The full `//app:app_ios` analysis fails on Linux
  at Apple toolchain resolution, which is expected — macOS builds it.
