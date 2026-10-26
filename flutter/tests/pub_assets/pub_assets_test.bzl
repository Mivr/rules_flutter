"""Tests for variant-aware pub asset expansion and strict asset conditions.

Covers the flutter_tools parity rules (`flutter_pub_assets.bzl`): file
entries bundle their main file plus resolution variants (variant-only
entries are accepted; missing mains fail), directory entries bundle their
own files plus variants (no recursion), walks fail loudly at their bound,
and the entry parser refuses non-list `platforms` / `flavors` and
`transformers` while ignoring other unknown keys.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_assets.bzl",
    "asset_entry_problem_error",
    "ctx_package_lister",
    "expand_pub_asset_entries",
    "is_asset_variant_dir",
    "list_files_recursive",
)
load("//flutter/private:flutter_pub_package.bzl", "check_spoke_file_names")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

# -- variant directory names ------------------------------------------------------

def _variant_dir_names_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["2x", "2.0x", "3.0x", "1.5x", "10x", "4x"]:
        asserts.true(env, is_asset_variant_dir(name), "%s is a variant dir" % name)
    for name in ["sub", "icons", "x", "foo", "2xx", "2xyz"]:
        asserts.false(env, is_asset_variant_dir(name), "%s is not a variant dir" % name)
    return unittest.end(env)

# -- bounded walk -------------------------------------------------------------------

_WALK_TREE = {
    "img": [
        struct(name = "logo.png", is_dir = False),
        struct(name = "2.0x", is_dir = True),
        struct(name = "sub", is_dir = True),
    ],
    "img/2.0x": [struct(name = "logo.png", is_dir = False)],
    "img/sub": [struct(name = "deep.png", is_dir = False)],
}

def _fake_readdir(directory):
    return _WALK_TREE.get(directory, [])

def _walk_lists_all_files_test_impl(ctx):
    env = unittest.begin(ctx)
    result = list_files_recursive(_fake_readdir, "img", "walk_pkg", 100)
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["img/2.0x/logo.png", "img/logo.png", "img/sub/deep.png"],
        sorted(result.files),
    )
    return unittest.end(env)

def _walk_bound_fails_loudly_test_impl(ctx):
    """A walk that reaches its bound reports the package and directory."""
    env = unittest.begin(ctx)
    result = list_files_recursive(_fake_readdir, "img", "walk_pkg", 1)
    asserts.equals(env, [], result.files)
    asserts.true(env, "walk_pkg" in result.error, result.error)
    asserts.true(env, "img" in result.error, result.error)
    return unittest.end(env)

# -- expansion ------------------------------------------------------------------------

_FAKE_FILES = {
    "img": [
        "img/logo.png",
        "img/banner.png",
        "img/2.0x/logo.png",
        "img/3.0x/logo.png",
        "img/2.0x/banner.png",
        "img/sub/deep.png",
    ],
    "lonely": ["lonely/2.0x/ghost.png"],
}

def _fake_list_dir(directory):
    return struct(files = _FAKE_FILES.get(directory, []), error = "")

def _file_entry_bundles_main_and_variants_test_impl(ctx):
    """The main file plus every variant, each with the entry's conditions."""
    env = unittest.begin(ctx)
    entries = [
        struct(path = "img/logo.png", key = "img/logo.png", flavors = ["paid"], platforms = ["ios"]),
    ]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["img/logo.png", "img/2.0x/logo.png", "img/3.0x/logo.png"],
        [e.path for e in result.expanded],
    )
    for entry in result.expanded:
        asserts.equals(env, ["paid"], entry.flavors)
        asserts.equals(env, ["ios"], entry.platforms)
    return unittest.end(env)

def _variant_only_entry_accepted_test_impl(ctx):
    """A missing main with variants bundles the variants, no error."""
    env = unittest.begin(ctx)
    entries = [struct(path = "lonely/ghost.png", key = "lonely/ghost.png", flavors = [], platforms = [])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(env, ["lonely/2.0x/ghost.png"], [e.path for e in result.expanded])
    return unittest.end(env)

def _missing_entry_fails_test_impl(ctx):
    """Neither main nor variant fails naming the package and the entry."""
    env = unittest.begin(ctx)
    entries = [struct(path = "img/absent.png", key = "img/absent.png", flavors = [], platforms = [])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, [], result.expanded)
    asserts.true(env, "variant_pkg" in result.error, result.error)
    asserts.true(env, "img/absent.png" in result.error, result.error)
    return unittest.end(env)

def _directory_entry_skips_nested_test_impl(ctx):
    """Own files plus their variants bundle; nested subdirectories do not."""
    env = unittest.begin(ctx)
    entries = [struct(path = "img/", key = "img/", flavors = [], platforms = ["android"])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        [
            "img/banner.png",
            "img/2.0x/banner.png",
            "img/logo.png",
            "img/2.0x/logo.png",
            "img/3.0x/logo.png",
        ],
        [e.path for e in result.expanded],
    )
    for entry in result.expanded:
        asserts.equals(env, ["android"], entry.platforms)
    return unittest.end(env)

def _directory_bound_error_propagates_test_impl(ctx):
    """A listing failure reaches the caller instead of truncating silently."""
    env = unittest.begin(ctx)

    def _failing_list_dir(directory):
        return struct(files = [], error = "walk refused for " + directory)

    result = expand_pub_asset_entries(
        [struct(path = "img/", key = "img/", flavors = [], platforms = [])],
        _failing_list_dir,
        "variant_pkg",
    )
    asserts.equals(env, [], result.expanded)
    asserts.true(env, "img" in result.error, result.error)
    return unittest.end(env)

# -- strict entry conditions ------------------------------------------------------------

_SCALAR_PLATFORMS_PUBSPEC = """\
name: scalar_platforms
flutter:
  assets:
    - path: assets/pic.png
      platforms: web
"""

_SCALAR_FLAVORS_PUBSPEC = """\
name: scalar_flavors
flutter:
  assets:
    - path: assets/pic.png
      flavors: paid
"""

_MIXED_ELEMENTS_PUBSPEC = """\
name: mixed_elements
flutter:
  assets:
    - path: assets/pic.png
      platforms:
        - ios
        - 5
"""

_TRANSFORMERS_PUBSPEC = """\
name: transformed
flutter:
  assets:
    - path: assets/pic.png
      transformers:
        - package: weave
"""

_UNKNOWN_KEYS_PUBSPEC = """\
name: unknown_keys
flutter:
  assets:
    - path: assets/kept.png
      platforms:
        - ios
      extra_key: ignored
    - path: assets/plain.png
      transformers:
"""

def _scalar_platforms_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SCALAR_PLATFORMS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "assets/pic.png", problem.path)
    asserts.equals(env, "platforms", problem.key)
    message = asset_entry_problem_error("scalar_pkg", problem)
    for want in ["scalar_pkg", "assets/pic.png", "platforms"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _scalar_flavors_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SCALAR_FLAVORS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "assets/pic.png", problem.path)
    asserts.equals(env, "flavors", problem.key)
    message = asset_entry_problem_error("scalar_pkg", problem)
    for want in ["scalar_pkg", "assets/pic.png", "flavors"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _non_string_element_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_MIXED_ELEMENTS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "platforms", problem.key)
    message = asset_entry_problem_error("mixed_pkg", problem)
    for want in ["mixed_pkg", "assets/pic.png", "platforms"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _transformers_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_TRANSFORMERS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "transformers", problem.key)
    message = asset_entry_problem_error("weave_pkg", problem)
    for want in ["weave_pkg", "assets/pic.png"]:
        asserts.true(env, want in message, message)
    asserts.true(
        env,
        "asset transformers are not supported by rules_flutter" in message,
        message,
    )
    return unittest.end(env)

def _unknown_keys_ignored_test_impl(ctx):
    """Keys flutter_tools ignores (and a null `transformers:`) stay accepted."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_UNKNOWN_KEYS_PUBSPEC)
    asserts.equals(env, [], result.asset_errors)
    asserts.equals(env, 2, len(result.assets))
    asserts.equals(env, "assets/kept.png", result.assets[0].path)
    asserts.equals(env, ["ios"], result.assets[0].platforms)
    return unittest.end(env)

_EMPTY_TRANSFORMERS_PUBSPEC = """\
name: empty_transformers
flutter:
  assets:
    - path: assets/a.png
      transformers: []
    - path: assets/b.png
      transformers: null
  shaders:
    - path: shaders/a.frag
      transformers: []
    - path: shaders/b.frag
      transformers: null
  deferred-components:
    - name: c1
      assets:
        - path: assets/c1.png
          transformers: []
    - name: c2
      assets:
        - path: assets/c2.png
          transformers: null
"""

def _empty_transformers_accepted_test_impl(ctx):
    """Empty list or null `transformers` are valid no-ops across assets, shaders, deferred."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_EMPTY_TRANSFORMERS_PUBSPEC)
    asserts.equals(env, [], result.asset_errors)
    asserts.equals(env, 2, len(result.assets))
    asserts.equals(env, 2, len(result.shaders))
    return unittest.end(env)

_MALFORMED_TRANSFORMERS_ASSETS_SCALAR = """\
name: bad_assets_trans_scalar
flutter:
  assets:
    - path: assets/a.png
      transformers: 42
"""

_MALFORMED_TRANSFORMERS_ASSETS_ITEMS = """\
name: bad_assets_trans_items
flutter:
  assets:
    - path: assets/a.png
      transformers:
        - bad
        - 123
"""

_MALFORMED_TRANSFORMERS_SHADERS_SCALAR = """\
name: bad_shaders_trans_scalar
flutter:
  shaders:
    - path: shaders/s.frag
      transformers: bad
"""

_MALFORMED_TRANSFORMERS_SHADERS_ITEMS = """\
name: bad_shaders_trans_items
flutter:
  shaders:
    - path: shaders/s.frag
      transformers:
        - 123
"""

_MALFORMED_TRANSFORMERS_DEFERRED_SCALAR = """\
name: bad_deferred_trans_scalar
flutter:
  deferred-components:
    - name: c
      assets:
        - path: assets/d.png
          transformers: 42
"""

_MALFORMED_TRANSFORMERS_DEFERRED_ITEMS = """\
name: bad_deferred_trans_items
flutter:
  deferred-components:
    - name: c
      assets:
        - path: assets/d.png
          transformers:
            - bad
"""

def _malformed_transformers_refused_test_impl(ctx):
    """Non-list or non-map transformers refuse with flutter_tools error."""
    env = unittest.begin(ctx)
    cases = [
        (_MALFORMED_TRANSFORMERS_ASSETS_SCALAR, "Expected transformers list to be a list of Map, but got 42 (int)."),
        (_MALFORMED_TRANSFORMERS_ASSETS_ITEMS, "Expected transformers list to be a list of Map, but element at index 0 was a String.\nExpected transformers list to be a list of Map, but element at index 1 was a int."),
        (_MALFORMED_TRANSFORMERS_SHADERS_SCALAR, "Expected transformers list to be a list of Map, but got bad (String)."),
        (_MALFORMED_TRANSFORMERS_SHADERS_ITEMS, "Expected transformers list to be a list of Map, but element at index 0 was a int."),
        (_MALFORMED_TRANSFORMERS_DEFERRED_SCALAR, "Expected transformers list to be a list of Map, but got 42 (int)."),
        (_MALFORMED_TRANSFORMERS_DEFERRED_ITEMS, "Expected transformers list to be a list of Map, but element at index 0 was a String."),
    ]
    for pubspec, expected_error in cases:
        r = parse_flutter_assets_block(pubspec)
        asserts.equals(env, 1, len(r.asset_errors))
        asserts.equals(env, "transformers", r.asset_errors[0].key)
        asserts.true(env, expected_error in r.asset_errors[0].detail, r.asset_errors[0].detail)
    return unittest.end(env)

_NONEMPTY_TRANSFORMERS_SHADERS_PUBSPEC = """\
name: bad_shaders_trans_nonempty
flutter:
  shaders:
    - path: shaders/s.frag
      transformers:
        - package: weave
"""

_NONEMPTY_TRANSFORMERS_DEFERRED_PUBSPEC = """\
name: bad_deferred_trans_nonempty
flutter:
  deferred-components:
    - name: c
      assets:
        - path: assets/d.png
          transformers:
            - package: weave
"""

def _shader_and_deferred_transformers_refused_test_impl(ctx):
    """Non-empty transformers on shaders or deferred-components refuse."""
    env = unittest.begin(ctx)
    for pubspec in [_NONEMPTY_TRANSFORMERS_SHADERS_PUBSPEC, _NONEMPTY_TRANSFORMERS_DEFERRED_PUBSPEC]:
        r = parse_flutter_assets_block(pubspec)
        asserts.equals(env, 1, len(r.asset_errors))
        asserts.equals(env, "transformers", r.asset_errors[0].key)
        asserts.true(
            env,
            "asset transformers are not supported by rules_flutter." in r.asset_errors[0].detail,
            r.asset_errors[0].detail,
        )
    return unittest.end(env)

# -- refused pubspec shapes (COV-75) ------------------------------------------------------
#
# Every shape below is one flutter_tools 3.47.7 refuses
# (`packages/flutter_tools/lib/src/flutter_manifest.dart`) that the
# projection used to drop silently. Each test pins the refusal: the
# parsed block carries an `asset_errors` entry naming the section key,
# the spoke message names the package and the key, and nothing usable
# survives the refused section.

_STRING_ASSETS_PUBSPEC = """\
name: string_assets
flutter:
  assets: assets/a.png
"""

_MAP_ASSETS_PUBSPEC = """\
name: map_assets
flutter:
  assets: {a: b}
"""

_BAD_ITEM_ASSETS_PUBSPEC = """\
name: bad_item_assets
flutter:
  assets:
    - 5
"""

_BAD_PATH_ASSETS_PUBSPEC = """\
name: bad_path_assets
flutter:
  assets:
    - path: 5
"""

_STRING_FONTS_PUBSPEC = """\
name: string_fonts
flutter:
  fonts: x
"""

_INT_LIST_FONTS_PUBSPEC = """\
name: int_list_fonts
flutter:
  fonts: [1]
"""

_BAD_FAMILY_FONTS_PUBSPEC = """\
name: bad_family_fonts
flutter:
  fonts: [{family: 1}]
"""

_BAD_FONTS_KEY_FONTS_PUBSPEC = """\
name: bad_fonts_key_fonts
flutter:
  fonts: [{family: F, fonts: x}]
"""

_BAD_FILE_FONTS_PUBSPEC = """\
name: bad_file_fonts
flutter:
  fonts:
    - family: F
      fonts:
        - 5
"""

_BAD_FILE_ASSET_FONTS_PUBSPEC = """\
name: bad_file_asset_fonts
flutter:
  fonts:
    - family: F
      fonts:
        - asset: 5
"""

_STRING_SHADERS_PUBSPEC = """\
name: string_shaders
flutter:
  shaders: x
"""

_BAD_ITEM_SHADERS_PUBSPEC = """\
name: bad_item_shaders
flutter:
  shaders:
    - 5
"""

_BAD_PATH_SHADERS_PUBSPEC = """\
name: bad_path_shaders
flutter:
  shaders:
    - path: 5
"""

def _assert_shape_refused(env, content, key):
    """Assert parsing `content` refuses the `key` section for the fetch.

    Every problem names the section key, and the spoke message built from
    it names the package, the entry and the key.

    Args:
        env: The unittest environment.
        content: Full pubspec.yaml content with a malformed section.
        key: `"assets"`, `"fonts"` or `"shaders"`.

    Returns:
        The parsed block, so the caller can pin what survived refusal.
    """
    result = parse_flutter_assets_block(content)
    asserts.true(env, len(result.asset_errors) > 0, "expected an %s refusal" % key)
    for problem in result.asset_errors:
        asserts.equals(env, key, problem.key)
        message = asset_entry_problem_error("shape_pkg", problem)
        for want in ["shape_pkg", problem.path, key]:
            asserts.true(env, want in message, message)
    return result

def _string_assets_refused_test_impl(ctx):
    """A string `assets` section fails naming the package and the key."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _STRING_ASSETS_PUBSPEC, "assets")
    asserts.equals(env, [], result.assets)
    return unittest.end(env)

def _map_assets_refused_test_impl(ctx):
    """A map `assets` section fails instead of bundling no assets."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _MAP_ASSETS_PUBSPEC, "assets")
    asserts.equals(env, [], result.assets)
    return unittest.end(env)

def _bad_item_assets_refused_test_impl(ctx):
    """An asset item that is neither a string nor a map fails."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_ITEM_ASSETS_PUBSPEC, "assets")
    asserts.equals(env, [], result.assets)
    return unittest.end(env)

def _bad_path_assets_refused_test_impl(ctx):
    """An asset map whose `path` is not a string fails."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_PATH_ASSETS_PUBSPEC, "assets")
    asserts.equals(env, [], result.assets)
    return unittest.end(env)

def _string_fonts_refused_test_impl(ctx):
    """A string `fonts` section fails naming the package and the key."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _STRING_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, [], result.fonts)
    return unittest.end(env)

def _int_list_fonts_refused_test_impl(ctx):
    """A non-map `fonts` entry fails instead of dropping the family."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _INT_LIST_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, [], result.fonts)
    return unittest.end(env)

def _bad_family_fonts_refused_test_impl(ctx):
    """A non-string font `family` fails instead of dropping the family."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_FAMILY_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, [], result.fonts)
    return unittest.end(env)

def _bad_fonts_key_fonts_refused_test_impl(ctx):
    """A non-list per-family `fonts` fails instead of emptying the family."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_FONTS_KEY_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, [], result.fonts)
    return unittest.end(env)

def _bad_file_fonts_refused_test_impl(ctx):
    """A non-map font file entry fails while the family still parses."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_FILE_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, "F", result.fonts[0].family)
    asserts.equals(env, [], result.fonts[0].fonts)
    return unittest.end(env)

def _bad_file_asset_fonts_refused_test_impl(ctx):
    """A non-string font file `asset` fails while the family still parses."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_FILE_ASSET_FONTS_PUBSPEC, "fonts")
    asserts.equals(env, 1, len(result.fonts))
    asserts.equals(env, "F", result.fonts[0].family)
    asserts.equals(env, [], result.fonts[0].fonts)
    return unittest.end(env)

def _string_shaders_refused_test_impl(ctx):
    """A string `shaders` section fails naming the package and the key."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _STRING_SHADERS_PUBSPEC, "shaders")
    asserts.equals(env, [], result.shaders)
    return unittest.end(env)

def _bad_item_shaders_refused_test_impl(ctx):
    """A shader item that is neither a string nor a map fails."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_ITEM_SHADERS_PUBSPEC, "shaders")
    asserts.equals(env, [], result.shaders)
    return unittest.end(env)

def _bad_path_shaders_refused_test_impl(ctx):
    """A shader map whose `path` is not a string fails."""
    env = unittest.begin(ctx)
    result = _assert_shape_refused(env, _BAD_PATH_SHADERS_PUBSPEC, "shaders")
    asserts.equals(env, [], result.shaders)
    return unittest.end(env)

# -- linear expansion at scale (M-9) ------------------------------------------------------
#
# One directory entry plus one file entry per file over 4,000 files, with
# variants, expands exactly as the quadratic code did, while the listing is
# read once per directory however many entries name it. The spoke reader
# below the expansion reads only what flutter_tools reads — the directory's
# own files plus its immediate variant subdirectories' files — so deeper
# non-variant directories are never read, and every read still fails loudly
# at its bound.

_BIG_COUNT = 4000
_BIG_MAINS = ["big/f" + str(i) + ".png" for i in range(_BIG_COUNT)]
_BIG_VARIANTS = ["big/2.0x/f" + str(i) + ".png" for i in range(_BIG_COUNT) if i % 2 == 0]
_BIG_FILES = _BIG_MAINS + _BIG_VARIANTS

def _counting_list_dir(files_by_dir):
    """A `list_dir` fake over `files_by_dir` recording every directory read.

    Args:
        files_by_dir: Dict from directory path to that directory's files.

    Returns:
        A struct `(list_dir, calls)`: the fake and its read log.
    """
    calls = []

    def list_dir(directory):
        calls.append(directory)
        return struct(files = files_by_dir.get(directory, []), error = "")

    return struct(list_dir = list_dir, calls = calls)

def _big_variants_by_main():
    """Map each big main file to its variant path, for the want list."""
    variants = {}
    for path in _BIG_VARIANTS:
        variants["big/" + path.rpartition("/")[2]] = path
    return variants

def _big_directory_and_file_entries_expand_test_impl(ctx):
    """4,000 files expand identically through one directory and 4,000 file entries."""
    env = unittest.begin(ctx)
    entries = [struct(path = "big/", key = "big/", flavors = [], platforms = [])]
    for main in _BIG_MAINS:
        entries.append(struct(path = main, key = main, flavors = [], platforms = []))
    counter = _counting_list_dir({"big": _BIG_FILES})
    result = expand_pub_asset_entries(entries, counter.list_dir, "big_pkg")
    asserts.equals(env, "", result.error)
    by_main = _big_variants_by_main()
    want = []
    for main in sorted(_BIG_MAINS):
        want.append(main)
        if main in by_main:
            want.append(by_main[main])
    for main in _BIG_MAINS:
        want.append(main)
        if main in by_main:
            want.append(by_main[main])
    asserts.equals(env, want, [e.path for e in result.expanded])
    asserts.equals(env, ["big"], counter.calls)
    return unittest.end(env)

_DEEP_TREE = {
    "img": [
        struct(name = "a.png", is_dir = False),
        struct(name = "b.png", is_dir = False),
        struct(name = "2.0x", is_dir = True),
        struct(name = "sub", is_dir = True),
    ],
    "img/2.0x": [struct(name = "a.png", is_dir = False)],
    "img/sub": [struct(name = "deep.png", is_dir = False)],
}

def _recording_repo_ctx(tree):
    """A repository-ctx fake over a flat directory tree, recording reads.

    Covers the `ctx.path` surface `ctx_package_lister` reads: a missing
    directory reports `exists = False`, a listed one answers `readdir()`
    with its immediate children.

    Args:
        tree: Dict from package-relative directory path to its children as
            `struct(name, is_dir)` lists. A missing key reads as missing.

    Returns:
        A struct `(ctx, reads)`: the fake ctx and its `path()` call log.
    """
    reads = []

    def path(rel):
        reads.append(rel)
        key = "" if rel == "." else rel
        if key not in tree:
            return struct(exists = False)
        children = tree[key]

        def readdir():
            return [struct(basename = child.name, is_dir = child.is_dir) for child in children]

        return struct(exists = True, readdir = readdir)

    return struct(ctx = struct(path = path), reads = reads)

def _shallow_lister_reads_once_and_skips_deep_test_impl(ctx):
    """The spoke reader reads each directory once and never a deep non-variant dir."""
    env = unittest.begin(ctx)
    fake = _recording_repo_ctx(_DEEP_TREE)
    lister = ctx_package_lister(fake.ctx, "deep_pkg", 100)
    entries = [
        struct(path = "img/", key = "img/", flavors = [], platforms = []),
        struct(path = "img/a.png", key = "img/a.png", flavors = [], platforms = []),
        struct(path = "img/b.png", key = "img/b.png", flavors = [], platforms = []),
    ]
    result = expand_pub_asset_entries(entries, lister, "deep_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        [
            "img/a.png",
            "img/2.0x/a.png",
            "img/b.png",
            "img/a.png",
            "img/2.0x/a.png",
            "img/b.png",
        ],
        [e.path for e in result.expanded],
    )
    asserts.equals(env, ["img", "img/2.0x"], fake.reads)
    return unittest.end(env)

def _shallow_lister_bound_fails_loudly_test_impl(ctx):
    """A directory with more reads than the bound fails naming package, dir, bound."""
    env = unittest.begin(ctx)
    tree = {"many": [struct(name = str(i) + "x", is_dir = True) for i in range(5)]}
    fake = _recording_repo_ctx(tree)
    lister = ctx_package_lister(fake.ctx, "bound_pkg", 3)
    result = expand_pub_asset_entries(
        [struct(path = "many/", key = "many/", flavors = [], platforms = [])],
        lister,
        "bound_pkg",
    )
    asserts.equals(env, [], result.expanded)
    for want in ["bound_pkg", "many", "3"]:
        asserts.true(env, want in result.error, result.error)
    asserts.equals(env, ["many"], fake.reads)
    return unittest.end(env)

def _covering_entries_resolve_at_scale_test_impl(ctx):
    """4,000 file entries under one directory entry all resolve through the lookup."""
    env = unittest.begin(ctx)
    assets = [struct(path = "big/")]
    for main in _BIG_MAINS:
        assets.append(struct(path = main))
    block = struct(assets = assets, fonts = [], shaders = [])
    expanded = [struct(path = main) for main in _BIG_MAINS]
    asserts.equals(env, None, check_spoke_file_names("big_pkg", block, expanded))
    return unittest.end(env)

_t0_test = unittest.make(_variant_dir_names_test_impl)
_t1_test = unittest.make(_walk_lists_all_files_test_impl)
_t2_test = unittest.make(_walk_bound_fails_loudly_test_impl)
_t3_test = unittest.make(_file_entry_bundles_main_and_variants_test_impl)
_t4_test = unittest.make(_variant_only_entry_accepted_test_impl)
_t5_test = unittest.make(_missing_entry_fails_test_impl)
_t6_test = unittest.make(_directory_entry_skips_nested_test_impl)
_t7_test = unittest.make(_directory_bound_error_propagates_test_impl)
_t8_test = unittest.make(_scalar_platforms_refused_test_impl)
_t9_test = unittest.make(_scalar_flavors_refused_test_impl)
_t10_test = unittest.make(_non_string_element_refused_test_impl)
_t11_test = unittest.make(_transformers_refused_test_impl)
_t12_test = unittest.make(_unknown_keys_ignored_test_impl)
_t13_test = unittest.make(_string_assets_refused_test_impl)
_t14_test = unittest.make(_map_assets_refused_test_impl)
_t15_test = unittest.make(_bad_item_assets_refused_test_impl)
_t16_test = unittest.make(_bad_path_assets_refused_test_impl)
_t17_test = unittest.make(_string_fonts_refused_test_impl)
_t18_test = unittest.make(_int_list_fonts_refused_test_impl)
_t19_test = unittest.make(_bad_family_fonts_refused_test_impl)
_t20_test = unittest.make(_bad_fonts_key_fonts_refused_test_impl)
_t21_test = unittest.make(_bad_file_fonts_refused_test_impl)
_t22_test = unittest.make(_bad_file_asset_fonts_refused_test_impl)
_t23_test = unittest.make(_string_shaders_refused_test_impl)
_t24_test = unittest.make(_bad_item_shaders_refused_test_impl)
_t25_test = unittest.make(_bad_path_shaders_refused_test_impl)
_t26_test = unittest.make(_big_directory_and_file_entries_expand_test_impl)
_t27_test = unittest.make(_shallow_lister_reads_once_and_skips_deep_test_impl)
_t28_test = unittest.make(_shallow_lister_bound_fails_loudly_test_impl)
_t29_test = unittest.make(_covering_entries_resolve_at_scale_test_impl)
_t30_test = unittest.make(_empty_transformers_accepted_test_impl)
_t31_test = unittest.make(_malformed_transformers_refused_test_impl)
_t32_test = unittest.make(_shader_and_deferred_transformers_refused_test_impl)

def pub_assets_test_suite(name):
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
        _t28_test,
        _t29_test,
        _t30_test,
        _t31_test,
        _t32_test,
    )
