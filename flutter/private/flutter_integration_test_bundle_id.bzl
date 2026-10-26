"""Default bundle ids for iOS simulator integration tests.

The `platform = "ios"` branch of `flutter_integration_test` installs every
test app on one shared simulator, so two tests must never share a bundle id:
the simulator refuses a second install under a known id, and one run can
launch, terminate or uninstall another run's app. The default id therefore
carries a short deterministic hash of the test target's full label, so any
two distinct labels get distinct ids even when their readable parts sanitize
identically (same target name in different packages, same `package_name` in
two packages, or names that differ only by case and separators).
"""

# A bundle id holds ASCII letters, digits, `-` and `.` in non-empty segments
# that never start with a digit; Apple reads at most 155 characters.
_MAX_IOS_BUNDLE_ID_LENGTH = 155

def sanitize_ios_bundle_id_segment(raw):
    """Sanitizes a string into a valid iOS bundle ID segment.

    A segment holds letters, digits and hyphens; anything else becomes a
    hyphen, hyphen runs collapse to one, and a leading digit gains an `id-`
    prefix, since Apple reads a digit-led segment as a version.

    Args:
        raw: The raw string to sanitize.

    Returns:
        The sanitized segment.
    """
    chars = []
    for c in raw.elems():
        if c.isalnum() or c == "-":
            chars.append(c.lower())
        elif not chars or chars[-1] != "-":
            chars.append("-")
    segment = "".join(chars).strip("-")
    if not segment:
        return "app"
    if segment[0].isdigit():
        segment = "id-" + segment
    return segment

def _label_hash_segment(label_string):
    """Short deterministic hash segment for a full test-target label.

    `Starlark's hash()` is stable across runs and machines; the absolute
    decimal value keeps the segment short, and the `h` prefix keeps it a
    valid bundle id segment (never digit-led) whatever the hash is.

    Args:
        label_string: The full label (repository, package and name) before
            any sanitizing.

    Returns:
        The `h<digits>` hash segment.
    """
    hashed = hash(label_string)
    if hashed < 0:
        hashed = -hashed
    return "h%d" % hashed

def default_ios_bundle_id(bazel_package, target_name, label_string):
    """Default `ios_bundle_id` for one iOS integration test.

    `com.example.<sanitized package path>.<sanitized target>.<label hash>`:
    the readable part names the test, and the hash of the full label keeps
    any two distinct labels distinct. A long package path shortens the
    readable part (never the hash) so the id stays within 155 characters.

    Args:
        bazel_package: The Bazel package path of the test target.
        target_name: The `flutter_integration_test` target name.
        label_string: The full label (repository, package and name) before
            any sanitizing; any two distinct labels must give distinct ids.

    Returns:
        The default bundle ID string.
    """
    readable = "%s.%s" % (
        sanitize_ios_bundle_id_segment(bazel_package),
        sanitize_ios_bundle_id_segment(target_name),
    )
    suffix = _label_hash_segment(label_string)
    candidate = "com.example.%s.%s" % (readable, suffix)
    if len(candidate) <= _MAX_IOS_BUNDLE_ID_LENGTH:
        return candidate
    budget = _MAX_IOS_BUNDLE_ID_LENGTH - len("com.example.") - 1 - len(suffix)
    trimmed = readable[:budget]
    if trimmed.endswith("-") or trimmed.endswith("."):
        trimmed = trimmed[:-1]
    if trimmed.endswith("-") or trimmed.endswith("."):
        trimmed = trimmed[:-1]
    if not trimmed:
        trimmed = "app"
    return "com.example.%s.%s" % (trimmed, suffix)

def resolve_ios_bundle_id(name, ios_bundle_id):
    """Resolves the bundle id for one iOS integration test target.

    An explicit `ios_bundle_id` is used verbatim; otherwise the default comes
    from the target's label (Bazel package path, target name and full label),
    so any two distinct test targets get distinct ids.

    Args:
        name: The `flutter_integration_test` target name.
        ios_bundle_id: The macro's `ios_bundle_id`, empty for the default.

    Returns:
        The bundle ID string for the test rule and its `flutter_ios_app`.
    """
    if ios_bundle_id:
        return ios_bundle_id
    package = native.package_name()
    return default_ios_bundle_id(
        package,
        name,
        "@%s//%s:%s" % (native.repository_name(), package, name),
    )
