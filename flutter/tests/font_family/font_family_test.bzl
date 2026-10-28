"""Analysis tests for the COV-29 font-family contract.

Every refusal fails on the base: the misbinding (a font paired with the file
at its index), a weight or style flutter_tools rejects, an application's
families, and the duplicate-family conflict. The positive cases inspect the
bundle config: an application's family and assets are bare, a library's are
`packages/<package_name>/`, each descriptor lists `weight`/`style` only when
given, and every asset maps to its own file.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/tests:action_content.bzl", "written_json")

def _assert_copy(env, config, dest, suffix):
    """Assert the bundle copies `dest` from the file ending in `suffix`.

    Args:
        env: The `analysistest` env.
        config: Decoded `.asset_bundle_config.json`.
        dest: The bundled destination key.
        suffix: The source path suffix the copied file must carry.
    """
    copies = config["copies"]
    asserts.true(env, dest in copies, "no bundle copy for %s: %s" % (dest, copies))
    if dest in copies:
        asserts.true(
            env,
            copies[dest].endswith(suffix),
            "bundle copy %s came from %s, not a file ending in %s" % (dest, copies[dest], suffix),
        )

def _app_fonts_test_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    asserts.equals(
        env,
        [{
            "family": "HelloSans",
            "fonts": [
                {"asset": "fonts/HelloSans-Regular.ttf"},
                {"asset": "fonts/HelloSans-Bold.ttf", "weight": 700},
            ],
        }],
        config["fonts"],
    )
    _assert_copy(env, config, "fonts/HelloSans-Regular.ttf", "font_family/fonts/HelloSans-Regular.ttf")
    _assert_copy(env, config, "fonts/HelloSans-Bold.ttf", "font_family/fonts/HelloSans-Bold.ttf")
    return analysistest.end(env)

def _library_fonts_test_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    asserts.equals(
        env,
        [{
            "family": "packages/fontpkg/HelloSans",
            "fonts": [
                {"asset": "packages/fontpkg/fonts/HelloSans-Regular.ttf"},
                {"asset": "packages/fontpkg/fonts/HelloSans-Bold.ttf", "weight": 700},
            ],
        }],
        config["fonts"],
    )
    _assert_copy(
        env,
        config,
        "packages/fontpkg/fonts/HelloSans-Regular.ttf",
        "font_family/fonts/HelloSans-Regular.ttf",
    )
    _assert_copy(
        env,
        config,
        "packages/fontpkg/fonts/HelloSans-Bold.ttf",
        "font_family/fonts/HelloSans-Bold.ttf",
    )
    return analysistest.end(env)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_app_fonts_test = analysistest.make(_app_fonts_test_impl)
_library_fonts_test = analysistest.make(_library_fonts_test_impl)
_failure_test = analysistest.make(
    _failure_test_impl,
    expect_failure = True,
    attrs = {"expected": attr.string_list(mandatory = True)},
)

def _failure(name, target, expected):
    """Register one expected-analysis-failure test.

    Args:
        name: Test target name.
        target: The fixture target under test.
        expected: Substrings the failure must name.
    """
    _failure_test(
        name = name,
        expected = expected,
        target_under_test = target,
    )

def font_family_test_suite(name):
    """Registers the COV-29 analysis tests.

    Args:
        name: Prefix for the generated tests and the suite.
    """
    _app_fonts_test(
        name = name + "_app_fonts",
        target_under_test = ":app_with_fonts",
    )
    _library_fonts_test(
        name = name + "_library_fonts",
        target_under_test = ":lib_fonts_bundle",
    )
    _failure(
        name + "_missing_font_file",
        ":missing_file_lib",
        ["missing_file_lib", "HelloSans", "fonts/HelloSans-Regular.ttf has no font_files entry"],
    )
    _failure(
        name + "_unclaimed_font_file",
        ":unclaimed_file_lib",
        ["unclaimed_file_lib", "fonts/HelloSans-Bold.ttf is named by no family"],
    )
    _failure(
        name + "_bad_weight_json",
        ":bad_weight_lib",
        ["bad_weight_lib", "HelloSans", "Invalid value 750 ((int)) for font -> weight."],
    )
    _failure(
        name + "_bad_style_json",
        ":bad_style_lib",
        ["bad_style_lib", "HelloSans", "Invalid value oblique ((String)) for font -> style."],
    )
    _failure(
        name + "_bad_weight_plugin",
        ":bad_weight_plugin",
        ["bad_weight_plugin", "HelloSans", "Invalid value 750 ((int)) for font -> weight."],
    )
    _failure(
        name + "_empty_family",
        ":empty_family",
        ["empty_family", "non-empty `family`"],
    )
    _failure(
        name + "_empty_fonts",
        ":empty_fonts",
        ["empty_fonts", "non-empty `fonts` list"],
    )
    _failure(
        name + "_missing_asset",
        ":missing_asset_family",
        ["missing_asset_family", "NoAssetSans", "no asset path"],
    )
    _failure(
        name + "_bad_weight_family",
        ":bad_weight_family",
        ["bad_weight_family", "HeavySans", "Invalid value 750 ((int)) for font -> weight."],
    )
    _failure(
        name + "_bad_style_family",
        ":bad_style_family",
        ["bad_style_family", "SlantedSans", "Invalid value oblique ((String)) for font -> style."],
    )
    _failure(
        name + "_conflict_app",
        ":conflict_app",
        ["font family 'ConflictSans' is carried with two different font lists", "conflict_a", "conflict_b"],
    )
    _failure(
        name + "_conflict_library",
        ":conflict_lib_bundle",
        ["font family 'packages/conflictpkg/ConflictSans' is carried with two different font lists", "conflict_a", "conflict_lib"],
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_app_fonts",
            ":" + name + "_library_fonts",
            ":" + name + "_missing_font_file",
            ":" + name + "_unclaimed_font_file",
            ":" + name + "_bad_weight_json",
            ":" + name + "_bad_style_json",
            ":" + name + "_bad_weight_plugin",
            ":" + name + "_empty_family",
            ":" + name + "_empty_fonts",
            ":" + name + "_missing_asset",
            ":" + name + "_bad_weight_family",
            ":" + name + "_bad_style_family",
            ":" + name + "_conflict_app",
            ":" + name + "_conflict_library",
        ],
    )
