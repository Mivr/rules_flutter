"""Unit tests for the `Package.swift` manifest parser."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")

_BIGINT = """// swift-tools-version:6.0
//
//  Package.swift
//  BigInt
//

import PackageDescription

let package = Package(
    name: "BigInt",
    platforms: [
        .macOS(.v10_13),
        .iOS(.v12),
        .tvOS(.v12),
        .watchOS(.v4),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "BigInt", targets: ["BigInt"])
    ],
    targets: [
        .target(
            name: "BigInt", path: "Sources"),
        .testTarget(
            name: "BigIntTests", dependencies: ["BigInt"], path: "Tests"),
    ]
)
"""

_KITCHEN_SINK = """// swift-tools-version: 5.9
/* A block comment spanning
   two lines. */
import PackageDescription // trailing comment

let package = Package(
    name: "KitchenSink",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "KitchenSink", targets: ["KitchenSink", "Helper"], type: .dynamic),
        .executable(name: "tool", targets: ["tool"]),
        .plugin(name: "plug", targets: ["plug"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(id: "tool-registry-id", exact: "2.0.0"),
        .package(name: "Local", path: "../Local"),
        .package(name: "Named", url: "https://example.com/other/RealName.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "KitchenSink",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"), "Helper", .target(name: "Helper2"), .byName(name: "Helper3")],
            exclude: ["skip"],
            sources: ["main"],
        ),
        .target(name: "Helper"),
        .target(name: "Helper2", path: "Custom"),
        .target(name: "Helper3"),
        .executableTarget(name: "tool"),
        .testTarget(name: "KitchenSinkTests", dependencies: ["KitchenSink"]),
        .binaryTarget(name: "Blob", url: "https://example.com/blob.zip", checksum: "abc"),
        .systemLibrary(name: "Sys"),
        .plugin(name: "plug", capability: .buildTool()),
        .macro(name: "Mac"),
    ],
    swiftLanguageModes: [.v5],
    cLanguageStandard: .c11,
    cxxLanguageStandard: "c++17",
)
"""

def _parses_the_bigint_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 6, parsed.model.tools_major)
    asserts.equals(env, 0, parsed.model.tools_minor)
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, "BigInt", parsed.model.products[0].name)
    asserts.equals(env, ["BigInt"], parsed.model.products[0].targets)
    asserts.equals(env, 2, len(parsed.model.targets))
    asserts.equals(env, "Sources", parsed.model.targets[0].path)
    asserts.equals(env, "testTarget", parsed.model.targets[1].kind)
    asserts.equals(env, [], parsed.model.pkg_deps)
    asserts.equals(env, [], parsed.model.modes)
    return unittest.end(env)

def _parses_every_supported_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("kitchensink", _KITCHEN_SINK)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 5, parsed.model.tools_major)
    asserts.equals(env, 9, parsed.model.tools_minor)

    # Only the `.library` product survives; executables and plugins drop.
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, ["KitchenSink", "Helper"], parsed.model.products[0].targets)

    asserts.equals(env, 4, len(parsed.model.pkg_deps))
    asserts.equals(env, "https://github.com/apple/swift-argument-parser", parsed.model.pkg_deps[0].ref)
    asserts.equals(env, "url", parsed.model.pkg_deps[0].ref_kind)
    asserts.equals(env, "tool-registry-id", parsed.model.pkg_deps[1].ref)
    asserts.equals(env, "id", parsed.model.pkg_deps[1].ref_kind)
    asserts.equals(env, "Local", parsed.model.pkg_deps[2].name)
    asserts.equals(env, "path", parsed.model.pkg_deps[2].ref_kind)
    asserts.equals(env, "Named", parsed.model.pkg_deps[3].name)

    asserts.equals(env, 1, len(parsed.model.modes))
    asserts.equals(env, 5, parsed.model.modes[0].major)
    asserts.equals(env, 0, parsed.model.modes[0].minor)

    main = parsed.model.targets[0]
    asserts.equals(env, 4, len(main.deps))
    asserts.equals(env, "product", main.deps[0].kind)
    asserts.equals(env, "ArgumentParser", main.deps[0].name)
    asserts.equals(env, "swift-argument-parser", main.deps[0].package)
    asserts.equals(env, "same", main.deps[1].kind)
    asserts.equals(env, "Helper", main.deps[1].name)
    asserts.equals(env, "same", main.deps[2].kind)
    asserts.equals(env, "Helper2", main.deps[2].name)
    asserts.equals(env, ["skip"], main.exclude)
    asserts.equals(env, ["main"], main.sources)

    # Special kinds keep their kind and name for the translator's refusal.
    by_kind = {target.name: target.kind for target in parsed.model.targets}
    asserts.equals(env, "binaryTarget", by_kind["Blob"])
    asserts.equals(env, "systemLibrary", by_kind["Sys"])
    asserts.equals(env, "plugin", by_kind["plug"])
    asserts.equals(env, "macro", by_kind["Mac"])
    return unittest.end(env)

def _refusal_names_identity_file_and_line_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", "let package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, parsed.error.startswith("SwiftPM package \"bigint\" (Package.swift line 1):"))
    return unittest.end(env)

def _tools_line_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", "import PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, "swift-tools-version" in parsed.error)
    parsed = parse_swiftpm_package("bigint", "// swift-tools-version:3.1\nimport PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    asserts.true(env, "older than the supported 4.0" in parsed.error)
    parsed = parse_swiftpm_package("bigint", "// swift-tools-version:abc\nimport PackageDescription\nlet package = Package(name: \"x\")\n")
    asserts.true(env, not parsed.ok)
    return unittest.end(env)

def _statement_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        ("// swift-tools-version:5.9\n#if os(macOS)\nlet package = Package(name: \"x\")\n#endif\n", "conditional compilation"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"\\(x)\")\n", "interpolation"),
        ("// swift-tools-version:5.9\nimport Foundation\n", "only `import PackageDescription`"),
        ("// swift-tools-version:5.9\nlet other = 1\n", "not supported"),
        ("// swift-tools-version:5.9\nvar package = Package(name: \"x\")\npackage.targets = []\n", "must not be mutated"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\")\nlet package = Package(name: \"y\")\n", "duplicate `let package`"),
        ("// swift-tools-version:5.9\nimport PackageDescription\n", "no `let package"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", bogus: 1)\n", "unknown `Package(...)` argument `bogus`"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\")])\n", "needs `name:` and `targets:`"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.weird(name: \"a\")])\n", "unknown product kind"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", targets: [.target(name: \"a\", resources: [])])\n", "no Bazel translation"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", targets: [.weird(name: \"a\")])\n", "unknown target kind"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\", targets: [\"a\"]), .library(name: \"a\", targets: [\"a\"])], targets: [.target(name: \"a\")])\n", "duplicate product"),
        ("// swift-tools-version:5.9\nlet package = Package(name: \"x\", products: [.library(name: \"a\", targets: [\"a\"])], targets: [.target(name: \"a\"), .target(name: \"a\")])\n", "duplicate target"),
    ]
    for case in cases:
        parsed = parse_swiftpm_package("pkg", case[0])
        asserts.true(env, not parsed.ok)
        asserts.true(env, case[1] in parsed.error)
    return unittest.end(env)

_PLUGIN_TEMPLATE = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ios_greeting",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "ios-greeting", targets: ["ios_greeting"])
    ],
    targets: [
        .target(name: "ios_greeting", path: "Classes")
    ],
    swiftLanguageVersions: [.v5]
)
"""

def _parses_a_plugin_template_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("ios-greeting", _PLUGIN_TEMPLATE)
    asserts.true(env, parsed.ok)
    asserts.equals(env, "", parsed.error)
    asserts.equals(env, 1, len(parsed.model.products))
    asserts.equals(env, "ios-greeting", parsed.model.products[0].name)
    asserts.equals(env, ["ios_greeting"], parsed.model.products[0].targets)
    asserts.equals(env, 1, len(parsed.model.targets))
    asserts.equals(env, "target", parsed.model.targets[0].kind)
    asserts.equals(env, "ios_greeting", parsed.model.targets[0].name)
    asserts.equals(env, "Classes", parsed.model.targets[0].path)
    asserts.equals(env, [], parsed.model.pkg_deps)
    return unittest.end(env)

_parses_the_bigint_manifest_test = unittest.make(_parses_the_bigint_manifest_test_impl)
_parses_every_supported_shape_test = unittest.make(_parses_every_supported_shape_test_impl)
_parses_a_plugin_template_manifest_test = unittest.make(_parses_a_plugin_template_manifest_test_impl)
_refusal_names_identity_file_and_line_test = unittest.make(_refusal_names_identity_file_and_line_test_impl)
_tools_line_refusals_test = unittest.make(_tools_line_refusals_test_impl)
_statement_refusals_test = unittest.make(_statement_refusals_test_impl)

def swiftpm_manifest_test_suite(name):
    """Registers the `Package.swift` parser unit tests."""
    unittest.suite(
        name + "_unit",
        _parses_the_bigint_manifest_test,
        _parses_every_supported_shape_test,
        _parses_a_plugin_template_manifest_test,
        _parses_condition_arguments_test,
        _condition_refusals_test,
        _refusal_names_identity_file_and_line_test,
        _tools_line_refusals_test,
        _statement_refusals_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )

_CONDITIONED = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Cond",
    products: [.library(name: "Cond", targets: ["Cond"])],
    dependencies: [.package(url: "https://example.com/Dep.git", from: "1.0.0")],
    targets: [.target(name: "Cond", dependencies: [.product(name: "Dp", package: "Dep", condition: .when(platforms: [.iOS, .macOS])), .target(name: "Help", condition: .when(platforms: [.iOS])), "Plain"])],
)
"""

def _parses_condition_arguments_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("cond", _CONDITIONED)
    asserts.true(env, parsed.ok)
    deps = parsed.model.targets[0].deps
    asserts.equals(env, 3, len(deps))
    asserts.equals(env, ["ios", "macos"], deps[0].condition.platforms)
    asserts.equals(env, ["ios"], deps[1].condition.platforms)
    asserts.equals(env, None, deps[2].condition)
    return unittest.end(env)

def _condition_refusals_test_impl(ctx):
    env = unittest.begin(ctx)
    cases = [
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(platforms: [.watchOS]))])", "unsupported condition platform"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: .when(traits: [\"Trait\"]))])", "only `.when(platforms: [...])`"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", condition: \"ios\")])", "expected a build condition"),
        (".target(name: \"C\", dependencies: [.product(name: \"Dp\", package: \"Dep\", extra: 1)])", "unknown `.product(...)` argument"),
    ]
    for target_decl, detail in cases:
        manifest = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Cond\", products: [.library(name: \"Cond\", targets: [\"C\"])], dependencies: [.package(url: \"https://example.com/Dep.git\", from: \"1.0.0\")], targets: [" + target_decl + "])\n"
        parsed = parse_swiftpm_package("cond", manifest)
        asserts.true(env, not parsed.ok)
        asserts.true(env, detail in parsed.error)
    return unittest.end(env)

_parses_condition_arguments_test = unittest.make(_parses_condition_arguments_test_impl)
_condition_refusals_test = unittest.make(_condition_refusals_test_impl)
