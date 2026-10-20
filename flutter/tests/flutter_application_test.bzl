"""Unit tests for flutter_application platform detection logic."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter:defs.bzl", "debug_kernel_tags")
load("//flutter/private:common.bzl", "android_platform_for_abi", "build_info_label", "detect_target_platform", "kernel_file_stem", "launch_build_args")
load("//flutter/private:flutter_application.bzl", "debug_kernel_transition_impl")
load("//flutter/private:plugin_registrant.bzl", "DEV_REGISTRANT_PLATFORMS")

def _ios_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

def _macos_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "macos", result)
    return unittest.end(env)

def _linux_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = True,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "linux", result)
    return unittest.end(env)

def _windows_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = True,
        is_android = False,
    )
    asserts.equals(env, "windows", result)
    return unittest.end(env)

def _android_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = True,
    )
    asserts.equals(env, "android", result)
    return unittest.end(env)

def _ios_priority_over_macos_test_impl(ctx):
    """iOS should take priority if both iOS and macOS match (edge case)."""
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

# `launch_build_args` has to stay in step with `Device.buildArgs` in
# tools/dev_tool/lib/device.dart — the app reports these flags so an attaching
# dev tool can rebuild in the configuration the app was actually built in.
# Nothing links the two languages, so these assertions are the link: each
# expected value below is quoted from the corresponding `buildArgs` getter.

def _ios_simulator_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--ios_multi_cpus=sim_arm64"],
        launch_build_args("ios", is_simulator = True, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _ios_device_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--ios_multi_cpus=arm64"],
        launch_build_args("ios", is_simulator = False, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _android_arm64_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--platforms=@rules_flutter//flutter/platforms:android_arm64"],
        launch_build_args("android", is_simulator = False, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _android_x64_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--platforms=@rules_flutter//flutter/platforms:android_x64"],
        launch_build_args("android", is_simulator = False, is_arm64 = False, is_x86_64 = True),
    )
    return unittest.end(env)

def _desktop_build_args_test_impl(ctx):
    """Desktop needs no flag: the app is already in the top-level configuration.

    Emitting `--platforms=` here would move a dev-loop rebuild to a different
    output directory than the one the running app was built in — the exact
    mismatch `build_info` exists to prevent.
    """
    env = unittest.begin(ctx)
    for platform in ["macos", "linux", "windows"]:
        asserts.equals(
            env,
            [],
            launch_build_args(platform, is_simulator = False, is_arm64 = True, is_x86_64 = False),
            msg = "expected no launch flags for %s" % platform,
        )
    return unittest.end(env)

def _dev_registrant_covers_every_platform_test_impl(ctx):
    """Every platform a running app can report has a dev-loop registrant.

    The dev tool's incremental compiler picks its plugin registrant by the
    platform the running app reports, which is whatever
    `detect_target_platform` produced for the launch build. It looks that
    value up in `DEV_REGISTRANT_PLATFORMS`, and a miss is a hard failure
    rather than a fallback — deliberately, because falling back to another
    platform's filter is the silent wrong-plugin-set bug the map exists to
    prevent. So the two lists have to name the same platforms, and nothing in
    the rules couples them: they are separate literals in separate files, and
    a sixth platform added to one alone would surface only at dev-tool
    runtime, on a legitimate run.

    Both directions of the set comparison are asserted: a platform missing
    from the map breaks every dev run on it, and a stale key left in the map
    generates a filter for a platform nothing can produce. What this cannot
    reach is a sixth platform added to `detect_target_platform` behind a
    parameter with a default — the call below would still compile, still name
    five platforms, and still pass. That case is left to the runtime failure,
    which is loud: the dev tool names the platform it could not find and the
    keys it has.
    """
    env = unittest.begin(ctx)
    detected = [
        detect_target_platform(
            is_ios = p == "ios",
            is_macos = p == "macos",
            is_linux = p == "linux",
            is_windows = p == "windows",
            is_android = p == "android",
        )
        # Spelled out rather than read from DEV_REGISTRANT_PLATFORMS, so this
        # compares two lists instead of comparing one with itself.
        for p in ["android", "ios", "linux", "macos", "windows"]
    ]
    asserts.equals(
        env,
        sorted(detected),
        sorted(DEV_REGISTRANT_PLATFORMS),
        msg = "the dev registrant map and detect_target_platform disagree",
    )
    return unittest.end(env)

_t0_test = unittest.make(_ios_detection_test_impl)
_t1_test = unittest.make(_macos_detection_test_impl)
_t2_test = unittest.make(_linux_detection_test_impl)
_t3_test = unittest.make(_windows_detection_test_impl)
_t4_test = unittest.make(_android_detection_test_impl)
_t5_test = unittest.make(_ios_priority_over_macos_test_impl)
_t6_test = unittest.make(_ios_simulator_build_args_test_impl)
_t7_test = unittest.make(_ios_device_build_args_test_impl)
_t8_test = unittest.make(_android_arm64_build_args_test_impl)
_t9_test = unittest.make(_android_x64_build_args_test_impl)
_t10_test = unittest.make(_desktop_build_args_test_impl)
_t11_test = unittest.make(_dev_registrant_covers_every_platform_test_impl)

def _debug_kernel_transition_moves_host_x64_to_android_test_impl(ctx):
    """An x86_64 host edge lands on the x86_64 Android platform, in dbg."""
    env = unittest.begin(ctx)
    result = debug_kernel_transition_impl(
        {
            "//command_line_option:platforms": ["@platforms//linux_x86_64"],
            "//command_line_option:android_platforms": [],
            "//command_line_option:cpu": "k8",
        },
        None,
    )
    asserts.equals(env, [android_platform_for_abi("x86_64")], result["//command_line_option:platforms"])
    asserts.equals(env, "dbg", result["//command_line_option:compilation_mode"])
    asserts.equals(env, "off", result["//command_line_option:dynamic_mode"])
    asserts.equals(env, True, result["@rules_go//go/config:pure"])
    return unittest.end(env)

_t12_test = unittest.make(_debug_kernel_transition_moves_host_x64_to_android_test_impl)

def _debug_kernel_transition_defaults_generic_host_to_arm64_test_impl(ctx):
    """A host platform naming no arch defaults to the arm64 Android platform.

    The same default-ABI choice the Android edge makes, so the canonical
    configuration stays the Android app's configuration.
    """
    env = unittest.begin(ctx)
    result = debug_kernel_transition_impl(
        {
            "//command_line_option:platforms": ["@platforms//host"],
            "//command_line_option:android_platforms": [],
            "//command_line_option:cpu": "k8",
        },
        None,
    )
    asserts.equals(env, [android_platform_for_abi("arm64-v8a")], result["//command_line_option:platforms"])
    asserts.equals(env, True, result["@rules_go//go/config:pure"])
    return unittest.end(env)

_t12b_test = unittest.make(_debug_kernel_transition_defaults_generic_host_to_arm64_test_impl)

def _debug_kernel_transition_moves_host_arm64_to_android_test_impl(ctx):
    """An arm64 host edge lands on the arm64 Android platform."""
    env = unittest.begin(ctx)
    result = debug_kernel_transition_impl(
        {
            "//command_line_option:platforms": ["@platforms//host"],
            "//command_line_option:android_platforms": [],
            "//command_line_option:cpu": "arm64",
        },
        None,
    )
    asserts.equals(env, [android_platform_for_abi("arm64-v8a")], result["//command_line_option:platforms"])
    asserts.equals(env, True, result["@rules_go//go/config:pure"])
    return unittest.end(env)

_t13_test = unittest.make(_debug_kernel_transition_moves_host_arm64_to_android_test_impl)

def _debug_kernel_transition_keeps_android_platforms_test_impl(ctx):
    """An edge already on Android keeps its platforms.

    The canonical configuration IS the Android app's, so its kernel bytes
    stay put.
    """
    env = unittest.begin(ctx)
    incoming = ["@rules_flutter//flutter/platforms:android_arm64"]
    result = debug_kernel_transition_impl(
        {
            "//command_line_option:platforms": incoming,
            "//command_line_option:android_platforms": [],
            "//command_line_option:cpu": "arm64",
        },
        None,
    )
    asserts.equals(env, incoming, result["//command_line_option:platforms"])
    asserts.equals(env, True, result["@rules_go//go/config:pure"])
    return unittest.end(env)

_t14_test = unittest.make(_debug_kernel_transition_keeps_android_platforms_test_impl)

def _build_info_label_defaults_to_own_label_test_impl(ctx):
    """Without an override the record names the compiling target, as before."""
    env = unittest.begin(ctx)
    ctx_like = struct(label = "@@//app:app", attr = struct(build_label = ""))
    asserts.equals(env, "@@//app:app", build_info_label(ctx_like))
    return unittest.end(env)

_t15_test = unittest.make(_build_info_label_defaults_to_own_label_test_impl)

def _build_info_label_override_names_the_served_app_test_impl(ctx):
    """The canonical kernel reports the application it serves.

    So the dev tool's label check (cquery for the application vs the running
    record) keeps passing on a shared kernel.
    """
    env = unittest.begin(ctx)
    ctx_like = struct(
        label = "@@//app:__app_debug_kernel",
        attr = struct(build_label = "@@//app:app"),
    )
    asserts.equals(env, "@@//app:app", build_info_label(ctx_like))
    return unittest.end(env)

_t16_test = unittest.make(_build_info_label_override_names_the_served_app_test_impl)

def _kernel_file_stem_defaults_to_target_name_test_impl(ctx):
    env = unittest.begin(ctx)
    ctx_like = struct(label = struct(name = "app"), attr = struct(build_label = ""))
    asserts.equals(env, "app", kernel_file_stem(ctx_like))
    return unittest.end(env)

_t17_test = unittest.make(_kernel_file_stem_defaults_to_target_name_test_impl)

def _kernel_file_stem_parses_the_served_app_test_impl(ctx):
    """The canonical target derives side-library names from the served app.

    Registrant and staged agent names come from the served application, so
    the shared kernel's recorded URIs match the per-platform kernel's.
    """
    env = unittest.begin(ctx)
    ctx_like = struct(
        label = struct(name = "__app_debug_kernel"),
        attr = struct(build_label = "@@//app:app"),
    )
    asserts.equals(env, "app", kernel_file_stem(ctx_like))
    return unittest.end(env)

_t18_test = unittest.make(_kernel_file_stem_parses_the_served_app_test_impl)

def _debug_kernel_tags_add_manual_test_impl(ctx):
    """The canonical kernel stays out of wildcard builds.

    Without `manual`, `//...` builds the inner target top-level in every
    requesting configuration and compiles the kernel once more per
    configuration — the duplication H17 removes.
    """
    env = unittest.begin(ctx)
    asserts.equals(env, ["manual"], debug_kernel_tags(None))
    asserts.equals(env, ["manual"], debug_kernel_tags([]))
    asserts.equals(env, ["manual"], debug_kernel_tags(["manual"]))
    asserts.equals(env, ["opt", "manual"], debug_kernel_tags(["opt"]))
    return unittest.end(env)

_t19_test = unittest.make(_debug_kernel_tags_add_manual_test_impl)

def flutter_application_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t12b_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
        _t18_test,
        _t19_test,
    )
