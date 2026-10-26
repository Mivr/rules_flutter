"""Apple plugin spoke parts of the `flutter pub get` analog.

Hosts the Apple half of `flutter_pub_package.bzl`'s spoke generator: source
and privacy-manifest detection for the SwiftPM (`ios/<pkg>/`,
`macos/<pkg>/`, `darwin/<pkg>`) and legacy (`<platform>/Classes`,
`darwin/Classes`) layouts, the `flutter_apple_plugin_library` pair renderer,
the `apple_libs` / `apple_privacy_files` selects and the
extra-loads/extra-targets joiners for the `flutter_plugin` template, and the
SwiftPM product links a plugin's `Package.swift` declares. Split out of
`flutter_pub_package.bzl` so that file stays under the god-file limit;
`flutter_pub_package.bzl` loads the pieces its pipeline still needs.
"""

load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_under_walk")
load(":starlark_literal.bzl", "starlark_string_literal")
load(":swiftpm_manifest.bzl", "parse_swiftpm_plugin_package")
load(":swiftpm_resolved.bzl", "swiftpm_spoke_name")
load(":swiftpm_translate.bzl", "swiftpm_locate_package_dep")

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

def _ctx_has_files_readdir(ctx, relative_path):
    """A `has_files_under_walk` reader over one spoke directory via `ctx.path`.

    Args:
        ctx: The spoke's repository context.
        relative_path: The package-relative directory the walk is rooted at.

    Returns:
        A `readdir` callable as `has_files_under_walk` takes it: a missing
        directory reads as empty, matching the walk's old skip.
    """

    def readdir(rel_dir):
        """The immediate children of `relative_path/rel_dir`."""
        full = relative_path if rel_dir == "" else relative_path + "/" + rel_dir
        node = ctx.path(full)
        if not node.exists:
            return []
        return [struct(name = child.basename, is_dir = child.is_dir) for child in node.readdir()]

    return readdir

def has_files_under(ctx, relative_path, extensions = None, package_name = "", bound = PUB_WALK_BOUND):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions` (any file when `extensions` is None).
    `ctx.path(p).readdir()` is the documented repo-rule way to walk a
    directory; recursing in Starlark keeps the logic local instead of
    forking out to `find`. The walk shares the pub spoke bound
    (`PUB_WALK_BOUND`): reaching it with directories unvisited fails the
    fetch naming the package, the directory, and the bound, instead of
    silently reporting no sources from a half-walked tree.

    Args:
        ctx: The spoke's repository context.
        relative_path: The package-relative directory to sweep.
        extensions: File extensions to match, or None for any file.
        package_name: The pub package name, for walk error messages.
        bound: The maximum directories the shared walk visits.

    Returns:
        True when the directory holds at least one matching file.
    """
    root = ctx.path(relative_path)
    if not root.exists:
        return False
    found = has_files_under_walk(
        _ctx_has_files_readdir(ctx, relative_path),
        "",
        package_name,
        extensions,
        bound,
    )
    if found.error:
        fail(found.error)
    return found.found

def _detect_apple_source_dirs(ctx, package_name, platform, shared_darwin_source):
    """List Apple source directory globs for the given platform.

    Returns the relative-to-package-root directories that contain Apple
    sources for `platform`. Empty list when no sources are detected.
    """
    candidates = []

    # Modern SwiftPM layout: <platform>/<pkg>/Sources/<pkg>/...
    swiftpm_dir = "{plat}/{pkg}/Sources/{pkg}".format(plat = platform, pkg = package_name)
    if has_files_under(ctx, swiftpm_dir, _APPLE_SRC_EXTENSIONS, package_name):
        candidates.append(swiftpm_dir)

    # Shared darwin source layout: darwin/Classes/...
    if shared_darwin_source:
        darwin_dir = "darwin/Classes"
        if has_files_under(ctx, darwin_dir, _APPLE_SRC_EXTENSIONS, package_name):
            candidates.append(darwin_dir)

        # Legacy darwin SwiftPM (older path_provider_foundation versions).
        darwin_swiftpm_dir = "darwin/{pkg}/Sources/{pkg}".format(pkg = package_name)
        if has_files_under(ctx, darwin_swiftpm_dir, _APPLE_SRC_EXTENSIONS, package_name):
            candidates.append(darwin_swiftpm_dir)

    # Legacy split layout: <platform>/Classes/...
    legacy_dir = "{plat}/Classes".format(plat = platform)
    if has_files_under(ctx, legacy_dir, _APPLE_SRC_EXTENSIONS, package_name):
        candidates.append(legacy_dir)

    return candidates

def _detect_apple_include_dirs(ctx, source_dirs, package_name):
    """Collect SwiftPM-canonical public-header directories for the given Apple sources.

    SwiftPM's `publicHeadersPath: "include"` (the default) places public
    headers at `Sources/<Target>/include/[<Module>/]Foo.h` and adds the
    `include` directory to the lib's own header search path. Plugins
    relying on this convention `#import "Foo.h"` (bare basename) from
    sibling `.m` files; without an explicit `-I` flag clang can't find
    the header. Mirror SwiftPM by adding both `include` and the
    `include/<pkg>` nested subdirectory (when present) — covers
    headers placed directly under `include/` and the more common
    umbrella-style layout.
    """
    include_dirs = []
    for src_dir in source_dirs:
        include_root = src_dir + "/include"
        include_root_path = ctx.path(include_root)
        if include_root_path.exists:
            include_dirs.append(include_root)
            nested = include_root + "/" + package_name
            if ctx.path(nested).exists:
                include_dirs.append(nested)
    return include_dirs

def _detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; App Store submission walks the bundle for
    `*.xcprivacy` files and aggregates them into the app's privacy
    report. CocoaPods/SwiftPM bundle them automatically as framework
    resources; we mirror by collecting them here and threading them
    through to `flutter_apple_plugin_library`'s `privacy_manifests`
    attr (which forwards to the inner objc/swift_library `data`).

    Two layouts occur in real plugins:

    * **Pattern A** (e.g. `package_info_plus`, `share_plus`):
      `<source_dir>/PrivacyInfo.xcprivacy`.
    * **Pattern B** (e.g. `path_provider_foundation`, `record_ios`,
      `webview_flutter_wkwebview`):
      `<source_dir>/Resources/PrivacyInfo.xcprivacy`.

    Returns a sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def glob_block(srcs_dirs, extensions):
    """Format a `glob([...])` expression covering the given extensions.

    Each directory in `srcs_dirs` is recursively swept for files matching
    any extension in `extensions`. `test/` and `example/` subtrees are
    excluded — pub plugins routinely ship integration tests next to
    their plugin source, but those should never be linked into the
    runner.

    Args:
        srcs_dirs: Package-relative source directories to sweep.
        extensions: File extensions to include in the glob.

    Returns:
        A `glob(...)` expression string with test/example excludes.
    """
    patterns = []
    excludes = []
    for d in srcs_dirs:
        for ext in extensions:
            patterns.append("{}/**/*.{}".format(d, ext))
        excludes.append("{}/test/**".format(d))
        excludes.append("{}/example/**".format(d))

    # Directories embed the pub package name, which lock classification
    # already refused when quotable; every pattern still renders through the
    # escaping helper, so an odd name lands inert inside a string literal.
    quoted = ["        " + starlark_string_literal(p) + "," for p in patterns]
    excl_quoted = ["        " + starlark_string_literal(e) + "," for e in excludes]
    return "glob(\n        [\n{}\n        ],\n        exclude = [\n{}\n        ],\n        allow_empty = True,\n    )".format("\n".join(quoted), "\n".join(excl_quoted))

def apple_plugin_targets(name, srcs_dirs, include_dirs, platform):
    """The `flutter_apple_plugin_library` pair (device + xtool) for one platform.

    Args:
        name: The pub package name used for the target names.
        srcs_dirs: Package-relative source directories.
        include_dirs: Header search paths for the library.
        platform: `"ios"` or `"macos"`.

    Returns:
        The rendered device + xtool library targets.
    """

    # `name` is a lock package name (refused quotable at classification) and
    # `platform` is a fixed literal at every call site; `srcs` globs and the
    # `includes` list render through the escaping helper.
    return """
flutter_apple_plugin_library(
    name = "{name}_apple_{platform}",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{name}_apple_{platform}_xtool",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "{platform}",
    backend = "xtool",
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = glob_block(srcs_dirs, _APPLE_SRC_EXTENSIONS),
        includes = starlark_string_literal(include_dirs),
    )

def plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs):
    """The `apple_libs` select routing each OS to its device/xtool library.

    Args:
        name: The pub package name used for the library target names.
        apple_macos_srcs_dirs: Detected macOS source directories.
        apple_ios_srcs_dirs: Detected iOS source directories.

    Returns:
        The rendered `apple_libs` select, or empty when no Apple sources.
    """
    if not (apple_macos_srcs_dirs or apple_ios_srcs_dirs):
        return ""

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
    macos_xtool_branch = '            ":{name}_apple_macos_xtool",'.format(name = name) if apple_macos_srcs_dirs else ""
    ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
    ios_xtool_branch = '            ":{name}_apple_ios_xtool",'.format(name = name) if apple_ios_srcs_dirs else ""
    return """    apple_libs = select({{
        "@rules_flutter//flutter/settings:macos_xtool_backend": [
{macos_xtool_branch}
        ],
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@rules_flutter//flutter/settings:ios_xtool_backend": [
{ios_xtool_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_branch = macos_branch,
        macos_xtool_branch = macos_xtool_branch,
        ios_branch = ios_branch,
        ios_xtool_branch = ios_xtool_branch,
    )

def plugin_privacy_files_arg(apple_macos_privacy_manifests, apple_ios_privacy_manifests):
    """The `apple_privacy_files` select splitting manifests per platform.

    Split per-platform via select() so the macOS bundle never picks up
    iOS-only manifests (and vice versa) — different platforms can declare
    different privacy uses, and Apple's submission validator aggregates
    whatever it finds in the per-platform bundle.

    Args:
        apple_macos_privacy_manifests: macOS privacy manifest paths.
        apple_ios_privacy_manifests: iOS privacy manifest paths.

    Returns:
        The rendered `apple_privacy_files` select, or empty when none.
    """
    if not (apple_macos_privacy_manifests or apple_ios_privacy_manifests):
        return ""

    # Manifest paths are walked from detected source directories plus a
    # fixed file name; each renders through the escaping helper.
    macos_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_macos_privacy_manifests])
    ios_lines = "\n".join(["            " + starlark_string_literal(p) + "," for p in apple_ios_privacy_manifests])
    return """    apple_privacy_files = select({{
        "@platforms//os:macos": [
{macos_lines}
        ],
        "@platforms//os:ios": [
{ios_lines}
        ],
        "//conditions:default": [],
    }}),
""".format(
        macos_lines = macos_lines,
        ios_lines = ios_lines,
    )

def detect_apple_plugin_sources(ctx, package_name, plugin_block):
    """Detects Apple sources per platform when pluginClass is set.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub package name to sweep.
        plugin_block: The parsed plugin block from the package pubspec.

    Returns:
        `struct(macos_srcs, ios_srcs, macos_includes, ios_includes,
        macos_manifests, ios_manifests)`.
    """
    apple_macos_srcs_dirs = []
    apple_ios_srcs_dirs = []
    apple_macos_include_dirs = []
    apple_ios_include_dirs = []
    apple_macos_privacy_manifests = []
    apple_ios_privacy_manifests = []

    macos_info = plugin_block.platforms.get("macos", {})
    ios_info = plugin_block.platforms.get("ios", {})
    macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
    ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

    if macos_info and macos_info.get("pluginClass", ""):
        apple_macos_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "macos",
            macos_shared_darwin,
        )
        apple_macos_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_macos_srcs_dirs,
            package_name,
        )
        apple_macos_privacy_manifests = _detect_apple_privacy_manifests(
            ctx,
            apple_macos_srcs_dirs,
        )

    if ios_info and ios_info.get("pluginClass", ""):
        apple_ios_srcs_dirs = _detect_apple_source_dirs(
            ctx,
            package_name,
            "ios",
            ios_shared_darwin,
        )
        apple_ios_include_dirs = _detect_apple_include_dirs(
            ctx,
            apple_ios_srcs_dirs,
            package_name,
        )
        apple_ios_privacy_manifests = _detect_apple_privacy_manifests(
            ctx,
            apple_ios_srcs_dirs,
        )

    return struct(
        macos_srcs = apple_macos_srcs_dirs,
        ios_srcs = apple_ios_srcs_dirs,
        macos_includes = apple_macos_include_dirs,
        ios_includes = apple_ios_include_dirs,
        macos_manifests = apple_macos_privacy_manifests,
        ios_manifests = apple_ios_privacy_manifests,
    )

# Plugin template renderers moved out of `flutter_pub_package.bzl` (which
# must not grow): the desktop target, the srcs/hdrs glob splitter, and the
# extra-loads/extra-targets joiners the `flutter_plugin` template renders
# through. Public names with private aliases at the single load site in
# `flutter_pub_package.bzl`, since Bazel forbids importing private symbols.

def split_glob_block(srcs_dirs, src_exts, hdr_exts):
    """Format separate srcs/hdrs glob expressions for desktop plugins.

    Returns (srcs_glob, hdrs_glob) so the spoke can pass the lists to
    flutter_linux_plugin_library / flutter_windows_plugin_library
    separately — those rules require .h/.hh/.hpp on `hdrs` and the
    compilable extensions on `srcs`.

    Args:
        srcs_dirs: Package-relative source directories to sweep.
        src_exts: Compilable file extensions for `srcs`.
        hdr_exts: Header file extensions for `hdrs`.

    Returns:
        The `(srcs_glob, hdrs_glob)` expression pair.
    """
    return glob_block(srcs_dirs, src_exts), glob_block(srcs_dirs, hdr_exts)

_DESKTOP_HDR_EXTS = ("h", "hh", "hpp")
_DESKTOP_C_EXTS = ("cc", "cpp", "c")

def desktop_plugin_target(name, src_dir, platform):
    """The `flutter_<platform>_plugin_library` target for one desktop platform."""

    # Same shape as above: `name` is a classified lock package name and
    # `platform` is `"linux"` or `"windows"` at every call site.
    srcs, hdrs = split_glob_block([src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
    return """
flutter_{platform}_plugin_library(
    name = "{name}_{platform}",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["{platform}/include"],
    visibility = ["//visibility:public"],
)""".format(
        name = name,
        platform = platform,
        srcs = srcs,
        hdrs = hdrs,
    )

def plugin_extra_loads(apple_macos_srcs_dirs, apple_ios_srcs_dirs, linux_src_dir, windows_src_dir):
    """The extra `load` lines a plugin spoke needs, joined for the template.

    Args:
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".

    Returns:
        The `load(...)` lines joined with newlines.
    """
    extra_loads = []
    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')
    return "\n".join(extra_loads)

def plugin_extra_targets(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs, apple_macos_include_dirs, apple_ios_include_dirs, linux_src_dir, windows_src_dir):
    """The per-platform plugin library targets, joined for the template.

    NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    spoke BUILD. Instead, they're exposed via a sibling `android/`
    sub-package (see make_android_subpackage_build_content) which loads
    @rules_android + @rules_kotlin lazily — only when something queries
    `@<spoke>//android:lib`. Mac-only / web-only workspaces never trigger
    the parse and don't pay the @rules_android / @rules_kotlin cost.
    The application-side `flutter_android_app` macro depends on the hub's
    `android/all_android_plugin_libs` aggregator, which deps on every
    spoke's `android:lib` — so Android-targeted builds pick up all
    plugin libraries automatically.

    Args:
        name: The pub package name used for the target names.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".

    Returns:
        The rendered per-platform library targets joined with newlines.
    """
    extra_targets = []
    if apple_macos_srcs_dirs:
        extra_targets.append(apple_plugin_targets(
            name,
            apple_macos_srcs_dirs,
            apple_macos_include_dirs,
            "macos",
        ))
    if apple_ios_srcs_dirs:
        extra_targets.append(apple_plugin_targets(
            name,
            apple_ios_srcs_dirs,
            apple_ios_include_dirs,
            "ios",
        ))
    if linux_src_dir:
        extra_targets.append(desktop_plugin_target(name, linux_src_dir, "linux"))
    if windows_src_dir:
        extra_targets.append(desktop_plugin_target(name, windows_src_dir, "windows"))
    return "\n".join(extra_targets)

def _apple_swiftpm_plugin_target(model, manifest_dir, srcs_dirs):
    """Find the manifest target the spoke builds from this manifest.

    The plugin's target is the one whose source directory (its `path:`,
    else the default `Sources/<name>`) is one of the `Sources/<pkg>`
    directories the spoke emits for this platform.

    Args:
        model: The parsed manifest model.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.

    Returns:
        The matching target struct, or None when the manifest builds
        nothing the spoke emits.
    """
    for target in model.targets:
        if target.kind != "target":
            continue
        target_dir = manifest_dir + "/" + (target.path if target.path else "Sources/" + target.name)
        if target_dir in srcs_dirs:
            return target
    return None

def _apple_is_flutterframework_skip(dep, pkg_deps):
    """True when a product dep names the template's FlutterFramework path package.

    Flutter's plugin template declares `.package(name: "FlutterFramework",
    path: ...)` and links it the Xcode way; the rules link Flutter
    themselves, so that product is skipped. The match is name-first, as
    in step 1: only when the manifest's first `FlutterFramework`-named
    declaration is the path one does the skip apply.

    Args:
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        True when the product resolves to the template path package.
    """
    if dep.package.lower() != "flutterframework":
        return False
    for decl in pkg_deps:
        if decl.name and decl.name.lower() == "flutterframework":
            return decl.ref_kind == "path"
    return False

def _apple_keeps_product_dep(dep, pkg_deps, platform):
    """True when this platform links one plugin-target product dep.

    Drops the products the spoke never links: a `condition:` excluding
    this platform and the template's `FlutterFramework` path product
    (the rules link Flutter themselves). Same-package dependencies
    never reach here: only `.product` references are passed in.

    Args:
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        platform: `"ios"` or `"macos"`, for condition filtering.

    Returns:
        True when the spoke links this product on this platform.
    """
    if getattr(dep, "condition", None) != None and platform not in dep.condition.platforms:
        return False
    if _apple_is_flutterframework_skip(dep, pkg_deps):
        return False
    return True

def _apple_swiftpm_dep_labels(plugin_name, manifest_dir, dep, pkg_deps, platform, pins):
    """Resolve one plugin-target product dep to spoke labels.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_dir: The manifest's package-relative directory.
        dep: The parsed product dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub)`: the hub's
            resolved label, the pinned identities, the
            identity-to-refusal dict for unfetchable pins, and the hub
            name for dep labels.

    Returns:
        `struct(ok, error, labels)`: `labels` holds zero (skipped) or one
        `@<hub>__swiftpm-<identity>//:<product>` label.
    """
    if not _apple_keeps_product_dep(dep, pkg_deps, platform):
        return struct(ok = True, error = "", labels = [])
    located = swiftpm_locate_package_dep(plugin_name, dep.package, pkg_deps)
    if not located.ok:
        return struct(ok = False, error = located.error, labels = [])
    canonical = None
    for pin_id in pins.pinned:
        if pin_id.lower() == located.dep_identity.lower():
            canonical = pin_id
            break
    if canonical == None:
        return struct(ok = False, error = "Flutter plugin {plugin}: its `{manifest}/Package.swift` needs SwiftPM package {identity}, which is not pinned in the hub's `Package.resolved` ({resolved}): re-resolve the app with Xcode so the pin lands in the resolved file.".format(plugin = repr(plugin_name), manifest = manifest_dir, identity = repr(located.dep_identity), resolved = pins.resolved), labels = [])
    if canonical in pins.unpinned:
        return struct(ok = False, error = "Flutter plugin {plugin}: its `{manifest}/Package.swift` needs SwiftPM package {identity}: {reason}".format(plugin = repr(plugin_name), manifest = manifest_dir, identity = repr(located.dep_identity), reason = pins.unpinned[canonical]), labels = [])
    return struct(ok = True, error = "", labels = ["@" + swiftpm_spoke_name(pins.hub, canonical) + "//:" + dep.name])

def select_apple_swiftpm_deps(plugin_name, manifest_text, manifest_dir, srcs_dirs, platform, pins):
    """Read one plugin manifest's SwiftPM product links for one platform.

    Parses the manifest with the lenient plugin entry point (target
    settings with no Bazel translation, such as `resources` or
    `swiftSettings`, are skipped: the spoke keeps its own source,
    header and privacy-manifest detection), finds the plugin target the
    spoke builds, and resolves its `.product(name:package:)`
    dependencies (matched as in step 1) to the hub's pinned
    repositories, keeping only the products whose `condition:` allows
    this platform. Same-package dependencies and the template's
    `FlutterFramework` path product are skipped, so a manifest from
    Flutter's plugin template links nothing. A manifest the parser
    cannot read fails only when its text declares a package dependency
    at all (contains `.package(`): a dependency-free manifest keeps
    building exactly as today. The resolved-file refusal applies only
    when a product this platform actually links needs a SwiftPM
    package, and names that package.

    Args:
        plugin_name: The pub plugin name, for messages.
        manifest_text: The `Package.swift` text.
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.
        platform: `"ios"` or `"macos"`, for condition filtering.
        pins: `struct(resolved, pinned, unpinned, hub)` (see
            `_apple_swiftpm_dep_labels`).

    Returns:
        `struct(ok, error, labels)`: the spoke dep labels in manifest
        order, deduplicated.
    """
    parsed = parse_swiftpm_plugin_package(plugin_name, manifest_text)
    if not parsed.ok:
        if ".package(" not in manifest_text:
            return struct(ok = True, error = "", labels = [])
        return struct(ok = False, error = parsed.error, labels = [])
    target = _apple_swiftpm_plugin_target(parsed.model, manifest_dir, srcs_dirs)
    if target == None:
        return struct(ok = True, error = "", labels = [])
    products = [dep for dep in target.deps if dep.kind == "product" and _apple_keeps_product_dep(dep, parsed.model.pkg_deps, platform)]
    if not products:
        return struct(ok = True, error = "", labels = [])
    if not pins.resolved:
        located = swiftpm_locate_package_dep(plugin_name, products[0].package, parsed.model.pkg_deps)
        identity = located.dep_identity if located.ok else products[0].package
        return struct(ok = False, error = "Flutter plugin {plugin}: its `{manifest}/Package.swift` needs SwiftPM package {identity}, but the `flutter.pub` hub {hub} sets no `swift_package_resolved`: point it at the app's `Package.resolved`.".format(plugin = repr(plugin_name), manifest = manifest_dir, identity = repr(identity), hub = repr(pins.hub)), labels = [])
    labels = []
    seen = {}
    for dep in products:
        resolved = _apple_swiftpm_dep_labels(plugin_name, manifest_dir, dep, parsed.model.pkg_deps, platform, pins)
        if not resolved.ok:
            return struct(ok = False, error = resolved.error, labels = [])
        for label in resolved.labels:
            if label not in seen:
                seen[label] = True
                labels.append(label)
    return struct(ok = True, error = "", labels = labels)

def _detect_apple_swiftpm_platform(ctx, package_name, platform, srcs_dirs, pins):
    """Collect one platform's SwiftPM product labels.

    Reads the platform's `<platform>/<pkg>/Package.swift` and the shared
    `darwin/<pkg>/Package.swift` when present. A refusal fails the fetch:
    the spoke never downloads anything itself.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        srcs_dirs: The platform's detected source directories.
        pins: `struct(resolved, pinned, unpinned, hub)` (see
            `_apple_swiftpm_dep_labels`).

    Returns:
        The platform's spoke dep labels, deduplicated.
    """
    labels = []
    if not srcs_dirs:
        return labels
    seen = {}
    for manifest_dir in [platform + "/" + package_name, "darwin/" + package_name]:
        manifest = manifest_dir + "/Package.swift"
        if not ctx.path(manifest).exists:
            continue
        selected = select_apple_swiftpm_deps(package_name, ctx.read(manifest), manifest_dir, srcs_dirs, platform, pins)
        if not selected.ok:
            fail(selected.error)
        for label in selected.labels:
            if label not in seen:
                seen[label] = True
                labels.append(label)
    return labels

def detect_apple_swiftpm_deps(ctx, package_name, apple, resolved_label, pinned_identities, unpinned_errors, hub_name):
    """Link the plugin's `Package.swift` products for both Apple platforms.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub plugin name.
        apple: The `detect_apple_plugin_sources` struct.
        resolved_label: The hub's `swift_package_resolved` label, or ""
            when unset.
        pinned_identities: Identities pinned in the hub's resolved file.
        unpinned_errors: Identity-to-refusal dict for unfetchable pins.
        hub_name: The `flutter.pub` hub name, for dep labels.

    Returns:
        `struct(macos, ios)`: The per-platform spoke dep label lists.
    """
    pins = struct(resolved = resolved_label, pinned = pinned_identities, unpinned = unpinned_errors, hub = hub_name)
    return struct(
        macos = _detect_apple_swiftpm_platform(ctx, package_name, "macos", apple.macos_srcs, pins),
        ios = _detect_apple_swiftpm_platform(ctx, package_name, "ios", apple.ios_srcs, pins),
    )

def _with_apple_swiftpm_platform_deps(content, package_name, platform, labels):
    """Splice one platform's labels into its device and xtool blocks.

    Each `flutter_apple_plugin_library` block gains a `deps = [...]`
    entry before its `visibility`. Both blocks must be present: labels
    only exist when the platform built sources, which always renders
    the device + xtool pair.

    Args:
        content: The rendered spoke BUILD content.
        package_name: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        labels: The platform's spoke dep labels.

    Returns:
        The patched BUILD content.
    """
    deps_block = "    deps = [\n"
    for label in sorted(labels):
        deps_block += "        " + starlark_string_literal(label) + ",\n"
    deps_block += "    ],\n"
    for suffix in ["", "_xtool"]:
        marker = '    name = "{name}_apple_{platform}{suffix}",\n'.format(name = package_name, platform = platform, suffix = suffix)
        head, sep, tail = content.partition(marker)
        if not sep:
            fail("Flutter plugin {plugin}: expected a `{target}` library target to carry its SwiftPM dependencies.".format(plugin = repr(package_name), target = "{name}_apple_{platform}{suffix}".format(name = package_name, platform = platform, suffix = suffix)))
        vis_head, vis_sep, vis_tail = tail.partition("\n    visibility = ")
        if not vis_sep:
            fail("Flutter plugin {plugin}: expected a `{target}` library target to carry its SwiftPM dependencies.".format(plugin = repr(package_name), target = "{name}_apple_{platform}{suffix}".format(name = package_name, platform = platform, suffix = suffix)))
        content = head + sep + vis_head + "\n" + deps_block + vis_sep + vis_tail
    return content

def with_apple_swiftpm_deps(content, package_name, macos_labels, ios_labels):
    """Splice SwiftPM product labels into the rendered Apple library targets.

    `make_flutter_plugin_build_content`'s signature is frozen, so the
    per-platform labels land here, after rendering. A platform with no
    labels leaves its blocks untouched, so spokes without a `Package.swift`
    render byte-identical content.

    Args:
        content: The rendered spoke BUILD content.
        package_name: The pub plugin name.
        macos_labels: The macOS SwiftPM spoke dep labels.
        ios_labels: The iOS SwiftPM spoke dep labels.

    Returns:
        The patched BUILD content.
    """
    if macos_labels:
        content = _with_apple_swiftpm_platform_deps(content, package_name, "macos", macos_labels)
    if ios_labels:
        content = _with_apple_swiftpm_platform_deps(content, package_name, "ios", ios_labels)
    return content
