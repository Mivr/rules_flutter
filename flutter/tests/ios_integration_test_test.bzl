"""Unit and analysis tests for the iOS simulator integration-test branch.

The `platform = "ios"` leg of `flutter_integration_test` assembles its
simulator app from Apple-toolchain targets, so the full macro cannot analyze
on Linux. These tests pin everything around that seam: the bundle-id
default, the simulator-debug transition settings, the macOS-only constraint
the macro applies, the bootstrap content (notably that it reads the harness
URL with no fixed-port fallback), and — through directly instantiated
fixtures — the bootstrap rule's entrypoint resolution and guards plus the
test rule's env and runfiles. The macro-created portable targets (the
bootstrap and the kernel application) analyze on Linux; the
Apple-toolchain targets and the macro-created test target are covered by a
macOS-gated analysis test.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_integration_test")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load(
    "//flutter/private:flutter_integration_test.bzl",
    "flutter_ios_integration_bootstrap",
    "make_linux_integration_bootstrap_content",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "IOS_APP_KWARG_KEYS",
    "default_ios_bundle_id",
    "flutter_ios_integration_test",
    "ios_integration_test_env",
    "sanitize_ios_bundle_id_segment",
)
load("//flutter/private:ios_sim_debug.bzl", "ios_sim_debug_transition_impl")

_TEST_IMPORT = "../../integration_test/app_test.dart"

# The macro pins its Apple-toolchain targets to macOS; the analysis test over
# the macro-created test target below carries this constraint, so it is
# skipped on Linux and runs on macOS. That gate itself is the assertion that
# the macro applies the constraint.
IOS_MACOS_ONLY = ["@platforms//os:macos"]

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

def _bundle_id_default_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "com.example.my-app.app-test",
        default_ios_bundle_id("my_app", "app_test"),
    )
    asserts.equals(env, "my-app", sanitize_ios_bundle_id_segment("My App!"))
    asserts.equals(env, "id-9lives", sanitize_ios_bundle_id_segment("9lives"))
    asserts.equals(env, "app", sanitize_ios_bundle_id_segment(""))
    asserts.false(
        env,
        default_ios_bundle_id("pkg", "one") == default_ios_bundle_id("pkg", "two"),
        "two tests in one package must never share a bundle id",
    )
    return unittest.end(env)

def _transition_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {
            "//command_line_option:compilation_mode": "dbg",
            "//command_line_option:ios_multi_cpus": ["sim_arm64"],
        },
        ios_sim_debug_transition_impl({}, None),
    )
    return unittest.end(env)

def _app_kwarg_keys_test_impl(ctx):
    env = unittest.begin(ctx)
    for key in ("srcs", "main", "app_srcs", "assets", "defines", "native_deps"):
        asserts.true(env, key in IOS_APP_KWARG_KEYS, "%r must reach flutter_application" % key)
    asserts.false(
        env,
        "profile" in IOS_APP_KWARG_KEYS,
        "profile comes from the configuration, not an attribute",
    )
    asserts.false(
        env,
        "ios_bundle_id" in IOS_APP_KWARG_KEYS,
        "ios_bundle_id belongs to the test target, not the app",
    )
    return unittest.end(env)

def _ios_bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in src)
    asserts.true(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();" in src)
    asserts.false(env, "class _IntegrationTestBinding" in src)
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in src)
    asserts.true(env, "WebSocket.connect(wsUrl)" in src)
    asserts.false(
        env,
        "ws://127.0.0.1" in src,
        "the iOS bootstrap takes the runner's per-launch URL; no fixed port",
    )
    asserts.false(
        env,
        "38427" in src,
        "the iOS bootstrap takes the runner's per-launch URL; no fixed port",
    )
    return unittest.end(env)

def _ios_bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.false(env, "package:integration_test/integration_test.dart" in src)
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in src)
    asserts.true(env, "_IntegrationTestBinding.ensureInitialized();" in src)
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in src)
    asserts.true(env, "WebSocket.connect(wsUrl)" in src)
    asserts.false(
        env,
        "ws://127.0.0.1" in src,
        "the iOS bootstrap takes the runner's per-launch URL; no fixed port",
    )
    return unittest.end(env)

def _bootstrap_file_test_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(
        env,
        files[0].basename.endswith("_bootstrap.dart"),
        "the macro must resolve the entrypoint into a bootstrap, got %r" % files[0].basename,
    )
    return analysistest.end(env)

def _application_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        FlutterApplicationInfo in tut,
        "the macro must assemble the bootstrap into a flutter_application",
    )
    asserts.true(
        env,
        tut[FlutterApplicationInfo].kernel_dill != None,
        "a debug simulator app carries its kernel, not AOT output",
    )
    return analysistest.end(env)

def _bootstrap_requires_flutter_test_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must depend on package:flutter_test")
    return analysistest.end(env)

def _bootstrap_resolves_main_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "specify `main`")
    return analysistest.end(env)

def _ios_env_test_impl(ctx):
    env = unittest.begin(ctx)
    test_env = ios_integration_test_env(
        "target",
        "pkg/ios_fixture_stub.ipa",
        "com.example.ios_fixture.app_test",
        "flutter/tests/ios_fixture_app_test.dart",
        {"MY_VAR": "1"},
        "pkg/ios_fixture_tags.txt",
        ["tag-a"],
        [],
    )
    asserts.equals(env, "ios", test_env["FLUTTER_INTEGRATION_TEST_PLATFORM"])
    asserts.equals(env, "pkg/ios_fixture_stub.ipa", test_env["FLUTTER_INTEGRATION_TEST_IOS_APP"])
    asserts.equals(
        env,
        "com.example.ios_fixture.app_test",
        test_env["FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID"],
    )
    asserts.equals(
        env,
        "flutter/tests/ios_fixture_app_test.dart",
        test_env["FLUTTER_INTEGRATION_TEST_PATH"],
    )
    asserts.equals(env, '{"MY_VAR":"1"}', test_env["FLUTTER_INTEGRATION_TEST_DECLARED_ENV"])
    asserts.equals(env, "pkg/ios_fixture_tags.txt", test_env["FLUTTER_TEST_LIBRARY_TAGS"])
    asserts.equals(env, "tag-a", test_env["FLUTTER_TEST_TAGS_ATTR"])
    asserts.false(env, "FLUTTER_TEST_EXCLUDE_TAGS_ATTR" in test_env)
    asserts.equals(env, "1", test_env["MY_VAR"])
    return unittest.end(env)

def _macro_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, "flutter_ios_integration_test", ctx.attr.test_kind)
    asserts.equals(env, "ios", ctx.attr.platform)
    asserts.equals(env, "ios_integration_fixture", ctx.attr.package_name)
    asserts.equals(
        env,
        "com.example.ios-integration-fixture.ios-macro-test",
        ctx.attr.ios_bundle_id,
        "the macro must default the bundle id from package and target",
    )
    asserts.equals(env, "flutter_ios_integration_bootstrap", ctx.attr.bootstrap_kind)
    asserts.equals(
        env,
        [
            "//flutter/private/runners/ios:AppDelegate.swift",
            "//flutter/private/runners/ios:SceneDelegate.swift",
            ":_____ios_macro_test_ios_registrant",
        ],
        ctx.attr.runner_srcs,
        "the macro must forward ios_runner_srcs to the app",
    )
    return analysistest.end(env)

def _direct_test_rule_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        tut[DefaultInfo].files_to_run.executable != None,
        "the test rule must expose the runner executable",
    )
    files = tut[DefaultInfo].default_runfiles.files.to_list()
    asserts.true(
        env,
        any([f.basename == "ios_fixture_stub.ipa" for f in files]),
        "the .ipa must be in runfiles, got %r" % [f.basename for f in files],
    )
    return analysistest.end(env)

def _env_collision_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "cannot be overridden")
    return analysistest.end(env)

def _macro_test_rule_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        tut[DefaultInfo].files_to_run.executable != None,
        "the macro must wire the test target to the runner executable",
    )
    return analysistest.end(env)

_t0_test = unittest.make(_bundle_id_default_test_impl)
_t1_test = unittest.make(_transition_settings_test_impl)
_t2_test = unittest.make(_app_kwarg_keys_test_impl)
_t3_test = unittest.make(_ios_bootstrap_with_integration_test_pkg_test_impl)
_t4_test = unittest.make(_ios_bootstrap_without_integration_test_pkg_test_impl)
_t5_test = unittest.make(_ios_env_test_impl)

_bootstrap_file_test = analysistest.make(_bootstrap_file_test_impl, config_settings = _DBG)
_application_info_test = analysistest.make(_application_info_test_impl, config_settings = _DBG)
_bootstrap_requires_flutter_test_test = analysistest.make(
    _bootstrap_requires_flutter_test_test_impl,
    expect_failure = True,
    config_settings = _DBG,
)
_bootstrap_resolves_main_test = analysistest.make(
    _bootstrap_resolves_main_test_impl,
    expect_failure = True,
    config_settings = _DBG,
)
_direct_test_rule_test = analysistest.make(_direct_test_rule_test_impl, config_settings = _DBG)
_macro_wiring_test = analysistest.make(
    _macro_wiring_test_impl,
    attrs = {
        "test_kind": attr.string(),
        "platform": attr.string(),
        "package_name": attr.string(),
        "ios_bundle_id": attr.string(),
        "bootstrap_kind": attr.string(),
        "runner_srcs": attr.string_list(),
    },
    config_settings = _DBG,
)
_env_collision_test = analysistest.make(
    _env_collision_test_impl,
    expect_failure = True,
    config_settings = _DBG,
)
_macro_test_rule_test = analysistest.make(_macro_test_rule_test_impl, config_settings = _DBG)

def ios_integration_test_test_suite(name):
    """Fixtures and tests for the iOS simulator integration-test branch.

    Args:
        name: The test suite name.
    """
    flutter_integration_test(
        name = "_ios_macro_test",
        package_name = "ios_integration_fixture",
        platform = "ios",
        srcs = ["ios_fixture_app_test.dart"],
        deps = ["//flutter/tests/ios_integration_dep:flutter_test_dep"],
        # The tests package has no ios/Runner of its own: point the app at
        # the shared default Runner instead.
        ios_runner_srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        ios_info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        tags = ["manual"],
    )
    flutter_ios_integration_bootstrap(
        name = "_ios_direct_bootstrap_no_deps",
        package_name = "ios_fixture",
        srcs = ["ios_fixture_app_test.dart"],
        tags = ["manual"],
    )
    flutter_ios_integration_bootstrap(
        name = "_ios_direct_bootstrap_ambiguous",
        package_name = "ios_fixture",
        srcs = [
            "ios_fixture_app_test.dart",
            "ios_fixture_other_test.dart",
        ],
        deps = ["//flutter/tests/ios_integration_dep:flutter_test_dep"],
        tags = ["manual"],
    )
    write_file(
        name = "_ios_stub_ipa",
        out = "ios_fixture_stub.ipa",
        content = ["stub"],
        tags = ["manual"],
    )
    flutter_ios_integration_test(
        name = "_ios_direct_test",
        app = ":_ios_stub_ipa",
        ios_bundle_id = "com.example.ios_fixture.app_test",
        package_name = "ios_fixture",
        srcs = ["ios_fixture_app_test.dart"],
        deps = ["//flutter/tests/ios_integration_dep:flutter_test_dep"],
        tags = ["manual"],
    )
    flutter_ios_integration_test(
        name = "_ios_direct_test_env_collision",
        app = ":_ios_stub_ipa",
        ios_bundle_id = "com.example.ios_fixture.app_test",
        package_name = "ios_fixture",
        srcs = ["ios_fixture_app_test.dart"],
        deps = ["//flutter/tests/ios_integration_dep:flutter_test_dep"],
        env = {"FLUTTER_TEST_TAGS": "tag-a"},
        tags = ["manual"],
    )
    _bootstrap_file_test(
        name = name + "_bootstrap_file",
        target_under_test = ":___ios_macro_test_bootstrap",
    )
    _application_info_test(
        name = name + "_application_info",
        target_under_test = ":___ios_macro_test_app",
    )
    _bootstrap_requires_flutter_test_test(
        name = name + "_bootstrap_requires_flutter_test",
        target_under_test = ":_ios_direct_bootstrap_no_deps",
    )
    _bootstrap_resolves_main_test(
        name = name + "_bootstrap_resolves_main",
        target_under_test = ":_ios_direct_bootstrap_ambiguous",
    )
    _direct_test_rule_test(
        name = name + "_direct_test_rule",
        target_under_test = ":_ios_direct_test",
    )

    # The macro-created test target is Apple-toolchain-bound (see the
    # macOS-gated test below); its wiring is pinned here instead, by reading
    # the created rules' attributes at loading time (as ios_test does) and
    # asserting them in analysis.
    created = native.existing_rules()
    macro_test_rule = created["_ios_macro_test"]

    # Internal `flutter_ios_app` target names derive from the app name, as in
    # ios_test's expectations.
    runner_name = "__%s_runner" % "___ios_macro_test_ios"
    _macro_wiring_test(
        name = name + "_macro_wiring",
        target_under_test = ":___ios_macro_test_bootstrap",
        test_kind = macro_test_rule["kind"],
        platform = macro_test_rule["platform"],
        package_name = macro_test_rule["package_name"],
        ios_bundle_id = macro_test_rule["ios_bundle_id"],
        bootstrap_kind = created["___ios_macro_test_bootstrap"]["kind"],
        runner_srcs = [
            str(s)
            for s in created[runner_name]["srcs"]
        ],
    )
    _env_collision_test(
        name = name + "_env_collision",
        target_under_test = ":_ios_direct_test_env_collision",
    )
    _macro_test_rule_test(
        name = name + "_macro_test_rule",
        target_under_test = ":_ios_macro_test",
        target_compatible_with = IOS_MACOS_ONLY,
    )
    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_bootstrap_file",
            ":" + name + "_application_info",
            ":" + name + "_bootstrap_requires_flutter_test",
            ":" + name + "_bootstrap_resolves_main",
            ":" + name + "_direct_test_rule",
            ":" + name + "_env_collision",
            ":" + name + "_macro_wiring",
            ":" + name + "_macro_test_rule",
        ],
    )
