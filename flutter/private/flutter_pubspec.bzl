"""Parse pub package pubspec.yaml `flutter:` block metadata.

YAML parsing itself delegates to the public `parse_pubspec_document` in
`@rules_dart//dart/pub:yaml_parser.bzl`, which reads zero-indented block
sequences at any depth and a leading byte-order mark, and fails naming
the package, the label and the line on anything it cannot read. This
module projects the parsed value down to the shapes rules_flutter
consumes:

- `parse_flutter_plugin_block` — `flutter.plugin` for plugin-spoke emission.
- `parse_flutter_assets_block` — `flutter.{fonts,assets,shaders,uses-material-design}`
  for the asset-bundling pipeline.

Parsing stays lenient (every readable shape loads), and `parse_flutter_assets_block`
additionally validates the section the way flutter_tools 3.47.7 `_validate`
(`packages/flutter_tools/lib/src/flutter_manifest.dart`, plus
`Plugin.validatePluginYaml` and each platform's `validate`) validates it: any
error flutter_tools reports is one refusal in `asset_errors`, and the spoke
fails the fetch on each through the single `check_asset_entry_problems` path,
naming the package, `pubspec.yaml` and the offending line. The per-key checks
live in `flutter_manifest_validate.bzl`, which shares this module's asset and
font parsers; accepted pubspecs parse exactly as on main. Shapes flutter_tools
only warns on stay silently skipped.

Schema reference (Flutter's pubspec):

    flutter:
      uses-material-design: bool
      fonts:
        - family: <name>
          fonts:
            - asset: <path>
              weight: <int>          # optional
              style: <italic|normal> # optional
      assets:
        - <path>                     # string form
        - path: <path>               # map form (modern)
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
      shaders:
        - <path>
      plugin:
        implements: <umbrella>
        platforms:
          <platform>:
            pluginClass: <Class>
            ...
"""

load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_document")
load(
    ":flutter_manifest_validate.bzl",
    "dart_str",
    "dart_type",
    "flutter_line_of",
    "item_key_line",
    "validate_flutter_section",
    "validate_pubspec_root",
)
load(
    ":flutter_pubspec_conditions.bzl",
    "entry_condition_problems",
    _VALID_ASSET_PLATFORMS = "VALID_ASSET_PLATFORMS",
)

VALID_ASSET_PLATFORMS = _VALID_ASSET_PLATFORMS

def parse_pubspec(content):
    """Parse pubspec.yaml content into a Starlark dict.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        Native dict of the parsed pubspec. Unreadable input fails with a
        message naming the package, the label and the line; an empty
        document returns `{}`.
    """
    return parse_pubspec_document(content)

def parse_flutter_block(content):
    """Return the `flutter:` sub-dict, or empty dict when absent."""
    pubspec = parse_pubspec(content)
    flutter = pubspec.get("flutter")
    return flutter if type(flutter) == "dict" else {}

# ---------------------------------------------------------------------------
# flutter.plugin
# ---------------------------------------------------------------------------

def _coerce_plugin_value(v):
    # Booleans stay booleans; everything else stringifies. None → empty string.
    if type(v) == "bool":
        return v
    if v == None:
        return ""
    return str(v)

def parse_flutter_plugin_block(content):
    """Parse `flutter.plugin` out of a pubspec.yaml string.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        A struct with:
            present: bool — True iff a `flutter.plugin` block exists.
            platforms: dict of `<platform> -> dict[key, value]`. Empty dict
                when no `platforms:` key is present.
            implements: str — value of `flutter.plugin.implements` or `""`.
            ffi_plugin: bool — value of `flutter.plugin.ffiPlugin` or False.
    """
    flutter = parse_flutter_block(content)
    plugin = flutter.get("plugin")
    if type(plugin) != "dict":
        return struct(
            present = False,
            platforms = {},
            implements = "",
            ffi_plugin = False,
        )

    platforms_raw = plugin.get("platforms", {})
    platforms = {}
    if type(platforms_raw) == "dict":
        for name, info in platforms_raw.items():
            if type(info) == "dict":
                platforms[name] = {k: _coerce_plugin_value(v) for k, v in info.items()}

    implements_raw = plugin.get("implements", "")
    implements = str(implements_raw) if implements_raw != None else ""

    ffi_raw = plugin.get("ffiPlugin", False)
    ffi_plugin = ffi_raw if type(ffi_raw) == "bool" else False

    return struct(
        present = True,
        platforms = platforms,
        implements = implements,
        ffi_plugin = ffi_plugin,
    )

# ---------------------------------------------------------------------------
# flutter.fonts / flutter.assets / flutter.shaders / flutter.uses-material-design
# ---------------------------------------------------------------------------

def _shape_problem(path, key, detail, line):
    """One spoke-fetch refusal for a malformed `flutter:` section shape.

    Args:
        path: The entry the problem is reported against: a real entry path,
            an indexed `key[index]` slot, or the key itself for a
            whole-section shape.
        key: `"assets"`, `"fonts"` or `"shaders"`, for the failure message.
        detail: The complaint, worded like flutter_tools where it has one.
        line: The 1-based `pubspec.yaml` line of the offending key or entry.

    Returns:
        A `struct(path, key, detail, line)` as `check_asset_entry_problems` takes it.
    """
    return struct(path = path, key = key, detail = detail, line = line)

def _expected_list_problem(key, raw, lines, locator):
    """The refusal for a non-list `flutter:` section value.

    Mirrors `_computeAssetsSafe` and the `fonts` check in `_validate`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): `Expected
    "assets" to be a list, ...`. `None` (an absent section) is valid and
    never reaches here; every other non-list shape fails the fetch.

    Args:
        key: `"assets"`, `"fonts"` or `"shaders"`.
        raw: The raw section value.
        lines: The pubspec text split on newlines.
        locator: The `["flutter", key]` path to the section, for the line.

    Returns:
        The refusal struct; the caller fails the fetch on it.
    """
    return _shape_problem(
        key,
        key,
        "Expected \"{key}\" to be a list, but got {value} ({type}).".format(
            key = key,
            value = dart_str(raw),
            type = dart_type(raw),
        ),
        flutter_line_of(lines, locator),
    )

def _parse_path_entry(item, index, key, lines, locator, shown):
    """Split one `assets`/`shaders` list item into its path or its refusal.

    Mirrors `AssetsEntry.parseFromYamlSafe`, which serves both sections
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): null or empty
    is a `null or empty uri` refusal, a string is the entry, an empty map is
    silently no entry, a map whose `path` is not a string is `malformed`,
    and anything else has an `unexpected shape`. The returned shape records
    which reading the normalizer must use: a string reads like `Uri.parse`,
    a map reads like `Uri(pathSegments: path.split('/'))`
    (RT38-flutter:01); the caller threads it, never guesses it from the
    text.

    Args:
        item: The raw list item.
        index: Its index in the section list, for the problem path.
        key: `"assets"` or `"shaders"`, for the problem key.
        lines: The pubspec text split on newlines.
        locator: The path to the item, for the line.
        shown: The problem-path slot prefix (`"assets"`, `"shaders"`, or a
            deferred `deferred-components[i].assets` slot).

    Returns:
        A `(path, is_map, problems)` tuple: the entry path, whether it came
        from a map-form item, or None when the item is no entry, and the
        refusal structs (empty when the item is usable or silently
        skipped).
    """
    slot = "{shown}[{index}]".format(shown = shown, index = index)
    item_line = flutter_line_of(lines, locator)
    if item == None or item == "":
        return (None, False, [_shape_problem(slot, key, "Asset manifest contains a null or empty uri.", item_line)])
    if type(item) == "string":
        return (item, False, [])
    if type(item) == "dict":
        if not item.keys():
            return (None, False, [])
        path = item.get("path")
        if type(path) == "string":
            return (path, True, [])
        return (None, False, [_shape_problem(
            slot,
            key,
            "Asset manifest entry is malformed. Expected asset entry to be " +
            "either a string or a map containing a \"path\" entry. " +
            "Got {type} instead.".format(type = dart_type(path)),
            item_line,
        )])
    return (None, False, [_shape_problem(
        slot,
        key,
        "Assets entry had unexpected shape. Expected a string or an object. " +
        "Got {type} instead.".format(type = dart_type(item)),
        item_line,
    )])

# The font weights flutter_tools accepts (`_validateFonts` in
# `packages/flutter_tools/lib/src/flutter_manifest.dart`): a present `weight`
# holding anything else is an invalid value, never silently unset.
_FONT_WEIGHTS = (100, 200, 300, 400, 500, 600, 700, 800, 900)

def _font_file_key_problems(item, slot, lines, flocator):
    """The refusals for one font file entry's keys, in document order.

    Mirrors the per-key loop of `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a present
    `weight` must be one of 100..900, a present `style` must be `normal`
    or `italic`, and any other key is `Unexpected`. A non-string key
    reports twice, like flutter_tools: its `if` refusal, then the
    `switch` default it also falls into. Each bad key is reported; an
    absent `weight` or `style` stays valid. A whole-number float `weight`
    (`400.0`) passes flutter_tools' validation (Dart `400.0 == 400`
    holds, so `fontWeights.contains` accepts it) but no build can read it
    (`flutter_manifest.dart:422` casts the weight with `as int?`), so on
    an entry carrying `asset` it fails saying that instead of quoting a
    validation error flutter_tools never prints. The build skips an
    entry with no `asset` before any cast
    (`flutter_manifest.dart:413-416`), so a whole-number float `weight`
    there stays silent. Every other non-member `weight` (an out-of-range
    whole-number float like `150.0`, a fractional float like `350.0`)
    keeps flutter_tools' own `Invalid value` refusal.

    Args:
        item: The raw font file mapping, with or without `asset`.
        slot: The `fonts[index]` problem path of the owning family entry.
        lines: The pubspec text split on newlines.
        flocator: The path to the file entry, for the line.

    Returns:
        The refusal structs for `asset_errors`.
    """
    problems = []

    # The build reads a file entry's weight only when the entry carries an
    # `asset` (entries without one are skipped before any cast), so the
    # unreadable-weight refusal applies only then.
    weight_readable = type(item.get("asset")) == "string"
    for key in item.keys():
        value = item[key]
        if type(key) != "string":
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Expected \"{key}\" under \"fonts\" to be a string.".format(key = dart_str(key)),
                item_key_line(lines, flocator, key),
            ))
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Unexpected key {key} (({type})) under font.".format(
                    key = dart_str(key),
                    type = dart_type(value),
                ),
                item_key_line(lines, flocator, key),
            ))
        elif key == "asset":
            if type(value) != "string":
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Expected font asset {value} (({type})) to be a string.".format(
                        value = dart_str(value),
                        type = dart_type(value),
                    ),
                    flutter_line_of(lines, flocator + ["asset"]),
                ))
        elif key == "weight":
            if type(value) == "float" and value in _FONT_WEIGHTS:
                if weight_readable:
                    problems.append(_shape_problem(
                        slot,
                        "fonts",
                        "Font weight {value} (({type})) must be an int: flutter_tools 3.47.7 cannot read it (flutter_manifest.dart:422 casts the weight with 'as int?').".format(
                            value = dart_str(value),
                            type = dart_type(value),
                        ),
                        flutter_line_of(lines, flocator + ["weight"]),
                    ))
            elif type(value) != "int" or value not in _FONT_WEIGHTS:
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Invalid value {value} (({type})) for font -> weight.".format(
                        value = dart_str(value),
                        type = dart_type(value),
                    ),
                    flutter_line_of(lines, flocator + ["weight"]),
                ))
        elif key == "style":
            if value != "normal" and value != "italic":
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Invalid value {value} (({type})) for font -> style.".format(
                        value = dart_str(value),
                        type = dart_type(value),
                    ),
                    flutter_line_of(lines, flocator + ["style"]),
                ))
        else:
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Unexpected key {key} (({type})) under font.".format(
                    key = key,
                    type = dart_type(value),
                ),
                flutter_line_of(lines, flocator + [key]),
            ))
    return problems

def _parse_font_files(fonts_raw, slot, lines, locator):
    """Parse one family's `fonts` list into font structs or refusals.

    Mirrors the inner loop of `_extractFonts` and the `weight` / `style` /
    extra-key checks of `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a non-map
    file entry is `Expected "fonts" to be a list of maps`, every key of
    every file mapping runs the per-key checks whether or not the entry
    carries `asset` (a missing `asset` with no other problem stays
    silently skipped, a warning only), a non-string `asset` is `Expected
    font asset ... to be a string`, a present `weight` must be one of
    100..900, a present `style` must be `normal` or `italic`, and any
    other key is `Unexpected`. An absent `weight` or `style` stays valid
    and reads as None.

    Args:
        fonts_raw: The raw `fonts` list of one family entry.
        slot: The `fonts[index]` problem path of the owning family entry.
        lines: The pubspec text split on newlines.
        locator: The `["flutter", "fonts", index, "fonts"]` path to the
            list, for the line.

    Returns:
        A `(fonts, problems)` tuple of `struct(asset, weight, style)`
        entries and refusal structs for `asset_errors`.
    """
    fonts = []
    problems = []
    for index, item in enumerate(fonts_raw):
        flocator = locator + [index]
        if type(item) != "dict":
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Expected \"fonts\" to be a list of maps.",
                flutter_line_of(lines, flocator),
            ))
            continue
        problems.extend(_font_file_key_problems(item, slot, lines, flocator))
        asset = item.get("asset")
        if type(asset) != "string":
            continue
        weight = item.get("weight")
        style = item.get("style")
        fonts.append(struct(
            asset = asset,
            weight = weight if type(weight) == "int" and weight in _FONT_WEIGHTS else None,
            style = style if style == "normal" or style == "italic" else None,
        ))
    return (fonts, problems)

def _parse_font_family(entry, index, lines, locator):
    """Parse one `fonts` list entry into a family struct or refusals.

    Mirrors `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): any key
    besides `family` and `fonts` is `Unexpected child ... under "fonts"`, a
    missing (null) `family` is silently skipped, a non-string one is `Font
    family must either be null or a String`; a missing or null per-family
    `fonts` stays the empty list, a non-list one is `Expected "fonts" to
    either be null or a list`.

    Args:
        entry: The raw family mapping.
        index: Its index in the `fonts` list, for the problem path.
        lines: The pubspec text split on newlines.
        locator: The `["flutter", "fonts", index]` path to the entry, for
            the line.

    Returns:
        A `(family, problems)` tuple: `struct(family, fonts)` or None, and
        the refusal structs for `asset_errors`.
    """
    slot = "fonts[{index}]".format(index = index)
    problems = []
    for key in entry.keys():
        if key != "family" and key != "fonts":
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Unexpected child \"{key}\" found under \"fonts\".".format(key = key),
                flutter_line_of(lines, locator + [key]),
            ))
    family = entry.get("family")
    if family == None:
        return (None, problems)
    if type(family) != "string":
        problems.append(_shape_problem(
            slot,
            "fonts",
            "Font family must either be null or a String.",
            flutter_line_of(lines, locator + ["family"]),
        ))
        return (None, problems)
    fonts_raw = entry.get("fonts", [])
    if fonts_raw == None:
        fonts_raw = []
    if type(fonts_raw) != "list":
        problems.append(_shape_problem(
            slot,
            "fonts",
            "Expected \"fonts\" to either be null or a list.",
            flutter_line_of(lines, locator + ["fonts"]),
        ))
        return (None, problems)
    (fonts, file_problems) = _parse_font_files(fonts_raw, slot, lines, locator + ["fonts"])
    problems.extend(file_problems)
    return (struct(family = family, fonts = fonts), problems)

def _parse_fonts(raw, lines, locator):
    """Parse the raw `flutter.fonts` list, collecting malformed shapes.

    Mirrors the `fonts` checks in `_validate` and `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a present
    but empty section value, a non-list section, a non-map entry, a
    non-string `family`, a non-list per-family `fonts`, a non-map font
    file entry and a non-string `asset` are each a refusal; entries
    flutter_tools only warns on stay silently skipped (a missing family;
    a file entry without an `asset` key whose other keys are clean),
    exactly as on main. When the
    first element is not a map the whole list is one refusal naming the
    value, and the remaining entries are not checked further.

    Args:
        raw: The raw `flutter.fonts` YAML value (None when absent).
        lines: The pubspec text split on newlines.
        locator: The `["flutter", "fonts"]` path to the section, for the line.

    Returns:
        A `(fonts, problems)` tuple of `struct(family, fonts)` entries and
        refusal structs for `asset_errors`.
    """
    if raw == None:
        return ([], [_expected_list_problem("fonts", raw, lines, locator)])
    if type(raw) != "list":
        return ([], [_expected_list_problem("fonts", raw, lines, locator)])
    if len(raw) > 0 and type(raw[0]) != "dict":
        return ([], [_shape_problem(
            "fonts",
            "fonts",
            "Expected \"fonts\" to contain maps, but the first element is {value} ({type}).".format(
                value = dart_str(raw),
                type = dart_type(raw),
            ),
            flutter_line_of(lines, locator),
        )])
    out = []
    problems = []
    for index, entry in enumerate(raw):
        if type(entry) != "dict":
            problems.append(_shape_problem(
                "fonts[{index}]".format(index = index),
                "fonts",
                "Unexpected child {value} found under \"fonts\". Expected a map.".format(
                    value = dart_str(entry),
                ),
                flutter_line_of(lines, locator + [index]),
            ))
            continue
        (family, family_problems) = _parse_font_family(entry, index, lines, locator + [index])
        problems.extend(family_problems)
        if family != None:
            out.append(family)
    return (out, problems)

def _entry_condition_problems(path, item, lines, elocator):
    """Validate one entry's `flavors` / `platforms` / `transformers` values.

    Shared by `_parse_assets` and `_parse_shaders` (RT40-flutter:01, RT40-flutter:02).

    Args:
        path: The entry path, for the problem path.
        item: The raw entry mapping.
        lines: The pubspec text split on newlines.
        elocator: The path to the entry, for the line.

    Returns:
        A `(flavors, platforms, problems)` tuple.
    """
    return entry_condition_problems(path, item, lines, elocator, _shape_problem)

def _parse_assets(raw, lines, locator, shown):
    """Parse the raw `flutter.assets` list, collecting malformed entries.

    A list item that is neither a usable string nor a map with a string
    `path` is a refusal shaped like flutter_tools'
    `AssetsEntry.parseFromYamlSafe`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`); a map
    entry's `flavors` / `platforms` must each be a list of strings naming
    known platforms (a bad one is the wrapped `Unable to parse assets section`
    refusal), and an
    entry must not carry `transformers` (rules_flutter does not run asset
    transformers; shipping the untransformed file would silently do the
    wrong thing). Problems are collected, not failed here, so unit tests
    can assert them; the spoke fails the fetch on each (see
    `check_asset_entry_problems`) naming the package, `pubspec.yaml` and
    the line. Any other unknown key in an entry mapping is ignored, the way
    flutter_tools ignores it. Deferred-component asset lists share this
    validator (their entries are validated only, never bundled).

    Args:
        raw: The raw `flutter.assets` YAML value (None when absent).
        lines: The pubspec text split on newlines.
        locator: The path to the section (e.g. `["flutter", "assets"]`),
            extended per item, for the line.
        shown: The problem-path slot prefix (`"assets"`, `"shaders"`, or a
            deferred `deferred-components[i].assets` slot).

    Returns:
        An `(entries, problems)` tuple: `entries` holds one
        `struct(path, is_map, flavors, platforms)` per usable entry (a
        problem entry keeps empty conditions; the fetch fails before they
        matter), and `problems` holds one `struct(path, key, detail, line)`
        per refusal.
    """
    if raw == None:
        return ([], [])
    if type(raw) != "list":
        return ([], [_expected_list_problem("assets", raw, lines, locator)])
    entries = []
    problems = []
    for index, item in enumerate(raw):
        elocator = locator + [index]
        (path, is_map, shape_problems) = _parse_path_entry(item, index, "assets", lines, elocator, shown)
        problems.extend(shape_problems)
        if path == None:
            continue
        if type(item) == "string":
            entries.append(struct(path = path, is_map = False, flavors = [], platforms = []))
            continue
        (flavors, platforms, condition_problems) = _entry_condition_problems(path, item, lines, elocator)
        problems.extend(condition_problems)
        entries.append(struct(path = path, is_map = is_map, flavors = flavors, platforms = platforms))
    return (entries, problems)

def _format_flavor_list(flavors):
    """Render a `flavors` list as `["a", "b"]`, or `[]` when it is empty."""
    return "[" + ", ".join(["\"%s\"" % f for f in flavors]) + "]"

def asset_flavor_error(package_name, asset_path, flavors_a, flavors_b):
    """The fetch failure for entries for one file with different flavors.

    Mirrors flutter_tools' `_checkForFlavorConflicts`: flavor lists compare
    as sets, so an entry without flavors conflicts with one that has some.
    Names the package, the file and both flavor lists.

    Args:
        package_name: The pub package the entries come from.
        asset_path: The file both entries expand to.
        flavors_a: The first entry's `flavors` list.
        flavors_b: The conflicting entry's `flavors` list.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": asset \"{path}\" lists conflicting " +
        "flavors {first} vs {second}. Entries for one file must agree on " +
        "flavors (compared as sets)."
    ).format(
        pkg = package_name,
        path = asset_path,
        first = _format_flavor_list(flavors_a),
        second = _format_flavor_list(flavors_b),
    )

def _parse_shaders(raw, lines, locator):
    """Parse the raw `flutter.shaders` list, collecting malformed shapes.

    Mirrors `_computeAssetsSafe`, which serves both `assets` and `shaders`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a non-list
    section, a null or empty entry, a non-string non-map item and a map
    whose `path` is not a string are each a refusal; an empty map is
    silently no entry, exactly as flutter_tools reads it. A map entry's
    `flavors` / `platforms` run the same condition checks an asset entry's
    do (`_entry_condition_problems`), with the same messages; a `path`
    entry that reads keeps only its path (shader bundling takes no
    conditions), but the fetch still fails on the problems first.

    Args:
        raw: The raw `flutter.shaders` YAML value (None when absent).
        lines: The pubspec text split on newlines.
        locator: The `["flutter", "shaders"]` path to the section, for the
            line.

    Returns:
        A `(shaders, problems)` tuple of `struct(path, is_map)` entries and
        refusal structs for `asset_errors`.
    """
    if raw == None:
        return ([], [])
    if type(raw) != "list":
        return ([], [_expected_list_problem("shaders", raw, lines, locator)])
    out = []
    problems = []
    for index, entry in enumerate(raw):
        elocator = locator + [index]
        (path, is_map, shape_problems) = _parse_path_entry(entry, index, "shaders", lines, elocator, "shaders")
        problems.extend(shape_problems)
        if path == None:
            continue
        if type(entry) == "dict":
            problems.extend(_entry_condition_problems(path, entry, lines, elocator)[2])
        out.append(struct(path = path, is_map = is_map))
    return (out, problems)

def _deferred_assets_check(lines):
    """A `check_assets` callback validating deferred-component asset lists.

    Args:
        lines: The pubspec text split on newlines.

    Returns:
        A `check_assets(raw, locator, shown)` callable returning that
        value's asset problems (entries are validated only, never bundled).
    """

    def check(raw, locator, shown):
        """Validate one deferred `assets` value, discarding its entries."""
        return _parse_assets(raw, lines, locator, shown)[1]

    return check

def parse_flutter_assets_block(content):
    """Parse `flutter.fonts`, `flutter.assets`, `flutter.shaders`, and `flutter.uses-material-design`.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        struct(
            fonts:    list[struct(family, fonts=list[struct(asset, weight, style)])],
            assets:   list[struct(path, is_map, flavors, platforms)],
            shaders:  list[struct(path, is_map)],
            uses_material_design: bool,
            asset_errors: list[struct(path, key, detail, line)],
        )

    `weight` and `style` on a font are None when unset. `flavors`/`platforms`
    are the modern-shape asset conditions the bundler filters on
    (`pub_asset_matches_target` checks flavor first, then platform, with the
    `tester` exception, exactly like flutter_tools' `matchesFlavor` /
    `matchesPlatform`); an unknown platform fails the spoke fetch.
    `asset_errors` collects the entries flutter_tools would refuse: a
    non-string pubspec root key, a non-string `name`, a `flutter.assets`
    / `flutter.shaders` / `flutter.fonts` section that is present but
    not a list (an empty `flutter.fonts` value counts), an
    asset or shader item that is neither a string nor a map with a string
    `path`, a `flutter.fonts` section that is not a list, a non-map font
    entry, a non-string `family`, a non-list per-family `fonts`, a non-map
    font file entry, a non-string font `asset`, an invalid font `weight`
    or `style` (a whole-number float `weight` on an entry carrying `asset`
    fails as unreadable by flutter_tools 3.47.7 instead; without `asset`
    it stays silent), an unexpected key in a font (checked
    whether or not the file entry carries `asset`), a `flavors` /
    `platforms` value that is not a list of strings, or a `platforms`
    value naming an unknown platform, on an asset or a shader entry, a
    malformed or non-empty `transformers` value (an empty list or null is
    accepted) on an asset, shader, or deferred-component entry, a `flutter:`
    section that is neither a map nor null,
    an empty `deferred-components` list (flutter_tools crashes reading
    one), and every other `flutter:` child flutter_tools `_validate` rejects
    (`uses-material-design`, `licenses`, `module`, `plugin`,
    `deferred-components`, `disable-swift-package-manager`,
    `default-flavor`, unknown children); the spoke fails the fetch on each
    (see `check_asset_entry_problems`), naming the package, `pubspec.yaml`
    and the line.
    """
    lines = content.split("\n")
    pubspec = parse_pubspec(content)
    root_problems = validate_pubspec_root(pubspec, lines)
    raw_flutter = pubspec.get("flutter")
    if raw_flutter == None:
        flutter = {}
        flutter_problem = []
    elif type(raw_flutter) != "dict":
        flutter = {}
        flutter_problem = [_shape_problem(
            "flutter",
            "flutter",
            "Expected \"flutter\" section to be an object or null, but got {value}.".format(
                value = dart_str(raw_flutter),
            ),
            flutter_line_of(lines, ["flutter"]),
        )]
    else:
        flutter = raw_flutter
        flutter_problem = []
    umd_raw = flutter.get("uses-material-design", False)
    (assets, asset_problems) = _parse_assets(flutter.get("assets"), lines, ["flutter", "assets"], "assets")
    if "fonts" in flutter:
        (fonts, font_problems) = _parse_fonts(flutter["fonts"], lines, ["flutter", "fonts"])
    else:
        (fonts, font_problems) = ([], [])
    (shaders, shader_problems) = _parse_shaders(flutter.get("shaders"), lines, ["flutter", "shaders"])
    scope = struct(lines = lines, check_assets = _deferred_assets_check(lines))
    section_problems = validate_flutter_section(flutter, scope)
    return struct(
        fonts = fonts,
        assets = assets,
        shaders = shaders,
        uses_material_design = umd_raw if type(umd_raw) == "bool" else False,
        asset_errors = root_problems + asset_problems + font_problems + shader_problems + flutter_problem + section_problems,
    )
