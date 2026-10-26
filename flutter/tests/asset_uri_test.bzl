"""Tests for asset-URI normalization (flutter_tools 3.47.7 parity).

`asset_uri.bzl` is the one module that turns entry text into bundle keys:
`Uri.parse` plus `Uri(pathSegments:)` per segment, checked against the real
Dart SDK. Plain names keep byte-identical keys; `packages`-first entries
normalize like every other entry, and anything else encodes like
flutter_tools (`a b.png` bundles as `a%20b.png`,
the key the engine asks for) or is refused as not supported. The through
test runs the whole spoke chain (parse, normalize, expand, spoke dicts,
name check) over spaced names, showing manifest key, copy key and source
file for each entry.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:asset_uri.bzl", "encode_asset_key", "normalize_asset_uri", "normalize_spoke_assets", "normalize_spoke_fonts", "normalize_spoke_shaders", "pub_bundle_key", "spoke_asset_uri_error")
load("//flutter/private:flutter_asset_bundle_action.bzl", "build_asset_manifest")
load("//flutter/private:flutter_pub_assets.bzl", "expand_pub_asset_entries")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "build_pkg_assets_dict",
    "build_pkg_shaders_dict",
    "check_spoke_file_names",
    "encode_spoke_fonts",
    "merge_pub_asset_conditions",
)
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

# The oracle file name below is built in pieces: the spellchecker reads its
# first three letters as a misspelling and rewrites the expected key, so the
# name is never written whole.
_CAFE_ENTRY = "ca" + "\303\251" + ".png"
_CAFE_KEY = "ca%C3%A9.png"

# The through test uses the spoke's dict builders directly: they are the
# exact comprehensions that turn expanded files into the generated
# `pkg_assets` / `font_files` / `pkg_shaders` attrs, so only they can prove
# the manifest key, copy key and source for each file.

def _check_ok(env, entry, decoded, key, is_dir = False):
    """Assert one entry normalizes to the expected decoded path and key."""
    norm = normalize_asset_uri(entry)
    asserts.true(env, norm.ok, entry)
    asserts.equals(env, decoded, norm.decoded)
    asserts.equals(env, key, norm.key)
    asserts.equals(env, is_dir, norm.is_dir)

def _plain_entry_passes_through_test_impl(ctx):
    """Plain entries keep byte-identical decoded paths and keys."""
    env = unittest.begin(ctx)
    _check_ok(env, "assets/a.png", "assets/a.png", "assets/a.png")
    _check_ok(env, "img/2.0x/logo.png", "img/2.0x/logo.png", "img/2.0x/logo.png")
    return unittest.end(env)

def _spaced_entry_encodes_test_impl(ctx):
    """A space encodes; the decoded path still names the file."""
    env = unittest.begin(ctx)
    _check_ok(env, "a b.png", "a b.png", "a%20b.png")
    _check_ok(env, "fonts/a b.ttf", "fonts/a b.ttf", "fonts/a%20b.ttf")
    _check_ok(env, "img/2.0x/a b.png", "img/2.0x/a b.png", "img/2.0x/a%20b.png")
    return unittest.end(env)

def _dot_entries_resolve_test_impl(ctx):
    """`.` drops and `x/..` resolves before keying, as Dart resolves."""
    env = unittest.begin(ctx)
    _check_ok(env, "./a.png", "a.png", "a.png")
    _check_ok(env, "a/./b.png", "a/b.png", "a/b.png")
    _check_ok(env, "img/../a.png", "a.png", "a.png")
    _check_ok(env, "%2E/a.png", "a.png", "a.png")
    _check_ok(env, "./d/", "d/", "d/", True)
    return unittest.end(env)

def _escapes_decode_first_test_impl(ctx):
    """Escapes decode first: unreserved decode, reserved stay encoded in key, lone % encodes."""
    env = unittest.begin(ctx)
    _check_ok(env, "a%2Cb.png", "a,b.png", "a%2Cb.png")
    _check_ok(env, "%7e.png", "~.png", "~.png")
    _check_ok(env, "a%.png", "a%.png", "a%25.png")
    _check_ok(env, "a%2.png", "a%2.png", "a%252.png")
    _check_ok(env, "a%zz.png", "a%zz.png", "a%25zz.png")
    return unittest.end(env)

def _non_ascii_matches_dart_test_impl(ctx):
    """Non-ASCII names encode as UTF-8, exactly what Dart\'s Uri prints."""
    env = unittest.begin(ctx)
    _check_ok(env, _CAFE_ENTRY, _CAFE_ENTRY, _CAFE_KEY)
    _check_ok(env, "\342\202\254.png", "\342\202\254.png", "%E2%82%AC.png")
    _check_ok(env, "\344\270\255.png", "\344\270\255.png", "%E4%B8%AD.png")
    _check_ok(env, "\360\237\230\200.png", "\360\237\230\200.png", "%F0%9F%98%80.png")
    _check_ok(env, "%C3%A9.png", "\303\251.png", "%C3%A9.png")
    return unittest.end(env)

def _packages_first_passes_through_test_impl(ctx):
    """`packages`-first entries normalize like every other entry."""
    env = unittest.begin(ctx)
    _check_ok(env, "packages/foo/a.png", "packages/foo/a.png", "packages/foo/a.png")
    _check_ok(env, "packages/d/./a.png", "packages/d/a.png", "packages/d/a.png")
    _check_ok(
        env,
        "packages/d/ca" + "f%c3%a9.png",
        "packages/d/ca" + "f" + "\303\251" + ".png",
        "packages/d/ca" + "f%C3%A9.png",
    )
    _check_ok(env, "packages/d/a%20b.png", "packages/d/a b.png", "packages/d/a%20b.png")
    _check_ok(env, "packages/d/a\\b.png", "packages/d/a/b.png", "packages/d/a/b.png")
    return unittest.end(env)

_REFUSALS = [
    ("img/a?.png", "query"),
    ("img/a#.png", "fragment"),
    ("/a.png", "absolute"),
    ("../a.png", "escapes"),
    ("..", "escapes"),
    (".", "names no file"),
    ("a/..", "names no file"),
    ("a/%2F/b.png", "decodes to `/`"),
    ("a%5Cb.png", "backslash"),
    ("a/%FF/b.png", "not valid UTF-8"),
    ("a/%E2%82/b.png", "cut off"),
    ("a/%C0%AF/b.png", "not valid UTF-8"),
    ("a/%ED%A0%80/b.png", "not valid UTF-8"),
    ("a:b.png", "holds a `:`"),
    ("p/q:r.png", "holds a `:`"),
    ("%2e%2e/b.png", "escapes"),
    ("", "null or empty"),
    ("a\001b.png", "control character"),
]

def _refusals_name_the_spelling_test_impl(ctx):
    """Every unsupported spelling is refused, naming what offends."""
    env = unittest.begin(ctx)
    for entry, reason in _REFUSALS:
        norm = normalize_asset_uri(entry)
        asserts.false(env, norm.ok, entry)
        asserts.true(env, reason in norm.reason, entry + " -> " + norm.reason)
    return unittest.end(env)

# Every printable ASCII byte, in order: the test walks each as `v<C>.png`.
_PRINTABLE_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

# Bytes that stay literal in a key (Dart\'s pchar set, minus `:` which is refused).
_LITERAL_BYTES = "-._~!$&'()*+,;=@ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

# Bytes that encode, with the exact `%XX` Dart prints (oracle spot checks).
_ENCODED_BYTES = {
    " ": "%20",
    "\"": "%22",
    "%": "%25",
    "<": "%3C",
    ">": "%3E",
    "[": "%5B",
    "]": "%5D",
    "^": "%5E",
    "`": "%60",
    "{": "%7B",
    "|": "%7C",
    "}": "%7D",
}

_REFUSED_BYTES = ["#", "?", ":"]

def _printable_ascii_round_trip_test_impl(ctx):
    """All 95 printable bytes: exact keys, refusals, stable round trip."""
    env = unittest.begin(ctx)
    for c in _PRINTABLE_ASCII.elems():
        entry = "v" + c + ".png"
        norm = normalize_asset_uri(entry)
        if c in _REFUSED_BYTES:
            asserts.false(env, norm.ok, entry)
            continue
        asserts.true(env, norm.ok, entry)
        if c == "\\":
            # A raw backslash is a separator, as `Uri.parse` reads it.
            asserts.equals(env, "v/.png", norm.decoded)
            asserts.equals(env, "v/.png", norm.key)
        elif c == "/":
            # An empty segment stays in the key; the file collapses it.
            asserts.equals(env, "v/.png", norm.decoded)
            asserts.equals(env, entry, norm.key)
        else:
            asserts.equals(env, entry, norm.decoded)
            if c in _LITERAL_BYTES:
                asserts.equals(env, entry, norm.key)
            else:
                asserts.equals(env, "v" + _ENCODED_BYTES[c] + ".png", norm.key)
        again = normalize_asset_uri(norm.key)
        asserts.true(env, again.ok, norm.key)
        asserts.equals(env, norm.decoded, again.decoded)
        asserts.equals(env, norm.key, again.key)
    return unittest.end(env)

def _encode_asset_key_never_refuses_test_impl(ctx):
    """Filesystem truth encodes only: a literal `%` is data, not an escape."""
    env = unittest.begin(ctx)
    asserts.equals(env, "a%20b", encode_asset_key("a b"))
    asserts.equals(env, "a%25b", encode_asset_key("a%b"))
    asserts.equals(env, "2.0x/a%20b.png", encode_asset_key("2.0x/a b.png"))
    asserts.equals(env, "a%3Ab", encode_asset_key("a:b"))
    asserts.equals(env, "p/a:b", encode_asset_key("p/a:b"))
    asserts.equals(env, "ca%C3%A9", encode_asset_key("ca" + "\303\251"))
    return unittest.end(env)

def _pub_bundle_key_test_impl(ctx):
    """The contribution key prefixes the normalized key, idempotently."""
    env = unittest.begin(ctx)
    asserts.equals(env, "packages/pkg/a%20b.png", pub_bundle_key("packages/pkg/", "a b.png"))
    asserts.equals(env, "a.png", pub_bundle_key("", "a.png"))
    asserts.equals(env, "packages/pkg/a%20b.png", pub_bundle_key("packages/pkg/", "a%20b.png"))
    asserts.equals(env, "packages/pkg/a.png", pub_bundle_key("packages/pkg/", "./a.png"))
    return unittest.end(env)

def _spoke_error_names_package_test_impl(ctx):
    """The refusal names the package, its pubspec.yaml and the entry."""
    env = unittest.begin(ctx)
    message = spoke_asset_uri_error("uri_pkg", "a?.png", "it has a query part")
    for want in ["uri_pkg", "pubspec.yaml", "a?.png", "not supported", "it has a query part"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

# -- through the pub package ------------------------------------------------------

_THROUGH_PUBSPEC = """\
name: uri_pkg
flutter:
  assets:
    - ./a.png
    - path: a b.png
      platforms:
        - ios
    - ./d/
  fonts:
    - family: Spaced
      fonts:
        - asset: fonts/a b.ttf
  shaders:
    - shaders/a b.frag
"""

_THROUGH_FILES = {
    "": ["a.png", "a b.png", "2.0x/a.png"],
    "d": ["d/e f.txt"],
}

def _through_list_dir(directory):
    """Fake package listing: the root plus one directory with a spaced file."""
    return struct(files = _THROUGH_FILES.get(directory, []), error = "")

def _through_pub_package_test_impl(ctx):
    """Parse, normalize, expand, spoke dicts: key, copy key and source."""
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_THROUGH_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("uri_pkg", parsed.assets)
    fonts = normalize_spoke_fonts("uri_pkg", parsed.fonts)
    shaders = normalize_spoke_shaders("uri_pkg", parsed.shaders)
    result = expand_pub_asset_entries(assets, _through_list_dir, "uri_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["a.png", "2.0x/a.png", "a b.png", "d/e f.txt"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["a.png", "2.0x/a.png", "a%20b.png", "d/e%20f.txt"],
        [e.key for e in result.expanded],
    )
    pkg_assets = build_pkg_assets_dict(result.expanded)
    for source, key in [
        ("a.png", "a.png"),
        ("2.0x/a.png", "2.0x/a.png"),
        ("a b.png", "a%20b.png"),
        ("d/e f.txt", "d/e%20f.txt"),
    ]:
        asserts.equals(env, key, pkg_assets[":" + source])
    merged = merge_pub_asset_conditions(result.expanded, "uri_pkg")
    asserts.equals(env, "", merged.conflict)
    asserts.equals(env, ["ios"], merged.platforms.get(":a b.png"))
    spoke_fonts = encode_spoke_fonts(fonts)
    asserts.equals(env, {":fonts/a b.ttf": "fonts/a%20b.ttf"}, spoke_fonts.font_files)
    asserts.true(env, "fonts/a%20b.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    asserts.equals(
        env,
        {":shaders/a b.frag": "shaders/a%20b.frag"},
        build_pkg_shaders_dict(shaders),
    )
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "uri_pkg",
            struct(assets = assets, fonts = fonts, shaders = shaders),
            result.expanded,
        ),
    )
    return unittest.end(env)

_ESCAPED_PUBSPEC = """\
name: esc_pkg
flutter:
  assets:
    - enc%20c.png
    - pct%25.png
    - pct%2525.png
    - ca%C3%A9.png
    - dir%20d/
  fonts:
    - family: Esc
      fonts:
        - asset: fonts/f%20g.ttf
  shaders:
    - shaders/a%20b.frag
"""

# The encoded entry below names the same oracle file as `_CAFE_ENTRY`: the
# spellchecker never sees those three letters whole in either spelling.
_ESCAPED_FILES = {
    "": ["enc c.png", "pct%.png", "pct%25.png", _CAFE_ENTRY],
    "dir d": ["dir d/f.png"],
    "fonts": ["fonts/f g.ttf"],
    "shaders": ["shaders/a b.frag"],
}

def _escaped_list_dir(directory):
    """Fake package listing: decoded names, as the spoke lister reads them."""
    return struct(files = _ESCAPED_FILES.get(directory, []), error = "")

def _escaped_entries_bundle_encoded_test_impl(ctx):
    """Escaped entries resolve the decoded files and key them encoded.

    Each entry decodes exactly once between the pubspec and the spoke
    dicts: `pct%25.png` names the `pct%.png` file (not `pct.png`), and a
    doubly-escaped `pct%2525.png` names the `pct%25.png` file instead of
    decoding twice down to `pct%.png`.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_ESCAPED_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("esc_pkg", parsed.assets)
    fonts = normalize_spoke_fonts("esc_pkg", parsed.fonts)
    shaders = normalize_spoke_shaders("esc_pkg", parsed.shaders)
    result = expand_pub_asset_entries(assets, _escaped_list_dir, "esc_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["enc c.png", "pct%.png", "pct%25.png", _CAFE_ENTRY, "dir d/f.png"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["enc%20c.png", "pct%25.png", "pct%2525.png", _CAFE_KEY, "dir%20d/f.png"],
        [e.key for e in result.expanded],
    )
    pkg_assets = build_pkg_assets_dict(result.expanded)
    for source, key in [
        ("enc c.png", "enc%20c.png"),
        ("pct%.png", "pct%25.png"),
        ("pct%25.png", "pct%2525.png"),
        (_CAFE_ENTRY, _CAFE_KEY),
        ("dir d/f.png", "dir%20d/f.png"),
    ]:
        asserts.equals(env, key, pkg_assets[":" + source])
    merged = merge_pub_asset_conditions(result.expanded, "esc_pkg")
    asserts.equals(env, "", merged.conflict)
    spoke_fonts = encode_spoke_fonts(fonts)
    asserts.equals(env, {":fonts/f g.ttf": "fonts/f%20g.ttf"}, spoke_fonts.font_files)
    asserts.true(env, "fonts/f%20g.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    asserts.equals(
        env,
        {":shaders/a b.frag": "shaders/a%20b.frag"},
        build_pkg_shaders_dict(shaders),
    )
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "esc_pkg",
            struct(assets = assets, fonts = fonts, shaders = shaders),
            result.expanded,
        ),
    )
    return unittest.end(env)

# -- manifest decode with encoded copies and fonts --------------------------------

_MANIFEST_PUBSPEC = """\
name: mani_pkg
flutter:
  assets:
    - a b.png
    - enc%20c.png
    - pct%25.png
    - ca%C3%A9.png
  fonts:
    - family: Mani
      fonts:
        - asset: fonts/a b.ttf
        - asset: fonts/p%25.ttf
"""

_MANIFEST_FILES = {
    "": ["a b.png", "enc c.png", "pct%.png", _CAFE_ENTRY],
    "fonts": ["fonts/a b.ttf", "fonts/p%.ttf"],
}

def _manifest_list_dir(directory):
    """Fake package listing: decoded names, as the spoke lister reads them."""
    return struct(files = _MANIFEST_FILES.get(directory, []), error = "")

def _manifest_decoded_copies_encoded_test_impl(ctx):
    """The manifest decodes while copies and FontManifest stay encoded.

    `Uri.decodeFull` of every key (`asset.dart:923-929`) names the manifest
    entries; the copied files keep the encoded keys
    (`bundle_builder.dart:182`), as do the FontManifest assets
    (`flutter_manifest.dart:480`).
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_MANIFEST_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("mani_pkg", parsed.assets)
    fonts = normalize_spoke_fonts("mani_pkg", parsed.fonts)
    result = expand_pub_asset_entries(assets, _manifest_list_dir, "mani_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["a b.png", "enc c.png", "pct%.png", _CAFE_ENTRY],
        [e.path for e in result.expanded],
    )
    copy_keys = [e.key for e in result.expanded]
    asserts.equals(
        env,
        ["a%20b.png", "enc%20c.png", "pct%25.png", _CAFE_KEY],
        copy_keys,
    )
    manifest = build_asset_manifest(copy_keys)
    asserts.equals(
        env,
        ["a b.png", _CAFE_ENTRY, "enc c.png", "pct%.png"],
        sorted(manifest.keys()),
    )
    for key in ["a b.png", "enc c.png", "pct%.png", _CAFE_ENTRY]:
        asserts.equals(env, key, manifest[key][0]["asset"])
    spoke_fonts = encode_spoke_fonts(fonts)
    asserts.equals(
        env,
        {":fonts/a b.ttf": "fonts/a%20b.ttf", ":fonts/p%.ttf": "fonts/p%25.ttf"},
        spoke_fonts.font_files,
    )
    asserts.true(env, "fonts/a%20b.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    asserts.true(env, "fonts/p%25.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    return unittest.end(env)

# -- packages-first entries through the spoke -------------------------------------

# The declaring package's own accented file, built in pieces like
# `_CAFE_ENTRY`: the spellchecker never sees those three letters whole.
_PACKAGES_CAFE = "ca" + "f" + "\303\251" + ".png"
_PACKAGES_CAFE_KEY = "ca" + "f%C3%A9.png"

_PACKAGES_PUBSPEC = """\
name: d
flutter:
  assets:
    - packages/d/./a.png
    - packages/d/ca""" + "f%c3%a9.png\n" + """\
"""

_PACKAGES_FILES = {
    "packages/d": ["packages/d/a.png", "packages/d/" + _PACKAGES_CAFE],
}

def _packages_list_dir(directory):
    """Fake declaring-package listing holding the normalized files."""
    return struct(files = _PACKAGES_FILES.get(directory, []), error = "")

def _packages_first_spoke_test_impl(ctx):
    """`packages`-first entries naming own files normalize, then bundle.

    Dot segments collapse and escapes key uppercase, as flutter_tools reads
    them (`asset.dart:1402-1428`); the manifest decodes the keys while the
    copies keep them encoded.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_PACKAGES_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("d", parsed.assets)
    result = expand_pub_asset_entries(assets, _packages_list_dir, "d")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["packages/d/a.png", "packages/d/" + _PACKAGES_CAFE],
        [e.path for e in result.expanded],
    )
    copy_keys = [e.key for e in result.expanded]
    asserts.equals(
        env,
        ["packages/d/a.png", "packages/d/" + _PACKAGES_CAFE_KEY],
        copy_keys,
    )
    manifest = build_asset_manifest(copy_keys)
    asserts.equals(
        env,
        ["packages/d/a.png", "packages/d/" + _PACKAGES_CAFE],
        sorted(manifest.keys()),
    )
    return unittest.end(env)

_PACKAGES_BACKSLASH_PUBSPEC = "name: d\nflutter:\n  assets:\n    - packages/d/a\\b.png\n"

def _packages_backslash_bundles_test_impl(ctx):
    """A backslash `packages`-first spelling splits as `Uri.parse` splits it."""
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_PACKAGES_BACKSLASH_PUBSPEC)
    asserts.equals(env, 1, len(parsed.assets))
    assets = normalize_spoke_assets("d", parsed.assets)
    asserts.equals(env, "packages/d/a/b.png", assets[0].path)
    asserts.equals(env, "packages/d/a/b.png", assets[0].key)
    return unittest.end(env)

_REFUSED_PUBSPEC = """\
name: refused_pkg
flutter:
  assets:
    - a?.png
"""

def _through_refusal_test_impl(ctx):
    """A pubspec entry no engine build reads fails as not supported."""
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_REFUSED_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    asserts.equals(env, 1, len(parsed.assets))
    norm = normalize_asset_uri(parsed.assets[0].path)
    asserts.false(env, norm.ok, parsed.assets[0].path)
    message = spoke_asset_uri_error("refused_pkg", parsed.assets[0].path, norm.reason)
    for want in ["refused_pkg", "pubspec.yaml", "a?.png", "not supported"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _backslash_splits_like_uri_test_impl(ctx):
    """Raw backslashes split as `Uri.parse` splits them (RT37-flutter:01)."""
    env = unittest.begin(ctx)
    _check_ok(env, "assets\\sub\\bs.png", "assets/sub/bs.png", "assets/sub/bs.png")
    _check_ok(env, "assets\\dir\\", "assets/dir/", "assets/dir/", True)
    _check_ok(env, "assets\\..\\x.png", "x.png", "x.png")
    _check_ok(env, "a\\b/c", "a/b/c", "a/b/c")
    norm = normalize_asset_uri("a%5Cb.png")
    asserts.false(env, norm.ok, "a%5Cb.png")
    asserts.true(env, "backslash" in norm.reason, norm.reason)
    norm = normalize_asset_uri("\\a.png")
    asserts.false(env, norm.ok, "\\a.png")
    asserts.true(env, "absolute" in norm.reason, norm.reason)
    return unittest.end(env)

_DOUBLE_SLASH_PUBSPEC = """\
name: dbl_pkg
flutter:
  assets:
    - assets/e//em.png
  fonts:
    - family: Dbl
      fonts:
        - asset: fonts//f g.ttf
"""

_DOUBLE_SLASH_FILES = {
    "assets/e": ["assets/e/em.png"],
    "fonts": ["fonts/f g.ttf"],
}

def _double_slash_list_dir(directory):
    """Fake package listing: collapsed names, as the spoke lister reads them."""
    return struct(files = _DOUBLE_SLASH_FILES.get(directory, []), error = "")

def _empty_segment_keeps_key_test_impl(ctx):
    """An empty segment keys with `//` while the file collapses (RT37-flutter:01)."""
    env = unittest.begin(ctx)
    _check_ok(env, "assets/e//em.png", "assets/e/em.png", "assets/e//em.png")
    norm = normalize_asset_uri("/a.png")
    asserts.false(env, norm.ok, "/a.png")
    asserts.true(env, "absolute" in norm.reason, norm.reason)
    parsed = parse_flutter_assets_block(_DOUBLE_SLASH_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("dbl_pkg", parsed.assets)
    fonts = normalize_spoke_fonts("dbl_pkg", parsed.fonts)
    result = expand_pub_asset_entries(assets, _double_slash_list_dir, "dbl_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(env, ["assets/e/em.png"], [e.path for e in result.expanded])
    asserts.equals(env, ["assets/e//em.png"], [e.key for e in result.expanded])
    pkg_assets = build_pkg_assets_dict(result.expanded)
    asserts.equals(env, "assets/e//em.png", pkg_assets[":assets/e/em.png"])
    manifest = build_asset_manifest([e.key for e in result.expanded])
    asserts.equals(env, "assets/e//em.png", manifest["assets/e//em.png"][0]["asset"])
    spoke_fonts = encode_spoke_fonts(fonts)
    asserts.equals(env, {":fonts/f g.ttf": "fonts//f%20g.ttf"}, spoke_fonts.font_files)
    asserts.true(env, "fonts//f%20g.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "dbl_pkg",
            struct(assets = assets, fonts = fonts, shaders = parsed.shaders),
            result.expanded,
        ),
    )
    return unittest.end(env)

# -- map-form entries read literally (RT38-flutter:01) ----------------------------

def _check_map_ok(env, entry, decoded, key):
    """Assert one map-form entry reads literally to the file and key."""
    norm = normalize_asset_uri(entry, True)
    asserts.true(env, norm.ok, entry)
    asserts.equals(env, decoded, norm.decoded)
    asserts.equals(env, key, norm.key)

def _map_form_reads_literal_test_impl(ctx):
    """Map-form entries read like `Uri(pathSegments: path.split('/'))`.

    Oracle-checked against flutter_tools 3.47.7: a backslash never
    separates and a `%XX` never decodes, so the literal bytes name the
    file and re-encode into the key — where the string form of the same
    text would split and decode. A literal backslash still refuses, as on
    the base (no Bazel target can name it), and so do a leading `/`, a
    query and a fragment, matching what flutter_tools throws on.
    """
    env = unittest.begin(ctx)
    _check_map_ok(env, "m/b.png", "m/b.png", "m/b.png")
    _check_map_ok(env, "a%20b.png", "a%20b.png", "a%2520b.png")
    _check_map_ok(env, "x%2Ey.png", "x%2Ey.png", "x%252Ey.png")
    _check_map_ok(env, "g/./h.png", "g/h.png", "g/h.png")
    _check_ok(env, "m\\b.png", "m/b.png", "m/b.png")
    _check_ok(env, "a%20b.png", "a b.png", "a%20b.png")
    norm = normalize_asset_uri("m\\b.png", True)
    asserts.false(env, norm.ok, "map backslash")
    asserts.true(env, "backslash" in norm.reason, norm.reason)
    norm = normalize_asset_uri("/a.png", True)
    asserts.false(env, norm.ok, "map absolute")
    asserts.true(env, "absolute" in norm.reason, norm.reason)
    norm = normalize_asset_uri("img/a?.png", True)
    asserts.false(env, norm.ok, "map query")
    asserts.true(env, "query" in norm.reason, norm.reason)
    norm = normalize_asset_uri("img/a#.png", True)
    asserts.false(env, norm.ok, "map fragment")
    asserts.true(env, "fragment" in norm.reason, norm.reason)
    return unittest.end(env)

_MAP_FORM_PUBSPEC = """\
name: map_pkg
flutter:
  assets:
    - path: lit%20x.png
      platforms:
        - ios
    - path: dots/./ok.png
  shaders:
    - path: shaders/s%2Ehd.frag
"""

_MAP_FORM_FILES = {
    "": ["lit%20x.png"],
    "dots": ["dots/ok.png"],
    "shaders": ["shaders/s%2Ehd.frag"],
}

def _map_form_list_dir(directory):
    """Fake package listing: literal names, as the spoke lister reads them."""
    return struct(files = _MAP_FORM_FILES.get(directory, []), error = "")

def _map_form_entries_bundle_literal_test_impl(ctx):
    """Map-form entries resolve the literal files and key them re-encoded.

    Oracle-checked against flutter_tools 3.47.7: `- path: a%20b.png`
    bundles the `a%20b.png` file (manifest `a%20b.png`, copy
    `a%2520b.png`), and dot segments still resolve. Platforms travel
    untouched from the map entry to the merged conditions.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_MAP_FORM_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    asserts.equals(env, True, parsed.assets[0].is_map)
    asserts.equals(env, True, parsed.assets[1].is_map)
    asserts.equals(env, True, parsed.shaders[0].is_map)
    assets = normalize_spoke_assets("map_pkg", parsed.assets)
    shaders = normalize_spoke_shaders("map_pkg", parsed.shaders)
    result = expand_pub_asset_entries(assets, _map_form_list_dir, "map_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["lit%20x.png", "dots/ok.png"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["lit%2520x.png", "dots/ok.png"],
        [e.key for e in result.expanded],
    )
    pkg_assets = build_pkg_assets_dict(result.expanded)
    asserts.equals(env, "lit%2520x.png", pkg_assets[":lit%20x.png"])
    asserts.equals(env, "dots/ok.png", pkg_assets[":dots/ok.png"])
    merged = merge_pub_asset_conditions(result.expanded, "map_pkg")
    asserts.equals(env, "", merged.conflict)
    asserts.equals(env, ["ios"], merged.platforms.get(":lit%20x.png"))
    asserts.equals(
        env,
        {":shaders/s%2Ehd.frag": "shaders/s%252Ehd.frag"},
        build_pkg_shaders_dict(shaders),
    )
    manifest = build_asset_manifest([e.key for e in result.expanded])
    asserts.equals(env, ["dots/ok.png", "lit%20x.png"], sorted(manifest.keys()))
    asserts.equals(env, "lit%20x.png", manifest["lit%20x.png"][0]["asset"])
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "map_pkg",
            struct(assets = assets, fonts = [], shaders = shaders),
            result.expanded,
        ),
    )
    return unittest.end(env)

_MISSING_LITERAL_PUBSPEC = """\
name: miss_pkg
flutter:
  assets:
    - path: no%20pe.png
"""

def _missing_literal_fails_fetch_test_impl(ctx):
    """A map-form entry whose literal file is missing fails the fetch.

    Oracle-checked against flutter_tools 3.47.7: with no literal file on
    disk the build fails rather than bundling under a guessed key. The
    fetch failure names the package and the entry.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_MISSING_LITERAL_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("miss_pkg", parsed.assets)
    asserts.equals(env, "no%20pe.png", assets[0].path)
    asserts.equals(env, "no%2520pe.png", assets[0].key)
    result = expand_pub_asset_entries(assets, _through_list_dir, "miss_pkg")
    asserts.true(env, result.error != "", "a missing literal file fails")
    asserts.true(env, "miss_pkg" in result.error, result.error)
    asserts.true(env, "no%20pe.png" in result.error, result.error)
    return unittest.end(env)

# -- empty-segment entries in either form (RT38-flutter:02) ---------------------

_EMPTY_SEGMENT_FORMS_PUBSPEC = """\
name: es_pkg
flutter:
  assets:
    - a//2.0x/b.png
    - path: f//fm.png
"""

_EMPTY_SEGMENT_FORMS_FILES = {
    "a/2.0x": ["a/2.0x/b.png"],
    "f": ["f/fm.png"],
}

def _empty_segment_forms_list_dir(directory):
    """Fake package listing: collapsed names, as the spoke lister reads them."""
    return struct(files = _EMPTY_SEGMENT_FORMS_FILES.get(directory, []), error = "")

def _empty_segment_forms_bundle_raw_test_impl(ctx):
    """Empty-segment entries in either form key raw and copy collapsed.

    Oracle-checked against flutter_tools 3.47.7: string `a//2.0x/b.png`
    manifests as `a//2.0x/b.png` <- [`a//2.0x/b.png` dpr 2.0,
    `a/2.0x/b.png` dpr 2.0], and map `f//fm.png` as `f//fm.png` <-
    [`f//fm.png`, `f/fm.png`]. The copies read the collapsed files.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_EMPTY_SEGMENT_FORMS_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    asserts.equals(env, False, parsed.assets[0].is_map)
    asserts.equals(env, True, parsed.assets[1].is_map)
    assets = normalize_spoke_assets("es_pkg", parsed.assets)
    result = expand_pub_asset_entries(assets, _empty_segment_forms_list_dir, "es_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["a/2.0x/b.png", "f/fm.png"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["a//2.0x/b.png", "f//fm.png"],
        [e.key for e in result.expanded],
    )
    pkg_assets = build_pkg_assets_dict(result.expanded)
    asserts.equals(env, "a//2.0x/b.png", pkg_assets[":a/2.0x/b.png"])
    asserts.equals(env, "f//fm.png", pkg_assets[":f/fm.png"])
    manifest = build_asset_manifest([e.key for e in result.expanded])
    asserts.equals(env, ["a//2.0x/b.png", "f//fm.png"], sorted(manifest.keys()))
    variants = manifest["a//2.0x/b.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "a//2.0x/b.png", variants[0]["asset"])
    asserts.equals(env, 2.0, variants[0]["dpr"])
    asserts.equals(env, "a/2.0x/b.png", variants[1]["asset"])
    asserts.equals(env, 2.0, variants[1]["dpr"])
    variants = manifest["f//fm.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "f//fm.png", variants[0]["asset"])
    asserts.equals(env, "f/fm.png", variants[1]["asset"])
    return unittest.end(env)

# -- overlapping plain and empty-segment entries (RT38-flutter:02, B2) --------
#
# rules_flutter's `pkg_assets` carries one bundle key per file, so when two
# entries of one package give one file two different keys — only an empty
# segment can do that — the spoke fetch fails, naming the package and the
# empty-segment entry. A mixed list without such a pair bundles with
# flutter_tools' own keys (oracle-checked below).

_OVERLAP_PLAIN_RAW_PUBSPEC = """\
name: hpkg
flutter:
  assets:
    - a/b.png
    - a//b.png
"""

_OVERLAP_VARIANT_RAW_PUBSPEC = """\
name: hpkg
flutter:
  assets:
    - a/b.png
    - a//2.0x/b.png
"""

_OVERLAP_FILES = {
    "a": ["a/b.png", "a/2.0x/b.png"],
    "a/2.0x": ["a/2.0x/b.png"],
}

def _overlap_list_dir(directory):
    """Fake package listing: collapsed names, as the spoke lister reads them."""
    return struct(files = _OVERLAP_FILES.get(directory, []), error = "")

def _overlap_plain_raw_refuses_test_impl(ctx):
    """A plain entry beside its empty-segment twin fails the fetch.

    `a/b.png` and `a//b.png` give the `a/b.png` file two bundle keys, which
    `pkg_assets` cannot carry (RT38-flutter:02, amendment B2). The failure
    names the package and the empty-segment entry and says the spelling is
    not supported. Fails on the base, which bundles the mixture.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_OVERLAP_PLAIN_RAW_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("hpkg", parsed.assets)
    result = expand_pub_asset_entries(assets, _overlap_list_dir, "hpkg")
    asserts.true(env, result.error != "", "the two-key mixture fails the fetch")
    for want in ["hpkg", "a//b.png", "not supported"]:
        asserts.true(env, want in result.error, result.error)
    return unittest.end(env)

def _overlap_variant_raw_refuses_test_impl(ctx):
    """A plain entry beside a raw variant of its file fails the fetch.

    `a//2.0x/b.png` reads the `a/2.0x/b.png` file that the `a/b.png` entry
    already bundles as its variant, giving it a second key (RT38-flutter:02,
    amendment B2). The failure names the package and the empty-segment entry
    and says the spelling is not supported. Fails on the base, which bundles
    the mixture.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_OVERLAP_VARIANT_RAW_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("hpkg", parsed.assets)
    result = expand_pub_asset_entries(assets, _overlap_list_dir, "hpkg")
    asserts.true(env, result.error != "", "the two-key mixture fails the fetch")
    for want in ["hpkg", "a//2.0x/b.png", "not supported"]:
        asserts.true(env, want in result.error, result.error)
    return unittest.end(env)

_MIXED_PUBSPEC = """\
name: hpkg
flutter:
  assets:
    - c/d.png
    - e//em.png
    - path: 'f//fm.png'
    - path: 'a%20b.png'
    - path: 'g/./h.png'
"""

_MIXED_FILES = {
    "": ["a%20b.png"],
    "c": ["c/d.png", "c/2.0x/d.png"],
    "c/2.0x": ["c/2.0x/d.png"],
    "e": ["e/em.png"],
    "f": ["f/fm.png"],
    "g": ["g/h.png"],
}

def _mixed_list_dir(directory):
    """Fake package listing: collapsed names, as the spoke lister reads them."""
    return struct(files = _MIXED_FILES.get(directory, []), error = "")

def _mixed_without_overlap_bundles_test_impl(ctx):
    """A mixed list with no two-key pair bundles flutter_tools' own keys.

    Oracle-checked against flutter_tools 3.47.7 (`ManifestAssetBundle.build`
    over files `c/d.png`, `c/2.0x/d.png`, `e/em.png`, `f/fm.png`,
    `a%20b.png`, `g/h.png`): five `packages/hpkg/` keys — `a%20b.png` <-
    [`a%20b.png`], `c/d.png` <- [`c/d.png`, `c/2.0x/d.png` dpr 2.0],
    `e//em.png` <- [`e//em.png`, `e/em.png`], `f//fm.png` <- [`f//fm.png`,
    `f/fm.png`], `g/h.png` <- [`g/h.png`]. The literal `a%20b.png` file
    bundles under the re-encoded key: the map form reads literally.
    """
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_MIXED_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    asserts.equals(
        env,
        [False, False, True, True, True],
        [entry.is_map for entry in parsed.assets],
    )
    assets = normalize_spoke_assets("hpkg", parsed.assets)
    asserts.equals(
        env,
        ["c/d.png", "e/em.png", "f/fm.png", "a%20b.png", "g/h.png"],
        [entry.path for entry in assets],
    )
    asserts.equals(
        env,
        ["c/d.png", "e//em.png", "f//fm.png", "a%2520b.png", "g/h.png"],
        [entry.key for entry in assets],
    )
    result = expand_pub_asset_entries(assets, _mixed_list_dir, "hpkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["c/d.png", "c/2.0x/d.png", "e/em.png", "f/fm.png", "a%20b.png", "g/h.png"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["c/d.png", "c/2.0x/d.png", "e//em.png", "f//fm.png", "a%2520b.png", "g/h.png"],
        [e.key for e in result.expanded],
    )
    manifest = build_asset_manifest([e.key for e in result.expanded])
    asserts.equals(
        env,
        ["a%20b.png", "c/d.png", "e//em.png", "f//fm.png", "g/h.png"],
        sorted(manifest.keys()),
    )
    asserts.equals(env, [{"asset": "a%20b.png"}], manifest["a%20b.png"])
    variants = manifest["c/d.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "c/d.png", variants[0]["asset"])
    asserts.equals(env, "c/2.0x/d.png", variants[1]["asset"])
    asserts.equals(env, 2.0, variants[1]["dpr"])
    variants = manifest["e//em.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "e//em.png", variants[0]["asset"])
    asserts.equals(env, "e/em.png", variants[1]["asset"])
    variants = manifest["f//fm.png"]
    asserts.equals(env, 2, len(variants))
    asserts.equals(env, "f//fm.png", variants[0]["asset"])
    asserts.equals(env, "f/fm.png", variants[1]["asset"])
    asserts.equals(env, [{"asset": "g/h.png"}], manifest["g/h.png"])
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "hpkg",
            struct(assets = assets, fonts = [], shaders = []),
            result.expanded,
        ),
    )
    return unittest.end(env)

def _trailing_dot_directories_test_impl(ctx):
    """Trailing dot segments resolve as directories per RFC 3986 §5.2.4."""
    env = unittest.begin(ctx)
    _check_ok(env, "assets/.", "assets/", "assets/", is_dir = True)
    _check_ok(env, "assets/%2E", "assets/", "assets/", is_dir = True)
    _check_ok(env, "assets/b/..", "assets/", "assets/", is_dir = True)
    _check_ok(env, "a//.", "a/", "a//", is_dir = True)
    _check_ok(env, "a//..", "a/", "a/", is_dir = True)
    _check_ok(env, "a/./.", "a/", "a/", is_dir = True)
    _check_ok(env, "x/.", "x/", "x/", is_dir = True)
    _check_ok(env, "a b/.", "a b/", "a%20b/", is_dir = True)
    _check_ok(env, "ca" + "f%C3%A9/.", "ca" + "f" + "\303\251" + "/", "ca" + "f%C3%A9/", is_dir = True)

    norm_map = normalize_asset_uri("%2E/.", is_map = True)
    asserts.true(env, norm_map.ok, "%2E/.")
    asserts.equals(env, "%2E/", norm_map.decoded)
    asserts.equals(env, "%252E/", norm_map.key)
    asserts.equals(env, True, norm_map.is_dir)

    for refused in [".", "./", "assets/..", "%2E", "%2E/."]:
        norm = normalize_asset_uri(refused)
        asserts.false(env, norm.ok, refused)
        asserts.true(env, "names no file" in norm.reason, refused + " -> " + norm.reason)

    for escaped in ["..", "../", "assets/../.."]:
        norm = normalize_asset_uri(escaped)
        asserts.false(env, norm.ok, escaped)
        asserts.true(env, "escapes the package" in norm.reason, escaped + " -> " + norm.reason)

    return unittest.end(env)

def _reserved_characters_pkg_key_test_impl(ctx):
    """Reserved characters stay encoded in norm.key but decode in norm.pkg_key."""
    env = unittest.begin(ctx)
    norm_at = normalize_asset_uri("assets/%40")
    asserts.true(env, norm_at.ok)
    asserts.equals(env, "assets/@", norm_at.decoded)
    asserts.equals(env, "assets/%40", norm_at.key)
    asserts.equals(env, "assets/@", norm_at.pkg_key)
    asserts.equals(env, "assets/%40", pub_bundle_key("", "assets/%40"))
    asserts.equals(env, "packages/p/assets/@", pub_bundle_key("packages/p/", "assets/%40"))

    norm_comma = normalize_asset_uri("a%2Cb.png")
    asserts.true(env, norm_comma.ok)
    asserts.equals(env, "a,b.png", norm_comma.decoded)
    asserts.equals(env, "a%2Cb.png", norm_comma.key)
    asserts.equals(env, "a,b.png", norm_comma.pkg_key)
    asserts.equals(env, "a%2Cb.png", pub_bundle_key("", "a%2Cb.png"))
    asserts.equals(env, "packages/p/a,b.png", pub_bundle_key("packages/p/", "a%2Cb.png"))

    norm_lit = normalize_asset_uri("assets/@")
    asserts.true(env, norm_lit.ok)
    asserts.equals(env, "assets/@", norm_lit.decoded)
    asserts.equals(env, "assets/@", norm_lit.key)
    asserts.equals(env, "assets/@", norm_lit.pkg_key)

    norm_map = normalize_asset_uri("assets/%40", is_map = True)
    asserts.true(env, norm_map.ok)
    asserts.equals(env, "assets/%40", norm_map.decoded)
    asserts.equals(env, "assets/%2540", norm_map.key)
    asserts.equals(env, "assets/%2540", norm_map.pkg_key)

    assets_pkg = normalize_spoke_assets("my_pkg", [struct(path = "assets/%40", is_map = False, flavors = [], platforms = [])])
    asserts.equals(env, "assets/@", assets_pkg[0].key)
    assets_root = normalize_spoke_assets("", [struct(path = "assets/%40", is_map = False, flavors = [], platforms = [])])
    asserts.equals(env, "assets/%40", assets_root[0].key)

    fonts_pkg = normalize_spoke_fonts("my_pkg", [struct(family = "F", fonts = [struct(asset = "fonts/%40.ttf", weight = 400, style = "normal")])])
    asserts.equals(env, "fonts/@.ttf", fonts_pkg[0].fonts[0].key)

    shaders_pkg = normalize_spoke_shaders("my_pkg", [struct(path = "shaders/%40.frag", is_map = False)])
    asserts.equals(env, "shaders/@.frag", shaders_pkg[0].key)

    return unittest.end(env)

_t0_test = unittest.make(_plain_entry_passes_through_test_impl)
_t1_test = unittest.make(_spaced_entry_encodes_test_impl)
_t2_test = unittest.make(_dot_entries_resolve_test_impl)
_t3_test = unittest.make(_escapes_decode_first_test_impl)
_t4_test = unittest.make(_non_ascii_matches_dart_test_impl)
_t5_test = unittest.make(_packages_first_passes_through_test_impl)
_t6_test = unittest.make(_refusals_name_the_spelling_test_impl)
_t7_test = unittest.make(_printable_ascii_round_trip_test_impl)
_t8_test = unittest.make(_encode_asset_key_never_refuses_test_impl)
_t9_test = unittest.make(_pub_bundle_key_test_impl)
_t10_test = unittest.make(_spoke_error_names_package_test_impl)
_t11_test = unittest.make(_through_pub_package_test_impl)
_t12_test = unittest.make(_through_refusal_test_impl)
_t13_test = unittest.make(_escaped_entries_bundle_encoded_test_impl)
_t14_test = unittest.make(_manifest_decoded_copies_encoded_test_impl)
_t15_test = unittest.make(_packages_first_spoke_test_impl)
_t16_test = unittest.make(_packages_backslash_bundles_test_impl)
_t17_test = unittest.make(_backslash_splits_like_uri_test_impl)
_t18_test = unittest.make(_empty_segment_keeps_key_test_impl)
_t19_test = unittest.make(_map_form_reads_literal_test_impl)
_t20_test = unittest.make(_map_form_entries_bundle_literal_test_impl)
_t21_test = unittest.make(_missing_literal_fails_fetch_test_impl)
_t22_test = unittest.make(_empty_segment_forms_bundle_raw_test_impl)
_t23_test = unittest.make(_overlap_plain_raw_refuses_test_impl)
_t24_test = unittest.make(_overlap_variant_raw_refuses_test_impl)
_t25_test = unittest.make(_mixed_without_overlap_bundles_test_impl)
_t26_test = unittest.make(_trailing_dot_directories_test_impl)
_t27_test = unittest.make(_reserved_characters_pkg_key_test_impl)

def asset_uri_test_suite(name):
    """Defines the asset-URI normalization unit and through tests.

    Args:
        name: Name of the resulting test_suite.
    """
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
        _t13_test,
        _t14_test,
        _t15_test,
        _t16_test,
        _t17_test,
        _t18_test,
        _t19_test,
        _t20_test,
        _t21_test,
        _t22_test,
        _t23_test,
        _t24_test,
        _t25_test,
        _t26_test,
        _t27_test,
    )
