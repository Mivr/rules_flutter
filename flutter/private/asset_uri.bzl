"""One URI normalizer for every Flutter asset path (RT35-flutter:01, opus-2026-10-26:L-7).

flutter_tools 3.47.7 reads every `flutter:` entry that names a file as a
URI: string-form assets and shaders via `Uri.parse(entry)`, map-form
(`path:`) assets and shaders via `Uri(pathSegments: path.split('/'))`
(`flutter_manifest.dart:826-890`, `AssetsEntry.parseFromYamlSafe`), font
files via `Uri.parse(fontFile['asset'])` (`flutter_manifest.dart:421`). It
finds the file from the decoded `pathSegments` (`asset.dart:1185`,
`1402-1428`) and keys the bundle by the percent-encoded path:
`Uri(pathSegments: ['packages', name, ...segments]).path` for a package
(`asset.dart:1425-1428`), the entry's URI path for the app
(`asset.dart:617`). The key is also the file name inside flutter_assets
(`bundle_builder.dart:182`, `build_system/targets/assets.dart:126`), and
the engine percent-encodes the key it asks for, so the bundle must carry
the encoded spelling.

rules_flutter used to keep the raw entry text as both file name and key, so
`./a.png` failed the spoke fetch with an unhelpful target-name error while
flutter_tools bundles it as `a.png`, and `a b.png` bundled under the key
`a b.png` while flutter_tools (and hence the engine) uses `a%20b.png`.

This module mirrors both readings. A string-form entry reads like
`Uri.parse`: split on `/` (a raw backslash separates first), decode valid
`%XX` escapes as UTF-8, dot-resolve `.` / `x/..` on the decoded segments
the way Dart does (so an escaped `%2E` counts as `.`), then re-encode each
segment leaving RFC 3986 unreserved characters, sub-delims, `:` and `@`
literal and emitting every other UTF-8 byte as uppercase `%XX` (a lone `%`
becomes `%25`). Trailing dot segments resolve per RFC 3986 §5.2.4, preserving
directory slashes on `is_dir = True` entries. Percent-encoded reserved
characters remain uppercase in string form keys matching `Uri.parse.path`,
while re-encoding decoded segments for package keys (`norm.pkg_key`).
"""

load(
    ":asset_uri_codec.bzl",
    "check_segment_bytes",
    "decode_segment",
    "encode_segment",
    "literal_segment",
    "resolve_segments",
)

def _refusal(reason):
    """The `normalize_asset_uri` result for an entry spelling we cannot bundle.

    Args:
        reason: Why the spelling is not supported, naming the offending part.

    Returns:
        The failure struct (`ok = False`); callers fail with it.
    """
    return struct(ok = False, segments = [], decoded = "", key = "", pkg_key = "", is_dir = False, reason = reason)

def normalize_asset_uri(entry, is_map = False):
    """Normalize one asset entry the way flutter_tools 3.47.7 reads it.

    A string-form entry mirrors `Uri.parse(entry)`; a map-form (`path:`)
    entry mirrors `Uri(pathSegments: entry.split('/'))`
    (`flutter_manifest.dart:826-890` for assets and shaders in either form,
    `flutter_manifest.dart:421` for font files, which are always
    string-form). Either reading then derives the bundle key
    (`asset.dart:1425-1428` for a package, `asset.dart:617` for the app):
    `decoded` is what the segments read as (the file to fetch, which the
    Bazel label names), `key` is the percent-encoded bundle key, and
    `pkg_key` is the segment-re-encoded key for package contributions.
    Trailing dot segments resolve per RFC 3986 §5.2.4, preserving directory
    slashes on `is_dir = True` entries.

    Args:
        entry: The entry text as written in pubspec.yaml (or a BUILD-listed
            relative path, which is already decoded — use `encode_asset_key`
            for those instead, so a literal `%` in a file name is not
            decoded).
        is_map: Whether the entry came from a map-form (`path:`) item. The
            parser threads the shape; never guess it from the text. String
            entries keep exactly the old reading.

    Returns:
        `struct(ok, segments, decoded, key, pkg_key, is_dir, reason)`: the decoded
        segments, the `/`-joined decoded path, the encoded key, the package
        key, whether the entry is a directory, or the reason the spelling is
        not supported.
    """
    if entry == "":
        return _refusal("it is null or empty")
    if "?" in entry:
        return _refusal("it has a query part")
    if "#" in entry:
        return _refusal("it has a fragment part")

    if is_map:
        if entry.startswith("/"):
            return _refusal("it is an absolute path")
        slashed = entry
    else:
        slashed = entry.replace("\\", "/")
        if slashed.startswith("/"):
            return _refusal("it is an absolute path")

    items = []
    for raw in slashed.split("/"):
        seg = literal_segment(raw) if is_map else decode_segment(raw)
        if not seg.ok:
            return _refusal(seg.reason)
        bad = check_segment_bytes(seg.values)
        if bad:
            return _refusal(bad)
        pkg_key = encode_segment(seg.text, False)
        items.append(struct(decoded = seg.text, key = seg.key, pkg_key = pkg_key))

    resolved = resolve_segments(items)
    if not resolved.ok:
        return _refusal(resolved.reason)

    collapsed = [text for text in resolved.decoded_segments if text != ""]
    if not collapsed:
        return _refusal("it names no file")

    is_dir = len(resolved.decoded_segments) > 0 and resolved.decoded_segments[-1] == ""
    key = "/".join(resolved.key_segments)
    pkg_key = "/".join(resolved.pkg_key_segments)
    decoded = "/".join(collapsed) + ("/" if is_dir else "")

    return struct(
        ok = True,
        segments = collapsed,
        decoded = decoded,
        key = key,
        pkg_key = pkg_key,
        is_dir = is_dir,
        reason = "",
    )

def encode_asset_key(decoded):
    """Percent-encode an already-decoded path for a bundle key.

    For filesystem truth (a walked file, a `short_path`-relative key),
    where decoding would corrupt a literal `%` in a file name: encodes each
    `/`-separated piece like Dart's `Uri(pathSegments:)` (see
    `encode_segment`). Total: unlike `normalize_asset_uri` it never
    refuses, so callers must already know the path bundles.

    Args:
        decoded: The decoded `/`-joined path.

    Returns:
        The encoded bundle key.
    """
    return "/".join([encode_segment(piece, i == 0) for i, piece in enumerate(decoded.split("/"))])

def decode_asset_key(key):
    """Decode an encoded bundle key for an AssetManifest entry.

    Mirrors `Uri.decodeFull` over the encoded key (flutter_tools 3.47.7
    `asset.dart:923-929`, `_createAssetManifest`): every `%XX` escape
    becomes its bytes — so `%25` is `%`, and escapes of reserved characters
    decode too — while literal `/` separators stay. The inverse of
    `encode_asset_key` on encoder output; a lone `%` stays literal, as in
    `decode_segment`. Total: unlike `normalize_asset_uri` it never
    refuses, so callers must already know the key bundles.

    Args:
        key: The encoded bundle key (what the copied file is named).

    Returns:
        The decoded manifest key: the manifest entry and variant path.
    """
    return "/".join([decode_segment(piece).text for piece in key.split("/")])

def pub_bundle_key(prefix, path):
    """The bundle key for one contribution path under `prefix`.

    Normalizes `path` and prefixes it: `prefix + norm.pkg_key` when
    `prefix != ""` (matching `Uri(pathSegments: ['packages', pkg, ...u.pathSegments]).path`),
    else `norm.key` when `prefix == ""` for non-package contributions. Fails on
    a spelling that is not supported.

    Args:
        prefix: `"packages/<name>/"`, or `""` for non-package contributions.
        path: The contribution's asset path (raw or already normalized).

    Returns:
        The bundle key.
    """
    norm = normalize_asset_uri(path)
    if not norm.ok:
        fail("asset path {path} uses a spelling that is not supported: {reason}".format(path = repr(path), reason = norm.reason))
    if prefix == "":
        return norm.key
    return prefix + norm.pkg_key

def spoke_asset_uri_error(package_name, entry, reason):
    """The fetch failure for an entry spelling rules_flutter cannot bundle.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, its pubspec.yaml and the
    entry, and says the spelling is not supported, so a refusal never comes
    out as a bundle under a key flutter_tools would not use.

    Args:
        package_name: The pub package the entry comes from.
        entry: The entry text as written in pubspec.yaml.
        reason: Why the spelling is not supported (a `normalize_asset_uri`
            refusal reason).

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": pubspec.yaml entry {entry} uses " +
        "a spelling that is not supported: {reason}"
    ).format(pkg = package_name, entry = repr(entry), reason = reason)

def normalize_spoke_assets(package_name, parsed_assets):
    """Normalize parsed `flutter.assets` entries or fail the spoke fetch.

    Decodes each entry for file resolution (the label names the decoded
    file) and keys it encoded (the bundle key). Directory entries keep
    their trailing `/` on both spellings; `flavors` / `platforms` travel
    untouched. Each entry carries its pubspec shape (`is_map`), so a
    map-form entry reads like `Uri(pathSegments: path.split('/'))` while a
    string entry keeps the `Uri.parse` reading. For a pub package
    (`package_name != ""`), keys use `norm.pkg_key` so percent-encoded
    reserved characters bundle matching `flutter_tools` `asset.dart:1428`.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_assets: `struct(path, is_map, flavors, platforms)` entries from
            `parse_flutter_assets_block().assets`.

    Returns:
        `struct(path, key, flavors, platforms)` entries with the decoded
        path and the encoded key; fails the fetch on the first spelling
        that is not supported.
    """
    out = []
    for entry in parsed_assets:
        norm = normalize_asset_uri(entry.path, entry.is_map)
        if not norm.ok:
            fail(spoke_asset_uri_error(package_name, entry.path, norm.reason))
        key = norm.pkg_key if package_name != "" else norm.key
        out.append(struct(path = norm.decoded, key = key, flavors = entry.flavors, platforms = entry.platforms))
    return out

def normalize_spoke_fonts(package_name, parsed_fonts):
    """Normalize parsed `flutter.fonts` file assets or fail the spoke fetch.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_fonts: `struct(family, fonts)` entries from
            `parse_flutter_assets_block().fonts`, each font a
            `struct(asset, weight, style)`.

    Returns:
        `struct(family, fonts)` entries with each font a `struct(asset,
        key, weight, style)`: the decoded file and the encoded bundle key;
        fails the fetch on the first spelling that is not supported.
    """
    out = []
    for entry in parsed_fonts:
        fonts = []
        for font in entry.fonts:
            norm = normalize_asset_uri(font.asset)
            if not norm.ok:
                fail(spoke_asset_uri_error(package_name, font.asset, norm.reason))
            key = norm.pkg_key if package_name != "" else norm.key
            fonts.append(struct(asset = norm.decoded, key = key, weight = font.weight, style = font.style))
        out.append(struct(family = entry.family, fonts = fonts))
    return out

def normalize_spoke_shaders(package_name, parsed_shaders):
    """Normalize parsed `flutter.shaders` entries or fail the spoke fetch.

    Args:
        package_name: The pub package the entries come from, for refusals.
        parsed_shaders: `struct(path, is_map)` entries from
            `parse_flutter_assets_block().shaders`.

    Returns:
        `struct(path, key)` entries with the decoded file and the encoded
        bundle key; fails the fetch on the first spelling that is not
        supported.
    """
    out = []
    for entry in parsed_shaders:
        norm = normalize_asset_uri(entry.path, entry.is_map)
        if not norm.ok:
            fail(spoke_asset_uri_error(package_name, entry.path, norm.reason))
        key = norm.pkg_key if package_name != "" else norm.key
        out.append(struct(path = norm.decoded, key = key))
    return out

def normalize_spoke_asset_block(package_name, asset_block):
    """Normalize a parsed `flutter` block once, for linking and expansion.

    The path-package link plan resolves declared entries against the source
    tree, and the expansion resolves them against the spoke listing: both
    must read the decoded files, never the raw entry text, or an escaped
    entry (`enc%20c.png`) links and expands nothing while the file
    (`enc c.png`) sits there. Normalizing here — and never again downstream —
    also means no entry text is decoded twice: a `%25` names the `%` file
    once (`pct%25.png` finds `pct%.png`, keyed `pct%25.png`).

    Args:
        package_name: The pub package the entries come from, for refusals.
        asset_block: The `parse_flutter_assets_block()` result to normalize.

    Returns:
        A struct `(fonts, assets, shaders)` of the `normalize_spoke_*`
        results; fails the fetch on the first spelling that is not
        supported.
    """
    return struct(
        fonts = normalize_spoke_fonts(package_name, asset_block.fonts),
        assets = normalize_spoke_assets(package_name, asset_block.assets),
        shaders = normalize_spoke_shaders(package_name, asset_block.shaders),
    )
