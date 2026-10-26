"""Apple plugin spoke parts of the `flutter pub get` analog.

Hosts the Apple half of `flutter_pub_package.bzl`'s spoke generator: source
and privacy-manifest detection for the SwiftPM (`ios/<pkg>/`,
`macos/<pkg>/`, `darwin/<pkg>`) and legacy (`<platform>/Classes`,
`darwin/Classes`) layouts, the `flutter_apple_plugin_library` pair renderer,
and the `apple_libs` / `apple_privacy_files` selects for the `flutter_plugin`
template. Split out of `flutter_pub_package.bzl` so that file stays
under the god-file limit; `flutter_pub_package.bzl` loads the pieces its
pipeline still needs.
"""

load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_under_walk")
load(":starlark_literal.bzl", "starlark_string_literal")

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
