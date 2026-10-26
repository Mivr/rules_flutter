#!/usr/bin/env python3
"""MODULE.bazel, .bazelrc, and fixture module parsing for the monorepo bench."""

import os
import re
import shutil
import sys
from typing import NamedTuple, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def write_plain(out_dir, rel, content):
    full = os.path.join(out_dir, rel)
    parent = os.path.dirname(full)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(full, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


def read_bazel_version_or(rules_flutter_dir, fallback="9.3.0"):
    try:
        with open(os.path.join(rules_flutter_dir, ".bazelversion"),
                  encoding="utf-8") as fh:
            trimmed = fh.read().strip()
            if trimmed:
                return trimmed
    except OSError:
        pass
    return fallback


# Module names the trees may carry (BCR rename): rules_dart is published
# as ai_rules_dart (repo_name "rules_dart") and rules_flutter as
# ai_rules_flutter (repo_name "rules_flutter"). Labels keep the repo
# names (@rules_dart, @rules_flutter); overrides use module names.
FLUTTER_MODULE_NAMES = ("rules_flutter", "ai_rules_flutter")
DART_MODULE_NAMES = ("rules_dart", "ai_rules_dart")
HELLO_MODULE_NAME = "rules_flutter_hello_world"
BENCH_MODULE_NAME = "bench_monorepo"
OVERRIDE_KINDS = ("git_override", "archive_override",
                  "single_version_override")


def _strip_comments(text):
    """MODULE.bazel text with # comments removed, strings intact."""
    out = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            out.append(ch)
        elif ch == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def _call_spans(text, kind):
    """(start, end) spans of each top-level kind(...) call in text."""
    spans = []
    for match in re.finditer(r"%s\(" % kind, text):
        depth = 0
        for i in range(match.end() - 1, len(text)):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    spans.append((match.start(), i + 1))
                    break
    return spans


def _call_bodies(text, kind):
    """The argument bodies of each top-level kind(...) call in text."""
    bodies = []
    for (start, end) in _call_spans(text, kind):
        open_paren = text.index("(", start)
        bodies.append(text[open_paren + 1:end - 1])
    return bodies


def _string_attrs(body):
    """{attribute: value} for the name = "value" attributes in a body."""
    return dict(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]*)\"",
                           body))


def extract_pin_block(module_bazel_text, module_name):
    """The git/archive/single_version override block for module_name.

    Matches the module_name attribute inside the call, so neither
    "ai_rules_dart" nor a repo_name fools the comparison. Returns the
    block's original text, or None when the module has no pin block.
    """
    for kind in OVERRIDE_KINDS:
        for (start, end) in _call_spans(module_bazel_text, kind):
            attrs = _string_attrs(module_bazel_text[start:end])
            if attrs.get("module_name") == module_name:
                if module_bazel_text[end:end + 1] == "\n":
                    end += 1
                return module_bazel_text[start:end]
    return None


def extract_rules_dart_git_override(module_bazel_text):
    return extract_pin_block(module_bazel_text, "rules_dart")


def parse_module_name(module_bazel_text):
    """The module(name = ...) of a MODULE.bazel, or None when absent."""
    match = re.search(r'module\(\s*name\s*=\s*"([^"]+)"',
                      module_bazel_text)
    return match.group(1) if match else None


def read_tree_modules(rules_flutter_dir):
    """(flutter_name, dart_name, dart_pin) the rules_flutter tree declares.

    The flutter name comes from the tree MODULE.bazel's module(name =
    ...); the dart name is the name attribute of the bazel_dep call whose
    repo is rules_dart (repo_name when present, else the name itself),
    so a repo_name = "rules_dart" is never mistaken for the module name;
    the pin is that module's override block in the same file. Without a
    tree MODULE.bazel (unit tests) the names stay None and the caller
    falls back to the fixture's names; every name written otherwise
    comes from the trees, never from a constant.
    """
    try:
        with open(os.path.join(rules_flutter_dir, "MODULE.bazel"),
                  encoding="utf-8") as fh:
            root = _strip_comments(fh.read())
    except OSError:
        return (None, None, None)
    dart_name = None
    for body in _call_bodies(root, "bazel_dep"):
        attrs = _string_attrs(body)
        if attrs.get("repo_name", attrs.get("name")) == "rules_dart":
            dart_name = attrs.get("name")
            break
    return (parse_module_name(root), dart_name,
            extract_pin_block(root, dart_name) if dart_name else None)


def read_fixture_modules(fixture_text):
    """(flutter_name, dart_name, dart_pin) the hello_world fixture declares.

    The flutter name is the module_name of the local_path_override
    pointing at "../.."; the dart name and pin come from the fixture's
    own override block, in either naming scheme.
    """
    flutter_name = None
    stripped = _strip_comments(fixture_text)
    for body in _call_bodies(stripped, "local_path_override"):
        attrs = _string_attrs(body)
        if attrs.get("path") == "../.." and "module_name" in attrs:
            flutter_name = attrs["module_name"]
    dart_name = None
    dart_pin = None
    for candidate in DART_MODULE_NAMES:
        dart_pin = extract_pin_block(stripped, candidate)
        if dart_pin is not None:
            dart_name = candidate
            break
    return (flutter_name, dart_name, dart_pin)


def local_path_override(module_name, path):
    """A local_path_override block for module_name pointing at path."""
    return (
        "local_path_override(\n"
        '    module_name = "%s",\n'
        '    path = "%s",\n)\n' % (module_name, path)
    )


def split_overrides(overrides, rules_flutter_dir):
    """(flutter_path, dart_path, extra) of --override NAME=PATH flags.

    NAME accepts the module name or the repo name of either rule set;
    anything else becomes a verbatim extra local_path_override.
    """
    flutter_path = rules_flutter_dir
    dart_path = None
    extra_overrides = ""
    for mod_name, mod_dir in overrides:
        if mod_name in FLUTTER_MODULE_NAMES:
            flutter_path = mod_dir
        elif mod_name in DART_MODULE_NAMES:
            dart_path = mod_dir
        else:
            extra_overrides += local_path_override(mod_name, mod_dir)
    return (flutter_path, dart_path, extra_overrides)


DEV_DROPPABLE_KINDS = ("bazel_dep", "register_toolchains",
                       "register_execution_platforms")


def _scan_code(text):
    """Per-char code mask and paren depth of MODULE.bazel text.

    Returns (is_code, depth_before): is_code[i] is False inside strings
    and # comments, depth_before[i] is the paren depth before text[i].
    Only double-quoted strings exist in these files.
    """
    is_code = [True] * len(text)
    depth_before = [0] * len(text)
    depth = 0
    in_str = False
    in_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_comment:
            is_code[i] = False
            if ch == "\n":
                in_comment = False
        elif in_str:
            is_code[i] = False
            if ch == "\\" and i + 1 < len(text):
                is_code[i + 1] = False
                depth_before[i + 1] = depth
                i += 1
            elif ch == '"':
                in_str = False
        elif ch == "#":
            is_code[i] = False
            in_comment = True
        elif ch == '"':
            is_code[i] = False
            in_str = True
        elif ch == "(":
            depth_before[i] = depth
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
            depth_before[i] = depth
        else:
            depth_before[i] = depth
        i += 1
    return (is_code, depth_before)


def _find_matching_paren(text, open_idx):
    """Index of the close paren matching the open paren at open_idx."""
    depth = 0
    i = open_idx
    in_str = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\" and i + 1 < len(text):
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif ch == '"':
            in_str = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced parentheses in MODULE.bazel text")


def _top_level_calls(text):
    """(kind, start, close, body) of each top-level kind(...) call.

    Only calls at paren depth zero in real code: comments, strings and
    method calls (`.download(`, `.install(`) never match.
    """
    is_code, depth_before = _scan_code(text)
    calls = []
    for match in re.finditer(r"([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(", text):
        kind = match.group(1)
        open_idx = match.end() - 1
        if not all(is_code[k] for k in range(match.start(), match.end())):
            continue
        if depth_before[open_idx] != 0:
            continue
        prev = match.start() - 1
        while prev >= 0 and text[prev] in " \t":
            prev -= 1
        if prev >= 0 and (text[prev] == "." or text[prev] == "_"
                          or text[prev].isalnum()):
            continue
        close_idx = _find_matching_paren(text, open_idx)
        calls.append((kind, match.start(), close_idx,
                      text[open_idx + 1:close_idx]))
    return calls


def _has_dev_dependency(body):
    """Whether a call body sets dev_dependency = True (comments ignored)."""
    stripped = _strip_comments(body)
    return re.search(r"\bdev_dependency\s*=\s*True\b", stripped) is not None


def _dropped_module_names(calls):
    """Module/repo names a dropped dev call provided."""
    names = set()
    for (kind, _, _, body) in calls:
        if kind == "bazel_dep":
            attrs = _string_attrs(body)
            if "name" in attrs:
                names.add(attrs["name"])
            if "repo_name" in attrs:
                names.add(attrs["repo_name"])
        else:
            names.update(re.findall(r'"@([^"/\s]+)//', body))
    return names


def drop_dev_dependency_blocks(text, label):
    """(text, names): fixture MODULE.bazel without dev-only dependencies.

    Removes every top-level bazel_dep, register_toolchains and
    register_execution_platforms call marked dev_dependency = True: each
    call's full text (first line through closing-paren line) plus exactly
    one directly following blank line, if there is one. Any other call
    kind marked dev_dependency = True fails with an error naming the
    call. The attribute is read from the call itself, so a comment that
    mentions dev_dependency drops nothing.
    """
    dev_calls = [c for c in _top_level_calls(text) if _has_dev_dependency(c[3])]
    for (kind, _, _, _) in dev_calls:
        if kind not in DEV_DROPPABLE_KINDS:
            raise ValueError(
                "fixture '%s' marks '%s' dev_dependency = True, which the "
                "bench workspace cannot drop" % (label, kind))
    names = _dropped_module_names(dev_calls)
    trailing = text.endswith("\n")
    lines = text.split("\n")
    if trailing:
        lines.pop()
    spans = []
    for (_, start, close, _) in dev_calls:
        spans.append((text.count("\n", 0, start), text.count("\n", 0, close)))
    for (first, last) in sorted(spans, reverse=True):
        del lines[first:last + 1]
        if first < len(lines) and lines[first].strip() == "":
            del lines[first]
    out = "\n".join(lines)
    if trailing:
        out += "\n"
    return (out, names)


def check_dropped_names_absent(out, names, label):
    """Fails when the generated text still names a dropped module."""
    for name in sorted(names):
        if ("@%s//" % name in out
                or re.search(r'module_name\s*=\s*"%s"' % re.escape(name),
                             out)
                or re.search(r'repo_name\s*=\s*"%s"' % re.escape(name), out)):
            raise ValueError(
                "fixture '%s' still references dropped dev dependency '%s'"
                % (label, name))


def fallback_module_text(flutter_name, dart_name, flutter_path,
                         dart_override, extra_overrides):
    """Embedded minimal MODULE.bazel when the fixture is absent.

    Names come from the tree (defaults for unit tests without one);
    the extension keeps the repo name, as labels do.
    """
    return (
        "module(name = \"%s\")\n" % BENCH_MODULE_NAME
        + "\n"
        + "bazel_dep(name = \"%s\", version = \"0.0.0\")\n" % flutter_name
        + "bazel_dep(name = \"%s\", version = \"0.7.3\")\n" % dart_name
        + "bazel_dep(name = \"bazel_skylib\", version = \"1.9.2\")\n"
        + "bazel_dep(name = \"apple_support\", version = \"2.9.1\")\n"
        + "bazel_dep(name = \"rules_apple\", version = \"5.2.0\")\n"
        + "bazel_dep(name = \"rules_swift\", version = \"4.1.2\")\n"
        + "bazel_dep(name = \"platforms\", version = \"1.1.0\")\n"
        + "\n"
        + local_path_override(flutter_name, flutter_path)
        + (dart_override or "")
        + extra_overrides
        + "flutter = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n"
        "flutter.toolchain(flutter_version = \"3.47.7\")\n"
        "flutter.pub(\n"
        "    name = \"deps\",\n"
        "    lock = \"//:pubspec.lock\",\n)\n"
        "use_repo(flutter, \"deps\", \"flutter_ios_engine\", \"flutter_toolchains\", \"flutter_web_sdk\")\n"
        "\n"
        "register_toolchains(\"@flutter_toolchains//:all\")\n"
    )


class _PinReplacement(NamedTuple):
    """Dart override choice for the generated MODULE.bazel."""

    dart_name: str
    dart_path: Optional[str]
    fixture_pin: Optional[str]
    tree_pin: Optional[str]


class _PinResult(NamedTuple):
    """Generated MODULE.bazel text plus the appended extra overrides."""

    out: str
    extra: str


def _check_fixture_text(fixture, text):
    """Fails when the hello_world fixture lost its expected shape."""
    if "module(name = \"%s\")" % HELLO_MODULE_NAME not in text:
        raise ValueError(
            "fixture '%s' is not the hello_world module" % fixture)
    if text.count("path = \"../..\",") != 1:
        raise ValueError(
            "fixture '%s' lacks the single rules_flutter path override"
            % fixture)


def _apply_pin_replacement(out, extra_overrides, pin):
    """Swaps the fixture's dart pin for the override or the tree's pin."""
    if pin.dart_path is not None:
        dart_override = local_path_override(pin.dart_name, pin.dart_path)
        if pin.fixture_pin is not None and pin.fixture_pin in out:
            out = out.replace(pin.fixture_pin, dart_override, 1)
        else:
            # No pin block to swap (minimal fixture): append instead
            # so the override is never silently dropped.
            extra_overrides += dart_override
    elif pin.tree_pin is not None and pin.fixture_pin != pin.tree_pin:
        # The tree's own pin is the source of truth: without a user
        # override the generated workspace pins what the tree pins.
        if pin.fixture_pin is not None and pin.fixture_pin in out:
            out = out.replace(pin.fixture_pin, pin.tree_pin, 1)
        else:
            extra_overrides += pin.tree_pin
    return _PinResult(out, extra_overrides)


def module_bazel_text(rules_flutter_dir, overrides):
    """MODULE.bazel derived from the hello_world fixture.

    Every module name written comes from the trees, never from a
    constant: rules_flutter's own name from its MODULE.bazel
    module(name = ...), the rules_dart dependency's name and pin from
    the same file, and the fixture's names as the fixture declares
    them (both schemes: rules_* and ai_rules_*). An --override
    NAME=PATH accepts the module name or the repo name and is written
    under the module name the tree declares; without one the dart pin
    is the tree's own pin block. Labels keep the repo names
    (@rules_dart, @rules_flutter). Everything else stays
    byte-identical to the fixture. Falls back to an embedded minimal
    module when the fixture is absent (unit tests).
    """
    tree_flutter, tree_dart, tree_pin = read_tree_modules(rules_flutter_dir)
    flutter_path, dart_path, extra_overrides = split_overrides(
        overrides, rules_flutter_dir)

    fixture = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", "MODULE.bazel")
    if os.path.isfile(fixture):
        with open(fixture, encoding="utf-8") as fh:
            text = fh.read()
        _check_fixture_text(fixture, text)
        text, dropped = drop_dev_dependency_blocks(text, fixture)
        fixture_flutter, fixture_dart, fixture_pin = read_fixture_modules(
            text)
        if (tree_flutter is not None and fixture_flutter is not None
                and tree_flutter != fixture_flutter):
            raise ValueError(
                "fixture '%s' overrides %s but the tree is %s"
                % (fixture, fixture_flutter, tree_flutter))
        if (tree_dart is not None and fixture_dart is not None
                and tree_dart != fixture_dart):
            raise ValueError(
                "fixture '%s' pins %s but the tree depends on %s"
                % (fixture, fixture_dart, tree_dart))
        dart_name = tree_dart or fixture_dart or "rules_dart"
        out = text.replace(
            "module(name = \"%s\")" % HELLO_MODULE_NAME,
            "module(name = \"%s\")" % BENCH_MODULE_NAME,
        )
        out = out.replace(
            "path = \"../..\",",
            "path = \"%s\"," % flutter_path,
        )
        result = _apply_pin_replacement(
            out, extra_overrides,
            _PinReplacement(dart_name, dart_path, fixture_pin, tree_pin))
        out = result.out
        extra_overrides = result.extra
        out += extra_overrides
        check_dropped_names_absent(out, dropped, fixture)
        return out

    dart_override = None
    if dart_path is not None:
        dart_override = local_path_override(tree_dart or "rules_dart",
                                            dart_path)
    return fallback_module_text(tree_flutter or "rules_flutter",
                                tree_dart or "rules_dart", flutter_path,
                                dart_override, extra_overrides)


def copy_pub_file(out_dir, rules_flutter_dir, file_name, fallback):
    src = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", file_name)
    if os.path.isfile(src):
        with open(src, "rb") as fin:
            content = fin.read()
        with open(os.path.join(out_dir, file_name), "wb") as fout:
            fout.write(content)
    else:
        write_plain(out_dir, file_name, fallback)


def bazelrc_text(rules_flutter_dir):
    """Generated .bazelrc: the fixture's without extra defines or lockfile.

    The bench workspace models a consumer workspace, so the generated
    file carries no --lockfile_mode flag at all and Bazel's default
    applies: any such line the fixture carries is dropped, and none is
    ever inserted. Every other line stays byte-identical to the fixture.
    """
    fallback = (
        "test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze\n"
        "test --output_groups=+dart_analyze\n"
        "test --output_groups=+dart_format\n"
        "common --@rules_dart//dart:analysis_config=//:analysis_config\n"
        "try-import %workspace%/.bazelrc.user\n"
    )
    src = os.path.join(rules_flutter_dir, "e2e", "hello_world", ".bazelrc")
    try:
        with open(src, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return fallback
    kept = [
        line for line in raw.split("\n")
        if not line.startswith("@rules_flutter//flutter:extra_dart_defines")
        and not line.startswith(
            "common --@rules_flutter//flutter:extra_dart_defines")
        and "--lockfile_mode" not in line
    ]
    return "\n".join(kept) + "\n"


def copy_dir_sorted(src, dest):
    entries = sorted(os.listdir(src))
    os.makedirs(dest, exist_ok=True)
    for name in entries:
        s = os.path.join(src, name)
        d = os.path.join(dest, name)
        if os.path.isdir(s) and not os.path.islink(s):
            copy_dir_sorted(s, d)
        else:
            shutil.copy2(s, d)


def copy_fixture_dir(out_dir, rules_flutter_dir, fixture_rel, dest_rel):
    src = os.path.join(rules_flutter_dir, *fixture_rel)
    if not os.path.isdir(src):
        if os.path.isfile(os.path.join(rules_flutter_dir, "MODULE.bazel")):
            raise ValueError(
                "rules_flutter fixture '%s' is missing "
                "(required for the iOS app)" % src)
        return
    copy_dir_sorted(src, os.path.join(out_dir, dest_rel))
