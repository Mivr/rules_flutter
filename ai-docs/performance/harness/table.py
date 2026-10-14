"""Prints result files side by side as a Markdown table.

Usage: table.py <label> [<label> ...]   (reads $RULES_FLUTTER_BENCH_DIR/results/<label>.json,
or <checkout>/ai-docs/performance/results/<label>.json when the bench copy is absent).
Adapted from rules_dart's harness table.py; the Flutter-specific rows are added.
"""
import json, os, sys

S = os.environ.get("RULES_FLUTTER_BENCH_DIR", os.path.expanduser("~/rules_flutter_bench"))


def load(label):
    p = f"{S}/results/{label}.json"
    if not os.path.exists(p):
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", f"{label}.json")
    return json.load(open(p))


def g(r, *path):
    v = r["scenarios"]
    for p in path:
        v = v.get(p) if isinstance(v, dict) else None
        if v is None:
            return "–"
    return v


ROWS = [
    ("Re-analysis, analysis variant (s)", ("reanalysis_{n}pkg_s",)),
    ("Clean build wall (s)", ("clean_build", "wall_s")),
    ("  compile CPU (s)", ("clean_build", "actions", "DartCompile", "cpu_s")),
    ("  kernel compile CPU (s)", ("clean_build", "actions", "FlutterKernelCompile", "cpu_s")),
    ("  asset bundle CPU (s)", ("clean_build", "actions", "FlutterAssetBundle", "cpu_s")),
    ("  sandboxed actions", ("clean_build", "sandboxed")),
    ("Body edit rebuild (s)", ("body_edit_build", "wall_s")),
    ("  compiles re-run", ("body_edit_build", "actions", "DartCompile", "n")),
    ("  kernel compiles re-run", ("body_edit_build", "actions", "FlutterKernelCompile", "n")),
    ("API edit rebuild (s)", ("api_edit_build", "wall_s")),
    ("Null build (s)", ("null_build_s",)),
    ("Test run wall (s)", ("test_run", "wall_s")),
    ("  per test (s)", ("test_run", "per_test_s")),
    ("Test runfiles (files)", ("test_runfiles", "files")),
    ("Test runfiles (MB)", ("test_runfiles", "mb")),
    ("Kernel inputs of one test (files)", ("kernel_inputs", "inputs")),
    ("Kernel inputs of one test (MB)", ("kernel_inputs", "mb")),
    ("Fetched external dirs (MB)", ("fetch_footprint", "total_mb")),
    ("  rules_dart Dart SDK fetched", ("fetch_footprint", "rules_dart_linux_sdk_fetched")),
    ("Lint clean wall (s)", ("lint_clean", "wall_s")),
    ("  sandboxed actions", ("lint_clean", "sandboxed")),
    ("Lint body edit wall (s)", ("lint_body_edit", "wall_s")),
    ("  analyze re-run", ("lint_body_edit", "actions", "DartAnalyze", "n")),
    ("  format re-run", ("lint_body_edit", "actions", "DartFormat", "n")),
    ("  copies re-run", ("lint_body_edit", "actions", "CopyToDirectory", "n")),
]


def main():
    labels = sys.argv[1:]
    runs = [load(l) for l in labels]
    print("| Metric | " + " | ".join(f"{r['label']} ({r['rules_rev']})" for r in runs) + " |")
    print("|---|" + "---|" * len(runs))
    for name, path in ROWS:
        if path[0].startswith("reanalysis_"):
            cells = []
            for r in runs:
                keys = [k for k in r["scenarios"] if k.startswith("reanalysis_")]
                cells.append(str(r["scenarios"][keys[0]]) if keys else "–")
        else:
            cells = [str(g(r, *path)) for r in runs]
        print(f"| {name} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
