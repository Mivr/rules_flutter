"""Analysis tests for trimmed SDK action inputs and test runfiles.

Asserts that `flutter_test` runfiles and Flutter build actions (`FlutterAotElf`,
`FlutterAotMacho`, `FlutterAssetBundle`, `FlutterDart2Wasm`, `FlutterDart2JS`)
stage only the SDK files their executables actually open, rather than the full
bundled `dart-sdk/` and `patched-sdk/` trees.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:analyze.bzl", "dart_analyze")
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_asset_bundle.bzl", "flutter_asset_bundle")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")

_PACKAGE = "inputs_fixture"
_MAIN = "lib/language_version_main.dart"

def _find_action(env, mnemonics):
    found = [a for a in analysistest.target_actions(env) if a.mnemonic in mnemonics]
    asserts.equals(
        env,
        1,
        len(found),
        "expected exactly one action in %s, got %s" % (mnemonics, [a.mnemonic for a in found]),
    )
    return found[0] if found else None

def _input_paths(action):
    return [f.path for f in action.inputs.to_list()] if action else []

def _assert_no_path_contains(env, paths, forbidden_substrings, context):
    for sub in forbidden_substrings:
        matches = [p for p in paths if sub in p]
        asserts.equals(
            env,
            [],
            matches[:5],
            "%s must not stage %r (found %d matching files, e.g. %s)" %
            (context, sub, len(matches), matches[:3]),
        )

def _assert_some_path_contains(env, paths, required_substrings, context):
    for sub in required_substrings:
        matches = [p for p in paths if sub in p]
        asserts.true(
            env,
            len(matches) > 0,
            "%s must stage %r" % (context, sub),
        )

def _flutter_test_runfiles_test_impl(ctx):
    """`flutter_test` runfiles carry `flutter_tester` and ICU data, not the SDK."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runfile_paths = [f.path for f in target[DefaultInfo].default_runfiles.files.to_list()]

    _assert_some_path_contains(
        env,
        runfile_paths,
        ["flutter_tester", "icudtl.dat"],
        "flutter_test runfiles",
    )
    _assert_no_path_contains(
        env,
        runfile_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "flutter_test runfiles",
    )

    asset_action = _find_action(env, ["FlutterAssetBundle"])
    _assert_no_path_contains(
        env,
        _input_paths(asset_action),
        ["/dart-sdk/", "/patched-sdk/"],
        "flutter_test FlutterAssetBundle",
    )

    # By default (`modular_kernel = True`), `flutter_test` compiles its entry module
    # with `DartKernel` against upstream `.flutter.koutline` summaries (without
    # staging upstream `.flutter.kmod` or transitive `.dart` sources) and links
    # with `DartKernelLink` against `.flutter.kmod`, emitting no whole-program
    # `FlutterKernelCompile`.
    kernel_action = _find_action(env, ["DartKernel"])
    kernel_inputs = _input_paths(kernel_action)
    _assert_some_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.koutline"],
        "flutter_test DartKernel inputs",
    )
    _assert_no_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.kmod/", "fake_test_api/lib/backend.dart"],
        "flutter_test DartKernel inputs",
    )
    link_action = _find_action(env, ["DartKernelLink"])
    _assert_some_path_contains(
        env,
        _input_paths(link_action),
        ["fake_test_api.flutter.kmod"],
        "flutter_test DartKernelLink inputs",
    )
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "modular flutter_test must not run FlutterKernelCompile")
    return analysistest.end(env)

def _flutter_test_defines_fallback_test_impl(ctx):
    """When per-test `defines` are set, `flutter_test` falls back to `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    _find_action(env, ["FlutterKernelCompile"])
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, [], modular_links, "flutter_test with own defines must fall back from DartKernelLink")
    return analysistest.end(env)

def _application_opt_inputs_test_impl(ctx):
    """In `-c opt`, AOT takes no SDK tree and asset bundling takes only the VM."""
    env = analysistest.begin(ctx)

    aot_action = _find_action(env, ["FlutterAotElf", "FlutterAotMacho"])
    aot_paths = _input_paths(aot_action)
    _assert_some_path_contains(env, aot_paths, ["gen_snapshot", ".dill"], "AOT action")
    _assert_no_path_contains(
        env,
        aot_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "AOT action",
    )

    asset_action = _find_action(env, ["FlutterAssetBundle"])
    asset_paths = _input_paths(asset_action)
    _assert_some_path_contains(
        env,
        asset_paths,
        ["const_finder.dart.snapshot", "font-subset", "/dart-sdk/bin/dart"],
        "release FlutterAssetBundle",
    )
    _assert_no_path_contains(
        env,
        asset_paths,
        [
            "/patched-sdk/",
            "/dart-sdk/lib/",
            "/dart-sdk/bin/snapshots/",
            "/dart-sdk/bin/utils/",
        ],
        "release FlutterAssetBundle",
    )
    return analysistest.end(env)

def _application_dbg_inputs_test_impl(ctx):
    """In `-c dbg`, icon tree shaking is off so asset bundling needs no Dart VM."""
    env = analysistest.begin(ctx)
    asset_action = _find_action(env, ["FlutterAssetBundle"])
    _assert_no_path_contains(
        env,
        _input_paths(asset_action),
        ["/dart-sdk/", "/patched-sdk/", "const_finder", "font-subset"],
        "debug FlutterAssetBundle",
    )
    return analysistest.end(env)

def _asset_bundle_inputs_test_impl(ctx):
    """Standalone `flutter_asset_bundle` never runs icon tree shaking or `dart`."""
    env = analysistest.begin(ctx)
    asset_action = _find_action(env, ["FlutterAssetBundle"])
    _assert_no_path_contains(
        env,
        _input_paths(asset_action),
        ["/dart-sdk/", "/patched-sdk/"],
        "standalone FlutterAssetBundle",
    )
    return analysistest.end(env)

def _aot_target_inputs_test_impl(ctx):
    """`flutter_aot_target` passes only the kernel dill and `gen_snapshot`."""
    env = analysistest.begin(ctx)
    aot_action = _find_action(env, ["FlutterAotElf", "FlutterAotMacho"])
    aot_paths = _input_paths(aot_action)
    _assert_some_path_contains(env, aot_paths, ["gen_snapshot", ".dill"], "flutter_aot_target")
    _assert_no_path_contains(
        env,
        aot_paths,
        ["/dart-sdk/", "/patched-sdk/"],
        "flutter_aot_target",
    )
    return analysistest.end(env)

def _kernel_target_modular_test_impl(ctx):
    """Default `flutter_kernel_target` (`aot = False`) compiles modularly without `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    kernel_action = _find_action(env, ["DartKernel"])
    kernel_inputs = _input_paths(kernel_action)
    _assert_some_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.koutline", "platform_strong.dill"],
        "flutter_kernel_target DartKernel inputs",
    )
    _assert_no_path_contains(
        env,
        kernel_inputs,
        ["fake_test_api.flutter.kmod/", "fake_test_api/lib/backend.dart"],
        "flutter_kernel_target DartKernel inputs",
    )
    link_action = _find_action(env, ["DartKernelLink"])
    _assert_some_path_contains(
        env,
        _input_paths(link_action),
        ["fake_test_api.flutter.kmod", "platform_strong.dill"],
        "flutter_kernel_target DartKernelLink inputs",
    )
    whole_program = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, [], whole_program, "non-AOT flutter_kernel_target must not run FlutterKernelCompile")
    return analysistest.end(env)

def _kernel_target_aot_test_impl(ctx):
    """`flutter_kernel_target(aot = True)` runs whole-program `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    _find_action(env, ["FlutterKernelCompile"])
    modular_links = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, [], modular_links, "AOT flutter_kernel_target must not run DartKernelLink")
    return analysistest.end(env)

def _web_inputs_test_impl(ctx):
    """`FlutterDart2Wasm` and `FlutterDart2JS` stage only their own compiler inputs."""
    env = analysistest.begin(ctx)

    wasm_action = _find_action(env, ["FlutterDart2Wasm"])
    wasm_paths = _input_paths(wasm_action)
    _assert_some_path_contains(
        env,
        wasm_paths,
        [
            "web-sdk/kernel/dart2wasm_platform.dill",
            "dart-sdk/bin/snapshots/dart2wasm",
            "dart-sdk/bin/snapshots/dartdev",
            "dart-sdk/bin/utils/wasm-opt",
        ],
        "FlutterDart2Wasm",
    )
    _assert_no_path_contains(
        env,
        wasm_paths,
        [
            "/patched-sdk/",
            "/web-sdk/canvaskit/",
            "/web-sdk/lib/",
            "dart2js_platform.dill",
            "dart2js_aot.dart.snapshot",
            "dartdevc",
            "analysis_server",
        ],
        "FlutterDart2Wasm",
    )

    js_action = _find_action(env, ["FlutterDart2JS"])
    js_paths = _input_paths(js_action)
    _assert_some_path_contains(
        env,
        js_paths,
        [
            "web-sdk/kernel/dart2js_platform.dill",
            "web-sdk/libraries.json",
            "dart-sdk/bin/snapshots/dart2js",
            "dart-sdk/bin/snapshots/dartdev",
        ],
        "FlutterDart2JS",
    )
    _assert_no_path_contains(
        env,
        js_paths,
        [
            "/patched-sdk/",
            "/web-sdk/canvaskit/",
            "dart2wasm_platform.dill",
            "dart2wasm_product.snapshot",
            "dartdevc",
            "wasm-opt",
            "analysis_server",
        ],
        "FlutterDart2JS",
    )
    return analysistest.end(env)

def _pub_runfiles_test_impl(ctx):
    """`//flutter:pub` runfiles carry `dartdev`, not the full Dart/patched SDK."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runfile_paths = [f.path for f in target[DefaultInfo].default_runfiles.files.to_list()]

    _assert_some_path_contains(
        env,
        runfile_paths,
        [
            "dart-sdk/bin/dart",
            "dart-sdk/bin/snapshots/dartdev",
            "dart-sdk/version",
        ],
        "flutter_pub runfiles",
    )
    _assert_no_path_contains(
        env,
        runfile_paths,
        [
            "/patched-sdk/",
            "/dart-sdk/lib/",
            "dartdevc",
            "analysis_server",
        ],
        "flutter_pub runfiles",
    )
    return analysistest.end(env)

_InspectActionsInfo = provider(
    doc = "Actions collected after `dart_analyze` and `dart_analyzer_summary` run.",
    fields = ["actions"],
)

def _inspect_analyze_actions_aspect_impl(target, _ctx):
    return [_InspectActionsInfo(actions = target.actions)]

_inspect_analyze_actions_aspect = aspect(
    implementation = _inspect_analyze_actions_aspect_impl,
    requires = [dart_analyze],
)

def _dart_toolchain_inputs_test_impl(ctx):
    """Bundled `dart_toolchain` stages `compile_files` for compile and `analyze_files` for analysis."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    all_actions = target[_InspectActionsInfo].actions

    for mnemonic in ["DartKernel", "DartCompile"]:
        compile_action = _find_action(env, [mnemonic])
        compile_paths = _input_paths(compile_action)
        _assert_some_path_contains(
            env,
            compile_paths,
            [
                "dart-sdk/bin/dart",
                "vm_platform_strong.dill",
            ],
            mnemonic,
        )
        _assert_no_path_contains(
            env,
            compile_paths,
            [
                "/patched-sdk/",
                "dart-sdk/bin/snapshots/analysis_server",
                "dart-sdk/bin/snapshots/dart2wasm",
                "dart-sdk/lib/core/",
            ],
            mnemonic,
        )

    analyze_found = [a for a in all_actions if a.mnemonic == "DartAnalyze"]
    asserts.equals(
        env,
        1,
        len(analyze_found),
        "expected one DartAnalyze action, got %s" % [a.mnemonic for a in all_actions],
    )
    analyze_paths = _input_paths(analyze_found[0] if analyze_found else None)
    _assert_some_path_contains(
        env,
        analyze_paths,
        [
            "dart-sdk/bin/snapshots/analysis_server",
            "dart-sdk/lib/core/",
        ],
        "DartAnalyze",
    )
    _assert_no_path_contains(
        env,
        analyze_paths,
        [
            "/patched-sdk/",
            "dart-sdk/bin/snapshots/dart2wasm",
            "dart-sdk/bin/utils/wasm-opt",
        ],
        "DartAnalyze",
    )
    return analysistest.end(env)

_flutter_test_runfiles_test = analysistest.make(_flutter_test_runfiles_test_impl)
_flutter_test_defines_fallback_test = analysistest.make(_flutter_test_defines_fallback_test_impl)
_application_opt_inputs_test = analysistest.make(
    _application_opt_inputs_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)
_application_dbg_inputs_test = analysistest.make(
    _application_dbg_inputs_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "dbg"},
)
_asset_bundle_inputs_test = analysistest.make(_asset_bundle_inputs_test_impl)
_aot_target_inputs_test = analysistest.make(
    _aot_target_inputs_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)
_kernel_target_modular_test = analysistest.make(_kernel_target_modular_test_impl)
_kernel_target_aot_test = analysistest.make(_kernel_target_aot_test_impl)
_web_inputs_test = analysistest.make(
    _web_inputs_test_impl,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)
_pub_runfiles_test = analysistest.make(_pub_runfiles_test_impl)
_dart_toolchain_inputs_test = analysistest.make(
    _dart_toolchain_inputs_test_impl,
    extra_target_under_test_aspects = [_inspect_analyze_actions_aspect],
)

def _setup_fixtures():
    flutter_test(
        name = "_inputs_flutter_test",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_test(
        name = "_inputs_flutter_test_defines",
        package_name = _PACKAGE,
        main = _MAIN,
        defines = ["FOO=1"],
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_application(
        name = "_inputs_application",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_asset_bundle(
        name = "_inputs_asset_bundle",
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_inputs_aot_target",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_inputs_kernel_target",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_kernel_target(
        name = "_inputs_kernel_target_aot",
        package_name = _PACKAGE,
        main = _MAIN,
        aot = True,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    flutter_web_bundle(
        name = "_inputs_web_bundle",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    dart_binary(
        name = "_inputs_dart_binary",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )

def action_inputs_test_suite(name):
    """Defines analysis tests for trimmed action inputs and test runfiles.

    Args:
        name: The test_suite target name.
    """
    _setup_fixtures()

    _flutter_test_runfiles_test(
        name = name + "_flutter_test_runfiles",
        target_under_test = ":_inputs_flutter_test",
    )
    _flutter_test_defines_fallback_test(
        name = name + "_flutter_test_defines_fallback",
        target_under_test = ":_inputs_flutter_test_defines",
    )
    _application_opt_inputs_test(
        name = name + "_application_opt",
        target_under_test = ":_inputs_application",
    )
    _application_dbg_inputs_test(
        name = name + "_application_dbg",
        target_under_test = ":_inputs_application",
    )
    _asset_bundle_inputs_test(
        name = name + "_asset_bundle",
        target_under_test = ":_inputs_asset_bundle",
    )
    _aot_target_inputs_test(
        name = name + "_aot_target",
        target_under_test = ":_inputs_aot_target",
    )
    _kernel_target_modular_test(
        name = name + "_kernel_target_modular",
        target_under_test = ":_inputs_kernel_target",
    )
    _kernel_target_aot_test(
        name = name + "_kernel_target_aot",
        target_under_test = ":_inputs_kernel_target_aot",
    )
    _web_inputs_test(
        name = name + "_web",
        target_under_test = ":_inputs_web_bundle",
    )
    _pub_runfiles_test(
        name = name + "_pub",
        target_under_test = "//flutter:pub",
    )
    _dart_toolchain_inputs_test(
        name = name + "_dart_toolchain",
        target_under_test = ":_inputs_dart_binary",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_flutter_test_runfiles",
            ":" + name + "_flutter_test_defines_fallback",
            ":" + name + "_application_opt",
            ":" + name + "_application_dbg",
            ":" + name + "_asset_bundle",
            ":" + name + "_aot_target",
            ":" + name + "_kernel_target_modular",
            ":" + name + "_kernel_target_aot",
            ":" + name + "_web",
            ":" + name + "_pub",
            ":" + name + "_dart_toolchain",
        ],
    )
