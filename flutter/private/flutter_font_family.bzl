"""A public `flutter_font_family` rule and the shared font validation.

COV-29. A font family declares each font with the asset path of the file it
ships, so a font and its file pair by that path and never by their position
in a list. `flutter_font_family` and the legacy `fonts_json` / `font_files`
path that `flutter_library` and `flutter_plugin` share both go through the
checks here: an asset with no file, a file no family names, and a weight or
style flutter_tools refuses all fail analysis, naming the target, the family
and the path. The refusal text is flutter_tools' own, for example
`Invalid value 750 ((int)) for font -> weight.`.
"""

load("//flutter/private:asset_uri.bzl", "normalize_asset_uri")
load("//flutter/private:flutter_manifest_validate.bzl", "dart_str", "dart_type")

# The weights flutter_tools accepts (`_validateFonts` in
# `packages/flutter_tools/lib/src/flutter_manifest.dart`). A present weight
# outside this table is an invalid value, never silently unset.
FONT_WEIGHTS = (100, 200, 300, 400, 500, 600, 700, 800, 900)

# The styles flutter_tools accepts for one font file.
FONT_STYLES = ("normal", "italic")

FlutterFontFamilyInfo = provider(
    doc = "One `flutter_font_family` target's family and its fonts.",
    fields = {
        "family": "The family name, unprefixed (`HelloSans`).",
        "fonts": "Tuple of struct(asset_path, file, weight, style) in declaration order. `asset_path` is the encoded bundle key; `file` is that font's own file.",
    },
)

FONTS_ATTR = attr.label_list(
    doc = "Font families this target ships, as `flutter_font_family` targets. List them in `flutter_application.fonts` for the root pubspec's bare family and asset paths (`HelloSans`, `fonts/HelloSans-Regular.ttf`), or in `flutter_library.fonts` to bundle them under `packages/<package_name>/`. The FontManifest entry lists the fonts in declaration order with `weight`/`style` only when given, and each asset carries its own file. Replaces the deprecated `fonts_json`/`font_files`.",
    providers = [FlutterFontFamilyInfo],
)

def font_weight_problem(weight):
    """The flutter_tools refusal for a font `weight`, or None when it is valid.

    Args:
        weight: The declared weight value.

    Returns:
        `Invalid value <value> ((<type>)) for font -> weight.`, flutter_tools'
        wording, or None for one of `FONT_WEIGHTS`.
    """
    if type(weight) == "int" and weight in FONT_WEIGHTS:
        return None
    return "Invalid value {value} (({type})) for font -> weight.".format(
        value = dart_str(weight),
        type = dart_type(weight),
    )

def font_style_problem(style):
    """The flutter_tools refusal for a font `style`, or None when it is valid.

    Args:
        style: The declared style value.

    Returns:
        `Invalid value <value> ((<type>)) for font -> style.`, flutter_tools'
        wording, or None for `"normal"` or `"italic"`.
    """
    if type(style) == "string" and style in FONT_STYLES:
        return None
    return "Invalid value {value} (({type})) for font -> style.".format(
        value = dart_str(style),
        type = dart_type(style),
    )

def font_file_table(label, font_files_dict):
    """The decoded-path to File table a `font_files` dict declares.

    Every entry must resolve to exactly one File and name one distinct path.
    Each failure names the declaring target and the entry it cannot use.

    Args:
        label: The declaring rule target, for the failure.
        font_files_dict: The rule's `ctx.attr.font_files`.

    Returns:
        A dict of normalized decoded asset path to that entry's File.
    """
    path_to_file = {}
    for target, asset_path in font_files_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("%s: font_files entry %s must resolve to exactly one File; got %d" % (label, target.label, len(files)))
        norm = normalize_asset_uri(asset_path)
        if not norm.ok:
            fail("%s: font_files value %s uses a spelling that is not supported: %s" % (label, repr(asset_path), norm.reason))
        if norm.decoded in path_to_file:
            fail("%s: font_files names %s twice; keep one entry per asset." % (label, norm.decoded))
        path_to_file[norm.decoded] = files[0]
    return path_to_file

def _checked_font(label, family, norm, weight, style, file):
    """One font struct after the weight and style checks, paired with `file`.

    Args:
        label: The declaring rule target, for the failure.
        family: The family name, for the failure.
        norm: The font asset's `normalize_asset_uri` result, already `ok`.
        weight: The declared weight, or None.
        style: The declared style, or None.
        file: The File that asset path names.

    Returns:
        A struct(asset_path, file, weight, style) for the family contribution.
    """
    if weight != None:
        problem = font_weight_problem(weight)
        if problem != None:
            fail("%s: font family '%s' font %s: %s" % (label, family, norm.decoded, problem))
    if style != None:
        problem = font_style_problem(style)
        if problem != None:
            fail("%s: font family '%s' font %s: %s" % (label, family, norm.decoded, problem))
    return struct(asset_path = norm.key, file = file, weight = weight, style = style)

def font_json_contribution(label, package_name, family, font_entries, path_to_file):
    """One pub_fonts contribution from a decoded `fonts_json` family.

    Each declared font pairs with the file its asset path names, never with
    the file at its index. An asset with no `font_files` entry fails naming
    the target, the family and the path, so a file list shorter than the font
    list cannot build.

    Args:
        label: The declaring rule target, for the failures.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).
        family: The family name.
        font_entries: The decoded `fonts` list of one family entry.
        path_to_file: `font_file_table` for the declaring rule.

    Returns:
        A pub_fonts contribution struct.
    """
    fonts = []
    files = []
    for font in font_entries:
        asset = font.get("asset") if type(font) == "dict" else None
        if type(asset) != "string" or not asset:
            fail("%s: font family '%s' has a font entry with no asset path." % (label, family))
        norm = normalize_asset_uri(asset)
        if not norm.ok:
            fail("%s: font family '%s' asset %s uses a spelling that is not supported: %s" % (label, family, repr(asset), norm.reason))
        file = path_to_file.get(norm.decoded)
        if file == None:
            fail("%s: font family '%s' asset %s has no font_files entry; add it to font_files or remove the font." % (label, family, norm.decoded))
        fonts.append(_checked_font(label, family, norm, font.get("weight"), font.get("style"), file))
        files.append(file)
    return struct(
        package_name = package_name,
        family = family,
        fonts = tuple(fonts),
        files = tuple(files),
        origin = str(label),
    )

def _claimed_paths(family_entry):
    """The decoded asset paths one `fonts_json` family entry declares.

    Args:
        family_entry: One decoded family map.

    Returns:
        A list of normalized decoded paths for its readable `asset` values.
    """
    claimed = []
    for font in family_entry.get("fonts", []):
        asset = font.get("asset") if type(font) == "dict" else None
        if type(asset) == "string" and asset:
            norm = normalize_asset_uri(asset)
            if norm.ok:
                claimed.append(norm.decoded)
    return claimed

def check_unclaimed_font_files(label, decoded, path_to_file):
    """Fail when a `font_files` entry is named by no family in `fonts_json`.

    Args:
        label: The declaring rule target, for the failure.
        decoded: The decoded `fonts_json` family list.
        path_to_file: `font_file_table` for the declaring rule.
    """
    claimed = {}
    for family_entry in decoded:
        for path in _claimed_paths(family_entry):
            claimed[path] = True
    for path in path_to_file:
        if path not in claimed:
            fail("%s: font_files entry %s is named by no family in fonts_json; remove it or add a font that uses it." % (label, path))

def font_family_contribution(target, package_name):
    """The pub_fonts contribution for one `flutter_font_family` target.

    Prefixing belongs to the consumer: an application passes the empty
    sentinel (bare family and asset paths), a library its `package_name`.

    Args:
        target: A `flutter_font_family` target.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).

    Returns:
        A pub_fonts contribution struct.
    """
    info = target[FlutterFontFamilyInfo]
    return struct(
        package_name = package_name,
        family = info.family,
        fonts = info.fonts,
        files = tuple([font.file for font in info.fonts]),
        origin = str(target.label),
    )

def font_family_contributions(targets, package_name):
    """The pub_fonts contributions for a rule's `fonts` attribute.

    Args:
        targets: The `fonts` attribute's `flutter_font_family` targets, in
            declaration order.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).

    Returns:
        A list of pub_fonts contribution structs.
    """
    return [font_family_contribution(target, package_name) for target in targets]

def _flutter_font_family_impl(ctx):
    if not ctx.attr.family:
        fail("%s: `flutter_font_family` needs a non-empty `family`." % ctx.label)
    decoded = json.decode(ctx.attr.fonts_json)
    if type(decoded) != "list" or not decoded:
        fail("%s: `flutter_font_family` needs a non-empty `fonts` list; give each font an `asset`." % ctx.label)
    contribution = font_json_contribution(
        ctx.label,
        "",
        ctx.attr.family,
        decoded,
        font_file_table(ctx.label, ctx.attr.font_files),
    )
    return [
        DefaultInfo(files = depset([font.file for font in contribution.fonts])),
        FlutterFontFamilyInfo(family = ctx.attr.family, fonts = contribution.fonts),
    ]

_flutter_font_family = rule(
    implementation = _flutter_font_family_impl,
    attrs = {
        "family": attr.string(
            doc = "The family name the app asks for in `TextStyle(fontFamily:)`. Must be non-empty.",
            mandatory = True,
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Font file label to asset path, one entry per font. The macro builds this from `fonts`; do not set it directly.",
            allow_files = True,
            mandatory = True,
        ),
        "fonts_json": attr.string(
            doc = "JSON-encoded `fonts` list, one entry per font with its `asset` and optional `weight`/`style`. The macro builds this from `fonts`; do not set it directly.",
            mandatory = True,
        ),
    },
    doc = "Internal target behind `flutter_font_family`: carries one declared family and its fonts.",
)

def flutter_font_family(name, family, fonts, **kwargs):
    """Declares one font family for `flutter_application.fonts` or `flutter_library.fonts`.

    Mirrors one `flutter: fonts:` family from `pubspec.yaml`. List the target
    in an application's `fonts` to bundle the family bare (`HelloSans`,
    `fonts/HelloSans-Regular.ttf`), as flutter_tools writes the root
    pubspec's, or in a library's `fonts` to bundle it under
    `packages/<package_name>/`.

    ```starlark
    flutter_font_family(
        name = "hello_sans",
        family = "HelloSans",
        fonts = [
            {"asset": "fonts/HelloSans-Regular.ttf"},
            {"asset": "fonts/HelloSans-Bold.ttf", "weight": 700},
        ],
    )
    ```

    Args:
        name: Target name.
        family: The family name the app asks for in `TextStyle(fontFamily:)`.
            Must be non-empty.
        fonts: A list of font maps, in `FontManifest.json` order. Each map
            names `asset`, the path of a font file in the calling package,
            and optionally `weight` (one of 100, 200, ..., 900) and `style`
            (`"normal"` or `"italic"`). The list must be non-empty and every
            entry must name an asset; a wrong weight, style, or a missing
            file fails analysis naming this target, the family and the path.
        **kwargs: Other attributes forwarded to the underlying rule, such as
            `tags` or `visibility`.
    """
    if type(fonts) != "list":
        fail("%s: `fonts` must be a list of font maps." % name)
    font_files = {}
    for font in fonts:
        asset = font.get("asset") if type(font) == "dict" else None
        if type(asset) == "string" and asset:
            font_files[":" + asset] = asset
    _flutter_font_family(
        name = name,
        family = family,
        fonts_json = json.encode(fonts),
        font_files = font_files,
        **kwargs
    )
