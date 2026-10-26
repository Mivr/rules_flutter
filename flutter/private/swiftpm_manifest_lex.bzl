"""Bounded lexer for SwiftPM `Package.swift` manifests.

Turns the manifest text into a token list for `swiftpm_manifest.bzl`. The
pattern follows the Gradle lexer (`gradle_lex.bzl`): one bounded `for` loop
over the input dispatches per-state step functions through a handler table
holding a mutable context dict (Starlark has no `while`, and the contract
forbids recursion here).

Tokens are structs of `kind`, `text` and `line`, where `kind` is one of
`"nl"` (line break), `"str"` (a double-quoted literal; `text` is the inner
value), `"word"`, `"num"`, `"punct"` (one character) or `"directive"` (a
`#...` token such as `#if`). A string holding `\\(` interpolation is marked
with `interp = True` so the parser can refuse it with its line: computed
values have no place in a manifest Bazel translates. Comments (line and
nesting block comments, as Swift accepts them) never reach the parser.
"""

_SWIFTPM_LEX_BOUND_SLACK = 2

def _swiftpm_is_word_start(c):
    """True when `c` can open a Swift identifier.

    Args:
        c: A single character.

    Returns:
        True for letters and `_`.
    """
    return ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"

def _swiftpm_is_word_char(c):
    """True when `c` can continue a Swift identifier.

    Args:
        c: A single character.

    Returns:
        True for letters, digits and `_`.
    """
    return _swiftpm_is_word_start(c) or ("0" <= c and c <= "9")

def _swiftpm_is_digit(c):
    """True when `c` is an ASCII digit.

    Args:
        c: A single character.

    Returns:
        True for `0`–`9`.
    """
    return "0" <= c and c <= "9"

def _swiftpm_consume_run(content, n, i):
    """Consume an identifier or number run starting at `i`.

    Args:
        content: The manifest text.
        n: `len(content)`.
        i: The position the run starts at.

    Returns:
        The index one past the run of word characters.
    """
    for _ in range(n + 1):
        if i >= n or not _swiftpm_is_word_char(content[i:i + 1]):
            break
        i += 1
    return i

def _swiftpm_lex_emit(ctx, kind, text):
    """Append one token to the context, stamped with the current line.

    Args:
        ctx: The lexer context dict.
        kind: The token kind.
        text: The token text.
    """
    ctx["tokens"].append(struct(kind = kind, text = text, line = ctx["line"], interp = False))

def _swiftpm_lex_code(ctx):
    """Lex one character in code state; words and numbers emit whole."""
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    c = content[i:i + 1]
    two = content[i:i + 2]
    if two == "//":
        ctx["state"] = 1
        ctx["i"] = i + 2
    elif two == "/*":
        ctx["state"] = 2
        ctx["depth"] = 1
        ctx["comment_line"] = ctx["line"]
        ctx["i"] = i + 2
    elif c == '"':
        if content[i:i + 3] == '"""':
            ctx["state"] = 4
        else:
            ctx["state"] = 3
        ctx["str_line"] = ctx["line"]
        ctx["interp"] = False
        ctx["buf"] = []
        ctx["i"] = i + (3 if content[i:i + 3] == '"""' else 1)
    elif c == "#":
        end = _swiftpm_consume_run(content, n, i + 1)
        ctx["tokens"].append(struct(kind = "directive", text = content[i:end], line = ctx["line"], interp = False))
        ctx["i"] = end
    elif _swiftpm_is_word_start(c):
        end = _swiftpm_consume_run(content, n, i)
        _swiftpm_lex_emit(ctx, "word", content[i:end])
        ctx["i"] = end
    elif _swiftpm_is_digit(c):
        end = _swiftpm_consume_run(content, n, i)
        _swiftpm_lex_emit(ctx, "num", content[i:end])
        ctx["i"] = end
    elif c == "\n":
        _swiftpm_lex_emit(ctx, "nl", "\n")
        ctx["line"] = ctx["line"] + 1
        ctx["i"] = i + 1
    elif c == " " or c == "\t" or c == "\r":
        ctx["i"] = i + 1
    else:
        _swiftpm_lex_emit(ctx, "punct", c)
        ctx["i"] = i + 1

def _swiftpm_lex_line_comment(ctx):
    """Skip a `//` comment up to (and emitting) its newline."""
    if ctx["content"][ctx["i"]:ctx["i"] + 1] == "\n":
        _swiftpm_lex_emit(ctx, "nl", "\n")
        ctx["line"] = ctx["line"] + 1
        ctx["state"] = 0
    ctx["i"] = ctx["i"] + 1

def _swiftpm_lex_block_comment(ctx):
    """Skip one character of a (nesting) block comment."""
    content = ctx["content"]
    i = ctx["i"]
    two = content[i:i + 2]
    if two == "/*":
        ctx["depth"] = ctx["depth"] + 1
        ctx["i"] = i + 2
    elif two == "*/":
        ctx["depth"] = ctx["depth"] - 1
        ctx["i"] = i + 2
        if ctx["depth"] <= 0:
            ctx["state"] = 0
    else:
        if content[i:i + 1] == "\n":
            ctx["line"] = ctx["line"] + 1
        ctx["i"] = i + 1

def _swiftpm_lex_string_char(ctx, terminator):
    """Lex one character inside a string; True when the string closed.

    Args:
        ctx: The lexer context dict.
        terminator: One double-quote, or three for a multiline string.

    Returns:
        True when the closing quote was consumed.
    """
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    if content[i:i + len(terminator)] == terminator:
        text = "".join(ctx["buf"])
        ctx["tokens"].append(struct(kind = "str", text = text, line = ctx["str_line"], interp = ctx["interp"]))
        ctx["buf"] = []
        ctx["state"] = 0
        ctx["i"] = i + len(terminator)
        return True
    c = content[i:i + 1]
    if c == "\\" and i + 1 < n:
        if content[i + 1:i + 2] == "(":
            ctx["interp"] = True
        ctx["buf"].append(c)
        ctx["buf"].append(content[i + 1:i + 2])
        ctx["i"] = i + 2
        return False
    if c == "\n":
        ctx["line"] = ctx["line"] + 1
    ctx["buf"].append(c)
    ctx["i"] = i + 1
    return False

def _swiftpm_lex_short_string(ctx):
    """Lex inside a `"..."` string; a newline ends the file's patience.

    A single-quoted-line string never spans lines in Swift: a newline
    before the closing quote fails the lex with the opener's line.
    """
    if ctx["content"][ctx["i"]:ctx["i"] + 1] == "\n":
        ctx["error"] = "unterminated string literal"
        ctx["error_line"] = ctx["str_line"]
        ctx["i"] = ctx["n"]
        return
    _swiftpm_lex_string_char(ctx, '"')

def _swiftpm_lex_long_string(ctx):
    """Lex inside a triple-quoted string, which may span lines."""
    _swiftpm_lex_string_char(ctx, '"""')

def _swiftpm_lex_events(content):
    """Run the lexer states over `content`.

    Args:
        content: The manifest text.

    Returns:
        `struct(ok, error, error_line, tokens)`.
    """
    n = len(content)
    ctx = {
        "content": content,
        "n": n,
        "tokens": [],
        "buf": [],
        "state": 0,
        "depth": 0,
        "line": 1,
        "str_line": 1,
        "comment_line": 1,
        "interp": False,
        "error": "",
        "error_line": 1,
        "i": 0,
    }
    handlers = {
        0: _swiftpm_lex_code,
        1: _swiftpm_lex_line_comment,
        2: _swiftpm_lex_block_comment,
        3: _swiftpm_lex_short_string,
        4: _swiftpm_lex_long_string,
    }
    for _ in range(n + _SWIFTPM_LEX_BOUND_SLACK):
        if ctx["i"] >= n or ctx["error"]:
            break
        handlers[ctx["state"]](ctx)
    if ctx["error"]:
        return struct(ok = False, error = ctx["error"], error_line = ctx["error_line"], tokens = [])
    if ctx["state"] == 3 or ctx["state"] == 4:
        return struct(ok = False, error = "unterminated string literal", error_line = ctx["str_line"], tokens = [])
    if ctx["state"] == 2:
        return struct(ok = False, error = "unterminated block comment", error_line = ctx["comment_line"], tokens = [])
    return struct(ok = True, error = "", error_line = 1, tokens = ctx["tokens"])

def lex_swiftpm_manifest(text, identity):
    """Tokenize a `Package.swift` manifest.

    Args:
        text: The manifest text.
        identity: The SwiftPM package identity, for messages.

    Returns:
        `struct(ok, error, tokens)`: `error` names the identity,
        `Package.swift` and the line on failure.
    """
    lexed = _swiftpm_lex_events(text)
    if not lexed.ok:
        return struct(
            ok = False,
            error = "SwiftPM package {identity} (Package.swift line {line}): {detail}.".format(
                identity = repr(identity),
                line = lexed.error_line,
                detail = lexed.error,
            ),
            tokens = [],
        )
    return struct(ok = True, error = "", tokens = lexed.tokens)

def _swiftpm_parse_version_number(text, pos, n):
    """Read a digit run at `pos`.

    Args:
        text: The tools-version line.
        pos: The position to read at.
        n: `len(text)`.

    Returns:
        `struct(ok, value, end)`: not-ok when no digit opens at `pos`.
    """
    end = pos
    for _ in range(n + 1):
        if end >= n or not ("0" <= text[end:end + 1] and text[end:end + 1] <= "9"):
            break
        end += 1
    if end == pos:
        return struct(ok = False, value = 0, end = pos)
    return struct(ok = True, value = int(text[pos:end]), end = end)

def _swiftpm_skip_blanks(text, pos, n):
    """Skip spaces and tabs from `pos`.

    Args:
        text: The tools-version line.
        pos: The position to start from.
        n: `len(text)`.

    Returns:
        The first position at or after `pos` holding no blank.
    """
    for _ in range(n + 1):
        if pos >= n or (text[pos:pos + 1] != " " and text[pos:pos + 1] != "\t"):
            break
        pos += 1
    return pos

def parse_swiftpm_tools_line(line, line_no, identity):
    """Parse the `// swift-tools-version:X[.Y[.Z]]` specification line.

    Spacing follows what SwiftPM accepts: blanks around `//`, between the
    marker and the label, and around the version; the label matches
    case-insensitively.

    Args:
        line: The raw line text (without its newline).
        line_no: The line number, for messages.
        identity: The SwiftPM package identity, for messages.

    Returns:
        `struct(ok, error, major, minor, patch)`.
    """
    bad = struct(ok = False, error = "SwiftPM package {identity} (Package.swift line {line}): the first line must read `// swift-tools-version:X[.Y[.Z]]`.".format(identity = repr(identity), line = line_no), major = 0, minor = 0, patch = 0)
    n = len(line)
    pos = _swiftpm_skip_blanks(line, 0, n)
    if line[pos:pos + 2] != "//":
        return bad
    pos = _swiftpm_skip_blanks(line, pos + 2, n)
    label = "swift-tools-version:"
    if line[pos:pos + len(label)].lower() != label:
        return bad
    pos = _swiftpm_skip_blanks(line, pos + len(label), n)
    major = _swiftpm_parse_version_number(line, pos, n)
    if not major.ok:
        return bad
    pos = major.end
    minor = struct(ok = True, value = 0, end = pos)
    patch = struct(ok = True, value = 0, end = pos)
    if line[pos:pos + 1] == ".":
        minor = _swiftpm_parse_version_number(line, pos + 1, n)
        if not minor.ok:
            return bad
        pos = minor.end
        if line[pos:pos + 1] == ".":
            patch = _swiftpm_parse_version_number(line, pos + 1, n)
            if not patch.ok:
                return bad
            pos = patch.end
    if _swiftpm_skip_blanks(line, pos, n) != n:
        return bad
    return struct(ok = True, error = "", major = major.value, minor = minor.value, patch = patch.value)

def swiftpm_first_content_line(text):
    """Find the first non-blank line of the manifest.

    Args:
        text: The manifest text.

    Returns:
        `struct(ok, line, line_no)`: not-ok for an all-blank file.
    """
    lines = text.split("\n")
    for i in range(len(lines)):
        if lines[i].strip():
            return struct(ok = True, line = lines[i], line_no = i + 1)
    return struct(ok = False, line = "", line_no = 0)
