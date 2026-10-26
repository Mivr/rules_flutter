#!/usr/bin/env python3
"""Layered Flutter monorepo workspace generator for the iOS perf bench.

Generates a deterministic monorepo-shaped Flutter workspace sized by total
Dart lines of code (``target_loc``), mirroring the manager referee's
``flutter-monorepo`` generator knobs (``target_loc``, ``layers`` default 8,
``fanout`` default 4, ``files_per_package`` default 20, ``seed``):

- Packages spread over ``layers`` (layer 0 holds core/util packages with high
  fan-in, upper layers hold feature packages). Each package above layer 0
  depends on ``fanout`` packages from strictly lower layers (seeded PRNG), so
  the graph is acyclic by construction.
- Every library file is 100-150 lines of realistic Dart (documented enum,
  generic class with chained methods, extension, a widget, imports from the
  own package and from dependencies, ``part`` files in every eighth library).
  The same inputs give a byte-identical tree.
- One ``flutter_library`` per package plus an ``app/`` package with a
  ``flutter_application`` and the Tier-1 iOS app targets
  (``flutter_ios_app`` + an explicit ``flutter_ios_framework_gen``
  App.framework target + simulator build test). This bench measures iOS only,
  so unlike the referee generator there is no Android app and no
  ``flutter_test`` targets unless ``--test-ratio`` asks for them.
- Reachability (generator v2): each package entry calls its direct
  dependencies' entries and every own file's functions (including the
  value functions the bench edits) and constructs every own file's
  widget; ``main`` calls every top-layer entry. Cross-package calls are
  guarded by a probe main reads from a runtime source the compiler
  cannot fold that is zero at run time, so AOT tree-shaking keeps the
  whole program without running it.
- An edit manifest (``bench-edit-manifest.json``) records the file the
  ``body_edit``/``api_edit`` scenarios edit, and a stats file
  (``bench-workspace-stats.json``) records the workspace statistics.

Only the Python 3 standard library is used. Generation streams files to disk
(one file in memory at a time) so large workspaces stay fast.

Scaffolding (MODULE.bazel, pub files, .bazelrc, the ``ios/Runner/`` scaffold
the Tier-1 ``flutter_ios_app`` discovers) is derived from the
``e2e/hello_world`` fixture of the ``--rules-flutter`` checkout, so hermetic
pins can never drift from what ``rules_flutter`` main verifies.

The generated workspace models a consumer's iOS workspace, not this repo's
own checkout: its ``.bazelrc`` carries no ``--lockfile_mode`` flag at all
(Bazel's default applies; any such line the fixture carries is dropped) and
its ``MODULE.bazel`` carries none of the fixture's dev-only dependencies
(top-level ``bazel_dep``, ``register_toolchains`` and
``register_execution_platforms`` calls marked ``dev_dependency = True``
are removed with one following blank line; any other dev-marked call fails
generation, as does any leftover reference to a dropped module).
"""


import argparse
import json
import os
import shutil
import sys
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_monorepo_dart import (
    LOC_TOLERANCE,
    MASK64,
    SplitMix64,
    _LibSpec,
    _lib_class_lines,
    _lib_import_lines,
    _lib_method_lines,
    build_dag,
    count_lines,
    fan_in_counts,
    fan_stats,
    file_rng,
    lib_skeleton_lines,
    method_count_for,
    method_count_range,
    pad_file,
    pick_test_packages,
    plan_total_lines,
    render_all_dart,
    render_app_main,
    render_entrypoint,
    render_lib_file,
    render_part_file,
    render_stateful_widget,
    render_test_file,
    repair_orphans,
    tune_plan_to_target,
)
from gen_monorepo_module import (
    BENCH_MODULE_NAME,
    DART_MODULE_NAMES,
    DEV_DROPPABLE_KINDS,
    FLUTTER_MODULE_NAMES,
    HELLO_MODULE_NAME,
    OVERRIDE_KINDS,
    _PinReplacement,
    _PinResult,
    _apply_pin_replacement,
    _call_bodies,
    _call_spans,
    _check_fixture_text,
    _dropped_module_names,
    _find_matching_paren,
    _has_dev_dependency,
    _scan_code,
    _string_attrs,
    _strip_comments,
    _top_level_calls,
    bazelrc_text,
    check_dropped_names_absent,
    copy_dir_sorted,
    copy_fixture_dir,
    copy_pub_file,
    drop_dev_dependency_blocks,
    extract_pin_block,
    extract_rules_dart_git_override,
    fallback_module_text,
    local_path_override,
    module_bazel_text,
    parse_module_name,
    read_bazel_version_or,
    read_fixture_modules,
    read_tree_modules,
    split_overrides,
    write_plain,
)

STATS_REL_PATH = "bench-workspace-stats.json"
EDIT_MANIFEST_REL_PATH = "bench-edit-manifest.json"

DEFAULT_LAYERS = 8
DEFAULT_FANOUT = 4
DEFAULT_FILES_PER_PACKAGE = 20
DEFAULT_TEST_RATIO = 0.0
DEFAULT_EDIT_LAYER = 0

class Options:
    def __init__(
        self,
        target_loc,
        layers=DEFAULT_LAYERS,
        fanout=DEFAULT_FANOUT,
        files_per_package=DEFAULT_FILES_PER_PACKAGE,
        seed=1,
        test_ratio=DEFAULT_TEST_RATIO,
        edit_layer=DEFAULT_EDIT_LAYER,
    ):
        if target_loc < 1:
            raise ValueError("target_loc must be >= 1")
        if layers < 1:
            raise ValueError("layers must be >= 1")
        if files_per_package < 1:
            raise ValueError("files_per_package must be >= 1")
        if not 0.0 <= test_ratio <= 1.0:
            raise ValueError("test_ratio must be in [0.0, 1.0]")
        if edit_layer >= layers:
            raise ValueError("edit_layer must be < layers")
        self.target_loc = target_loc
        self.layers = layers
        self.fanout = fanout
        self.files_per_package = files_per_package
        self.seed = seed
        self.test_ratio = test_ratio
        self.edit_layer = edit_layer


class MonorepoPlan:
    def __init__(self, opts, n_packages):
        self.dag = build_dag(n_packages, opts.layers, opts.fanout, opts.seed)
        self.has_test = pick_test_packages(
            n_packages, opts.test_ratio, opts.seed
        )
        self.method_counts = []
        for p in range(n_packages):
            counts = []
            for f in range(opts.files_per_package):
                rng = file_rng(opts.seed, p, f)
                skeleton = lib_skeleton_lines(
                    f > 0, len(self.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                counts.append(method_count_for(rng, skeleton))
            self.method_counts.append(counts)

        edit_layer = min(opts.edit_layer, len(self.dag["layers"]) - 1)
        fan_in = fan_in_counts(self.dag)
        edit_pkg = self.dag["layers"][edit_layer][0]
        for pkg in self.dag["layers"][edit_layer]:
            if fan_in[pkg] > fan_in[edit_pkg]:
                edit_pkg = pkg
        self.edit_rel_path = "packages/pkg%d/lib/src/f%s.dart" % (
            edit_pkg,
            pad_file(opts.files_per_package, 0),
        )

    def top_layer(self):
        return self.dag["layers"][-1]


def select_package_count(opts):
    n = max(1, opts.target_loc // (opts.files_per_package * 125))
    seen = set()
    for _ in range(10):
        if n in seen:
            break
        seen.add(n)
        plan = MonorepoPlan(opts, n)
        total = tune_plan_to_target(opts, plan)
        lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
        hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
        if lo <= total <= hi:
            return (plan, total)
        per_pkg = max(total, 1) // max(n, 1)
        nxt = min(1000000, max(1, opts.target_loc // max(per_pkg, 1)))
        if nxt == n:
            n = n + 1 if total < opts.target_loc else max(1, n - 1)
        else:
            n = nxt
    raise ValueError(
        "flutter-monorepo could not reach target_loc %d within +/-%d%% "
        "(last tried %d packages)"
        % (opts.target_loc, int(LOC_TOLERANCE * 100), n)
    )


def write_app_build(out_dir, top_layer):
    """app/BUILD.bazel: VM application, analyzer library, Tier-1 iOS app.

    flutter_ios_app tags every internal target "manual" itself, so iOS stays
    out of a Linux //... (the ios/Runner/ scaffold it discovers is copied
    from the hello_world fixture). Five top-level targets: the shared
    flutter_application, its analyzer library, the full Tier-1 simulator/
    device app, an explicit public App.framework target (Tier-2
    flutter_ios_framework_gen over the same application, so the bench's
    device_release config builds a stable public label instead of the
    macro's private __app_ios_app_framework), and the simulator build test.
    """
    app_deps = "".join("        \"//packages/pkg%d\",\n" % a for a in top_layer)
    build = (
        "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_application\", \"flutter_library\")\n"
        "load(\"@rules_flutter//flutter:ios.bzl\", \"flutter_ios_app\", \"flutter_ios_framework_gen\", \"flutter_ios_simulator_build_test\")\n"
        "\n"
        "flutter_application(\n"
        "    name = \"app\",\n"
        "    package_name = \"app\",\n"
        "    main = \"lib/main.dart\",\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
        "# The app rule is a bundle and carries no DartInfo, so the sources are\n"
        "# declared once more as a library for the analyzer to stage.\n"
        "flutter_library(\n"
        "    name = \"app_lib\",\n"
        "    package_name = \"app\",\n"
        "    srcs = glob([\"lib/**/*.dart\"]),\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
        "# iOS, Tier-1 style: the macro discovers ios/Runner/ from `flutter create`\n"
        "# and tags every internal target \"manual\" itself, so a Linux `//...`\n"
        "# skips the whole stack without any explicit constraint here.\n"
        "flutter_ios_app(\n"
        "    name = \"app_ios\",\n"
        "    app_name = \"Bench\",\n"
        "    application = \":app\",\n"
        "    bundle_id = \"com.example.bench\",\n"
        ")\n"
        "\n"
        "# Explicit public App.framework target for the device_release bench\n"
        "# config: AOT gen_snapshot for arm64 plus framework assembly, with no\n"
        "# ios_application, so no signing and no provisioning profile.\n"
        "flutter_ios_framework_gen(\n"
        "    name = \"app_framework\",\n"
        "    application = \":app\",\n"
        ")\n"
        "\n"
        "flutter_ios_simulator_build_test(\n"
        "    name = \"app_ios_sim\",\n"
        "    targets = [\":app_ios\"],\n"
        "    target_compatible_with = [\"@platforms//os:macos\"],\n"
        ")\n"
    )
    write_plain(out_dir, "app/BUILD.bazel", build)
    return 5


class _ScaffoldFiles(NamedTuple):
    """Workspace locations the scaffolding files are written to."""

    out_dir: str
    rules_flutter_dir: str
    overrides: list


def _write_root_files(files):
    """MODULE, pub files, bazelrc, analysis config and the ios scaffold."""
    out_dir = files.out_dir
    rules_flutter_dir = files.rules_flutter_dir
    overrides = files.overrides
    bazel_version = read_bazel_version_or(rules_flutter_dir)
    write_plain(
        out_dir, "MODULE.bazel", module_bazel_text(rules_flutter_dir, overrides))
    copy_pub_file(
        out_dir, rules_flutter_dir, "pubspec.lock",
        "# Generated by pub\npackages: {}\nsdks:\n  dart: \">=3.9.0 <4.0.0\"\n")
    copy_pub_file(
        out_dir, rules_flutter_dir, "pubspec.yaml",
        "name: bench_monorepo\nenvironment:\n  sdk: ^3.9.0\n")
    write_plain(out_dir, ".bazelversion", bazel_version + "\n")
    write_plain(out_dir, ".bazelrc", bazelrc_text(rules_flutter_dir))
    copy_pub_file(
        out_dir, rules_flutter_dir, "analysis_options.yaml",
        "analyzer:\n  language:\n    strict-casts: true\n")
    write_plain(
        out_dir, "BUILD.bazel",
        "load(\"@rules_dart//dart:defs.bzl\", \"dart_analysis_config\", \"dart_analysis_options\")\n"
        "\n"
        "exports_files([\"pubspec.lock\"])\n"
        "\n"
        "dart_analysis_options(\n"
        "    name = \"options\",\n"
        "    src = \"analysis_options.yaml\",\n"
        "    deps = [\"@deps//:very_good_analysis\"],\n"
        ")\n"
        "\n"
        "dart_analysis_config(\n"
        "    name = \"analysis_config\",\n"
        "    options = [\":options\"],\n"
        ")\n")
    copy_fixture_dir(
        out_dir, rules_flutter_dir, ["e2e", "hello_world", "ios"], "app/ios")


def _package_build_text(package, deps):
    """One leaf package BUILD.bazel (library over its direct deps)."""
    dep_lines = "".join(
        "        \"//packages/pkg%d\",\n" % d for d in deps)
    return (
        "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_library\", \"flutter_test\")\n"
        "\n"
        "_HOST_COMPATIBLE = select({\n"
        "    \"@platforms//os:linux\": [],\n"
        "    \"@platforms//os:macos\": [],\n"
        "    \"@platforms//os:windows\": [],\n"
        "    \"//conditions:default\": [\"@platforms//:incompatible\"],\n"
        "})\n"
        "\n"
        "flutter_library(\n"
        "    name = \"pkg%d\",\n" % package
        + "    package_name = \"pkg%d\",\n" % package
        + "    srcs = glob([\"lib/**/*.dart\"]),\n"
        + "    visibility = [\"//visibility:public\"],\n"
        + "    deps = [\n"
        + "%s" % dep_lines
        + "        \"@deps//:flutter\",\n"
        + "    ],\n"
        + ")\n"
    )


def _package_test_build_text(package, deps):
    """The flutter_test block appended for packages with tests."""
    dep_lines = "".join(
        "        \"//packages/pkg%d\",\n" % d for d in deps)
    return (
        "\nflutter_test(\n"
        "    name = \"pkg%d_test\",\n" % package
        + "    package_name = \"pkg%d\",\n" % package
        + "    main = \"test/pkg%d_test.dart\",\n" % package
        + "    srcs = glob([\"lib/**/*.dart\"]),\n"
        + "    target_compatible_with = _HOST_COMPATIBLE,\n"
        + "    deps = [\n"
        + "%s" % dep_lines
        + "        \"@deps//:flutter\",\n"
        + "        \"@deps//:flutter_test\",\n"
        + "    ],\n"
        + ")\n"
    )


def _write_package_builds(out_dir, plan):
    """Per-package BUILD.bazel files; returns the targets added."""
    targets = 0
    n = len(plan.dag["deps"])
    for p in range(n):
        write_plain(out_dir, "packages/pkg%d/BUILD.bazel" % p,
                    _package_build_text(p, plan.dag["deps"][p]))
        targets += 1
        if plan.has_test[p]:
            path = os.path.join(out_dir, "packages/pkg%d/BUILD.bazel" % p)
            with open(path, encoding="utf-8") as fh:
                existing = fh.read()
            write_plain(
                out_dir, "packages/pkg%d/BUILD.bazel" % p,
                existing + _package_test_build_text(p, plan.dag["deps"][p]))
            targets += 1
    return targets


def write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally):
    _write_root_files(_ScaffoldFiles(out_dir, rules_flutter_dir, overrides))
    tally["targets"] += _write_package_builds(out_dir, plan)
    tally["targets"] += write_app_build(out_dir, plan.top_layer())


def generate_flutter_monorepo(out_dir, rules_flutter_dir, overrides, opts):
    if not os.path.isdir(rules_flutter_dir):
        raise ValueError(
            "rules_flutter directory '%s' does not exist" % rules_flutter_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    plan, _ = select_package_count(opts)

    tally = {"files": 0, "lines": 0, "targets": 0}
    write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally)

    def write_dart(rel, content):
        write_plain(out_dir, rel, content)
        tally["files"] += 1
        tally["lines"] += count_lines(content)

    render_all_dart(opts, plan, write_dart)

    n = len(plan.dag["deps"])
    fan_in = fan_in_counts(plan.dag)
    fan_out = [len(d) for d in plan.dag["deps"]]
    stats = {
        "edit_layer": opts.edit_layer,
        "fan_in": fan_stats(fan_in),
        "fan_out": fan_stats(fan_out),
        "files": tally["files"],
        "generator": "flutter-monorepo",
        # Shape version: 2 = reachable program (entries call dep entries
        # and own functions under an unfoldable guard, main calls top-layer
        # entries). v1 numbers are never comparable with v2 numbers.
        "generator_version": 2,
        "layers": opts.layers,
        "lines": tally["lines"],
        "packages": n,
        "seed": opts.seed,
        "target_loc": opts.target_loc,
        "targets": tally["targets"],
        "test_ratio": opts.test_ratio,
    }

    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    if tally["lines"] < lo or tally["lines"] > hi:
        raise ValueError(
            "flutter-monorepo generated %d lines for target_loc %d "
            "(outside +/-%d%%)"
            % (tally["lines"], opts.target_loc, int(LOC_TOLERANCE * 100)))

    manifest = {
        "api_edit": plan.edit_rel_path,
        "body_edit": plan.edit_rel_path,
        "app_main": "app/lib/main.dart",
    }
    write_plain(
        out_dir, EDIT_MANIFEST_REL_PATH,
        json.dumps(manifest, indent=2) + "\n")
    write_plain(
        out_dir, STATS_REL_PATH, json.dumps(stats, indent=2) + "\n")
    return stats


# --------------------------------------------------------------------------
# Edits.


def resolve_edit_path(workspace_dir, key):
    """Manifest edit target, validated (relative, contained, Dart, exists)."""
    manifest_path = os.path.join(workspace_dir, EDIT_MANIFEST_REL_PATH)
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    rel = manifest.get(key)
    if not rel:
        raise ValueError(
            "edit manifest '%s' is missing required key '%s'"
            % (manifest_path, key))
    if os.path.isabs(rel):
        raise ValueError("edit manifest has an absolute '%s' path" % key)
    if ".." in rel.split(os.sep):
        raise ValueError("edit manifest has an escaping '%s' path" % key)
    if not rel.endswith(".dart"):
        raise ValueError("edit manifest has a non-Dart '%s' path" % key)
    full = os.path.join(workspace_dir, rel)
    if not os.path.isfile(full):
        raise ValueError("edit manifest '%s' target '%s' does not exist"
                         % (key, full))
    return full


def apply_body_edit(workspace_dir, key="body_edit"):
    """Body-only edit keeping the public API (kernel outline) unchanged."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "i * 1]" in original:
        edited = original.replace("i * 1]", "i * 1 + 0]", 1)
    elif "var total = 1;" in original:
        edited = original.replace("var total = 1;", "var total = 2;", 1)
    elif "return " in original:
        pos = original.rfind("return ")
        edited = original[:pos] + "final _ = 0;\n  " + original[pos:]
    else:
        raise ValueError("unable to apply body-only edit to '%s'" % path)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_api_edit(workspace_dir, key="api_edit"):
    """Public API edit (adding a member), changing the kernel outline."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "  /// The value.\n" in original:
        edited = original.replace(
            "  /// The value.\n",
            "  /// Added API.\n  int get extra => 1;\n\n  /// The value.\n",
            1)
    else:
        edited = original + "\n/// Added API.\nint addedApi0x0() => 1;\n"
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_app_edit(workspace_dir):
    """Behaviour-changing top-layer edit of the bench application.

    Bumps the first wired widget's displayed value, changing what the app
    renders without touching any package API.
    """
    path = os.path.join(workspace_dir, "app", "lib", "main.dart")
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    marker = "W"
    idx = original.find("              W")
    if idx < 0:
        raise ValueError(
            "unable to apply app edit: no wired widget in '%s'" % path)
    end = original.find("),", idx)
    if end < 0:
        raise ValueError(
            "unable to apply app edit: malformed widget line in '%s'" % path)
    line = original[idx:end]
    if marker not in line or "value" not in line:
        raise ValueError(
            "unable to apply app edit: unexpected widget line in '%s'" % path)
    edited = original[:end] + " + 1" + original[end:]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


# --------------------------------------------------------------------------
# CLI.


def build_parser():
    parser = argparse.ArgumentParser(
        description="Generate a layered Flutter monorepo for the iOS bench.")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="generate a workspace")
    gen.add_argument("--target-loc", type=int, required=True)
    gen.add_argument("--layers", type=int, default=DEFAULT_LAYERS)
    gen.add_argument("--fanout", type=int, default=DEFAULT_FANOUT)
    gen.add_argument("--files-per-package", type=int,
                     default=DEFAULT_FILES_PER_PACKAGE)
    gen.add_argument("--seed", type=int, default=1)
    gen.add_argument("--test-ratio", type=float, default=DEFAULT_TEST_RATIO)
    gen.add_argument("--edit-layer", type=int, default=DEFAULT_EDIT_LAYER)
    gen.add_argument("--rules-flutter", required=True)
    gen.add_argument("--out", required=True)
    gen.add_argument("--override", action="append", default=[],
                     metavar="NAME=PATH",
                     help="extra local_path_override (repeatable)")

    for name in ["apply-body-edit", "apply-api-edit", "apply-app-edit"]:
        p = sub.add_parser(name, help="%s in a generated workspace" % name)
        p.add_argument("--workspace", required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "generate":
        overrides = []
        for item in args.override:
            name, _, path = item.partition("=")
            if not name or not path:
                raise ValueError(
                    "--override must be NAME=PATH, got '%s'" % item)
            overrides.append((name, path))
        opts = Options(
            target_loc=args.target_loc,
            layers=args.layers,
            fanout=args.fanout,
            files_per_package=args.files_per_package,
            seed=args.seed,
            test_ratio=args.test_ratio,
            edit_layer=args.edit_layer,
        )
        stats = generate_flutter_monorepo(
            args.out, args.rules_flutter, overrides, opts)
        print(json.dumps(stats, indent=2))
    elif args.command == "apply-body-edit":
        apply_body_edit(args.workspace)
    elif args.command == "apply-api-edit":
        apply_api_edit(args.workspace)
    elif args.command == "apply-app-edit":
        apply_app_edit(args.workspace)
    else:  # pragma: no cover
        parser.error("unknown command '%s'" % args.command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
