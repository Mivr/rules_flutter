"""`Package.swift` model to Bazel BUILD translation for SwiftPM spokes.

Pure functions over the `parse_swiftpm_package` model: the repository rule
(`swiftpm_package.bzl`) resolves target directories and Swift sources at
fetch time, then calls `swiftpm_reachable_targets` (dependency resolution,
reachability, special-kind refusals) and `swiftpm_emit_build` (BUILD text)
here. Starlark unit tests drive both without any fetch.
"""

_SWIFTPM_C99_OK = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

def swiftpm_c99name(name):
    """Mangle a target name the way SwiftPM's `c99name` does.

    SwiftPM (`spm_mangledToC99ExtendedIdentifier`) replaces every character
    outside the C99 ranges with `_`, one for one: no collapsing, no
    stripping, no leading-digit fix. Starlark indexes strings by byte, so
    a non-ASCII character becomes one `_` per UTF-8 byte rather than
    SwiftPM's one per scalar; target names are ASCII in practice, and the
    difference only matters there.

    Args:
        name: The target name.

    Returns:
        The `module_name` for the target's `swift_library`.
    """
    out = []
    for i in range(len(name)):
        char = name[i]
        if char in _SWIFTPM_C99_OK:
            out.append(char)
        else:
            out.append("_")
    return "".join(out)

def swiftpm_language_mode(tools_major, tools_minor, modes):
    """Pick the `-swift-version` language mode for one package.

    Args:
        tools_major: The manifest's tools major version.
        tools_minor: The manifest's tools minor version.
        modes: The parsed `swiftLanguageVersions`/`swiftLanguageModes`
            entries (structs with `major` and `minor`).

    Returns:
        `struct(major, minor)`: the maximum declared mode, else Swift 6
        for tools 6.0+, 5 for tools 5.x, and 4.2/4 for those tools.
    """
    best = None
    for mode in modes:
        if best == None or (mode.major, mode.minor) > (best.major, best.minor):
            best = mode
    if best != None:
        return struct(major = best.major, minor = best.minor)
    if tools_major >= 6:
        return struct(major = 6, minor = 0)
    if tools_major == 5:
        return struct(major = 5, minor = 0)
    return struct(major = 4, minor = tools_minor)

def swiftpm_url_identity(url):
    """Derive a package identity from a `.package(url:)` locator.

    Args:
        url: The url string.

    Returns:
        The last URL path segment minus an optional `.git` suffix ("" when
        the url has no usable segment).
    """
    segment = url
    for _ in range(len(url) + 1):
        slash = segment.rfind("/")
        if slash < 0:
            break
        segment = segment[slash + 1:]
        if segment:
            break
    if segment.endswith(".git"):
        segment = segment[:len(segment) - 4]
    return segment

def _swiftpm_build_files_hint(identity):
    """The escape-hatch pointer every untranslatable target carries."""
    return "Point at a hand-written BUILD file with swift_package_build_files[{identity}] = \"<label>\" to build it another way.".format(identity = repr(identity))

def _swiftpm_special_kind_error(identity, kind, name):
    """The refusal for a reachable target with no Bazel translation.

    Args:
        identity: The SwiftPM package identity.
        kind: The target kind (`executableTarget`, `binaryTarget`,
            `systemLibrary`, `plugin`, `macro`).
        name: The target name ("" when the manifest gave none yet).

    Returns:
        The fetch failure.
    """
    reasons = {
        "executableTarget": "an executable target (a command-line tool)",
        "binaryTarget": "a binary target (a prebuilt artifact)",
        "systemLibrary": "a system library target (a pkg-config/module-map shim)",
        "plugin": "a plugin target (a build-tool plugin)",
        "macro": "a macro target (a compiler plugin)",
    }
    shown = repr(name) if name else "an unnamed target"
    return "SwiftPM package {identity}: target {shown} is {reason}, which has no Bazel translation. {hint}".format(
        identity = repr(identity),
        shown = shown,
        reason = reasons.get(kind, "a special target kind"),
        hint = _swiftpm_build_files_hint(identity),
    )

def swiftpm_locate_package_dep(identity, package, pkg_deps):
    """Resolve a `.product(name:package:)` reference to a pin identity.

    Matches `package:` against a `name:` of a `.package(...)` of the same
    manifest first, else against a `.package(...)`'s url (last URL path
    segment minus an optional `.git`); `id:` declarations match through
    their `name:` only. Every comparison is case-insensitive: manifests
    keep their own case while `Package.resolved` lowercases the identity.
    The pub plugin spoke reuses this matcher so its products resolve
    exactly as the hub's do.

    Args:
        identity: The SwiftPM package identity.
        package: The `package:` reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        `struct(ok, error, dep_identity)`.
    """
    lowered = package.lower()
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == lowered:
            return _swiftpm_decl_identity(identity, package, decl)
    for decl in pkg_deps:
        if decl.ref_kind == "url" and swiftpm_url_identity(decl.ref).lower() == lowered:
            return _swiftpm_decl_identity(identity, package, decl)
    return struct(ok = False, error = "SwiftPM package {identity}: `.product(package: {package})` names no package declared in this manifest.".format(identity = repr(identity), package = repr(package)), dep_identity = "")

def _swiftpm_decl_identity(identity, package, decl):
    """Read the pin identity out of one matched `.package(...)`.

    Args:
        identity: The SwiftPM package identity.
        package: The `package:` reference being resolved, for messages.
        decl: The matched declaration.

    Returns:
        `struct(ok, error, dep_identity)`.
    """
    if decl.ref == "":
        return struct(ok = False, error = "SwiftPM package {identity}: `.product(package: {package})` matches a `.package(...)` declaring no url or id.".format(identity = repr(identity), package = repr(package)), dep_identity = "")
    if decl.ref_kind == "path":
        return struct(ok = False, error = "SwiftPM package {identity}: `.product(package: {package})` matches a local path dependency, which has no fetchable identity.".format(identity = repr(identity), package = repr(package)), dep_identity = "")
    if decl.ref_kind == "id":
        return struct(ok = True, error = "", dep_identity = decl.ref)
    found = swiftpm_url_identity(decl.ref)
    if not found:
        return struct(ok = False, error = "SwiftPM package {identity}: `.product(package: {package})` matches a `.package(...)` whose url has no usable last path segment.".format(identity = repr(identity), package = repr(package)), dep_identity = "")
    return struct(ok = True, error = "", dep_identity = found)

def _swiftpm_resolve_same_dep(identity, targets, by_name, target_name, dep):
    """Resolve a same-package `.byName`/`.target` dependency to a target.

    Exact names win; otherwise the match is case-insensitive, because
    `Package.resolved` lowercases the identity while manifests keep
    their own case.

    Args:
        identity: The SwiftPM package identity.
        targets: The parsed target list, in manifest order.
        by_name: The same list indexed by exact target name.
        target_name: The depending target's name, for messages.
        dep: The parsed same-package dependency reference.

    Returns:
        `struct(ok, error, target)`.
    """
    if dep.name in by_name:
        return struct(ok = True, error = "", target = by_name[dep.name])
    lowered = dep.name.lower()
    for candidate in targets:
        if candidate.name and candidate.name.lower() == lowered:
            return struct(ok = True, error = "", target = candidate)
    return struct(ok = False, error = "SwiftPM package {identity}: target {target} depends on unknown target {name}.".format(identity = repr(identity), target = repr(target_name), name = repr(dep.name)), target = None)

def _swiftpm_check_product_targets(identity, model, by_name):
    """Refuse products naming unknown or test targets.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        by_name: The parsed targets indexed by exact name.

    Returns:
        "" or the fetch failure.
    """
    for product in model.products:
        for name in product.targets:
            if name not in by_name:
                return "SwiftPM package {identity}: product {product} names unknown target {name}.".format(identity = repr(identity), product = repr(product.name), name = repr(name))
            if by_name[name].kind == "testTarget":
                return "SwiftPM package {identity}: product {product} names test target {name}, which is ignored.".format(identity = repr(identity), product = repr(product.name), name = repr(name))
    return ""

def _swiftpm_product_dep_label(identity, hub_name, dep, pkg_deps, pin_identities):
    """Resolve one `.product(name:package:)` dep to a spoke label.

    Args:
        identity: The SwiftPM package identity.
        hub_name: The `flutter.pub` hub name, for dep labels.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        pin_identities: The identities pinned in `Package.resolved`.

    Returns:
        `struct(ok, error, label)`.
    """
    located = swiftpm_locate_package_dep(identity, dep.package, pkg_deps)
    if not located.ok:
        return struct(ok = False, error = located.error, label = "")
    canonical = None
    for pin_id in pin_identities:
        if pin_id.lower() == located.dep_identity.lower():
            canonical = pin_id
            break
    if canonical == None:
        return struct(ok = False, error = "SwiftPM package {identity}: `.product(package: {package})` matches package {dep} which is not pinned in Package.resolved.".format(identity = repr(identity), package = repr(dep.package), dep = repr(located.dep_identity)), label = "")
    return struct(ok = True, error = "", label = "@" + hub_name + "__swiftpm-" + canonical + "//:" + dep.name)

def _swiftpm_target_edge(identity, model, target, by_name, pin_identities, hub_name):
    """Resolve one target's dependencies to Bazel labels.

    A dependency carrying a `condition:` fails the fetch: the hub builds
    one library for every Apple platform, so a platform-gated dependency
    has no Bazel meaning here. The pub plugin spoke filters conditions
    per platform instead (see `select_apple_swiftpm_deps`).

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        target: The target struct.
        by_name: The parsed targets indexed by exact name.
        pin_identities: The identities pinned in `Package.resolved`.
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        `struct(ok, error, labels, followed)`: `followed` names the
        same-package targets for the reachability walk.
    """
    labels = []
    followed = []
    for dep in target.deps:
        if getattr(dep, "condition", None) != None:
            return struct(ok = False, error = "SwiftPM package {identity}: target {target} depends on {name} with a `condition:`, which has no Bazel translation.".format(identity = repr(identity), target = repr(target.name), name = repr(dep.name)), labels = [], followed = [])
        if dep.kind == "same":
            resolved = _swiftpm_resolve_same_dep(identity, model.targets, by_name, target.name, dep)
            if not resolved.ok:
                return struct(ok = False, error = resolved.error, labels = [], followed = [])
            if resolved.target.kind == "testTarget":
                return struct(ok = False, error = "SwiftPM package {identity}: target {target} depends on test target {name}, which is ignored.".format(identity = repr(identity), target = repr(target.name), name = repr(resolved.target.name)), labels = [], followed = [])
            labels.append(":" + resolved.target.name + "_lib")
            followed.append(resolved.target.name)
        else:
            located = _swiftpm_product_dep_label(identity, hub_name, dep, model.pkg_deps, pin_identities)
            if not located.ok:
                return struct(ok = False, error = located.error, labels = [], followed = [])
            labels.append(located.label)
    return struct(ok = True, error = "", labels = labels, followed = followed)

def _swiftpm_walk_reachable(model, same_edges):
    """Walk the targets each library product reaches.

    Args:
        model: The parsed manifest model.
        same_edges: The per-target followed same-package target names.

    Returns:
        The reached-name dict.
    """
    reached = {}
    stack = []
    for product in model.products:
        for name in product.targets:
            if name not in reached:
                reached[name] = True
                stack.append(name)
    for _ in range(len(model.targets) + 1):
        if not stack:
            break
        current = stack.pop()
        for name in same_edges.get(current, []):
            if name not in reached:
                reached[name] = True
                stack.append(name)
    return reached

def _swiftpm_collect_reached(identity, model, reached):
    """List the reached targets in manifest order, refusing specials.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        reached: The reached-name dict.

    Returns:
        `struct(ok, error, names)`.
    """
    names = []
    for target in model.targets:
        if target.name and target.name in reached:
            if target.kind in ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]:
                return struct(ok = False, error = _swiftpm_special_kind_error(identity, target.kind, target.name), names = [])
            names.append(target.name)
    return struct(ok = True, error = "", names = names)

def swiftpm_reachable_targets(identity, model, pin_identities, hub_name):
    """Resolve dependencies and walk the targets a product reaches.

    Seeds from every `.library` product's targets and follows same-package
    target dependencies. Test targets are ignored: a product naming one,
    or a target depending on one, fails the fetch. A reached
    `executableTarget`, `binaryTarget`, `systemLibrary`, `plugin` or
    `macro` target fails with a refusal pointing at
    `swift_package_build_files`.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        pin_identities: The identities pinned in `Package.resolved`.
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        `struct(ok, error, names, edges)`: `names` lists reached regular
        targets in manifest order; `edges` maps each reached name to its
        dep label list (`:other_lib` for same-package targets,
        `@<hub>__swiftpm-<id>//:<product>` for products).
    """
    by_name = {}
    for target in model.targets:
        if target.name:
            by_name[target.name] = target
    invalid = _swiftpm_check_product_targets(identity, model, by_name)
    if invalid:
        return struct(ok = False, error = invalid, names = [], edges = {})
    edges = {}
    same_edges = {}
    for target in model.targets:
        if not target.name or target.kind in ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]:
            continue
        resolved = _swiftpm_target_edge(identity, model, target, by_name, pin_identities, hub_name)
        if not resolved.ok:
            return struct(ok = False, error = resolved.error, names = [], edges = {})
        edges[target.name] = resolved.labels
        same_edges[target.name] = resolved.followed
    reached = _swiftpm_walk_reachable(model, same_edges)
    collected = _swiftpm_collect_reached(identity, model, reached)
    if not collected.ok:
        return struct(ok = False, error = collected.error, names = [], edges = {})
    return struct(ok = True, error = "", names = collected.names, edges = edges)

def _swiftpm_copts_flag(mode):
    """The `-swift-version` flag value for one language mode."""
    if mode.minor == 0:
        return str(mode.major)
    return str(mode.major) + "." + str(mode.minor)

def _swiftpm_build_string(text):
    """Quote arbitrary text as a BUILD string literal.

    Args:
        text: The raw text.

    Returns:
        The double-quoted literal with `\\` and `"` escaped.
    """
    return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _swiftpm_emit_library(identity, model, target, edges, files, mode):
    """Emit one `swift_library` for a reached target.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        target: The target struct.
        edges: The dep label map from `swiftpm_reachable_targets`.
        files: `struct(dir, srcs)` with the target's directory and
            explicit Swift sources, package-root relative.
        mode: The language mode struct.

    Returns:
        The `swift_library` block text.
    """
    lines = ["swift_library("]
    lines.append("    name = " + _swiftpm_build_string(target.name + "_lib") + ",")
    lines.append("    srcs = [")
    for src in sorted(files.srcs):
        lines.append("        {src},".format(src = repr(src)))
    lines.append("    ],")
    lines.append("    module_name = {module},".format(module = repr(swiftpm_c99name(target.name))))
    if model.tools_major > 5 or (model.tools_major == 5 and model.tools_minor >= 9):
        lines.append("    package_name = {package},".format(package = repr(identity)))
    lines.append("    copts = [\"-swift-version\", {flag}],".format(flag = repr(_swiftpm_copts_flag(mode))))
    if edges.get(target.name):
        lines.append("    deps = [")
        for label in edges[target.name]:
            lines.append("        {label},".format(label = repr(label)))
        lines.append("    ],")
    lines.append("    visibility = [\"//visibility:public\"],")
    lines.append(")")
    return "\n".join(lines)

def swiftpm_emit_build(identity, model, names, edges, files_by_target):
    """Emit the spoke BUILD file for one translated package.

    One `swift_library` per reached target (named `<target>_lib`), one
    `alias` per single-target product (even when the product and target
    names differ), and one `swift_library_group` per multi-target
    product.

    Args:
        identity: The SwiftPM package identity.
        model: The parsed manifest model.
        names: The reached target names from `swiftpm_reachable_targets`.
        edges: The dep label map from `swiftpm_reachable_targets`.
        files_by_target: Dict of reached target name to `struct(dir,
            srcs)`.

    Returns:
        `struct(ok, error, text)`.
    """
    mode = swiftpm_language_mode(model.tools_major, model.tools_minor, model.modes)
    by_name = {target.name: target for target in model.targets}
    blocks = ["load(\"@rules_swift//swift:swift.bzl\", \"swift_library\", \"swift_library_group\")"]
    for name in names:
        if name not in files_by_target:
            return struct(ok = False, error = "SwiftPM package {identity}: target {name} has no resolved sources.".format(identity = repr(identity), name = repr(name)), text = "")
        blocks.append(_swiftpm_emit_library(identity, model, by_name[name], edges, files_by_target[name], mode))
    for product in model.products:
        if len(product.targets) == 1:
            blocks.append("alias(\n    name = {name},\n    actual = {actual},\n    visibility = [\"//visibility:public\"],\n)".format(name = repr(product.name), actual = repr(":" + product.targets[0] + "_lib")))
        else:
            deps = [_swiftpm_build_string(":" + target_name + "_lib") for target_name in product.targets]
            blocks.append("swift_library_group(\n    name = {name},\n    deps = [\n        {deps},\n    ],\n    visibility = [\"//visibility:public\"],\n)".format(name = repr(product.name), deps = ",\n        ".join(deps)))
    return struct(ok = True, error = "", text = "\n\n".join(blocks) + "\n")

def translate_swiftpm_package(identity, hub_name, model, pin_identities, files_by_target):
    """Reach and emit a package in one call, for tests and the repo rule.

    Args:
        identity: The SwiftPM package identity.
        hub_name: The `flutter.pub` hub name, for dep labels.
        model: The parsed manifest model.
        pin_identities: The identities pinned in `Package.resolved`.
        files_by_target: Dict of target name to `struct(dir, srcs)`.

    Returns:
        `struct(ok, error, text, names)`.
    """
    reached = swiftpm_reachable_targets(identity, model, pin_identities, hub_name)
    if not reached.ok:
        return struct(ok = False, error = reached.error, text = "", names = [])
    emitted = swiftpm_emit_build(identity, model, reached.names, reached.edges, files_by_target)
    if not emitted.ok:
        return struct(ok = False, error = emitted.error, text = "", names = [])
    return struct(ok = True, error = "", text = emitted.text, names = reached.names)
