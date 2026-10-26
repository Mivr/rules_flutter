"""Unit tests for the `Package.resolved` reader and pin classifier."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:swiftpm_resolved.bzl",
    "check_swiftpm_config_present",
    "check_swiftpm_dicts",
    "classify_swiftpm_pin",
    "is_swiftpm_identity",
    "is_swiftpm_revision",
    "is_swiftpm_sha256",
    "read_swiftpm_pins",
    "swiftpm_github_parts",
    "swiftpm_spoke_name",
)

_BIGINT_REV = "63feef7820abb1a8fb08587d7da56bb0b7db8751"
_BIGINT_SHA = "55fc8a63f655a09d9216f2c9bc062c508f98d4eca4b8ebefaf295a3ea4ac8f22"

_V3 = """{
  "pins" : [
    {
      "identity" : "bigint",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/attaswift/BigInt",
      "state" : {
        "revision" : "63feef7820abb1a8fb08587d7da56bb0b7db8751",
        "version" : "6.0.1"
      }
    }
  ],
  "version" : 3
}
"""

_V2 = """{
  "pins" : [
    {
      "identity" : "bigint",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/attaswift/BigInt.git",
      "state" : {
        "branch" : null,
        "revision" : "63feef7820abb1a8fb08587d7da56bb0b7db8751",
        "version" : null
      }
    }
  ],
  "version" : 2
}
"""

def _validators_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_swiftpm_identity("bigint"))
    asserts.true(env, is_swiftpm_identity("a.b_c-d9"))
    asserts.true(env, not is_swiftpm_identity(""))
    asserts.true(env, not is_swiftpm_identity("BigInt"))
    asserts.true(env, not is_swiftpm_identity("big int"))
    asserts.true(env, not is_swiftpm_identity("big/int"))
    asserts.true(env, is_swiftpm_sha256(_BIGINT_SHA))
    asserts.true(env, not is_swiftpm_sha256(_BIGINT_SHA.upper()))
    asserts.true(env, not is_swiftpm_sha256("abc"))
    asserts.true(env, not is_swiftpm_sha256(_BIGINT_SHA + "0"))
    asserts.true(env, is_swiftpm_revision(_BIGINT_REV))
    asserts.true(env, is_swiftpm_revision(_BIGINT_REV.upper()))
    asserts.true(env, not is_swiftpm_revision("main"))
    asserts.equals(env, "deps__swiftpm-bigint", swiftpm_spoke_name("deps", "bigint"))
    return unittest.end(env)

def _location_parts_test_impl(ctx):
    env = unittest.begin(ctx)
    parts = swiftpm_github_parts("https://github.com/attaswift/BigInt")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("https://github.com/attaswift/BigInt.git")
    asserts.true(env, parts.ok)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("https://GITHUB.COM/attaswift/BigInt")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    parts = swiftpm_github_parts("https://gitlab.com/some/group")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("git@github.com:attaswift/BigInt.git")
    asserts.true(env, parts.ok)
    asserts.equals(env, "attaswift", parts.owner)
    asserts.equals(env, "BigInt", parts.repo)
    parts = swiftpm_github_parts("git@github.com:attaswift/BigInt")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "ssh", parts.reason)
    parts = swiftpm_github_parts("git@gitlab.com:attaswift/BigInt.git")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("file:///tmp/BigInt")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("https://github.com/onlyowner")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    parts = swiftpm_github_parts("https://github.com/a/b/c")
    asserts.true(env, not parts.ok)
    asserts.equals(env, "location", parts.reason)
    return unittest.end(env)

def _reads_v2_and_v3_test_impl(ctx):
    env = unittest.begin(ctx)
    for content in [_V2, _V3]:
        pins = read_swiftpm_pins(content, "//ios:Package.resolved")
        asserts.true(env, pins.ok)
        asserts.equals(env, "", pins.error)
        asserts.equals(env, 1, len(pins.pins))
        asserts.equals(env, "bigint", pins.pins[0].identity)
        asserts.equals(env, _BIGINT_REV, pins.pins[0].revision)
    return unittest.end(env)

def _refuses_v1_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins('{"object": {"pins": []}, "version": 1}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "version 1" in pins.error)
    asserts.true(env, "//ios:Package.resolved" in pins.error)
    return unittest.end(env)

def _bad_json_names_the_file_test_impl(ctx):
    env = unittest.begin(ctx)
    for content in ["{not json", '{"pins": [}, "version": 3}', '{"pins": []}, trailing', ""]:
        pins = read_swiftpm_pins(content, "//ios:Package.resolved")
        asserts.true(env, not pins.ok)
        asserts.true(env, "//ios:Package.resolved" in pins.error)
    return unittest.end(env)

def _bad_pin_shapes_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins('{"pins": [], "version": 9}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    pins = read_swiftpm_pins('{"version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    pins = read_swiftpm_pins('{"pins": [{"identity": "BigInt", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {"revision": "' + _BIGINT_REV + '"}}], "version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "identity" in pins.error)
    pins = read_swiftpm_pins('{"pins": [{"identity": "bigint", "kind": "remoteSourceControl", "state": {"revision": "' + _BIGINT_REV + '"}}], "version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "location" in pins.error)
    pins = read_swiftpm_pins('{"pins": [{"identity": "bigint", "kind": "remoteSourceControl", "location": "https://github.com/a/b", "state": {}}], "version": 3}', "//ios:Package.resolved")
    asserts.true(env, not pins.ok)
    asserts.true(env, "revision" in pins.error)
    return unittest.end(env)

def _classify_pinned_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins(_V3, "//ios:Package.resolved")
    classified = classify_swiftpm_pin(pins.pins[0], {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, classified.ok)
    asserts.equals(env, "https://github.com/attaswift/BigInt/archive/" + _BIGINT_REV + ".tar.gz", classified.url)
    asserts.equals(env, _BIGINT_SHA, classified.sha256)
    return unittest.end(env)

def _classify_unpinned_names_the_fix_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = read_swiftpm_pins(_V3, "//ios:Package.resolved")
    classified = classify_swiftpm_pin(pins.pins[0], {}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "deps__swiftpm-bigint" in classified.error)
    asserts.true(env, "bigint" in classified.error)
    asserts.true(env, "//ios:Package.resolved" in classified.error)
    asserts.true(env, "has no `swift_package_sha256[" in classified.error)
    asserts.true(env, "https://github.com/attaswift/BigInt/archive/" + _BIGINT_REV + ".tar.gz" in classified.error)
    return unittest.end(env)

def _classify_bad_revision_and_location_test_impl(ctx):
    env = unittest.begin(ctx)
    good = read_swiftpm_pins(_V3, "//ios:Package.resolved").pins[0]
    bad_rev = struct(identity = good.identity, kind = good.kind, location = good.location, revision = "main")
    classified = classify_swiftpm_pin(bad_rev, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "revision" in classified.error)
    bad_sha = classify_swiftpm_pin(good, {"bigint": "xyz"}, "deps", "//ios:Package.resolved")
    asserts.true(env, not bad_sha.ok)
    asserts.true(env, "invalid" in bad_sha.error)
    bad_kind = struct(identity = good.identity, kind = "localSourceControl", location = good.location, revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(bad_kind, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "remoteSourceControl" in classified.error)
    bad_loc = struct(identity = "bigint", kind = "remoteSourceControl", location = "git@github.com:attaswift/BigInt", revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(bad_loc, {}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, ".git" in classified.error)
    file_loc = struct(identity = "bigint", kind = "remoteSourceControl", location = "https://gitlab.com/attaswift/BigInt", revision = _BIGINT_REV)
    classified = classify_swiftpm_pin(file_loc, {"bigint": _BIGINT_SHA}, "deps", "//ios:Package.resolved")
    asserts.true(env, not classified.ok)
    asserts.true(env, "not a GitHub repository" in classified.error)
    return unittest.end(env)

def _config_checks_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", check_swiftpm_config_present(None, {}, {}))
    asserts.true(env, "swift_package_sha256" in check_swiftpm_config_present(None, {"a": "b"}, {}))
    asserts.true(env, "swift_package_build_files" in check_swiftpm_config_present(None, {}, {"a": "b"}))
    asserts.equals(env, "", check_swiftpm_config_present("//ios:Package.resolved", {}, {}))
    asserts.equals(env, "", check_swiftpm_dicts({"bigint": _BIGINT_SHA}, {"bigint": "//:BigInt.BUILD"}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "pinned nowhere" in check_swiftpm_dicts({"other": _BIGINT_SHA}, {}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "pinned nowhere" in check_swiftpm_dicts({}, {"other": "//:B"}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "64 lowercase hex" in check_swiftpm_dicts({"bigint": "xyz"}, {}, ["bigint"], "//ios:Package.resolved"))
    asserts.true(env, "absolute label" in check_swiftpm_dicts({}, {"bigint": "relative/BUILD"}, ["bigint"], "//ios:Package.resolved"))
    return unittest.end(env)

_validators_test = unittest.make(_validators_test_impl)
_location_parts_test = unittest.make(_location_parts_test_impl)
_reads_v2_and_v3_test = unittest.make(_reads_v2_and_v3_test_impl)
_refuses_v1_test = unittest.make(_refuses_v1_test_impl)
_bad_json_names_the_file_test = unittest.make(_bad_json_names_the_file_test_impl)
_bad_pin_shapes_test = unittest.make(_bad_pin_shapes_test_impl)
_classify_pinned_test = unittest.make(_classify_pinned_test_impl)
_classify_unpinned_names_the_fix_test = unittest.make(_classify_unpinned_names_the_fix_test_impl)
_classify_bad_revision_and_location_test = unittest.make(_classify_bad_revision_and_location_test_impl)
_config_checks_test = unittest.make(_config_checks_test_impl)

def swiftpm_resolved_test_suite(name):
    """Registers the `Package.resolved` reader unit tests."""
    unittest.suite(
        name + "_unit",
        _validators_test,
        _location_parts_test,
        _reads_v2_and_v3_test,
        _refuses_v1_test,
        _bad_json_names_the_file_test,
        _bad_pin_shapes_test,
        _classify_pinned_test,
        _classify_unpinned_names_the_fix_test,
        _classify_bad_revision_and_location_test,
        _config_checks_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
