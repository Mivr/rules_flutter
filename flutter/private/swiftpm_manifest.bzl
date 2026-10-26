"""Bounded `Package.swift` parser for SwiftPM iOS native dependencies.

Reads the manifest subset `flutter.pub` translates (see the README section
"iOS native (SwiftPM) dependencies"): the tools-version first line, `import
PackageDescription`, and one literal `let package = Package(...)`. Anything
else — another top-level statement, `#if`, string interpolation, variables,
or a mutation of `package` — fails with a message naming the identity,
`Package.swift`, the line and the construct.

Like the Gradle readers, the parser is iterative: tokens from
`swiftpm_manifest_lex.bzl` are split into top-level statements and
comma-separated argument lists by depth-counting loops. Starlark call depth
stays constant no matter how deeply the manifest nests.
"""

load(
    ":swiftpm_manifest_lex.bzl",
    "lex_swiftpm_manifest",
    "parse_swiftpm_tools_line",
    "swiftpm_first_content_line",
)

def _swiftpm_fail(identity, line, detail):
    """The fetch failure for one manifest refusal.

    Args:
        identity: The SwiftPM package identity.
        line: The 1-based line number.
        detail: What was found and why it is unsupported.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return "SwiftPM package {identity} (Package.swift line {line}): {detail}.".format(
        identity = repr(identity),
        line = line,
        detail = detail,
    )

def _swiftpm_token_text(tokens, index):
    """The text of token `index`, or "" past the end.

    Args:
        tokens: The token list.
        index: The position to read.

    Returns:
        The token text, or "" when out of range.
    """
    if index < 0 or index >= len(tokens):
        return ""
    return tokens[index].text

def _swiftpm_split_statements(tokens):
    """Split tokens into top-level statements.

    Statements end at a newline or `;` at paren/bracket depth 0. Empty
    statements are dropped. Depth never goes negative: a stray closer just
    stays in its statement, which the dispatcher refuses.

    Args:
        tokens: The lexed token list.

    Returns:
        A list of token lists.
    """
    statements = []
    current = []
    depth = 0
    for tok in tokens:
        if tok.kind == "nl" or (tok.kind == "punct" and tok.text == ";"):
            if depth == 0:
                if current:
                    statements.append(current)
                    current = []
            else:
                current.append(tok)
        else:
            if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
                depth += 1
            elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]") and depth > 0:
                depth -= 1
            current.append(tok)
    if current:
        statements.append(current)
    return statements

def _swiftpm_match_paren(tokens, open_idx):
    """Find the `)` matching the `(` at `open_idx`.

    Args:
        tokens: The token list.
        open_idx: The position of the opening paren.

    Returns:
        The index of the matching closer, or -1.
    """
    depth = 0
    for i in range(open_idx, len(tokens)):
        tok = tokens[i]
        if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
            depth += 1
        elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]"):
            depth -= 1
            if depth == 0:
                if tok.text == ")":
                    return i
                return -1
    return -1

def _swiftpm_call_head(seg):
    """Read the call head of one statement or element segment.

    Accepts `Package(...)` and `.name(...)`; anything else (a bare word, a
    literal, member chains, operators) is not a call this parser models.

    Args:
        seg: The segment's token list.

    Returns:
        `struct(ok, detail, dotted, name, args, line)`: `dotted` is True
        for `.name(...)`; `args` holds the tokens between the outer
        parens; `line` is the segment's first line.
    """
    line = seg[0].line if seg else 0
    if len(seg) >= 2 and seg[0].kind == "word" and seg[0].text == "Package" and seg[1].kind == "punct" and seg[1].text == "(":
        close = _swiftpm_match_paren(seg, 1)
        if close != len(seg) - 1:
            return struct(ok = False, detail = "malformed `Package(...)` call", dotted = False, name = "", args = [], line = line)
        return struct(ok = True, detail = "", dotted = False, name = "Package", args = seg[2:close], line = line)
    if len(seg) >= 3 and seg[0].kind == "punct" and seg[0].text == "." and seg[1].kind == "word" and seg[2].kind == "punct" and seg[2].text == "(":
        close = _swiftpm_match_paren(seg, 2)
        if close != len(seg) - 1:
            return struct(ok = False, detail = "malformed `.{name}(...)` call".format(name = seg[1].text), dotted = True, name = "", args = [], line = line)
        return struct(ok = True, detail = "", dotted = True, name = seg[1].text, args = seg[3:close], line = line)
    return struct(ok = False, detail = "not a `Package(...)` or `.name(...)` call", dotted = False, name = "", args = [], line = line)

def _swiftpm_split_commas(tokens):
    """Split tokens at depth-0 commas.

    Newlines are statement separators, not argument content: filtering
    them here keeps multi-line calls readable. A trailing comma (the
    multi-line style swift-format emits) is dropped; a leading or doubled
    comma fails like Swift rejects it.

    Args:
        tokens: The argument or element list contents.

    Returns:
        `struct(ok, detail, parts)`: not-ok names a leading or doubled
        comma.
    """
    dense = [tok for tok in tokens if tok.kind != "nl"]
    if dense and dense[len(dense) - 1].kind == "punct" and dense[len(dense) - 1].text == ",":
        dense = dense[:len(dense) - 1]
    parts = []
    current = []
    depth = 0
    for tok in dense:
        if tok.kind == "punct" and tok.text == "," and depth == 0:
            if not current:
                return struct(ok = False, detail = "empty argument (a leading or doubled comma)", parts = [])
            parts.append(current)
            current = []
        else:
            if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
                depth += 1
            elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]"):
                depth -= 1
            current.append(tok)
    if current:
        parts.append(current)
    return struct(ok = True, detail = "", parts = parts)

def _swiftpm_split_kwargs(args):
    """Split call arguments into `key: value` pairs.

    Args:
        args: The tokens between the call's parens.

    Returns:
        `struct(ok, detail, kwargs)`: `kwargs` is a list of structs with
        `key`, `value` tokens and `line`. Duplicate keys fail like Swift.
    """
    split = _swiftpm_split_commas(args)
    if not split.ok:
        return struct(ok = False, detail = split.detail, kwargs = [])
    kwargs = []
    seen = {}
    for part in split.parts:
        if len(part) < 3 or part[0].kind != "word" or part[1].kind != "punct" or part[1].text != ":":
            return struct(ok = False, detail = "expected a `name: value` argument", kwargs = [])
        if part[0].text in seen:
            return struct(ok = False, detail = "duplicate argument `{key}`".format(key = part[0].text), kwargs = [])
        seen[part[0].text] = True
        kwargs.append(struct(key = part[0].text, value = part[2:], line = part[0].line))
    return struct(ok = True, detail = "", kwargs = kwargs)

def _swiftpm_single_string(value):
    """Read a value that must be one string literal.

    Args:
        value: The argument's value tokens.

    Returns:
        `struct(ok, detail, text)`.
    """
    if len(value) == 1 and value[0].kind == "str":
        return struct(ok = True, detail = "", text = value[0].text)
    return struct(ok = False, detail = "expected one string literal", text = "")

def _swiftpm_array_parts(value):
    """Read a value that must be an array literal.

    Args:
        value: The argument's value tokens.

    Returns:
        `struct(ok, detail, elements)`: `elements` holds each element's
        token list.
    """
    if not value or value[0].kind != "punct" or value[0].text != "[":
        return struct(ok = False, detail = "expected an array literal", elements = [])
    depth = 0
    close = -1
    for i in range(len(value)):
        tok = value[i]
        if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
            depth += 1
        elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]"):
            depth -= 1
            if depth == 0:
                if tok.text != "]" or i != len(value) - 1:
                    return struct(ok = False, detail = "malformed array literal", elements = [])
                close = i
                break
    if close < 0:
        return struct(ok = False, detail = "malformed array literal", elements = [])
    split = _swiftpm_split_commas(value[1:close])
    if not split.ok:
        return struct(ok = False, detail = split.detail, elements = [])
    return struct(ok = True, detail = "", elements = split.parts)

def _swiftpm_string_list(value):
    """Read an array of string literals.

    Args:
        value: The argument's value tokens.

    Returns:
        `struct(ok, detail, items)`.
    """
    array = _swiftpm_array_parts(value)
    if not array.ok:
        return struct(ok = False, detail = array.detail, items = [])
    items = []
    for element in array.elements:
        one = _swiftpm_single_string(element)
        if not one.ok:
            return struct(ok = False, detail = "expected an array of string literals", items = [])
        items.append(one.text)
    return struct(ok = True, detail = "", items = items)

def _swiftpm_parse_mode_element(element):
    """Read one language-mode element (`.v4`, `.v4_2`, `.v5`, `.v6`).

    Args:
        element: The element's token list.

    Returns:
        `struct(ok, detail, major, minor)`.
    """
    if len(element) == 2 and element[0].kind == "punct" and element[0].text == "." and element[1].kind == "word":
        table = {"v4": (4, 0), "v4_2": (4, 2), "v5": (5, 0), "v6": (6, 0)}
        if element[1].text in table:
            pair = table[element[1].text]
            return struct(ok = True, detail = "", major = pair[0], minor = pair[1])
    return struct(ok = False, detail = "expected a language mode (`.v4`, `.v4_2`, `.v5` or `.v6`)", major = 0, minor = 0)

def _swiftpm_parse_modes(value):
    """Read a `swiftLanguageVersions`/`swiftLanguageModes` array.

    Args:
        value: The argument's value tokens.

    Returns:
        `struct(ok, detail, modes)`: `modes` is a list of structs with
        `major` and `minor`.
    """
    array = _swiftpm_array_parts(value)
    if not array.ok:
        return struct(ok = False, detail = array.detail, modes = [])
    modes = []
    for element in array.elements:
        mode = _swiftpm_parse_mode_element(element)
        if not mode.ok:
            return struct(ok = False, detail = mode.detail, modes = [])
        modes.append(struct(major = mode.major, minor = mode.minor))
    return struct(ok = True, detail = "", modes = modes)

def _swiftpm_parse_target_dep(element):
    """Read one target `dependencies` element.

    Accepts a string, `.target(name:)` and `.byName(name:)` (a target of
    the same package) and `.product(name:package:)` (a product of a
    declared `.package(...)` dependency). Each form accepts an optional
    `condition: .when(platforms: [...])` limiting the dependency to the
    listed platforms (`.iOS`, `.macOS`).

    Args:
        element: The element's token list.

    Returns:
        `struct(ok, detail, dep)`: `dep` is `struct(kind, name, package,
        condition)` with `kind` `"same"` or `"product"` and `condition`
        None or `struct(platforms)`.
    """
    if len(element) == 1 and element[0].kind == "str":
        return struct(ok = True, detail = "", dep = struct(kind = "same", name = element[0].text, package = "", condition = None))
    head = _swiftpm_call_head(element)
    if not head.ok or not head.dotted or head.name not in ["target", "byName", "product"]:
        return struct(ok = False, detail = "expected a target dependency (a string, `.target(name:)`, `.byName(name:)` or `.product(name:package:)`)", dep = None)
    kwargs = _swiftpm_split_kwargs(head.args)
    if not kwargs.ok:
        return struct(ok = False, detail = kwargs.detail, dep = None)
    if head.name == "product":
        return _swiftpm_parse_product_dep(kwargs.kwargs)
    return _swiftpm_parse_same_dep(kwargs.kwargs)

_SWIFTPM_CONDITION_PLATFORMS = {"iOS": "ios", "macOS": "macos"}

def _swiftpm_parse_dep_condition(kwarg):
    """Read a `condition:` target-dependency argument.

    Only `.when(platforms: [...])` translates: the hub builds one
    library for every Apple platform, so any other shape (traits,
    configurations, other platforms) has no Bazel meaning and fails.

    Args:
        kwarg: The `condition:` kwarg struct, or None when absent.

    Returns:
        `struct(ok, detail, value)`: `value` is None when the argument
        is absent, else `struct(platforms)` with `"ios"`/`"macos"`
        entries in manifest order.
    """
    if kwarg == None:
        return struct(ok = True, detail = "", value = None)
    head = _swiftpm_call_head(kwarg.value)
    if not head.ok or not head.dotted or head.name != "when":
        return struct(ok = False, detail = "expected a build condition (`.when(platforms: [...])`)", value = None)
    kwargs = _swiftpm_split_kwargs(head.args)
    if not kwargs.ok:
        return struct(ok = False, detail = kwargs.detail, value = None)
    if len(kwargs.kwargs) != 1 or kwargs.kwargs[0].key != "platforms":
        return struct(ok = False, detail = "only `.when(platforms: [...])` conditions are supported", value = None)
    array = _swiftpm_array_parts(kwargs.kwargs[0].value)
    if not array.ok:
        return struct(ok = False, detail = array.detail, value = None)
    platforms = []
    for element in array.elements:
        if len(element) == 2 and element[0].kind == "punct" and element[0].text == "." and element[1].kind == "word" and element[1].text in _SWIFTPM_CONDITION_PLATFORMS:
            platforms.append(_SWIFTPM_CONDITION_PLATFORMS[element[1].text])
        else:
            return struct(ok = False, detail = "unsupported condition platform (only `.iOS` and `.macOS` translate)", value = None)
    return struct(ok = True, detail = "", value = struct(platforms = platforms))

def _swiftpm_parse_same_dep(kwargs):
    """Read a `.target(name:)` / `.byName(name:)` dependency.

    Args:
        kwargs: The call's parsed keyword arguments.

    Returns:
        `struct(ok, detail, dep)`.
    """
    by_key = {kwarg.key: kwarg for kwarg in kwargs}
    for kwarg in kwargs:
        if kwarg.key != "name" and kwarg.key != "condition":
            return struct(ok = False, detail = "unknown dependency argument `{key}`".format(key = kwarg.key), dep = None)
    if "name" not in by_key or (len(kwargs) != 1 and not (len(kwargs) == 2 and "condition" in by_key)):
        return struct(ok = False, detail = "expected exactly `name:`", dep = None)
    one = _swiftpm_single_string(by_key["name"].value)
    if not one.ok:
        return struct(ok = False, detail = one.detail, dep = None)
    condition = _swiftpm_parse_dep_condition(by_key.get("condition", None))
    if not condition.ok:
        return struct(ok = False, detail = condition.detail, dep = None)
    return struct(ok = True, detail = "", dep = struct(kind = "same", name = one.text, package = "", condition = condition.value))

def _swiftpm_parse_product_dep(kwargs):
    """Read a `.product(name:package:)` dependency.

    Args:
        kwargs: The call's parsed keyword arguments.

    Returns:
        `struct(ok, detail, dep)`.
    """
    by_key = {kwarg.key: kwarg for kwarg in kwargs}
    for kwarg in kwargs:
        if kwarg.key != "name" and kwarg.key != "package" and kwarg.key != "condition":
            return struct(ok = False, detail = "unknown `.product(...)` argument `{key}`".format(key = kwarg.key), dep = None)
    if "name" not in by_key or "package" not in by_key:
        return struct(ok = False, detail = "expected `name:` and `package:`", dep = None)
    name = _swiftpm_single_string(by_key["name"].value)
    package = _swiftpm_single_string(by_key["package"].value)
    if not name.ok or not package.ok:
        return struct(ok = False, detail = "expected string literals for `name:` and `package:`", dep = None)
    condition = _swiftpm_parse_dep_condition(by_key.get("condition", None))
    if not condition.ok:
        return struct(ok = False, detail = condition.detail, dep = None)
    return struct(ok = True, detail = "", dep = struct(kind = "product", name = name.text, package = package.text, condition = condition.value))

_SWIFTPM_REFUSED_TARGET_KEYS = ["resources", "swiftSettings", "cSettings", "cxxSettings", "linkerSettings", "plugins"]

def _swiftpm_target_kwarg_error(target_name, key):
    """The refusal detail for an untranslatable target argument.

    Args:
        target_name: The target holding the argument.
        key: The argument key.

    Returns:
        The detail string; the caller wraps it with identity and line.
    """
    return "target {target} uses `{key}`, which has no Bazel translation".format(target = repr(target_name), key = key)

def _swiftpm_apply_target_deps(identity, kwarg, acc):
    """Fold a `.target(...)` `dependencies:` array into the accumulator.

    Args:
        identity: The SwiftPM package identity.
        kwarg: The parsed keyword argument.
        acc: The accumulator dict (mutated in place).

    Returns:
        `struct(ok, error)`.
    """
    array = _swiftpm_array_parts(kwarg.value)
    if not array.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, array.detail))
    for element in array.elements:
        dep = _swiftpm_parse_target_dep(element)
        if not dep.ok:
            element_line = element[0].line if element else kwarg.line
            return struct(ok = False, error = _swiftpm_fail(identity, element_line, dep.detail))
        acc["deps"].append(dep.dep)
    return struct(ok = True, error = "")

def _swiftpm_apply_target_kwarg(identity, kind, kwarg, acc, lenient):
    """Fold one `.target(...)` keyword argument into the accumulator.

    Args:
        identity: The SwiftPM package identity.
        kind: The target head (`target`).
        kwarg: The parsed keyword argument.
        acc: The accumulator dict (mutated in place).
        lenient: When True, skip every setting that cannot change the
            dependency list (`publicHeadersPath`, `packageAccess`,
            `resources`, `swiftSettings`, ...) instead of refusing it.
            The pub plugin spoke reads only the `.package(...)`
            declarations and the plugin target's `dependencies`, so such
            settings never change its output.

    Returns:
        `struct(ok, error)`.
    """
    key = kwarg.key
    if key == "name" or key == "path":
        one = _swiftpm_single_string(kwarg.value)
        if not one.ok:
            return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, one.detail))
        acc[key] = one.text
    elif key == "dependencies":
        return _swiftpm_apply_target_deps(identity, kwarg, acc)
    elif key == "exclude" or key == "sources":
        listed = _swiftpm_string_list(kwarg.value)
        if not listed.ok:
            return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, listed.detail))
        acc[key] = listed.items
    elif lenient:
        # The plugin spoke reads only the `.package(...)` declarations and
        # the plugin target's `dependencies`, so any other target setting
        # (`publicHeadersPath`, `packageAccess`, `resources`,
        # `swiftSettings`, ...) never changes its output.
        return struct(ok = True, error = "")
    elif key in _SWIFTPM_REFUSED_TARGET_KEYS:
        return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, _swiftpm_target_kwarg_error(acc["name"] if acc["name"] else kind, key)))
    else:
        return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, "unknown `.{kind}(...)` argument `{key}`".format(kind = kind, key = key)))
    return struct(ok = True, error = "")

def _swiftpm_parse_target_kwargs(identity, kind, args, line, lenient):
    """Parse a regular `.target(...)` call.

    Args:
        identity: The SwiftPM package identity.
        kind: The target head (`target`).
        args: The tokens between the call's parens.
        line: The call's line.
        lenient: When True, skip untranslatable target settings.

    Returns:
        `struct(ok, error, target)`: `target` holds `kind`, `name`,
        `deps`, `path` ("" when defaulted), `exclude`, `sources` (None
        when unrestricted) and `line`.
    """
    kwargs = _swiftpm_split_kwargs(args)
    if not kwargs.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, line, kwargs.detail), target = None)
    acc = {"name": "", "deps": [], "path": "", "exclude": [], "sources": None}
    for kwarg in kwargs.kwargs:
        applied = _swiftpm_apply_target_kwarg(identity, kind, kwarg, acc, lenient)
        if not applied.ok:
            return struct(ok = False, error = applied.error, target = None)
    if not acc["name"]:
        return struct(ok = False, error = _swiftpm_fail(identity, line, "a `.{kind}(...)` target without a `name:`".format(kind = kind)), target = None)
    return struct(ok = True, error = "", target = struct(kind = kind, name = acc["name"], deps = acc["deps"], path = acc["path"], exclude = acc["exclude"], sources = acc["sources"], line = line))

def _swiftpm_parse_target_element(identity, element, lenient):
    """Parse one `targets` array element of any target kind.

    Args:
        identity: The SwiftPM package identity.
        element: The element's token list.
        lenient: When True, skip untranslatable target settings.

    Returns:
        `struct(ok, error, target)`: regular `.target` declarations keep
        their full arguments; every other kind (`testTarget`,
        `executableTarget`, `binaryTarget`, `systemLibrary`, `plugin`,
        `macro`) keeps only its kind and name. Test targets are ignored
        by the translator; the rest are refused when a product reaches
        them.
    """
    line = element[0].line if element else 0
    head = _swiftpm_call_head(element)
    if not head.ok or not head.dotted:
        return struct(ok = False, error = _swiftpm_fail(identity, line, "expected a target (`.target(...)`, `.testTarget(...)` or a special target kind)"), target = None)
    if head.name == "target":
        return _swiftpm_parse_target_kwargs(identity, head.name, head.args, line, lenient)
    if head.name in ["testTarget", "executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]:
        named = _swiftpm_parse_special_target_name(identity, head.name, head.args, line)
        if not named.ok:
            return struct(ok = False, error = named.error, target = None)
        return struct(ok = True, error = "", target = struct(kind = head.name, name = named.name, deps = [], path = "", exclude = [], sources = None, line = line))
    return struct(ok = False, error = _swiftpm_fail(identity, line, "unknown target kind `.{kind}(...)`".format(kind = head.name)), target = None)

def _swiftpm_parse_special_target_name(identity, kind, args, line):
    """Read the `name:` out of an untranslatable target declaration.

    Only the name is kept: the translator refuses these targets when a
    product reaches them, so their other arguments never matter.

    Args:
        identity: The SwiftPM package identity.
        kind: The target kind.
        args: The tokens between the call's parens.
        line: The call's line.

    Returns:
        `struct(ok, error, name)`.
    """
    kwargs = _swiftpm_split_kwargs(args)
    if not kwargs.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, line, kwargs.detail), name = "")
    for kwarg in kwargs.kwargs:
        if kwarg.key == "name":
            one = _swiftpm_single_string(kwarg.value)
            if not one.ok:
                return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, one.detail), name = "")
            return struct(ok = True, error = "", name = one.text)
    return struct(ok = False, error = _swiftpm_fail(identity, line, "a `.{kind}(...)` target without a `name:`".format(kind = kind)), name = "")

def _swiftpm_parse_library_element(identity, element):
    """Parse one `products` array element.

    `.library(name:targets:)` records its product; executable and plugin
    products are ignored; anything else fails.

    Args:
        identity: The SwiftPM package identity.
        element: The element's token list.

    Returns:
        `struct(ok, error, product)`: `product` is None for an ignored
        executable or plugin product.
    """
    line = element[0].line if element else 0
    head = _swiftpm_call_head(element)
    if not head.ok or not head.dotted:
        return struct(ok = False, error = _swiftpm_fail(identity, line, "expected a product (`.library(...)`, `.executable(...)` or `.plugin(...)`)"), product = None)
    if head.name == "executable" or head.name == "plugin":
        return struct(ok = True, error = "", product = None)
    if head.name != "library":
        return struct(ok = False, error = _swiftpm_fail(identity, line, "unknown product kind `.{kind}(...)`".format(kind = head.name)), product = None)
    kwargs = _swiftpm_split_kwargs(head.args)
    if not kwargs.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, line, kwargs.detail), product = None)
    name = ""
    targets = None
    for kwarg in kwargs.kwargs:
        if kwarg.key == "name":
            one = _swiftpm_single_string(kwarg.value)
            if not one.ok:
                return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, one.detail), product = None)
            name = one.text
        elif kwarg.key == "targets":
            listed = _swiftpm_string_list(kwarg.value)
            if not listed.ok:
                return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, listed.detail), product = None)
            targets = listed.items
        elif kwarg.key == "type":
            pass
        else:
            return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, "unknown `.library(...)` argument `{key}`".format(key = kwarg.key)), product = None)
    if not name or targets == None:
        return struct(ok = False, error = _swiftpm_fail(identity, line, "a `.library(...)` product needs `name:` and `targets:`"), product = None)
    return struct(ok = True, error = "", product = struct(kind = "library", name = name, targets = targets, line = line))

_SWIFTPM_PACKAGE_DEP_STRINGS = ["name", "url", "id", "path"]
_SWIFTPM_PACKAGE_DEP_IGNORED = ["from", "exact", "branch", "revision"]

def _swiftpm_parse_package_dep_element(identity, element):
    """Parse one `dependencies` array element (`.package(...)`).

    The version requirement never matters to the rules (`Package.resolved`
    pins the revision), so besides the `from:`/`exact:`/`branch:`/
    `revision:` keyword forms any positional requirement form is accepted
    and ignored: a version range (`"6.0.0"..<"7.0.0"`), a closed range
    (`"1.0.0"..."1.9.0"`) or a requirement call (`.upToNextMajor(from:)`,
    `.upToNextMinor(from:)`, `.exact(...)`, `.branch(...)`,
    `.revision(...)`). A declaration with no `url:`, `id:`, `path:` or
    `name:`, or with an unreadable locator, still fails.

    Args:
        identity: The SwiftPM package identity.
        element: The element's token list.

    Returns:
        `struct(ok, error, dep)`: `dep` holds `name` ("" when unnamed),
        `ref` (the url, id or path, "" when none), `ref_kind` (which of
        the three), and `line`.
    """
    line = element[0].line if element else 0
    head = _swiftpm_call_head(element)
    if not head.ok or not head.dotted or head.name != "package":
        return struct(ok = False, error = _swiftpm_fail(identity, line, "expected a package dependency (`.package(...)`)"), dep = None)
    split = _swiftpm_split_commas(head.args)
    if not split.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, line, split.detail), dep = None)
    fields = {}
    kinds = {}
    seen = {}
    for part in split.parts:
        if not (len(part) >= 3 and part[0].kind == "word" and part[1].kind == "punct" and part[1].text == ":"):
            continue
        key = part[0].text
        if key in seen:
            return struct(ok = False, error = _swiftpm_fail(identity, part[0].line, "duplicate argument `{key}`".format(key = key)), dep = None)
        seen[key] = True
        if key in _SWIFTPM_PACKAGE_DEP_IGNORED:
            continue
        if key not in _SWIFTPM_PACKAGE_DEP_STRINGS:
            return struct(ok = False, error = _swiftpm_fail(identity, part[0].line, "unknown `.package(...)` argument `{key}`".format(key = key)), dep = None)
        one = _swiftpm_single_string(part[2:])
        if not one.ok:
            return struct(ok = False, error = _swiftpm_fail(identity, part[0].line, one.detail), dep = None)
        fields[key] = one.text
        if key in ["url", "id", "path"]:
            kinds[key] = key
    ref = fields.get("url", "")
    ref_kind = kinds.get("url", "")
    if not ref:
        ref = fields.get("id", "")
        ref_kind = kinds.get("id", "")
    if not ref:
        ref = fields.get("path", "")
        ref_kind = kinds.get("path", "")
    if not ref and not fields.get("name", ""):
        return struct(ok = False, error = _swiftpm_fail(identity, line, "a `.package(...)` dependency needs one of `url:`, `id:` or `path:`"), dep = None)
    return struct(ok = True, error = "", dep = struct(name = fields.get("name", ""), ref = ref, ref_kind = ref_kind, line = line))

def _swiftpm_apply_package_array(identity, kwarg, acc, key, lenient):
    """Fold a `products:`/`dependencies:`/`targets:` array into the model.

    Args:
        identity: The SwiftPM package identity.
        kwarg: The parsed keyword argument.
        acc: The accumulator dict (mutated in place).
        key: Which array this is.
        lenient: When True, skip untranslatable target settings.

    Returns:
        `struct(ok, error)`.
    """
    array = _swiftpm_array_parts(kwarg.value)
    if not array.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, array.detail))
    for element in array.elements:
        if key == "products":
            parsed = _swiftpm_parse_library_element(identity, element)
            if not parsed.ok:
                return struct(ok = False, error = parsed.error)
            if parsed.product != None:
                acc["products"].append(parsed.product)
        elif key == "dependencies":
            parsed = _swiftpm_parse_package_dep_element(identity, element)
            if not parsed.ok:
                return struct(ok = False, error = parsed.error)
            acc["pkg_deps"].append(parsed.dep)
        else:
            parsed = _swiftpm_parse_target_element(identity, element, lenient)
            if not parsed.ok:
                return struct(ok = False, error = parsed.error)
            acc["targets"].append(parsed.target)
    return struct(ok = True, error = "")

def _swiftpm_apply_package_kwarg(identity, kwarg, acc, lenient):
    """Fold one `Package(...)` keyword argument into the model.

    Args:
        identity: The SwiftPM package identity.
        kwarg: The parsed keyword argument.
        acc: The accumulator dict (mutated in place).
        lenient: When True, skip package settings outside the
            `products:`/`dependencies:`/`targets:` the plugin spoke
            reads (`defaultLocalization`, `pkgConfig`, `providers`,
            ...).

    Returns:
        `struct(ok, error)`.
    """
    key = kwarg.key
    if key == "name" or key == "platforms" or key == "cLanguageStandard" or key == "cxxLanguageStandard":
        return struct(ok = True, error = "")
    if key == "products" or key == "dependencies" or key == "targets":
        return _swiftpm_apply_package_array(identity, kwarg, acc, key, lenient)
    if key == "swiftLanguageVersions" or key == "swiftLanguageModes":
        parsed = _swiftpm_parse_modes(kwarg.value)
        if not parsed.ok:
            return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, parsed.detail))
        acc["modes"].extend(parsed.modes)
        return struct(ok = True, error = "")
    if lenient:
        # The plugin spoke reads only `products:`, `dependencies:` and
        # `targets:`, so any other package setting (`defaultLocalization`,
        # `pkgConfig`, `providers`, ...) never changes its output.
        return struct(ok = True, error = "")
    return struct(ok = False, error = _swiftpm_fail(identity, kwarg.line, "unknown `Package(...)` argument `{key}`".format(key = key)))

def _swiftpm_parse_package_kwargs(identity, args, line, lenient):
    """Parse the `Package(...)` argument list into a model.

    Args:
        identity: The SwiftPM package identity.
        args: The tokens between the call's parens.
        line: The `let package` line.
        lenient: When True, skip untranslatable target settings.

    Returns:
        `struct(ok, error, model)` without tools version or line info.
    """
    kwargs = _swiftpm_split_kwargs(args)
    if not kwargs.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, line, kwargs.detail), model = None)
    acc = {"products": [], "targets": [], "pkg_deps": [], "modes": []}
    for kwarg in kwargs.kwargs:
        applied = _swiftpm_apply_package_kwarg(identity, kwarg, acc, lenient)
        if not applied.ok:
            return struct(ok = False, error = applied.error, model = None)
    return struct(ok = True, error = "", model = struct(products = acc["products"], targets = acc["targets"], pkg_deps = acc["pkg_deps"], modes = acc["modes"]))

def _swiftpm_parse_statement(identity, seg, acc, lenient):
    """Fold one top-level statement into the parse accumulator.

    Args:
        identity: The SwiftPM package identity.
        seg: The statement's token list.
        acc: The accumulator struct (`has_package`, `products`,
            `targets`, `pkg_deps`, `modes`).
        lenient: When True, skip untranslatable target settings.

    Returns:
        `struct(ok, error, acc)`.
    """
    line = seg[0].line if seg else 0
    snippet = " ".join([_swiftpm_token_text(seg, i) for i in range(3)])
    if len(seg) == 2 and seg[0].kind == "word" and seg[0].text == "import" and seg[1].kind == "word" and seg[1].text == "PackageDescription":
        return struct(ok = True, error = "", acc = acc)
    if seg and seg[0].kind == "word" and seg[0].text == "import":
        return struct(ok = False, error = _swiftpm_fail(identity, line, "only `import PackageDescription` is supported, not `{snippet}`".format(snippet = snippet)), acc = acc)
    if len(seg) >= 4 and seg[0].kind == "word" and (seg[0].text == "let" or seg[0].text == "var") and seg[1].kind == "word" and seg[1].text == "package" and seg[2].kind == "punct" and seg[2].text == "=":
        if acc.has_package:
            return struct(ok = False, error = _swiftpm_fail(identity, line, "a duplicate `let package` declaration"), acc = acc)
        head = _swiftpm_call_head(seg[3:])
        if not head.ok or head.dotted or head.name != "Package":
            return struct(ok = False, error = _swiftpm_fail(identity, line, "`let package` must be one literal `Package(...)` call"), acc = acc)
        parsed = _swiftpm_parse_package_kwargs(identity, head.args, line, lenient)
        if not parsed.ok:
            return struct(ok = False, error = parsed.error, acc = acc)
        return struct(ok = True, error = "", acc = struct(
            has_package = True,
            products = acc.products + parsed.model.products,
            targets = acc.targets + parsed.model.targets,
            pkg_deps = acc.pkg_deps + parsed.model.pkg_deps,
            modes = acc.modes + parsed.model.modes,
        ))
    if seg and seg[0].kind == "word" and (seg[0].text == "let" or seg[0].text == "var"):
        return struct(ok = False, error = _swiftpm_fail(identity, line, "variables are not supported: the manifest must declare one literal `let package = Package(...)`"), acc = acc)
    if seg and seg[0].kind == "word" and seg[0].text == "package":
        return struct(ok = False, error = _swiftpm_fail(identity, line, "`package` must not be mutated after its declaration"), acc = acc)
    return struct(ok = False, error = _swiftpm_fail(identity, line, "unsupported top-level statement `{snippet}`: the manifest holds `import PackageDescription` and one literal `let package = Package(...)`".format(snippet = snippet)), acc = acc)

def _swiftpm_check_duplicates(identity, products, targets):
    """Refuse duplicate product or target names.

    Args:
        identity: The SwiftPM package identity.
        products: The parsed products.
        targets: The parsed targets.

    Returns:
        "" or the fetch failure naming the duplicate.
    """
    seen_products = {}
    for product in products:
        if product.name in seen_products:
            return _swiftpm_fail(identity, product.line, "a duplicate product {name}".format(name = repr(product.name)))
        seen_products[product.name] = True
    seen_targets = {}
    for target in targets:
        if target.name:
            if target.name in seen_targets:
                return _swiftpm_fail(identity, target.line, "a duplicate target {name}".format(name = repr(target.name)))
            seen_targets[target.name] = True
    return ""

def _swiftpm_parse_text(identity, text, lenient):
    """Parse a manifest, optionally skipping untranslatable target settings.

    Args:
        identity: The SwiftPM package identity, for messages.
        text: The manifest text.
        lenient: When True, skip target settings with no Bazel
            translation instead of refusing them.

    Returns:
        `struct(ok, error, model)`: `model` holds `tools_major`,
        `tools_minor`, `products`, `targets`, `pkg_deps` and `modes`.
    """
    first = swiftpm_first_content_line(text)
    if not first.ok:
        return struct(ok = False, error = _swiftpm_fail(identity, 1, "the manifest is empty"), model = None)
    tools = parse_swiftpm_tools_line(first.line, first.line_no, identity)
    if not tools.ok:
        return struct(ok = False, error = tools.error, model = None)
    if tools.major < 4:
        return struct(ok = False, error = _swiftpm_fail(identity, first.line_no, "tools version {major}.{minor} is older than the supported 4.0".format(major = tools.major, minor = tools.minor)), model = None)
    lexed = lex_swiftpm_manifest(text, identity)
    if not lexed.ok:
        return struct(ok = False, error = lexed.error, model = None)
    for tok in lexed.tokens:
        if tok.kind == "directive":
            return struct(ok = False, error = _swiftpm_fail(identity, tok.line, "conditional compilation (`{directive}`) is not supported".format(directive = tok.text)), model = None)
        if tok.kind == "str" and tok.interp:
            return struct(ok = False, error = _swiftpm_fail(identity, tok.line, "string interpolation is not supported"), model = None)
    acc = struct(has_package = False, products = [], targets = [], pkg_deps = [], modes = [])
    for seg in _swiftpm_split_statements(lexed.tokens):
        folded = _swiftpm_parse_statement(identity, seg, acc, lenient)
        if not folded.ok:
            return struct(ok = False, error = folded.error, model = None)
        acc = folded.acc
    if not acc.has_package:
        return struct(ok = False, error = _swiftpm_fail(identity, first.line_no, "no `let package = Package(...)` declaration"), model = None)
    dup = _swiftpm_check_duplicates(identity, acc.products, acc.targets)
    if dup:
        return struct(ok = False, error = dup, model = None)
    return struct(ok = True, error = "", model = struct(
        tools_major = tools.major,
        tools_minor = tools.minor,
        products = acc.products,
        targets = acc.targets,
        pkg_deps = acc.pkg_deps,
        modes = acc.modes,
    ))

def parse_swiftpm_package(identity, text):
    """Parse a `Package.swift` manifest into the translator's model.

    The strict entry point the hub's SwiftPM package spokes use:
    every untranslatable target setting fails the fetch.

    Args:
        identity: The SwiftPM package identity, for messages.
        text: The manifest text.

    Returns:
        `struct(ok, error, model)`: `model` holds `tools_major`,
        `tools_minor`, `products`, `targets`, `pkg_deps` and `modes`.
    """
    return _swiftpm_parse_text(identity, text, False)

def parse_swiftpm_plugin_package(identity, text):
    """Parse a plugin's `Package.swift` for the pub spoke's product links.

    The lenient entry point the pub plugin spoke uses: target settings
    (`publicHeadersPath`, `packageAccess`, `resources`, `swiftSettings`,
    ...) and package settings (`defaultLocalization`, `pkgConfig`,
    `providers`, ...) outside the `products:`/`dependencies:`/`targets:`
    the spoke reads are skipped, because the spoke keeps its own source,
    header and privacy-manifest detection and reads only the manifest's
    `.package(...)` declarations and the plugin target's `dependencies`
    (with their `condition:`). Anything making the dependency list
    itself unknowable (an unreadable `dependencies:` entry, a variable
    or interpolation inside it, `#if`, an unreadable `.package(...)`)
    still fails.

    Args:
        identity: The pub plugin name, for messages.
        text: The manifest text.

    Returns:
        `struct(ok, error, model)`: `model` holds `tools_major`,
        `tools_minor`, `products`, `targets`, `pkg_deps` and `modes`.
    """
    return _swiftpm_parse_text(identity, text, True)
