"""Asset condition and transformer validation for pubspec.yaml (RT40-flutter:01, RT40-flutter:02).

Shared condition parsing and validation for `flutter.assets`, `flutter.shaders`,
and `deferred-components` asset entries.
"""

load(
    ":flutter_manifest_validate.bzl",
    "dart_str",
    "dart_type",
    "flutter_line_of",
)

VALID_ASSET_PLATFORMS = (
    "android",
    "ios",
    "web",
    "windows",
    "linux",
    "macos",
)

def section_error(path, section, inner):
    """Wrap a condition-list complaint the way flutter_tools wraps it.

    Mirrors `AssetsEntry.parseFromYamlSafe`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a bad
    `flavors` / `platforms` / `transformers` value is `Unable to parse
    assets section.\nIn {section} section of asset "{path}": {inner}`.

    Args:
        path: The entry path, for the problem path.
        section: `"flavors"`, `"platforms"`, or `"transformers"`.
        inner: The inner error text.

    Returns:
        The formatted error message string.
    """
    return "Unable to parse assets section.\nIn {section} section of asset \"{path}\": {inner}".format(
        section = section,
        path = path,
        inner = inner,
    )

def parse_condition_list(raw_value, key):
    """Parse and validate one `flavors` or `platforms` list value.

    Args:
        raw_value: The YAML value for the key (None when unset).
        key: `"flavors"` or `"platforms"`.

    Returns:
        A `(values, error)` tuple: the string list (empty on error) and the
        unwrapped error message ("" on success).
    """
    if raw_value == None:
        return ([], "")
    if type(raw_value) != "list":
        return ([], "Expected {key} to be a list of String, but got {value} ({type}).".format(
            key = key,
            value = dart_str(raw_value),
            type = dart_type(raw_value),
        ))
    values = []
    bad = []
    for index, item in enumerate(raw_value):
        if type(item) != "string":
            bad.append("Expected {key} to be a list of String, but element at index {index} was a {type}.".format(
                key = key,
                index = index,
                type = dart_type(item),
            ))
        else:
            values.append(item)
    if bad:
        return ([], "\n".join(bad))
    if key == "platforms":
        unknown = []
        for value in values:
            if value not in VALID_ASSET_PLATFORMS and value not in unknown:
                unknown.append(value)
        if unknown:
            return ([], "Invalid platform(s): \"{unknown}\". Supported platforms are: \"{valid}\".".format(
                unknown = ", ".join(unknown),
                valid = ", ".join(VALID_ASSET_PLATFORMS),
            ))
    return (values, "")

def _validate_transformers(path, item, lines, elocator, shape_problem_fn):
    """Validate `transformers` on an entry (RT40-flutter:01, RT40-flutter:02).

    Args:
        path: The entry path.
        item: The raw entry mapping.
        lines: The pubspec text split on newlines.
        elocator: The locator path to the entry.
        shape_problem_fn: Factory `(path, key, detail, line) -> problem`.

    Returns:
        List of refusal problems (at most one).
    """
    if "transformers" not in item:
        return []
    raw = item.get("transformers")
    if raw == None or raw == []:
        return []
    line = flutter_line_of(lines, elocator + ["transformers"])
    if type(raw) != "list":
        msg = "Expected transformers list to be a list of Map, but got {value} ({type}).".format(
            value = dart_str(raw),
            type = dart_type(raw),
        )
        return [shape_problem_fn(path, "transformers", section_error(path, "transformers", msg), line)]
    bad = []
    for index, element in enumerate(raw):
        if type(element) != "dict":
            bad.append("Expected transformers list to be a list of Map, but element at index {index} was a {type}.".format(
                index = index,
                type = dart_type(element),
            ))
    if bad:
        return [shape_problem_fn(path, "transformers", section_error(path, "transformers", "\n".join(bad)), line)]
    return [shape_problem_fn(path, "transformers", "asset transformers are not supported by rules_flutter.", line)]

def entry_condition_problems(path, item, lines, elocator, shape_problem_fn):
    """Validate one entry's `flavors` / `platforms` / `transformers` values.

    Args:
        path: The entry path, for the problem path.
        item: The raw entry mapping.
        lines: The pubspec text split on newlines.
        elocator: The path to the entry, for the line.
        shape_problem_fn: Factory `(path, key, detail, line) -> problem`.

    Returns:
        A `(flavors, platforms, problems)` tuple.
    """
    problems = []
    (flavors, f_err) = parse_condition_list(item.get("flavors"), "flavors")
    if f_err:
        problems.append(shape_problem_fn(path, "flavors", section_error(path, "flavors", f_err), flutter_line_of(lines, elocator + ["flavors"])))
    (platforms, p_err) = parse_condition_list(item.get("platforms"), "platforms")
    if p_err:
        problems.append(shape_problem_fn(path, "platforms", section_error(path, "platforms", p_err), flutter_line_of(lines, elocator + ["platforms"])))
    problems.extend(_validate_transformers(path, item, lines, elocator, shape_problem_fn))
    return (flavors, platforms, problems)
