"""Unit and analysis tests for iOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework", "flutter_ios_native_frameworks")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load(":apple_bundling.bzl", "fake_application", "outputs_under_target_dir_test")

def _ios_device_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64"))}

_ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_target_impl(ctx):
    files = []
    for t in ctx.attr.targets:
        files.append(t[DefaultInfo].files)
    return [DefaultInfo(files = depset(transitive = files))]

_ios_device_targets = rule(
    implementation = _platform_target_impl,
    attrs = {
        "targets": attr.label_list(cfg = _ios_device_transition, mandatory = True),
    },
)

def _simulator_fastbuild_refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "The iOS simulator runs debug builds only, and this is a fastbuild build.",
    )
    return analysistest.end(env)

_simulator_fastbuild_refused_test = analysistest.make(
    _simulator_fastbuild_refused_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "fastbuild",
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_x64")),
    },
)

_DISCOVERED = "ios/Runner/Runner.entitlements"

def _resolve_test_impl(ctx):
    env = unittest.begin(ctx)

    # Said nothing: the app ships what `flutter create` and Xcode left on disk.
    asserts.equals(
        env,
        _DISCOVERED,
        resolve_ios_entitlements(None, discovered = _DISCOVERED),
        "an unset attribute ships the discovered file",
    )

    # Said nothing, and there is nothing: a capability-less app, which is the
    # common iOS case and not an error.
    asserts.equals(
        env,
        None,
        resolve_ios_entitlements(None, discovered = None),
        "an app with no entitlements file ships none",
    )

    # Said "none": the device build whose profile cannot grant what the file
    # asks for. The file stays on disk for the targets that can use it.
    asserts.equals(
        env,
        None,
        resolve_ios_entitlements(False, discovered = _DISCOVERED),
        "False ships none although the file exists",
    )

    # Named one: an override beats both discovery and its absence.
    asserts.equals(
        env,
        "//other:entitlements",
        resolve_ios_entitlements("//other:entitlements", discovered = _DISCOVERED),
        "an explicit label wins over the discovered file",
    )
    asserts.equals(
        env,
        "//other:entitlements",
        resolve_ios_entitlements("//other:entitlements", discovered = None),
        "an explicit label is used when there is nothing to discover",
    )

    return unittest.end(env)

_resolve_test = unittest.make(_resolve_test_impl)

# -- Bundling ------------------------------------------------------------------

def _bundling_tests(name):
    """Declare the bundling fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """

    for app in ["_fake_app", "_fake_app_other"]:
        fake_application(
            name = name + app,
            debug = True,
            tags = ["manual"],
        )
        flutter_ios_framework(
            name = name + app + "_framework",
            application = name + app,
            tags = ["manual"],
        )

    # Release-mode fixture with a synthetic Mach-O AOT dylib and native dylib,
    # transitioned to //flutter/platforms:ios_arm64 so `FlutterIOSRetagDylib`
    # and `FlutterIOSNativeAssetFramework` run via `macho_edit.dart` on both
    # Linux and macOS hosts.
    fake_application(
        name = name + "_fake_release_app",
        debug = False,
        macho_aot = True,
        native_libs = ["libfoo.dylib"],
        code_assets = ["libbar.dylib"],
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_fake_release_app_framework",
        application = name + "_fake_release_app",
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_fake_release_app_native_frameworks",
        application = name + "_fake_release_app",
        tags = ["manual"],
    )
    _ios_device_targets(
        name = name + "_release_device_targets",
        targets = [
            name + "_fake_release_app_framework",
            name + "_fake_release_app_native_frameworks",
        ],
        tags = ["manual"],
    )

    outputs_under_target_dir_test(
        name = name + "_framework_outputs_under_target_dir",
        target_under_test = name + "_fake_app_framework",
    )

    _simulator_fastbuild_refused_test(
        name = name + "_simulator_fastbuild_refused",
        target_under_test = name + "_fake_release_app_framework",
    )

    # Two different apps in one package, built together: any output the two
    # declare under one name conflicts. A pair built from the same application
    # would not — Bazel shares identical actions.
    build_test(
        name = name + "_two_apps_one_package",
        targets = [
            name + "_fake_app_framework",
            name + "_fake_app_other_framework",
            name + "_release_device_targets",
        ],
    )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_simulator_fastbuild_refused",
        name + "_two_apps_one_package",
    ]

def ios_test_suite(name):
    """Declares the iOS entitlement and bundling tests.

    Args:
        name: The test_suite name.
    """
    _resolve_test(name = name + "_resolve")
    native.test_suite(
        name = name,
        tests = [":" + t for t in [name + "_resolve"] + _bundling_tests(name)],
    )
