"""Flutter rules for iOS builds.

Two tiers of API:

    Tier 1 — flutter_ios_app (self-contained, recommended):

        load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_ios_app(
            name = "my_app_ios",
            application = ":my_app",
            bundle_id = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=ios .` in your package to
    generate the conventional `ios/Runner/` directory with AppDelegate.swift
    and SceneDelegate.swift.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:ios.bzl",
            "IOS_DEFAULT_LAUNCH_STORYBOARD",
            "flutter_ios_engine",
            "flutter_ios_framework_gen",
            "flutter_ios_info_plist_gen",
            "flutter_ios_registrant_gen",
            "flutter_ios_runner_lib_gen")

        flutter_ios_framework_gen(name = "my_framework", application = ":my_app")
        flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
        flutter_ios_engine(name = "my_engine")
        flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

        flutter_ios_runner_lib_gen(
            name = "my_runner",
            registrant = ":my_registrant",
            engine = ":my_engine",
        )

        ios_application(
            name = "my_ios_app",
            bundle_id = "com.example.myapp",
            infoplists = [":my_info_plist"],
            launch_storyboard = IOS_DEFAULT_LAUNCH_STORYBOARD,
            deps = [
                ":my_framework",
                # Frameworks for native assets / `native_deps` dylibs. Leave
                # this out and the app still builds and renders — it just
                # cannot resolve any native asset at runtime.
                ":my_native_frameworks",
                ":my_runner",
            ],
        )
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _IOS_MINIMUM_OS_VERSION = "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:debug_build.bzl", _debug_build = "debug_build")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library", _flutter_xtool_apple_plugin_library = "flutter_xtool_apple_plugin_library")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_application = "flutter_ios_application", _flutter_ios_framework_rule = "flutter_ios_framework", _flutter_ios_native_frameworks_rule = "flutter_ios_native_frameworks", _flutter_ios_privacy_manifests_rule = "flutter_ios_privacy_manifests")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge")
load("//flutter/private:flutter_xtool_bundle.bzl", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import", _flutter_xtool_bundle_version = "flutter_xtool_bundle_version", _flutter_xtool_ios_bundle = "flutter_xtool_ios_bundle")
load("//flutter/private:ios_app.bzl", _IOS_DEFAULT_LAUNCH_STORYBOARD = "IOS_DEFAULT_LAUNCH_STORYBOARD", _IOS_DEFAULT_MAIN_STORYBOARD = "IOS_DEFAULT_MAIN_STORYBOARD", _flutter_ios_app = "flutter_ios_app", _flutter_ios_engine = "flutter_ios_engine")
load("//flutter/private:ios_sim_debug.bzl", _ios_sim_debug_app = "ios_sim_debug_app")

# Re-export constants for user BUILD files.
IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION
IOS_DEFAULT_LAUNCH_STORYBOARD = _IOS_DEFAULT_LAUNCH_STORYBOARD
IOS_DEFAULT_MAIN_STORYBOARD = _IOS_DEFAULT_MAIN_STORYBOARD

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_ios_app as `additional_entitlements`; exposed for Tier 2
# users assembling an ios_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# Host-agnostic xtool xcframework import, versioning, and iOS bundle rules.
flutter_darwin_xcframework_import = _flutter_darwin_xcframework_import
flutter_xtool_bundle_version = _flutter_xtool_bundle_version
flutter_xtool_ios_bundle = _flutter_xtool_ios_bundle

# Tier 1 app assembly and engine import live in flutter/private/ios_app.bzl;
# re-exported here so user BUILD files are unaffected.
flutter_ios_engine = _flutter_ios_engine
flutter_ios_app = _flutter_ios_app

# Simulator-debug (JIT) rebuild of an iOS app: `-c dbg` plus
# `--ios_multi_cpus=sim_arm64` on the app only, so `bazel test //...` needs
# no flags. Used by `flutter_integration_test(platform = "ios")`; also handy
# for hand-rolled simulator tests. See `flutter_ios_simulator_build` below
# for the `-c dbg`-only variant.
ios_sim_debug_app = _ios_sim_debug_app

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of an
# `ios_application` (whose split transition puts them in an iOS
# configuration). Built standalone by a `//...` pattern they'd run in the
# host configuration — wrapping the wrong platform's dylibs and invoking
# Apple-only tools (`xcrun`), which fails outright on non-macOS hosts.

def flutter_ios_registrant_gen(name, language = "swift", exclude_plugins = [], **kwargs):
    """Generates the iOS GeneratedPluginRegistrant. See `flutter_ios_registrant`.

    Args:
        name: Target name.
        language: Registrant language: `"swift"` (default) emits
            GeneratedPluginRegistrant.swift; `"objc"` emits
            GeneratedPluginRegistrant.h and GeneratedPluginRegistrant.m
            matching the flutter tool's own template, exposed through the
            `hdrs` and `srcs` output groups for an objc_library to consume.
        exclude_plugins: Plugin module names to leave out of the
            registrant. A name that is not a native iOS plugin of the
            application is an error, listing the valid names. iOS-only:
            the Android, Linux, macOS and Windows registrants always
            register every collected native plugin.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    if language not in ("swift", "objc"):
        fail("flutter_ios_registrant_gen: language must be 'swift' or 'objc', got %r" % language)
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_registrant_rule(
        name = name,
        language = language,
        exclude_plugins = exclude_plugins,
        tags = tags,
        **kwargs
    )

def flutter_ios_native_frameworks_gen(name, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Wraps native dylibs in .frameworks for iOS bundling. See `flutter_ios_native_frameworks`.

    Args:
        name: Target name.
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_native_frameworks_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

def flutter_ios_privacy_manifests_gen(name, **kwargs):
    """Exposes plugin privacy manifests. See `flutter_ios_privacy_manifests`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_privacy_manifests_rule(name = name, tags = tags, **kwargs)

# Public wrapper that compiles a Flutter plugin's iOS Apple sources into a
# swift_library. Use directly to wire a monorepo plugin's BUILD.bazel without
# going through the ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_ios_framework_gen(name, application, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Generates App.framework and wraps it as apple_dynamic_framework_import.

    Chains: flutter_application → intermediates → framework assembly → import.
    The resulting target can be added to ios_application deps directly.

    In debug mode (-c dbg), bundle_only=True embeds the framework without
    linking (stub binary for rules_apple compatibility, not loaded at runtime).

    Args:
        name: Target name. Add to ios_application deps.
        application: A flutter_application target.
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = internal_tags,
    )

    _flutter_ios_framework_rule(
        name = "__%s_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = internal_tags,
    )

    apple_dynamic_framework_import(
        name = name,
        framework_imports = ["__%s_framework" % name],
        bundle_only = select({
            Label("@rules_flutter//flutter/private:dbg"): True,
            "//conditions:default": False,
        }),
        tags = tags,
        **kwargs
    )

def flutter_ios_info_plist_gen(name, app_name, module_name = "Runner", **kwargs):
    """Generates an iOS Info.plist from the default Bazel template.

    The template includes UIApplicationSceneManifest pointing to
    MODULE_NAME.SceneDelegate for scene-based lifecycle.

    The output is a filegroup that includes the generated plist plus
    NSBonjourServices for debug/profile builds (required for mDNS
    VM service registration). Pass this target to ios_application
    infoplists.

    Args:
        name: Target name. Pass to ios_application infoplists.
        app_name: Display name (CFBundleDisplayName, CFBundleName).
        module_name: Swift module name for SceneDelegate lookup.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    visibility = kwargs.pop("visibility", None)

    expand_template(
        name = "__%s_plist" % name,
        template = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        out = name + "/Info.plist",
        substitutions = {
            "APP_NAME": app_name,
            "MODULE_NAME": module_name,
        },
        tags = tags,
        **kwargs
    )

    native.filegroup(
        name = name,
        srcs = ["__%s_plist" % name] + select({
            "@rules_flutter//flutter:release": [],
            "//conditions:default": [
                "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist",
            ],
        }),
        tags = tags,
        visibility = visibility,
    )

def flutter_ios_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", backend = "rules_apple", **kwargs):
    """Generates a swift_library for the default iOS runner.

    Uses template AppDelegate.swift and SceneDelegate.swift from rules_flutter.
    This replaces `flutter create --platforms=ios` output for users who
    don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive.

    Args:
        name: Target name. Add to ios_application deps.
        registrant: A flutter_ios_registrant_gen target (Swift source).
        engine: A flutter_ios_engine target (Flutter.xcframework).
        application: A flutter_application target. Required to wire pub
            plugins' iOS Swift modules + link inputs into the runner;
            optional only for legacy Tier-2 setups with no native plugins.
        module_name: Swift module name (default "Runner").
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments passed to swift_library.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_runner_lib_gen: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    deps = [engine]
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            platform = "ios",
            tags = internal_tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    runner_srcs = [
        registrant,
        "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
    ]
    if backend == "rules_apple":
        swift_library(
            name = name,
            srcs = runner_srcs,
            data = [
                "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard",
            ],
            module_name = module_name,
            tags = tags,
            deps = deps,
            **kwargs
        )
    else:
        _flutter_xtool_apple_plugin_library(
            name = name,
            srcs = runner_srcs,
            module_name = module_name,
            platform = "ios",
            deps = deps,
            tags = tags,
            **kwargs
        )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_ios_simulator_build(name, targets, **kwargs):
    """Builds iOS apps for the simulator in debug mode, whatever `-c` says.

    The simulator engine runs only debug builds, so a simulator app built in
    `fastbuild` or `opt` is refused at analysis. This forwards the files of
    `targets` built with `-c dbg`, for anything that needs a simulator bundle
    under a default `bazel test //...`: a `build_test`, or a test that reads
    the bundle through `data`. The files keep their runfiles paths.

    Args:
        name: Target name.
        targets: `flutter_ios_app` or `ios_application` targets.
        **kwargs: Common attributes (e.g. `tags`, `testonly`, `visibility`).
    """
    _debug_build(
        name = name,
        targets = targets,
        **kwargs
    )

def flutter_ios_simulator_build_test(name, targets, **kwargs):
    """A build test of iOS simulator apps, built with `-c dbg`.

    A plain `build_test` of a simulator app fails under a default
    `bazel test //...`, because the app is refused outside debug mode. See
    `flutter_ios_simulator_build`.

    Args:
        name: Target name.
        targets: `flutter_ios_app` or `ios_application` targets to build.
        **kwargs: Passed through to `build_test` (e.g. `tags`,
            `target_compatible_with`).
    """
    flutter_ios_simulator_build(
        name = "__%s_dbg" % name,
        targets = targets,
        tags = ["manual"],
        testonly = True,
    )
    build_test(
        name = name,
        targets = ["__%s_dbg" % name],
        **kwargs
    )
