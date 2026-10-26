#!/usr/bin/env python3
"""PRNG, DAG construction, and Dart source rendering for the monorepo bench."""

import math
import os
import sys
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MASK64 = (1 << 64) - 1
LOC_TOLERANCE = 0.05

# --------------------------------------------------------------------------
# Deterministic PRNG (splitmix64, same stream shape as the referee generator).


class SplitMix64:
    """Small deterministic PRNG. Same seed yields the same stream everywhere."""

    def __init__(self, state):
        self.state = state & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def below(self, n):
        if n <= 0:
            raise ValueError("SplitMix64.below requires n >= 1")
        return self.next() % n


def file_rng(seed, package, file):
    """Per-file PRNG stream derived from the workspace seed (deterministic)."""
    return SplitMix64(seed + package * 1000003 + file * 1000033 + 0xA5A5A5A5)


# --------------------------------------------------------------------------
# Package DAG.


def repair_orphans(deps, layer_vecs, layer_count, seed):
    """Attaches every unreachable package to a higher-layer dependent.

    Generator v2 needs every package below the top layer reachable from
    main through the DAG (each entry calls its dependencies' entries, main
    calls the top layer). The seeded fanout above can leave a package with
    no dependents; such an orphan gains one edge from a package in a
    strictly higher layer, drawn from a fresh seeded stream so the main
    fanout stream is undisturbed. Top-layer packages need no repair: main
    calls them all directly. Edges stay sorted, unique, and downward, so
    the graph remains an acyclic layered DAG.
    """
    if layer_count < 2:
        return
    fan_in = [0] * len(deps)
    for edges in deps:
        for d in edges:
            fan_in[d] += 1
    rng = SplitMix64((seed ^ 0x0B971E) & MASK64)
    for layer in range(layer_count - 1):
        higher = [q for upper in layer_vecs[layer + 1:] for q in upper]
        for pkg in layer_vecs[layer]:
            if fan_in[pkg] > 0:
                continue
            dependent = higher[rng.below(len(higher))]
            deps[dependent].append(pkg)
            deps[dependent].sort()
            fan_in[pkg] += 1


def build_dag(n_packages, layers, fanout, seed):
    """Layered DAG: deps[p] holds the sorted direct deps of package p.

    Packages spread over min(layers, n_packages) layers (extras go to the top
    layers); each package above layer 0 depends on min(fanout, lower_count)
    distinct packages from strictly lower layers. A repair pass then gives
    every package below the top layer at least one dependent (generator v2
    reachability), adding the minimum edges to packages that fanout left
    orphaned.
    """
    if n_packages < 1:
        raise ValueError("build_dag requires n_packages >= 1")
    layer_count = max(1, min(layers, n_packages))
    base = n_packages // layer_count
    rem = n_packages % layer_count

    layer_vecs = []
    layer_of = [0] * n_packages
    next_pkg = 0
    for layer in range(layer_count):
        size = base + (1 if layer >= layer_count - rem else 0)
        members = []
        for _ in range(size):
            layer_of[next_pkg] = layer
            members.append(next_pkg)
            next_pkg += 1
        layer_vecs.append(members)

    rng = SplitMix64((seed ^ 0x51F15EED) & MASK64)
    deps = [[] for _ in range(n_packages)]
    for layer in range(1, layer_count):
        # Candidate pool: every package in a strictly lower layer. Built once
        # per layer; the per-package partial Fisher-Yates mutates it in place
        # through the shared seeded stream.
        candidates = [p for lower in layer_vecs[:layer] for p in lower]
        for pkg in layer_vecs[layer]:
            want = min(fanout, len(candidates))
            for j in range(want):
                k = j + rng.below(len(candidates) - j)
                candidates[j], candidates[k] = candidates[k], candidates[j]
            deps[pkg] = sorted(candidates[:want])

    repair_orphans(deps, layer_vecs, layer_count, seed)

    return {"deps": deps, "layer_of": layer_of, "layers": layer_vecs}


def fan_in_counts(dag):
    fan_in = [0] * len(dag["deps"])
    for deps in dag["deps"]:
        for d in deps:
            fan_in[d] += 1
    return fan_in


def fan_stats(values):
    if not values:
        return {"max": 0, "mean": 0.0, "min": 0}
    return {
        "max": max(values),
        "mean": sum(values) / len(values),
        "min": min(values),
    }


def pick_test_packages(n_packages, test_ratio, seed):
    """Seeded shuffle picking round(n * test_ratio) packages for flutter_test."""
    selected = [False] * n_packages
    k = min(int(round(n_packages * test_ratio)), n_packages)
    if k == 0:
        return selected
    rng = SplitMix64((seed ^ 0x7E57) & MASK64)
    order = list(range(n_packages))
    for j in range(k):
        swap = j + rng.below(n_packages - j)
        order[j], order[swap] = order[swap], order[j]
        selected[order[j]] = True
    return selected


# --------------------------------------------------------------------------
# File sizing.


def method_count_range(skeleton_lines):
    """Admissible method-count range keeping the file total in [100, 150]."""
    under = max(0, 100 - skeleton_lines)
    min_m = max(1, (under + 7) // 8)
    over = max(0, 150 - skeleton_lines)
    max_m = max(min_m, over // 8)
    return (min_m, max_m)


def method_count_for(rng, skeleton_lines):
    min_m, max_m = method_count_range(skeleton_lines)
    if max_m <= min_m:
        return min_m
    return min_m + rng.below(max_m - min_m + 1)


def pad_file(files_per_package, file):
    width = max(1, len(str(files_per_package - 1)))
    return str(file).zfill(width)


def lib_skeleton_lines(has_sibling, dep_count, has_part, odd_file):
    """Exact non-method line count of render_lib_file for the given shape.

    Must stay in lockstep with the template; unit tests cross-check it.
    """
    # Base: material import (1) + blank (1) + file doc (1) + enum
    # (header + 4 documented values + close = 10) + blank (1) + extension
    # (16) + blank (1) + class (19) + close (1) + blank (1) + stateless
    # widget (13) + blank (1) + value function (7) + helper (6).
    lines = 79
    if has_sibling:
        lines += 1  # sibling package: import
        lines += 1  # sibling call in fn
    if dep_count > 0:
        lines += dep_count  # dep imports
        lines += 2 * dep_count + 1  # per-dep doc + typedef + blank
    if has_part:
        lines += 1  # part directive
    if odd_file:
        lines += 21  # stateful widget block is 21 lines larger
    return lines


# --------------------------------------------------------------------------
# Dart rendering.


class _LibSpec(NamedTuple):
    """Shape of one generated library file: identity plus dependencies."""

    package: int
    file: int
    files_per_package: int
    deps: tuple
    method_count: int

    @property
    def has_sibling(self):
        return self.file > 0

    @property
    def has_part(self):
        return self.file % 8 == 0

    @property
    def odd_file(self):
        return self.file % 2 == 1

    @property
    def factor(self):
        return self.file + 2

    @property
    def pad(self):
        return pad_file(self.files_per_package, self.file)


def _lib_import_lines(spec):
    """Import block plus the dependency typedefs of one library file."""
    package = spec.package
    file = spec.file
    imports = ["import 'package:flutter/material.dart';"]
    for d in spec.deps:
        imports.append("import 'package:pkg%d/pkg%d.dart';" % (d, d))
    if spec.has_sibling:
        imports.append(
            "import 'package:pkg%d/src/f%s.dart';"
            % (package, pad_file(spec.files_per_package, file - 1))
        )
    imports.sort()

    out = []
    out.extend(imports)
    out.append("")
    if spec.has_part:
        out.append("part 'f%s.part.dart';" % spec.pad)
    if spec.deps:
        dep_lines = sorted(
            "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in spec.deps
        )
        for line in dep_lines:
            d = int(line.split("pkg")[1].split("/")[0])
            out.append("/// Dependency API of package pkg%d used here." % d)
            out.append("typedef D%dx%dA%d = C%dx0<int>;" % (package, file, d, d))
        out.append("")
    return out


def _lib_class_lines(spec):
    """Value-holder class header, fields and small members."""
    package, file = spec.package, spec.file
    out = []
    out.append("/// Boxed value %d of package %d." % (file, package))
    if spec.has_part:
        out.append("class C%dx%d<T> with M%dx%d {" % (package, file, package, file))
    else:
        out.append("class C%dx%d<T> {" % (package, file))
    out.append("  /// Creates the value holder.")
    out.append("  C%dx%d(this.value, [this.tag, this.payload]);" % (package, file))
    out.append("")
    out.append("  /// The value.")
    out.append("  final int value;")
    out.append("")
    out.append("  /// The tag.")
    out.append("  final E%dx%d? tag;" % (package, file))
    out.append("")
    out.append("  /// The extra payload.")
    out.append("  final T? payload;")
    out.append("")
    out.append("  /// Describe this holder.")
    out.append("  String describe() => 'C%dx%d($value)';" % (package, file))
    out.append("")
    out.append("  /// Pick an item.")
    out.append("  T? pick(List<T> items) => items.isEmpty ? null : items.first;")
    return out


def _lib_method_lines(spec):
    """The chained m0.. methods of the value holder."""
    out = []
    for m in range(spec.method_count):
        tail = " + m%d(x)" % (m + 1) if m + 1 < spec.method_count else ""
        out.append("  /// Method %d of C%dx%d." % (m, spec.package, spec.file))
        out.append("  int m%d(int x) {" % m)
        out.append("    var total = x + value;")
        out.append("    for (var i = 0; i < x; i++) {")
        out.append("      total += i * %d;" % spec.factor)
        out.append("    }")
        out.append("    return total%s;" % tail)
        out.append("  }")
    return out


def render_lib_file(package, file, files_per_package, deps, method_count):
    """One library file: package: imports only, enum, extension, generic class.

    Layout (100-150 lines): a documented enum, a generic class with
    method_count chained methods, one widget (stateless on even files,
    stateful on odd files), a public value function and a local helper. The
    class carries the api_edit marker ("  /// The value.") and the value
    function the body_edit marker ("  var total = 1;").
    """
    spec = _LibSpec(package, file, files_per_package, tuple(deps),
                    method_count)

    out = []
    out.extend(_lib_import_lines(spec))
    out.append("/// File %d of package %d." % (file, package))
    out.append("enum E%dx%d {" % (package, file))
    for value, kind in [
        ("alpha", "First"),
        ("beta", "Second"),
        ("gamma", "Third"),
        ("delta", "Fourth"),
    ]:
        out.append("  /// %s kind." % kind)
        out.append("  %s," % value)
    out.append("}")
    out.append("")
    out.append("/// Extension on [E%dx%d]." % (package, file))
    out.append("extension E%dx%dExt on E%dx%d {" % (package, file, package, file))
    out.append("  /// Describe this value.")
    out.append("  String describe() {")
    out.append("    switch (this) {")
    for value in ["alpha", "beta", "gamma", "delta"]:
        out.append("      case E%dx%d.%s:" % (package, file, value))
        out.append("        return 'p%df%d:%s';" % (package, file, value))
    out.append("    }")
    out.append("  }")
    out.append("}")
    out.append("")
    out.extend(_lib_class_lines(spec))
    out.extend(_lib_method_lines(spec))
    out.append("}")
    out.append("")
    if spec.odd_file:
        out.extend(render_stateful_widget(package, file))
    else:
        out.append("/// Widget %d of package %d." % (file, package))
        out.append("class W%dx%d extends StatelessWidget {" % (package, file))
        out.append("  /// Creates the widget.")
        out.append("  const W%dx%d({super.key, this.value = 0});" % (package, file))
        out.append("")
        out.append("  /// The number shown.")
        out.append("  final int value;")
        out.append("")
        out.append("  @override")
        out.append("  Widget build(BuildContext context) {")
        out.append(
            "    return Text('pkg%d f%d: $value ${value%dx%d()}');"
            % (package, file, package, file)
        )
        out.append("  }")
        out.append("}")
    out.append("")
    out.append("/// Plain value of file %d of package %d." % (file, package))
    out.append("int value%dx%d() {" % (package, file))
    out.append("  var total = 1;")
    out.append("  total += fn%dx%d(%d);" % (package, file, file + 1))
    out.append("  return total % 1000003;")
    out.append("}")
    out.append("")
    out.append("/// Local helper of file %d of package %d." % (file, package))
    out.append("int fn%dx%d(int x) {" % (package, file))
    out.append("  var total = x + 1;")
    out.append(
        "  total += C%dx%d<int>(total).m0(total %% 7);" % (package, file)
    )
    if spec.has_sibling:
        out.append("  total += fn%dx%d(x);" % (package, file - 1))
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_stateful_widget(package, file):
    """Stateful widget block of a library file (odd files only)."""
    p, f = package, file
    return [
        "/// Stateful widget %d of package %d." % (f, p),
        "class S%dx%d extends StatefulWidget {" % (p, f),
        "  /// Creates the widget.",
        "  const S%dx%d({super.key, this.value = 0});" % (p, f),
        "",
        "  /// The number shown.",
        "  final int value;",
        "",
        "  @override",
        "  State<S%dx%d> createState() => _S%dx%dState();" % (p, f, p, f),
        "}",
        "",
        "/// State of [S%dx%d]." % (p, f),
        "class _S%dx%dState extends State<S%dx%d> {" % (p, f, p, f),
        "  int _counter = 0;",
        "",
        "  /// Increments the counter.",
        "  void incrementCounter() {",
        "    setState(() {",
        "      _counter++;",
        "    });",
        "  }",
        "",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return Column(",
        "      mainAxisSize: MainAxisSize.min,",
        "      children: [",
        "        Text('pkg%d f%d: ${widget.value} ${value%dx%d()} $_counter'),"
        % (p, f, p, f),
        "        TextButton(onPressed: incrementCounter, child: const Text('+')),",
        "      ],",
        "    );",
        "  }",
        "}",
    ]


def render_part_file(package, file, files_per_package):
    pad = pad_file(files_per_package, file)
    return "\n".join(
        [
            "part of 'f%s.dart';" % pad,
            "",
            "/// Mixin for [C%dx%d]." % (package, file),
            "mixin M%dx%d {" % (package, file),
            "  /// Adjust a value.",
            "  int adjust(int x) => x + 1;",
            "}",
        ]
    ) + "\n"


def render_entrypoint(package, files_per_package, deps):
    """Package entry point: own files' functions plus dependencies' entries.

    Calls every own file's helper and value functions (including the value
    functions the bench edits) and constructs every own file's widget, all
    unconditionally, so any body_edit in the package changes the AOT
    program. Cross-package calls to the direct dependencies' entries are
    guarded by [probe]: main passes a value from a runtime source the
    compiler cannot fold that is zero at run time, so the whole transitive
    closure stays reachable for AOT tree-shaking without running.
    """
    imports = [
        "import 'package:pkg%d/src/f%s.dart';"
        % (package, pad_file(files_per_package, f))
        for f in range(files_per_package)
    ]
    imports.extend(
        "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in deps
    )
    imports.sort()
    out = ["/// Public API of package pkg%d." % package]
    out.extend(imports)
    for f in range(files_per_package):
        out.append("export 'src/f%s.dart';" % pad_file(files_per_package, f))
    out.append("")
    out.append("/// Entry point of package %d." % package)
    out.append("///")
    out.append("/// Calls every own file's functions and — guarded by [probe]")
    out.append("/// — the direct dependencies' entries.")
    out.append("int entry%d(int x, int probe) {" % package)
    out.append("  var total = x;")
    for f in range(files_per_package):
        out.append("  total += fn%dx%d(x);" % (package, f))
    for f in range(files_per_package):
        out.append("  total += value%dx%d();" % (package, f))
    for f in range(files_per_package):
        widget = "W" if f % 2 == 0 else "S"
        out.append(
            "  total += const %s%dx%d(value: 1).value;" % (widget, package, f)
        )
    if deps:
        out.append("  if (probe != 0) {")
        for d in deps:
            out.append("    total += entry%d(x, probe);" % d)
        out.append("  }")
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_test_file(package):
    return "\n".join(
        [
            "import 'package:flutter/material.dart';",
            "import 'package:flutter_test/flutter_test.dart';",
            "import 'package:pkg%d/pkg%d.dart';" % (package, package),
            "",
            "void main() {",
            "  testWidgets('W%dx0 renders in a MaterialApp', (tester) async {"
            % package,
            "    await tester.pumpWidget(",
            "      const MaterialApp(home: Scaffold(body: W%dx0(value: 1))),"
            % package,
            "    );",
            "    expect(find.byType(W%dx0), findsOneWidget);" % package,
            "    expect(value%dx0(), greaterThan(0));" % package,
            "  });",
            "}",
        ]
    ) + "\n"


def render_app_main(top_layer):
    """Application entrypoint wiring every top-layer feature package.

    Builds every top-layer package's widget and calls every top-layer
    package's entry point with a probe main reads from a runtime source
    (`int.tryParse` on a non-numeric literal is always null here, so the
    probe is zero at run time) the compiler cannot fold, keeping the
    guarded cross-package calls reachable for AOT tree-shaking. The summed
    entry results flow into a displayed string, so edited functions below
    the top layer have a reachable use.
    """
    out = ["import 'package:flutter/material.dart';"]
    dep_imports = sorted(
        "import 'package:pkg%d/pkg%d.dart';" % (a, a) for a in top_layer
    )
    out.extend(dep_imports)
    out.append("")
    out.append("/// Bench application wiring the top-layer feature packages.")
    out.append("void main() {")
    out.append("  final int probe = int.tryParse('probe') ?? 0;")
    out.append("  var reach = 0;")
    for a in top_layer:
        out.append("  reach += entry%d(3, probe);" % a)
    out.append("  runApp(")
    out.append("    MaterialApp(")
    out.append("      home: Scaffold(")
    out.append("        body: Center(")
    out.append("          child: Column(")
    out.append("            mainAxisSize: MainAxisSize.min,")
    out.append("            children: [")
    for a in top_layer:
        out.append("              W%dx0(value: value%dx0())," % (a, a))
    out.append("              Text('reach: $reach'),")
    out.append("            ],")
    out.append("          ),")
    out.append("        ),")
    out.append("      ),")
    out.append("    ),")
    out.append("  );")
    out.append("}")
    return "\n".join(out) + "\n"

def count_lines(text):
    return text.count("\n")


def render_all_dart(opts, plan, render_one):
    """Renders every Dart file, passing (rel_path, content) to render_one."""
    lines = 0
    n = len(plan.dag["deps"])
    for p in range(n):
        for f in range(opts.files_per_package):
            content = render_lib_file(
                p, f, opts.files_per_package,
                plan.dag["deps"][p], plan.method_counts[p][f],
            )
            lines += count_lines(content)
            rel = "packages/pkg%d/lib/src/f%s.dart" % (
                p, pad_file(opts.files_per_package, f))
            render_one(rel, content)
            if f % 8 == 0:
                content = render_part_file(p, f, opts.files_per_package)
                lines += count_lines(content)
                rel = "packages/pkg%d/lib/src/f%s.part.dart" % (
                    p, pad_file(opts.files_per_package, f))
                render_one(rel, content)
        content = render_entrypoint(
            p, opts.files_per_package, plan.dag["deps"][p])
        lines += count_lines(content)
        render_one("packages/pkg%d/lib/pkg%d.dart" % (p, p), content)
        if plan.has_test[p]:
            content = render_test_file(p)
            lines += count_lines(content)
            render_one("packages/pkg%d/test/pkg%d_test.dart" % (p, p), content)
    content = render_app_main(plan.top_layer())
    lines += count_lines(content)
    render_one("app/lib/main.dart", content)
    return lines


def plan_total_lines(opts, plan):
    total = [0]

    def count_only(rel, content):
        total[0] += count_lines(content)

    render_all_dart(opts, plan, count_only)
    return total[0]


def tune_plan_to_target(opts, plan):
    """Adjusts method counts one method at a time toward target_loc."""
    total = plan_total_lines(opts, plan)
    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    n = len(plan.dag["deps"])
    for _ in range(16):
        if lo <= total <= hi:
            break
        moved = False
        for p in range(n):
            for f in range(opts.files_per_package):
                if lo <= total <= hi:
                    break
                skeleton = lib_skeleton_lines(
                    f > 0, len(plan.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                min_m, max_m = method_count_range(skeleton)
                current = plan.method_counts[p][f]
                if total < opts.target_loc and current < max_m:
                    plan.method_counts[p][f] = current + 1
                    total += 8
                    moved = True
                elif total > opts.target_loc and current > min_m:
                    plan.method_counts[p][f] = current - 1
                    total -= 8
                    moved = True
        if not moved:
            break
    return total
