"""Unit tests for versions.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:artifact_urls.bzl",
    "android_engine_artifact_path",
    "desktop_engine_artifact_path",
    "gen_snapshot_cross_artifact_path",
    "ios_engine_artifact_path",
)
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS", "flutter_artifact_sha256")

def _latest_version_first_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.41.2", FLUTTER_VERSIONS.keys()[0])
    return unittest.end(env)

def _engine_revision_format_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(
            env,
            40,
            len(meta.engine_revision),
            "engine_revision for {} should be 40-char hex".format(version),
        )
    return unittest.end(env)

def _checksums_exist_for_all_versions_test_impl(ctx):
    env = unittest.begin(ctx)
    for version in FLUTTER_VERSIONS.keys():
        asserts.true(
            env,
            version in ARTIFACT_CHECKSUMS,
            "ARTIFACT_CHECKSUMS missing entry for version {}".format(version),
        )
    return unittest.end(env)

def _checksums_have_key_artifacts_test_impl(ctx):
    env = unittest.begin(ctx)
    required_artifacts = [
        # Patched SDKs
        "flutter_patched_sdk.zip",
        "flutter_patched_sdk_product.zip",
        # Dart SDK sources the analyzer resolves `dart:` URIs from
        "sky_engine.zip",
        # Host Dart SDKs
        "dart-sdk-darwin-arm64.zip",
        "dart-sdk-darwin-x64.zip",
        "dart-sdk-linux-x64.zip",
        "dart-sdk-linux-arm64.zip",
        "dart-sdk-windows-x64.zip",
        # Host tools (frontend_server, gen_snapshot, icudtl.dat)
        "darwin-arm64/artifacts.zip",
        "darwin-x64/artifacts.zip",
        "linux-x64/artifacts.zip",
        "linux-arm64/artifacts.zip",
        "windows-x64/artifacts.zip",
        # Flutter web SDK
        "flutter-web-sdk.zip",
        # Desktop engine runtime libraries (release mode)
        "darwin-x64-release/FlutterMacOS.framework.zip",
        "linux-x64-release/linux-x64-flutter-gtk.zip",
        "windows-x64-release/windows-x64-flutter.zip",
    ]
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for artifact in required_artifacts:
            asserts.true(
                env,
                artifact in checksums,
                "ARTIFACT_CHECKSUMS[{}] missing {}".format(version, artifact),
            )
    return unittest.end(env)

def _source_sha256_recorded_for_all_versions_test_impl(ctx):
    # Every fetch of the framework source tarball is pinned against this
    # field, so an entry without one cannot be built at all —
    # `flutter_source_sha256()` fails the extension. Asserted against the raw
    # struct rather than through the accessor so an omission surfaces as a
    # test failure naming the version, not as a load-time abort.
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(
            env,
            64,
            len(getattr(meta, "source_sha256", "")),
            "source_sha256 for {} should be 64-char hex (sha256)".format(version),
        )
    return unittest.end(env)

def _checksums_are_sha256_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, checksums in ARTIFACT_CHECKSUMS.items():
        for artifact, sha in checksums.items():
            asserts.equals(
                env,
                64,
                len(sha),
                "checksum for {}:{} should be 64-char hex (sha256)".format(version, artifact),
            )
    return unittest.end(env)

def _artifact_sha256_returns_recorded_value_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ARTIFACT_CHECKSUMS["3.47.5"]["linux-x64/artifacts.zip"],
        flutter_artifact_sha256("3.47.5", "linux-x64/artifacts.zip"),
    )
    return unittest.end(env)

def _android_and_cross_artifacts_have_checksums_test_impl(ctx):
    # The Android engine repos and the Android gen_snapshot cross repos fetch
    # these paths. Each one is looked up strictly, so a missing entry fails
    # the extension; this test catches it at unit-test time, with the version
    # named.
    env = unittest.begin(ctx)
    for version in FLUTTER_VERSIONS.keys():
        paths = [
            android_engine_artifact_path("arm64", "release"),
            android_engine_artifact_path("arm64", "debug"),
            android_engine_artifact_path("x64", "release"),
            android_engine_artifact_path("x64", "debug"),
            ios_engine_artifact_path("release"),
            ios_engine_artifact_path("debug"),
            desktop_engine_artifact_path("linux", "arm64", "release"),
            desktop_engine_artifact_path("linux", "arm64", "debug"),
        ]
        for arch in ["arm64", "x64"]:
            for host in ["darwin-x64", "linux-x64", "windows-x64"]:
                paths.append(gen_snapshot_cross_artifact_path("android-" + arch, "release", host))
        for path in paths:
            asserts.true(
                env,
                path in ARTIFACT_CHECKSUMS[version],
                "ARTIFACT_CHECKSUMS[{}] missing {}".format(version, path),
            )

            # Also goes through the strict accessor, which fails if empty.
            flutter_artifact_sha256(version, path)
    return unittest.end(env)

_t0_test = unittest.make(_latest_version_first_test_impl)
_t1_test = unittest.make(_engine_revision_format_test_impl)
_t2_test = unittest.make(_checksums_exist_for_all_versions_test_impl)
_t3_test = unittest.make(_checksums_have_key_artifacts_test_impl)
_t4_test = unittest.make(_checksums_are_sha256_test_impl)
_t5_test = unittest.make(_source_sha256_recorded_for_all_versions_test_impl)
_t6_test = unittest.make(_artifact_sha256_returns_recorded_value_test_impl)
_t7_test = unittest.make(_android_and_cross_artifacts_have_checksums_test_impl)

def versions_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test)
