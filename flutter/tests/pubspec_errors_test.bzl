"""Tests for strict pubspec parsing: compact sequences, BOMs, and failures.

`parse_pubspec` is a thin call to rules_dart's public
`parse_pubspec_document`, so these tests pin the shapes that must read
(zero-indented block sequences outside and inside `flutter:`, a leading
byte-order mark) and the failure an unreadable pubspec raises at
analysis time (naming the package and the line). Today's indented shapes
stay covered by `flutter_pubspec_test`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//flutter/private:flutter_pubspec.bzl",
    "parse_flutter_assets_block",
    "parse_flutter_plugin_block",
    "parse_pubspec",
)

# A block sequence at its key's own column, outside `flutter:` (`topics`)
# and inside it (`assets`).
_COMPACT_PUBSPEC = """\
name: compact_pkg
version: 1.0.0
topics:
- a
- b
flutter:
  assets:
  - assets/a.png
  - assets/b.png
"""

# Zero-indented sequences at deeper nesting: the `fonts` list and each
# family's `fonts` list, plus a compact `shaders` list.
_COMPACT_FONTS_PUBSPEC = """\
name: compact_fonts
flutter:
  uses-material-design: true
  fonts:
  - family: Roboto
    fonts:
    - asset: fonts/Roboto-Regular.ttf
    - asset: fonts/Roboto-Bold.ttf
      weight: 700
      style: italic
  shaders:
  - shaders/sparkle.frag
"""

# A plugin block beside a map-form asset whose `flavors`/`platforms`
# conditions sit at their key's own column.
_COMPACT_PLUGIN_PUBSPEC = """\
name: compact_plugin
flutter:
  plugin:
    implements: umbrella
    platforms:
      android:
        pluginClass: CompactPlugin
  assets:
  - path: assets/foo.png
    flavors:
    - prod
    platforms:
    - ios
    - android
"""

# A byte-order mark before an otherwise ordinary pubspec.
_BOM_PUBSPEC = "\357\273\277name: bom_pkg\nflutter:\n  assets:\n    - assets/a.png\n"

# A line the parser cannot read: the failure names `broken_pkg` at line 2.
_BAD_PUBSPEC = "name: broken_pkg\nno colon here\n"

def _compact_top_test_impl(ctx):
    """Zero-indented sequences read outside and inside `flutter:`."""
    env = unittest.begin(ctx)
    data = parse_pubspec(_COMPACT_PUBSPEC)
    asserts.equals(env, "compact_pkg", data.get("name"))
    asserts.equals(env, ["a", "b"], data.get("topics"))
    assets = parse_flutter_assets_block(_COMPACT_PUBSPEC).assets
    asserts.equals(env, 2, len(assets))
    asserts.equals(env, "assets/a.png", assets[0].path)
    asserts.equals(env, "assets/b.png", assets[1].path)
    return unittest.end(env)

def _compact_fonts_test_impl(ctx):
    """Zero-indented sequences read at deeper nesting levels."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_COMPACT_FONTS_PUBSPEC)
    asserts.equals(env, True, result.uses_material_design)
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, "Roboto", result.fonts[0].family)
    asserts.equals(env, 2, len(result.fonts[0].fonts))
    asserts.equals(env, "fonts/Roboto-Regular.ttf", result.fonts[0].fonts[0].asset)
    asserts.equals(env, "fonts/Roboto-Bold.ttf", result.fonts[0].fonts[1].asset)
    asserts.equals(env, 700, result.fonts[0].fonts[1].weight)
    asserts.equals(env, "italic", result.fonts[0].fonts[1].style)
    asserts.equals(env, 1, len(result.shaders))
    asserts.equals(env, "shaders/sparkle.frag", result.shaders[0].path)
    return unittest.end(env)

def _compact_plugin_test_impl(ctx):
    """Plugin data and asset conditions survive the compact form."""
    env = unittest.begin(ctx)
    plugin = parse_flutter_plugin_block(_COMPACT_PLUGIN_PUBSPEC)
    asserts.true(env, plugin.present)
    asserts.equals(env, "umbrella", plugin.implements)
    asserts.equals(env, "CompactPlugin", plugin.platforms["android"]["pluginClass"])
    assets = parse_flutter_assets_block(_COMPACT_PLUGIN_PUBSPEC).assets
    asserts.equals(env, 1, len(assets))
    asserts.equals(env, "assets/foo.png", assets[0].path)
    asserts.equals(env, ["prod"], assets[0].flavors)
    asserts.equals(env, ["ios", "android"], assets[0].platforms)
    return unittest.end(env)

def _bom_test_impl(ctx):
    """A leading byte-order mark parses instead of emptying the name."""
    env = unittest.begin(ctx)
    data = parse_pubspec(_BOM_PUBSPEC)
    asserts.equals(env, "bom_pkg", data.get("name"))
    assets = parse_flutter_assets_block(_BOM_PUBSPEC).assets
    asserts.equals(env, 1, len(assets))
    asserts.equals(env, "assets/a.png", assets[0].path)
    return unittest.end(env)

_t_compact_top_test = unittest.make(_compact_top_test_impl)
_t_compact_fonts_test = unittest.make(_compact_fonts_test_impl)
_t_compact_plugin_test = unittest.make(_compact_plugin_test_impl)
_t_bom_test = unittest.make(_bom_test_impl)

def _pubspec_error_probe_impl(ctx):
    parse_pubspec(ctx.attr.pubspec)
    return [DefaultInfo(files = depset())]

pubspec_error_probe = rule(
    implementation = _pubspec_error_probe_impl,
    attrs = {
        "pubspec": attr.string(doc = "Full pubspec.yaml content; analysis fails when it is unreadable."),
    },
    doc = "Parses one pubspec at analysis time so failure tests can assert the error.",
)

def _unreadable_pubspec_fails_test_impl(ctx):
    """An unreadable pubspec fails naming the package and the line."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "broken_pkg")
    asserts.expect_failure(env, "line 2")
    return analysistest.end(env)

_unreadable_pubspec_fails_test = analysistest.make(
    _unreadable_pubspec_fails_test_impl,
    expect_failure = True,
)

def pubspec_errors_test_suite(name):
    """Defines the strict-pubspec unit and analysis tests.

    Args:
        name: Name of the resulting test_suite.
    """
    unittest.suite(
        name + "_pure",
        _t_compact_top_test,
        _t_compact_fonts_test,
        _t_compact_plugin_test,
        _t_bom_test,
    )
    pubspec_error_probe(
        name = name + "_probe",
        pubspec = _BAD_PUBSPEC,
        tags = ["manual"],
    )
    _unreadable_pubspec_fails_test(
        name = name + "_unreadable_fails",
        target_under_test = ":" + name + "_probe",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_pure",
            ":" + name + "_unreadable_fails",
        ],
    )
