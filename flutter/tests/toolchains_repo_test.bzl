"""Unit tests for toolchains_repo.bzl — DESKTOP_CROSS_PAIRS and CROSS_COMPILATION_PAIRS validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:toolchains_repo.bzl", "CROSS_COMPILATION_PAIRS", "DESKTOP_CROSS_PAIRS", "HOST_PLATFORMS", "TARGET_PLATFORMS")
load("//flutter/private:xtool_darwin_sdk_repo.bzl", "FlutterXtoolSdkInfo", "XTOOL_DARWIN_TARGETS", "generate_xtool_darwin_sdk_build", "resolve_darwin_artifactbundle_sdk_paths")

def _desktop_cross_pairs_keys_are_host_platforms_test_impl(ctx):
    """Every key in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host in DESKTOP_CROSS_PAIRS.keys():
        asserts.true(
            env,
            host in HOST_PLATFORMS,
            "DESKTOP_CROSS_PAIRS key '{}' is not in HOST_PLATFORMS".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_targets_are_host_platforms_test_impl(ctx):
    """Every target in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        for target in targets:
            asserts.true(
                env,
                target in HOST_PLATFORMS,
                "DESKTOP_CROSS_PAIRS[{}] target '{}' is not in HOST_PLATFORMS".format(host, target),
            )
    return unittest.end(env)

def _desktop_cross_pairs_no_self_pairs_test_impl(ctx):
    """No host should target itself in DESKTOP_CROSS_PAIRS."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        asserts.true(
            env,
            host not in targets,
            "DESKTOP_CROSS_PAIRS[{}] contains self-pair".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_no_same_os_test_impl(ctx):
    """No host should target a platform with the same OS (e.g. darwin-arm64 → darwin-x64)."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        host_os = HOST_PLATFORMS[host].os
        for target in targets:
            target_os = HOST_PLATFORMS[target].os
            asserts.true(
                env,
                host_os != target_os,
                "DESKTOP_CROSS_PAIRS[{}] targets same-OS platform '{}' (both {})".format(host, target, host_os),
            )
    return unittest.end(env)

def _desktop_cross_pairs_all_hosts_covered_test_impl(ctx):
    """Every HOST_PLATFORMS entry should have a DESKTOP_CROSS_PAIRS entry."""
    env = unittest.begin(ctx)
    for host in HOST_PLATFORMS.keys():
        asserts.true(
            env,
            host in DESKTOP_CROSS_PAIRS,
            "HOST_PLATFORMS key '{}' missing from DESKTOP_CROSS_PAIRS".format(host),
        )
    return unittest.end(env)

def _cross_compilation_pairs_valid_test_impl(ctx):
    """Every (host, target) in CROSS_COMPILATION_PAIRS must reference valid platforms, and Linux hosts target iOS and macOS."""
    env = unittest.begin(ctx)
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        asserts.true(
            env,
            host in HOST_PLATFORMS,
            "CROSS_COMPILATION_PAIRS key '{}' is not in HOST_PLATFORMS".format(host),
        )
        for target in targets:
            asserts.true(
                env,
                target in TARGET_PLATFORMS,
                "CROSS_COMPILATION_PAIRS[{}] target '{}' is not in TARGET_PLATFORMS".format(host, target),
            )
    for linux_host in ("linux-x64", "linux-arm64"):
        asserts.true(
            env,
            "ios-arm64" in CROSS_COMPILATION_PAIRS[linux_host],
            "{} must support ios-arm64 in CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "ios-x64" in CROSS_COMPILATION_PAIRS[linux_host],
            "{} must support ios-x64 in CROSS_COMPILATION_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "darwin-arm64" in DESKTOP_CROSS_PAIRS[linux_host],
            "{} must support darwin-arm64 in DESKTOP_CROSS_PAIRS".format(linux_host),
        )
        asserts.true(
            env,
            "darwin-x64" in DESKTOP_CROSS_PAIRS[linux_host],
            "{} must support darwin-x64 in DESKTOP_CROSS_PAIRS".format(linux_host),
        )
    return unittest.end(env)

def _xtool_darwin_sdk_build_test_impl(ctx):
    """generate_xtool_darwin_sdk_build emits all 5 Darwin targets in both configured and stub modes."""
    env = unittest.begin(ctx)
    expected_triples = {
        "ios_arm64": "arm64-apple-ios14.0",
        "ios_sim_arm64": "arm64-apple-ios14.0-simulator",
        "ios_x64": "x86_64-apple-ios14.0-simulator",
        "macos_arm64": "arm64-apple-macosx11.0",
        "macos_x64": "x86_64-apple-macosx11.0",
    }
    for key, triple in expected_triples.items():
        asserts.true(env, key in XTOOL_DARWIN_TARGETS, "Missing target key %s" % key)
        asserts.equals(env, triple, XTOOL_DARWIN_TARGETS[key].triple)

    stub_build = generate_xtool_darwin_sdk_build(sdk_available = False)
    asserts.true(env, "SDK_AVAILABLE = False" in stub_build, "Expected SDK_AVAILABLE = False in stub build")
    for key in expected_triples.keys():
        asserts.true(
            env,
            'name = "%s_cc_toolchain"' % key in stub_build,
            "Expected %s_cc_toolchain in stub build" % key,
        )

    configured_build = generate_xtool_darwin_sdk_build(
        sdk_available = True,
        sdk_paths = {
            "iPhoneOS": "/xtool/iPhoneOS.sdk",
            "iPhoneSimulator": "/xtool/iPhoneSimulator.sdk",
            "MacOSX": "/xtool/MacOSX.sdk",
        },
        swift_bin_dir = "/opt/swift/usr/bin",
    )
    asserts.true(env, "SDK_AVAILABLE = True" in configured_build, "Expected SDK_AVAILABLE = True")
    asserts.true(env, "/xtool/iPhoneOS.sdk" in configured_build, "Expected iPhoneOS.sdk path")
    asserts.true(env, "/xtool/MacOSX.sdk" in configured_build, "Expected MacOSX.sdk path")
    asserts.true(env, "xtool_darwin_sdk_status(" in configured_build, "Expected xtool_darwin_sdk_status target")

    info_json = json.encode({
        "schemaVersion": "1.0",
        "artifacts": {
            "iphoneos": {
                "type": "sdk",
                "variants": [{"path": "iPhoneOS17.4.sdk"}],
            },
            "iphonesimulator": {
                "type": "sdk",
                "variants": [{"path": "iPhoneSimulator17.4.sdk"}],
            },
            "macosx": {
                "type": "sdk",
                "variants": [{"path": "MacOSX14.4.sdk"}],
            },
        },
    })
    resolved_paths = resolve_darwin_artifactbundle_sdk_paths(info_json, "/opt/darwin.artifactbundle")
    asserts.equals(env, "/opt/darwin.artifactbundle/iPhoneOS17.4.sdk", resolved_paths["iPhoneOS"])
    asserts.equals(env, "/opt/darwin.artifactbundle/iPhoneSimulator17.4.sdk", resolved_paths["iPhoneSimulator"])
    asserts.equals(env, "/opt/darwin.artifactbundle/MacOSX14.4.sdk", resolved_paths["MacOSX"])
    return unittest.end(env)

_BackendProbeInfo = provider(fields = ["backend"])

def _backend_probe_impl(ctx):
    return [_BackendProbeInfo(backend = ctx.attr.selected_backend)]

_backend_probe = rule(
    implementation = _backend_probe_impl,
    attrs = {
        "selected_backend": attr.string(mandatory = True),
    },
)

def _apple_backend_xtool_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.equals(env, "xtool", tut[_BackendProbeInfo].backend)
    return analysistest.end(env)

_apple_backend_xtool_test = analysistest.make(
    _apple_backend_xtool_test_impl,
    config_settings = {
        str(Label("//flutter/settings:apple_backend")): "xtool",
    },
)

def _apple_backend_rules_apple_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.equals(env, "rules_apple", tut[_BackendProbeInfo].backend)
    return analysistest.end(env)

_apple_backend_rules_apple_test = analysistest.make(
    _apple_backend_rules_apple_test_impl,
    config_settings = {
        str(Label("//flutter/settings:apple_backend")): "rules_apple",
    },
)

_t0_test = unittest.make(_desktop_cross_pairs_keys_are_host_platforms_test_impl)
_t1_test = unittest.make(_desktop_cross_pairs_targets_are_host_platforms_test_impl)
_t2_test = unittest.make(_desktop_cross_pairs_no_self_pairs_test_impl)
_t3_test = unittest.make(_desktop_cross_pairs_no_same_os_test_impl)
_t4_test = unittest.make(_desktop_cross_pairs_all_hosts_covered_test_impl)
_t5_test = unittest.make(_cross_compilation_pairs_valid_test_impl)
_t6_test = unittest.make(_xtool_darwin_sdk_build_test_impl)

def toolchains_repo_test_suite(name):
    _backend_probe(
        name = name + "_backend_probe",
        selected_backend = select({
            "//flutter/settings:use_xtool_backend": "xtool",
            "//conditions:default": "rules_apple",
        }),
        tags = ["manual"],
    )
    _apple_backend_xtool_test(
        name = name + "_apple_backend_xtool",
        target_under_test = ":" + name + "_backend_probe",
    )
    _apple_backend_rules_apple_test(
        name = name + "_apple_backend_rules_apple",
        target_under_test = ":" + name + "_backend_probe",
    )
    build_test(
        name = name + "_xtool_sdk_status_build",
        targets = [
            "@flutter_xtool_darwin_sdk//:sdk_status",
            "@flutter_xtool_darwin_sdk//:sdk_files",
            "@flutter_xtool_darwin_sdk//:ios_arm64_cc_toolchain_config",
            "@flutter_xtool_darwin_sdk//:macos_arm64_cc_toolchain_config",
        ],
    )
    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_apple_backend_xtool",
            ":" + name + "_apple_backend_rules_apple",
            ":" + name + "_xtool_sdk_status_build",
        ],
    )
