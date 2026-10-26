"""Unit tests for the pub plugin spoke's SwiftPM product links."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "select_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)

_BIGINT_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],
    targets: [.target(name: "spm_bigint_plugin", dependencies: ["Helper", .target(name: "Other"), .product(name: "BigInt", package: "BigInt")])],
)
"""

_CONDITIONED_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
        .package(url: "https://example.com/MacOnly.git", exact: "1.0.0"),
    ],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "BigInt", package: "BigInt", condition: .when(platforms: [.iOS])), .product(name: "MacOnly", package: "MacOnly", condition: .when(platforms: [.macOS]))])],
)
"""

_FRAMEWORK_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
    ],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework"), .product(name: "BigInt", package: "BigInt")])],
)
"""

_TEMPLATE_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "spm_bigint_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: [.define("SPM_TEST")],
        ),
    ],
)
"""

_TEMPLATE_BIGINT_MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_bigint_plugin",
    platforms: [.iOS("12.0")],
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),
    ],
    targets: [
        .target(
            name: "spm_bigint_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework"), .product(name: "BigInt", package: "BigInt")],
            resources: [.process("Resources")],
            swiftSettings: [.define("SPM_TEST")],
        ),
    ],
)
"""

def _pins(pinned = ["bigint"], unpinned = {}, resolved = "//:Package.resolved"):
    return struct(resolved = resolved, pinned = pinned, unpinned = unpinned, hub = "deps")

def _products_resolve_to_pinned_labels_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _conditions_filter_per_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    ios = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _CONDITIONED_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = ["bigint", "maconly"]),
    )
    asserts.true(env, ios.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], ios.labels)
    macos = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _CONDITIONED_MANIFEST,
        "macos/spm_bigint_plugin",
        ["macos/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "macos",
        _pins(pinned = ["bigint", "maconly"]),
    )
    asserts.true(env, macos.ok)
    asserts.equals(env, ["@deps__swiftpm-maconly//:MacOnly"], macos.labels)
    return unittest.end(env)

def _flutterframework_product_is_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _FRAMEWORK_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _template_manifest_builds_without_link_test_impl(ctx):
    env = unittest.begin(ctx)
    with_resolved = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, with_resolved.ok)
    asserts.equals(env, [], with_resolved.labels)
    without_resolved = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, without_resolved.ok)
    asserts.equals(env, [], without_resolved.labels)
    return unittest.end(env)

def _real_world_manifest_settings_still_link_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BIGINT_MANIFEST.replace(
        'let package = Package(\n    name: "spm_bigint_plugin",',
        'let package = Package(\n    name: "spm_bigint_plugin",\n    defaultLocalization: "en",',
    ).replace(
        '.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")',
        '.package(url: "https://github.com/attaswift/BigInt.git", "6.0.0"..<"7.0.0")',
    ).replace(
        '.target(name: "spm_bigint_plugin", dependencies:',
        '.target(name: "spm_bigint_plugin", publicHeadersPath: "include", packageAccess: false, dependencies:',
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], selected.labels)
    return unittest.end(env)

def _template_settings_leave_links_unchanged_test_impl(ctx):
    env = unittest.begin(ctx)
    with_settings = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, with_settings.ok)
    asserts.equals(env, ["@deps__swiftpm-bigint//:BigInt"], with_settings.labels)
    without_settings = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _FRAMEWORK_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, without_settings.ok)
    asserts.equals(env, with_settings.labels, without_settings.labels)
    return unittest.end(env)

def _flutterframework_first_names_real_package_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _TEMPLATE_BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "ios/spm_bigint_plugin/Package.swift" in selected.error)
    asserts.true(env, "BigInt" in selected.error)
    asserts.true(env, "FlutterFramework" not in selected.error)
    return unittest.end(env)

def _conditional_dependencies_still_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    conditional = _BIGINT_MANIFEST.replace(
        'dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")]',
        'dependencies: [\n        #if os(iOS)\n        .package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1"),\n        #endif\n    ]',
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        conditional,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Package.swift" in selected.error)

    variable = _BIGINT_MANIFEST.replace(
        'url: "https://github.com/attaswift/BigInt.git"',
        "url: bigIntUrl",
    )
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        variable,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Package.swift" in selected.error)
    return unittest.end(env)

def _undeclared_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = _BIGINT_MANIFEST.replace('package: "BigInt"', 'package: "Missing"')
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Missing" in selected.error)
    return unittest.end(env)

def _path_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "spm_bigint_plugin",
    products: [.library(name: "spm_bigint_plugin", targets: ["spm_bigint_plugin"])],
    dependencies: [.package(name: "Local", path: "../Local")],
    targets: [.target(name: "spm_bigint_plugin", dependencies: [.product(name: "L", package: "Local")])],
)
"""
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        manifest,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "Local" in selected.error)
    return unittest.end(env)

def _unpinned_package_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(pinned = []),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "bigint" in selected.error)
    asserts.true(env, "Package.resolved" in selected.error)
    return unittest.end(env)

def _unfetchable_pin_reports_its_reason_test_impl(ctx):
    env = unittest.begin(ctx)
    reason = "deps__swiftpm-bigint: SwiftPM package \"bigint\" cannot be fetched: test reason."
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(unpinned = {"bigint": reason}),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, reason in selected.error)
    return unittest.end(env)

def _missing_resolved_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(resolved = ""),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    asserts.true(env, "bigint" in selected.error)
    asserts.true(env, "swift_package_resolved" in selected.error)
    return unittest.end(env)

def _unreadable_manifest_without_packages_builds_on_test_impl(ctx):
    env = unittest.begin(ctx)
    broken = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(\n"
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        broken,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)

    broken_packages = broken.replace("Package(", "Package(name: \"p\", dependencies: [.package(")
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        broken_packages,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, not selected.ok)
    asserts.true(env, "spm_bigint_plugin" in selected.error)
    return unittest.end(env)

def _manifests_without_links_resolve_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    nodeps = _BIGINT_MANIFEST.replace('    dependencies: [.package(url: "https://github.com/attaswift/BigInt.git", exact: "6.0.1")],\n', "").replace(', dependencies: ["Helper", .target(name: "Other"), .product(name: "BigInt", package: "BigInt")]', "")
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        nodeps,
        "ios/spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)

    # The manifest's target builds nothing the spoke emits.
    selected = select_apple_swiftpm_deps(
        "spm_bigint_plugin",
        _BIGINT_MANIFEST,
        "ios/spm_bigint_plugin",
        ["ios/other/Sources/other"],
        "ios",
        _pins(),
    )
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.labels)
    return unittest.end(env)

def _deps_render_on_both_backends_test_impl(ctx):
    env = unittest.begin(ctx)
    content = apple_plugin_targets(
        "spm_bigint_plugin",
        ["ios/spm_bigint_plugin/Sources/spm_bigint_plugin"],
        [],
        "ios",
    )
    asserts.equals(env, content, with_apple_swiftpm_deps(content, "spm_bigint_plugin", [], []))
    patched = with_apple_swiftpm_deps(content, "spm_bigint_plugin", [], ["@deps__swiftpm-bigint//:BigInt"])
    asserts.true(env, patched != content)
    asserts.equals(env, 2, len(patched.split("@deps__swiftpm-bigint//:BigInt")) - 1)
    asserts.equals(env, 2, len(patched.split("    deps = [\n")) - 1)
    asserts.equals(env, 2, len(patched.split("    visibility = [")) - 1)
    return unittest.end(env)

_products_resolve_to_pinned_labels_test = unittest.make(_products_resolve_to_pinned_labels_test_impl)
_conditions_filter_per_platform_test = unittest.make(_conditions_filter_per_platform_test_impl)
_flutterframework_product_is_skipped_test = unittest.make(_flutterframework_product_is_skipped_test_impl)
_template_manifest_builds_without_link_test = unittest.make(_template_manifest_builds_without_link_test_impl)
_real_world_manifest_settings_still_link_test = unittest.make(_real_world_manifest_settings_still_link_test_impl)
_template_settings_leave_links_unchanged_test = unittest.make(_template_settings_leave_links_unchanged_test_impl)
_flutterframework_first_names_real_package_test = unittest.make(_flutterframework_first_names_real_package_test_impl)
_conditional_dependencies_still_refused_test = unittest.make(_conditional_dependencies_still_refused_test_impl)
_undeclared_package_fails_test = unittest.make(_undeclared_package_fails_test_impl)
_path_package_fails_test = unittest.make(_path_package_fails_test_impl)
_unpinned_package_fails_test = unittest.make(_unpinned_package_fails_test_impl)
_unfetchable_pin_reports_its_reason_test = unittest.make(_unfetchable_pin_reports_its_reason_test_impl)
_missing_resolved_fails_test = unittest.make(_missing_resolved_fails_test_impl)
_unreadable_manifest_without_packages_builds_on_test = unittest.make(_unreadable_manifest_without_packages_builds_on_test_impl)
_manifests_without_links_resolve_empty_test = unittest.make(_manifests_without_links_resolve_empty_test_impl)
_deps_render_on_both_backends_test = unittest.make(_deps_render_on_both_backends_test_impl)

def flutter_pub_apple_test_suite(name):
    """Registers the Apple plugin spoke SwiftPM link unit tests."""
    unittest.suite(
        name + "_unit",
        _products_resolve_to_pinned_labels_test,
        _conditions_filter_per_platform_test,
        _flutterframework_product_is_skipped_test,
        _template_manifest_builds_without_link_test,
        _real_world_manifest_settings_still_link_test,
        _template_settings_leave_links_unchanged_test,
        _flutterframework_first_names_real_package_test,
        _conditional_dependencies_still_refused_test,
        _undeclared_package_fails_test,
        _path_package_fails_test,
        _unpinned_package_fails_test,
        _unfetchable_pin_reports_its_reason_test,
        _missing_resolved_fails_test,
        _unreadable_manifest_without_packages_builds_on_test,
        _manifests_without_links_resolve_empty_test,
        _deps_render_on_both_backends_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
