"""Unit tests for the manifest-to-BUILD translator."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")
load(
    "//flutter/private:swiftpm_translate.bzl",
    "swiftpm_c99name",
    "swiftpm_language_mode",
    "swiftpm_url_identity",
    "translate_swiftpm_package",
)

_BIGINT = """// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "BigInt",
    products: [.library(name: "BigInt", targets: ["BigInt"])],
    targets: [
        .target(name: "BigInt", path: "Sources"),
        .testTarget(name: "BigIntTests", dependencies: ["BigInt"], path: "Tests"),
    ]
)
"""

_MULTI = """// swift-tools-version:5.8
import PackageDescription
let package = Package(
    name: "Multi",
    products: [.library(name: "Everything", targets: ["One", "Two"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(name: "Named", url: "https://example.com/other/RealName.git", branch: "main"),
    ],
    targets: [
        .target(name: "One", dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser"), .product(name: "Thing", package: "Named")]),
        .target(name: "Two", dependencies: ["One"]),
    ],
    swiftLanguageVersions: [.v5],
)
"""

def _bigint_files(name):
    return struct(dir = "BigInt-1/Sources", srcs = ["BigInt-1/Sources/" + name + ".swift"])

def _c99name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "BigInt", swiftpm_c99name("BigInt"))
    asserts.equals(env, "my_pkg_1", swiftpm_c99name("my-pkg.1"))
    asserts.equals(env, "a_b", swiftpm_c99name("a b"))
    return unittest.end(env)

def _language_mode_test_impl(ctx):
    env = unittest.begin(ctx)
    mode = swiftpm_language_mode(6, 0, [])
    asserts.equals(env, (6, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(5, 9, [])
    asserts.equals(env, (5, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(4, 2, [])
    asserts.equals(env, (4, 2), (mode.major, mode.minor))
    mode = swiftpm_language_mode(6, 0, [struct(major = 5, minor = 0), struct(major = 6, minor = 0)])
    asserts.equals(env, (6, 0), (mode.major, mode.minor))
    mode = swiftpm_language_mode(5, 9, [struct(major = 4, minor = 2)])
    asserts.equals(env, (4, 2), (mode.major, mode.minor))
    asserts.equals(env, "swift-argument-parser", swiftpm_url_identity("https://github.com/apple/swift-argument-parser"))
    asserts.equals(env, "BigInt", swiftpm_url_identity("https://github.com/attaswift/BigInt.git"))
    return unittest.end(env)

def _translates_bigint_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("bigint", "deps", parsed.model, ["bigint"], {"BigInt": _bigint_files("BigInt")})
    asserts.true(env, translated.ok)
    asserts.equals(env, "", translated.error)
    asserts.equals(env, ["BigInt"], translated.names)
    asserts.true(env, "load(\"@rules_swift//swift:swift.bzl\", \"swift_library\", \"swift_library_group\")" in translated.text)
    asserts.true(env, "name = \"BigInt_lib\"" in translated.text)
    asserts.true(env, "module_name = \"BigInt\"" in translated.text)
    asserts.true(env, "package_name = \"bigint\"" in translated.text)
    asserts.true(env, "\"-swift-version\", \"6\"" in translated.text)
    asserts.true(env, "\"BigInt-1/Sources/BigInt.swift\"" in translated.text)
    asserts.true(env, "name = \"BigInt\",\n    actual = \":BigInt_lib\"" in translated.text)
    asserts.true(env, not "BigIntTests" in translated.text)
    return unittest.end(env)

def _translates_groups_and_product_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI)
    asserts.true(env, parsed.ok)
    files = {
        "One": struct(dir = "pkg/Sources/One", srcs = ["pkg/Sources/One/a.swift"]),
        "Two": struct(dir = "pkg/Sources/Two", srcs = ["pkg/Sources/Two/b.swift"]),
    }
    translated = translate_swiftpm_package("multi", "deps", parsed.model, ["multi", "swift-argument-parser", "RealName"], files)
    asserts.true(env, translated.ok)
    asserts.equals(env, ["One", "Two"], translated.names)
    asserts.true(env, "swift_library_group(\n    name = \"Everything\"" in translated.text)
    asserts.true(env, "\":One_lib\"" in translated.text)
    asserts.true(env, "\":Two_lib\"" in translated.text)
    asserts.true(env, "\"@deps__swiftpm-swift-argument-parser//:ArgumentParser\"" in translated.text)
    asserts.true(env, "\"@deps__swiftpm-RealName//:Thing\"" in translated.text)
    asserts.true(env, "\":One_lib\"" in translated.text)
    asserts.true(env, "\"-swift-version\", \"5\"" in translated.text)
    asserts.true(env, not "package_name" in translated.text)
    return unittest.end(env)

def _unpinned_product_dep_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("multi", _MULTI)
    translated = translate_swiftpm_package("multi", "deps", parsed.model, ["multi"], {
        "One": struct(dir = "d", srcs = ["d/a.swift"]),
        "Two": struct(dir = "d", srcs = ["d/b.swift"]),
    })
    asserts.true(env, not translated.ok)
    asserts.true(env, "not pinned in Package.resolved" in translated.error)
    asserts.true(env, "swift-argument-parser" in translated.error)
    return unittest.end(env)

def _special_target_refusal_points_at_overrides_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Blobby",
    products: [.library(name: "Blobby", targets: ["Blobby", "Blob"])],
    targets: [.target(name: "Blobby"), .binaryTarget(name: "Blob", url: "https://example.com/b.zip", checksum: "abc")],
)
"""
    parsed = parse_swiftpm_package("blobby", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("blobby", "deps", parsed.model, ["blobby"], {"Blobby": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "binary target" in translated.error)
    asserts.true(env, "swift_package_build_files[\"blobby\"]" in translated.error)

    # The same package translates once the binary target is unreachable.
    manifest = manifest.replace('"Blobby", "Blob"', '"Blobby"')
    parsed = parse_swiftpm_package("blobby", manifest)
    translated = translate_swiftpm_package("blobby", "deps", parsed.model, ["blobby"], {"Blobby": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    return unittest.end(env)

def _unknown_target_dep_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Broken",
    products: [.library(name: "Broken", targets: ["Broken"])],
    targets: [.target(name: "Broken", dependencies: ["Missing"])],
)
"""
    parsed = parse_swiftpm_package("broken", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("broken", "deps", parsed.model, ["broken"], {"Broken": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "unknown target" in translated.error)
    return unittest.end(env)

def _renamed_single_target_product_aliases_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Renamed",
    products: [.library(name: "Renamed", targets: ["Inner"])],
    targets: [.target(name: "Inner")],
)
"""
    parsed = parse_swiftpm_package("renamed", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("renamed", "deps", parsed.model, ["renamed"], {"Inner": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    asserts.true(env, "name = \"Renamed\",\n    actual = \":Inner_lib\"" in translated.text)
    return unittest.end(env)

def _case_insensitive_same_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cased",
    products: [.library(name: "Cased", targets: ["Two"])],
    targets: [.target(name: "One"), .target(name: "Two", dependencies: ["one"])],
)
"""
    parsed = parse_swiftpm_package("cased", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("cased", "deps", parsed.model, ["cased"], {
        "One": struct(dir = "d", srcs = ["d/a.swift"]),
        "Two": struct(dir = "d", srcs = ["d/b.swift"]),
    })
    asserts.true(env, translated.ok)
    asserts.equals(env, ["One", "Two"], translated.names)
    asserts.true(env, "\":One_lib\"" in translated.text)
    return unittest.end(env)

def _case_insensitive_product_package_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "mixed",
    products: [.library(name: "mixed", targets: ["mixed"])],
    dependencies: [.package(url: "https://github.com/Apple/SwiftArgumentParser.git", from: "1.2.0")],
    targets: [.target(name: "mixed", dependencies: [.product(name: "ArgumentParser", package: "SWIFTARGUMENTPARSER")])],
)
"""
    parsed = parse_swiftpm_package("mixed", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("mixed", "deps", parsed.model, ["mixed", "swiftargumentparser"], {"mixed": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, translated.ok)
    asserts.true(env, "\"@deps__swiftpm-swiftargumentparser//:ArgumentParser\"" in translated.text)
    return unittest.end(env)

def _product_naming_test_target_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = parse_swiftpm_package("bigint", _BIGINT.replace('targets: ["BigInt"]', 'targets: ["BigIntTests"]'))
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("bigint", "deps", parsed.model, ["bigint"], {"BigInt": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "test target" in translated.error)
    return unittest.end(env)

def _same_dep_onto_test_target_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Testing",
    products: [.library(name: "Testing", targets: ["Testing"])],
    targets: [.target(name: "Testing", dependencies: ["TestingTests"]), .testTarget(name: "TestingTests")],
)
"""
    parsed = parse_swiftpm_package("testing", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("testing", "deps", parsed.model, ["testing"], {"Testing": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "test target" in translated.error)
    return unittest.end(env)

def _executable_target_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Tooling",
    products: [.library(name: "Tooling", targets: ["Tool"])],
    targets: [.executableTarget(name: "Tool")],
)
"""
    parsed = parse_swiftpm_package("tooling", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("tooling", "deps", parsed.model, ["tooling"], {})
    asserts.true(env, not translated.ok)
    asserts.true(env, "executable target" in translated.error)
    asserts.true(env, "swift_package_build_files[\"tooling\"]" in translated.error)
    return unittest.end(env)

_c99name_test = unittest.make(_c99name_test_impl)
_language_mode_test = unittest.make(_language_mode_test_impl)
_translates_bigint_test = unittest.make(_translates_bigint_test_impl)
_translates_groups_and_product_deps_test = unittest.make(_translates_groups_and_product_deps_test_impl)
_unpinned_product_dep_fails_test = unittest.make(_unpinned_product_dep_fails_test_impl)
_special_target_refusal_points_at_overrides_test = unittest.make(_special_target_refusal_points_at_overrides_test_impl)
_unknown_target_dep_fails_test = unittest.make(_unknown_target_dep_fails_test_impl)
_renamed_single_target_product_aliases_test = unittest.make(_renamed_single_target_product_aliases_test_impl)
_case_insensitive_same_dep_test = unittest.make(_case_insensitive_same_dep_test_impl)
_case_insensitive_product_package_test = unittest.make(_case_insensitive_product_package_test_impl)
_product_naming_test_target_fails_test = unittest.make(_product_naming_test_target_fails_test_impl)
_same_dep_onto_test_target_fails_test = unittest.make(_same_dep_onto_test_target_fails_test_impl)
_executable_target_refusal_test = unittest.make(_executable_target_refusal_test_impl)

def swiftpm_translate_test_suite(name):
    """Registers the translator unit tests."""
    unittest.suite(
        name + "_unit",
        _c99name_test,
        _language_mode_test,
        _translates_bigint_test,
        _translates_groups_and_product_deps_test,
        _unpinned_product_dep_fails_test,
        _special_target_refusal_points_at_overrides_test,
        _unknown_target_dep_fails_test,
        _renamed_single_target_product_aliases_test,
        _case_insensitive_same_dep_test,
        _case_insensitive_product_package_test,
        _product_naming_test_target_fails_test,
        _same_dep_onto_test_target_fails_test,
        _executable_target_refusal_test,
        _conditioned_dep_refusal_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )

def _conditioned_dep_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cond",
    products: [.library(name: "Cond", targets: ["Cond"])],
    dependencies: [.package(url: "https://example.com/Dep.git", from: "1.0.0")],
    targets: [.target(name: "Cond", dependencies: [.product(name: "Dp", package: "Dep", condition: .when(platforms: [.iOS]))])],
)
"""
    parsed = parse_swiftpm_package("cond", manifest)
    asserts.true(env, parsed.ok)
    translated = translate_swiftpm_package("cond", "deps", parsed.model, ["cond", "dep"], {"Cond": struct(dir = "d", srcs = ["d/a.swift"])})
    asserts.true(env, not translated.ok)
    asserts.true(env, "with a `condition:`" in translated.error)
    asserts.true(env, "\"Cond\"" in translated.error)
    return unittest.end(env)

_conditioned_dep_refusal_test = unittest.make(_conditioned_dep_refusal_test_impl)
