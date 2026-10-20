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

- `device_release`: the Flutter iOS framework only —
  `//app:app_framework` with `-c opt --ios_multi_cpus=arm64`. That target
  is an explicit public `flutter_ios_framework_gen` over the shared
  application (emitted by the generator, not the macro's private
  `__app_ios_app_framework`), covering AOT gen_snapshot for arm64 plus
  App.framework assembly with no `ios_application`, hence no signing and
  no provisioning profile.
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
  Linux sandbox runs omit user/sys; `cpu_time_available` says whether any
  spawn carried them, so missing data is never mistaken for zero CPU.
- Instructions retired for the iOS-only actions (`FlutterAotMacho`
  gen_snapshot for iOS, the `FlutterIOS*` framework/bundle tools,
  `FlutterStripEngine`, `FlutterPlistMerge`, `FlutterMachOVerifyProbe`,
  assembler/clang and linker steps), by replaying each such action's
  command line under `/usr/bin/time -l` with the logged environment in the
  build's execroot right after the build. Kernel compiles are excluded
  (the Linux bench measures them); pass `--mnemonic` to opt back in.
  Replays run with stdin closed, a 600 s per-action timeout, and an
  1800 s whole-log budget; on exhaustion the report records
  `truncated=true` and the skipped count.

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
  Both bench targets must load:
  `bazel query '//app:app_framework + //app:app_ios'`. Configured
  analysis of either iOS target fails on Linux at Apple toolchain
  resolution (no Apple SDK), which is expected — macOS builds them.
