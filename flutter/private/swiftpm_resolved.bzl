"""`Package.resolved` reading and pin classification for SwiftPM spokes.

Only versions 2 and 3 (`{"pins": [...], "version": N}`) are supported;
version 1 (`object.pins`) fails naming the file. Starlark's `json.decode`
reports no file on malformed input, so a bounded tokenizer and checker run
first and fail naming the resolved label. Pin classification is pure, so
Starlark unit tests drive every pinned/unpinned shape without fetching.
"""

def is_swiftpm_identity(text):
    """Whether `text` is a usable SwiftPM package identity.

    Args:
        text: The candidate identity.

    Returns:
        True for non-empty lowercase letters, digits, `.`, `_` and `-`.
    """
    if not text:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("a" <= char and char <= "z") or ("0" <= char and char <= "9") or char == "." or char == "_" or char == "-"):
            return False
    return True

def is_swiftpm_sha256(text):
    """Whether `text` is a pinned SHA-256 hex digest.

    Args:
        text: The candidate digest.

    Returns:
        True for exactly 64 lowercase hex characters.
    """
    if len(text) != 64:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("0" <= char and char <= "9") or ("a" <= char and char <= "f")):
            return False
    return True

def is_swiftpm_revision(text):
    """Whether `text` is a usable commit revision.

    Args:
        text: The candidate `state.revision`.

    Returns:
        True for exactly 40 hex characters of either case.
    """
    if len(text) != 40:
        return False
    for i in range(len(text)):
        char = text[i]
        if not (("0" <= char and char <= "9") or ("a" <= char and char <= "f") or ("A" <= char and char <= "F")):
            return False
    return True

def swiftpm_spoke_name(hub_name, identity):
    """The spoke repository name for one SwiftPM pin.

    Args:
        hub_name: The `flutter.pub` hub name.
        identity: The SwiftPM package identity.

    Returns:
        `<hub>__swiftpm-<identity>`.
    """
    return hub_name + "__swiftpm-" + identity

def _swiftpm_bad_location():
    """The `swiftpm_github_parts` failure for a non-GitHub location.

    Returns:
        The failure struct with reason `"location"`.
    """
    return struct(ok = False, owner = "", repo = "", reason = "location")

def _swiftpm_https_parts(rest):
    """Split the host-and-path remainder of an `https://` location.

    Args:
        rest: The location past the `https://` scheme.

    Returns:
        `struct(ok, owner, repo, reason)`.
    """
    slash = rest.find("/")
    if slash < 0:
        return _swiftpm_bad_location()
    if rest[:slash].lower() != "github.com":
        return _swiftpm_bad_location()
    path = rest[slash + 1:]
    first = path.find("/")
    if first < 0 or path.find("/", first + 1) >= 0:
        return _swiftpm_bad_location()
    owner = path[:first]
    repo = path[first + 1:]
    if repo.endswith(".git"):
        repo = repo[:len(repo) - 4]
    if not owner or not repo:
        return _swiftpm_bad_location()
    return struct(ok = True, owner = owner, repo = repo, reason = "")

def _swiftpm_scp_parts(rest):
    """Split the remainder of a `git@` scp-like location.

    Args:
        rest: The location past the `git@` prefix.

    Returns:
        `struct(ok, owner, repo, reason)`: reason `"ssh"` marks a
        `git@github.com` location without the `.git` suffix.
    """
    colon = rest.find(":")
    if colon < 0:
        return _swiftpm_bad_location()
    if rest[:colon].lower() != "github.com":
        return _swiftpm_bad_location()
    path = rest[colon + 1:]
    if not path.endswith(".git"):
        return struct(ok = False, owner = "", repo = "", reason = "ssh")
    path = path[:len(path) - 4]
    first = path.find("/")
    if first < 0 or path.find("/", first + 1) >= 0:
        return _swiftpm_bad_location()
    owner = path[:first]
    repo = path[first + 1:]
    if not owner or not repo:
        return _swiftpm_bad_location()
    return struct(ok = True, owner = owner, repo = repo, reason = "")

def swiftpm_github_parts(location):
    """Split a pin location into a GitHub owner/repo.

    Accepts `https://github.com/<owner>/<repo>[.git]` (any host letter
    case) and `git@github.com:<owner>/<repo>.git`. Anything else —
    another host, another scheme, a `git@` location without the `.git`
    suffix — is not a fetchable GitHub repository.

    Args:
        location: The pin's `location` string.

    Returns:
        `struct(ok, owner, repo, reason)`: `reason` is "" when ok, else
        `"ssh"` (a `git@github.com` location without `.git`) or
        `"location"` (not a GitHub repository location at all).
    """
    if location[:8].lower() == "https://":
        return _swiftpm_https_parts(location[len("https://"):])
    if location.startswith("git@"):
        return _swiftpm_scp_parts(location[len("git@"):])
    return _swiftpm_bad_location()

def _swiftpm_json_scan_gap(char):
    """Whether one character is JSON whitespace outside strings.

    Args:
        char: The single character.

    Returns:
        Whether it is a space, tab, carriage return or newline.
    """
    return char == " " or char == "\t" or char == "\r" or char == "\n"

def _swiftpm_json_scan_one(text, i, line):
    """Scan the single token starting at one index.

    Args:
        text: The full text.
        i: The index of the token's first character (never whitespace).
        line: The line the token starts on.

    Returns:
        `struct(ok, detail, kind, next, line)`: `kind` is "" when the
        character starts no token.
    """
    char = text[i]
    if char == "{" or char == "}" or char == "[" or char == "]" or char == "," or char == ":":
        return struct(ok = True, detail = "", kind = char, next = i + 1, line = line)
    if char == "\"":
        parsed = _swiftpm_json_string(text, i, line)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "str", next = parsed.next, line = parsed.line)
    if char == "-" or ("0" <= char and char <= "9"):
        parsed = _swiftpm_json_number(text, i)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "num", next = parsed.next, line = line)
    if ("a" <= char and char <= "z") or ("A" <= char and char <= "Z"):
        parsed = _swiftpm_json_literal(text, i)
        if not parsed.ok:
            return struct(ok = False, detail = parsed.detail, kind = "", next = i, line = line)
        return struct(ok = True, detail = "", kind = "lit", next = parsed.next, line = line)
    return struct(ok = False, detail = "unexpected character {char}".format(char = repr(char)), kind = "", next = i, line = line)

def _swiftpm_json_tokenize(text):
    """Tokenize JSON text without decoding it.

    Args:
        text: The candidate JSON text.

    Returns:
        `struct(ok, detail, tokens)`: tokens carry `kind` (`{`, `}`, `[`,
        `]`, `,`, `:`, `str`, `num`, `lit`) and `line`.
    """
    tokens = []
    i = 0
    line = 1
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        if _swiftpm_json_scan_gap(text[i]):
            if text[i] == "\n":
                line += 1
            i += 1
            continue
        scanned = _swiftpm_json_scan_one(text, i, line)
        if not scanned.ok:
            return struct(ok = False, detail = scanned.detail, tokens = [])
        tokens.append(struct(kind = scanned.kind, line = line))
        i = scanned.next
        line = scanned.line
    return struct(ok = True, detail = "", tokens = tokens)

def _swiftpm_json_is_hex(char):
    """Whether one character is an ASCII hex digit.

    Args:
        char: The single character.

    Returns:
        True for `0-9`, `a-f` and `A-F`.
    """
    return ("0" <= char and char <= "9") or ("a" <= char and char <= "f") or ("A" <= char and char <= "F")

def _swiftpm_json_unicode(text, i, n):
    """Skip the four hex digits of a `\\u` escape.

    Args:
        text: The full text.
        i: The index of the `u`.
        n: The text length.

    Returns:
        `struct(ok, detail, next)`: `next` is past the fourth digit.
    """
    for j in range(1, 5):
        if i + j >= n:
            return struct(ok = False, detail = "a bad `\\u` escape", next = i)
        if not _swiftpm_json_is_hex(text[i + j]):
            return struct(ok = False, detail = "a bad `\\u` escape", next = i)
    return struct(ok = True, detail = "", next = i + 5)

def _swiftpm_json_escape(text, i, n):
    """Skip one backslash escape inside a JSON string.

    Args:
        text: The full text.
        i: The index of the backslash.
        n: The text length.

    Returns:
        `struct(ok, detail, next)`: `next` is past the escape.
    """
    if i + 1 >= n:
        return struct(ok = False, detail = "an unterminated string", next = i)
    esc = text[i + 1]
    if esc == "u":
        return _swiftpm_json_unicode(text, i + 1, n)
    if esc == "\"" or esc == "\\" or esc == "/" or esc == "b" or esc == "f" or esc == "n" or esc == "r" or esc == "t":
        return struct(ok = True, detail = "", next = i + 2)
    return struct(ok = False, detail = "a bad escape {esc}".format(esc = repr("\\" + esc)), next = i + 1)

def _swiftpm_json_string(text, start, line):
    """Skip one JSON string literal.

    Args:
        text: The full text.
        start: The index of the opening quote.
        line: The line the string starts on.

    Returns:
        `struct(ok, detail, next, line)`: `next` is the index past the
        closing quote.
    """
    i = start + 1
    n = len(text)
    for _ in range(n - start):
        if i >= n:
            return struct(ok = False, detail = "an unterminated string", next = i, line = line)
        char = text[i]
        if char == "\"":
            return struct(ok = True, detail = "", next = i + 1, line = line)
        if char == "\n":
            return struct(ok = False, detail = "an unterminated string", next = i, line = line)
        if char == "\\":
            skipped = _swiftpm_json_escape(text, i, n)
            if not skipped.ok:
                return struct(ok = False, detail = skipped.detail, next = skipped.next, line = line)
            i = skipped.next
            continue
        i += 1
    return struct(ok = False, detail = "an unterminated string", next = i, line = line)

def _swiftpm_json_digits(text, i, n):
    """Skip one run of ASCII digits.

    Args:
        text: The full text.
        i: The index the run starts at.
        n: The text length.

    Returns:
        `struct(next, count)`: the index past the run and its length.
    """
    count = 0
    for _ in range(n - i):
        if i >= n or text[i] < "0" or text[i] > "9":
            break
        i += 1
        count += 1
    return struct(next = i, count = count)

def _swiftpm_json_number(text, start):
    """Skip one JSON number literal.

    Args:
        text: The full text.
        start: The index the number starts at.

    Returns:
        `struct(ok, detail, next)`: `next` is the index past the number.
    """
    i = start
    n = len(text)
    if i < n and text[i] == "-":
        i += 1
    if i >= n:
        return struct(ok = False, detail = "a bad number", next = i)
    if text[i] == "0":
        i += 1
    elif "1" <= text[i] and text[i] <= "9":
        i = _swiftpm_json_digits(text, i, n).next
    else:
        return struct(ok = False, detail = "a bad number", next = i)
    if i < n and text[i] == ".":
        frac = _swiftpm_json_digits(text, i + 1, n)
        if frac.count == 0:
            return struct(ok = False, detail = "a bad number", next = frac.next)
        i = frac.next
    if i < n and (text[i] == "e" or text[i] == "E"):
        i += 1
        if i < n and (text[i] == "+" or text[i] == "-"):
            i += 1
        exp = _swiftpm_json_digits(text, i, n)
        if exp.count == 0:
            return struct(ok = False, detail = "a bad number", next = exp.next)
        i = exp.next
    return struct(ok = True, detail = "", next = i)

def _swiftpm_json_literal(text, start):
    """Skip one `true`, `false` or `null` literal.

    Args:
        text: The full text.
        start: The index the literal starts at.

    Returns:
        `struct(ok, detail, next)`.
    """
    for word in ["true", "false", "null"]:
        if text[start:start + len(word)] == word:
            after = start + len(word)
            if after < len(text):
                tail = text[after]
                if ("a" <= tail and tail <= "z") or ("A" <= tail and tail <= "Z") or ("0" <= tail and tail <= "9") or tail == "_":
                    continue
            return struct(ok = True, detail = "", next = after)
    return struct(ok = False, detail = "an unknown literal", next = start)

def _swiftpm_json_after_value(stack, counts):
    """Fold one completed value into the checker state.

    Args:
        stack: The open containers (`{`/`[`).
        counts: The per-frame completed values (mutated in place).

    Returns:
        The next state (`"sep"` or `"end"`).
    """
    if not stack:
        return "end"
    counts[len(counts) - 1] += 1
    return "sep"

def _swiftpm_json_check_val(tok, stack, counts):
    """Consume one token where a value is expected.

    Args:
        tok: The token.
        stack: The open containers (`{`/`[`; mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == "str" or tok.kind == "num" or tok.kind == "lit":
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    if tok.kind == "{":
        stack.append("{")
        counts.append(0)
        return struct(ok = True, detail = "", state = "key")
    if tok.kind == "[":
        stack.append("[")
        counts.append(0)
        return struct(ok = True, detail = "", state = "val")
    if tok.kind == "]" and stack and stack[len(stack) - 1] == "[" and counts[len(counts) - 1] == 0:
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected a value", state = "")

def _swiftpm_json_check_key(tok, stack, counts):
    """Consume one token where an object key is expected.

    Args:
        tok: The token.
        stack: The open containers (mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == "str":
        return struct(ok = True, detail = "", state = "colon")
    if tok.kind == "}" and stack and stack[len(stack) - 1] == "{" and counts[len(counts) - 1] == 0:
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected an object key", state = "")

def _swiftpm_json_check_sep(tok, stack, counts):
    """Consume one token where a separator or closing bracket is expected.

    Args:
        tok: The token.
        stack: The open containers (mutated in place).
        counts: The per-frame completed values (mutated in place).

    Returns:
        `struct(ok, detail, state)`: the next state.
    """
    if tok.kind == ",":
        if stack[len(stack) - 1] == "{":
            return struct(ok = True, detail = "", state = "key")
        return struct(ok = True, detail = "", state = "val")
    if tok.kind == "]" and stack[len(stack) - 1] == "[":
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    if tok.kind == "}" and stack[len(stack) - 1] == "{":
        stack.pop()
        counts.pop()
        return struct(ok = True, detail = "", state = _swiftpm_json_after_value(stack, counts))
    return struct(ok = False, detail = "expected a `,` or a closing bracket", state = "")

def _swiftpm_json_check_tokens(tokens):
    """Check one token stream against the JSON value grammar.

    Iterative over an explicit stack, so nesting depth cannot overflow
    Starlark call depth.

    Args:
        tokens: The tokenized stream.

    Returns:
        `struct(ok, detail)`.
    """
    stack = []
    counts = []
    state = "val"
    for tok in tokens:
        if state == "val":
            stepped = _swiftpm_json_check_val(tok, stack, counts)
        elif state == "key":
            stepped = _swiftpm_json_check_key(tok, stack, counts)
        elif state == "colon":
            if tok.kind == ":":
                stepped = struct(ok = True, detail = "", state = "val")
            else:
                stepped = struct(ok = False, detail = "expected a `:`", state = "")
        elif state == "sep":
            stepped = _swiftpm_json_check_sep(tok, stack, counts)
        else:
            return struct(ok = False, detail = "trailing content after the top-level value")
        if not stepped.ok:
            return struct(ok = False, detail = stepped.detail)
        state = stepped.state
    if state == "end":
        return struct(ok = True, detail = "")
    return struct(ok = False, detail = "an incomplete document")

def _swiftpm_check_json(text, label):
    """Fail malformed JSON naming the resolved file.

    Args:
        text: The file content.
        label: The resolved label, for messages.

    Returns:
        "" or the fetch failure naming the file and the first problem.
    """
    tokenized = _swiftpm_json_tokenize(text)
    if not tokenized.ok:
        return "Cannot parse {label} as JSON: {detail}.".format(label = label, detail = tokenized.detail)
    checked = _swiftpm_json_check_tokens(tokenized.tokens)
    if not checked.ok:
        return "Cannot parse {label} as JSON: {detail}.".format(label = label, detail = checked.detail)
    return ""

def read_swiftpm_pins(content, label):
    """Read the pins out of a `Package.resolved` file.

    Args:
        content: The file content.
        label: The resolved label, for messages.

    Returns:
        `struct(ok, error, pins)`: `pins` lists `struct(identity, kind,
        location, revision)`.
    """
    bad = _swiftpm_check_json(content, label)
    if bad:
        return struct(ok = False, error = bad, pins = [])
    data = json.decode(content)
    if type(data) != "dict":
        return struct(ok = False, error = "{label} must hold a JSON object.".format(label = label), pins = [])
    version = data.get("version", 0)
    if version == 1 or "object" in data:
        return struct(ok = False, error = "{label} is a version 1 `Package.resolved` (`object.pins`): re-resolve it with Xcode to version 2 or 3.".format(label = label), pins = [])
    if version != 2 and version != 3:
        return struct(ok = False, error = "{label} has an unsupported version ({version}): only versions 2 and 3 parse.".format(label = label, version = repr(version)), pins = [])
    raw_pins = data.get("pins", None)
    if type(raw_pins) != "list":
        return struct(ok = False, error = "{label} has no top-level `pins` array.".format(label = label), pins = [])
    pins = []
    for raw in raw_pins:
        if type(raw) != "dict":
            return struct(ok = False, error = "{label} holds a pin that is not an object.".format(label = label), pins = [])
        identity = raw.get("identity", "")
        kind = raw.get("kind", "")
        location = raw.get("location", "")
        state = raw.get("state", None)
        revision = state.get("revision", "") if type(state) == "dict" else ""
        if type(identity) != "string" or not is_swiftpm_identity(identity):
            return struct(ok = False, error = "{label} holds a pin with an unusable identity ({identity}): identities are lowercase letters, digits, `.`, `_` and `-`.".format(label = label, identity = repr(identity)), pins = [])
        if type(kind) != "string":
            return struct(ok = False, error = "{label} holds a pin {pin} with no `kind`.".format(label = label, pin = repr(identity)), pins = [])
        if type(location) != "string" or not location:
            return struct(ok = False, error = "{label} holds a pin {pin} with no `location`.".format(label = label, pin = repr(identity)), pins = [])
        if type(revision) != "string" or not revision:
            return struct(ok = False, error = "{label} holds a pin {pin} with no `state.revision`.".format(label = label, pin = repr(identity)), pins = [])
        pins.append(struct(identity = identity, kind = kind, location = location, revision = revision))
    return struct(ok = True, error = "", pins = pins)

def classify_swiftpm_pin(pin, sha256_by_identity, hub_name, resolved_label):
    """Decide how one pin fetches: pinned download or fail-closed refusal.

    A pin is pinned only with all of kind `remoteSourceControl`, a GitHub
    location, a usable `state.revision`, and a `swift_package_sha256` dict
    entry. Anything missing becomes one fetch failure whose clauses each
    name their fix; the checksum clause carries the exact archive URL when
    the location parses.

    Args:
        pin: The pin struct from `read_swiftpm_pins`.
        sha256_by_identity: The `swift_package_sha256` dict.
        hub_name: The `flutter.pub` hub name.
        resolved_label: The resolved label, for messages.

    Returns:
        `struct(ok, url, sha256, error)`: the exact archive URL and digest
        when pinned, else the fetch failure.
    """
    sha = sha256_by_identity.get(pin.identity, "")
    parts = swiftpm_github_parts(pin.location)
    kind_ok = pin.kind == "remoteSourceControl"
    rev_ok = is_swiftpm_revision(pin.revision)
    sha_ok = sha != "" and is_swiftpm_sha256(sha)
    if kind_ok and parts.ok and rev_ok and sha_ok:
        url = "https://github.com/{owner}/{repo}/archive/{revision}.tar.gz".format(owner = parts.owner, repo = parts.repo, revision = pin.revision)
        return struct(ok = True, url = url, sha256 = sha, error = "")
    problems = []
    if not sha_ok:
        if sha == "":
            if parts.ok:
                url = "https://github.com/{owner}/{repo}/archive/{revision}.tar.gz".format(owner = parts.owner, repo = parts.repo, revision = pin.revision)
                problems.append("has no `swift_package_sha256[{identity}]` entry: download {url} and record its SHA-256 digest".format(identity = repr(pin.identity), url = url))
            else:
                problems.append("has no `swift_package_sha256[{identity}]` entry, and its location parses to no downloadable archive URL".format(identity = repr(pin.identity)))
        else:
            problems.append("has an invalid `swift_package_sha256[{identity}]` entry (not 64 lowercase hex characters)".format(identity = repr(pin.identity)))
    if not rev_ok:
        problems.append("has no usable `state.revision` (a 40-character commit hash)")
    if not kind_ok:
        problems.append("has kind {kind} (not `remoteSourceControl`)".format(kind = repr(pin.kind)))
    if not parts.ok:
        if parts.reason == "ssh":
            problems.append("has a `git@github.com` location without a `.git` suffix, which is unresolvable: {location}".format(location = repr(pin.location)))
        else:
            problems.append("has a location that is not a GitHub repository (`https://github.com/<owner>/<repo>` or `git@github.com:<owner>/<repo>.git`): {location}".format(location = repr(pin.location)))
    return struct(ok = False, url = "", sha256 = "", error = "{spoke}: SwiftPM package {identity} (pinned in {label}) cannot be fetched: {problems}.".format(
        spoke = swiftpm_spoke_name(hub_name, pin.identity),
        identity = repr(pin.identity),
        label = resolved_label,
        problems = "; ".join(problems),
    ))

def check_swiftpm_config_present(resolved, sha256_by_identity, build_files):
    """Refuse checksum/build-file dicts with no resolved file to pin.

    Args:
        resolved: The resolved label string, or None when unset.
        sha256_by_identity: The `swift_package_sha256` dict.
        build_files: The `swift_package_build_files` dict.

    Returns:
        "" or the failure naming the dicts without entries to attach to.
    """
    if resolved != None:
        return ""
    problems = []
    if sha256_by_identity:
        problems.append("`swift_package_sha256` names checksums with no `swift_package_resolved` file pinning the packages they belong to")
    if build_files:
        problems.append("`swift_package_build_files` names overrides with no `swift_package_resolved` file pinning the packages they belong to")
    if not problems:
        return ""
    return "flutter.pub: {problems}; set `swift_package_resolved` first.".format(problems = "; ".join(problems))

def check_swiftpm_dicts(sha256_by_identity, build_files, pin_identities, resolved_label):
    """Validate the checksum/build-file dicts against the pins.

    Args:
        sha256_by_identity: The `swift_package_sha256` dict.
        build_files: The `swift_package_build_files` dict.
        pin_identities: Every identity pinned in the resolved file.
        resolved_label: The resolved label, for messages.

    Returns:
        "" or the first failure: unknown dict keys, malformed digests,
        or non-absolute override labels.
    """
    pinned = {identity: True for identity in pin_identities}
    for identity in sorted(sha256_by_identity.keys()):
        if identity not in pinned:
            return "flutter.pub: `swift_package_sha256[{identity}]` names a package pinned nowhere in {label}.".format(identity = repr(identity), label = resolved_label)
        if not is_swiftpm_sha256(sha256_by_identity[identity]):
            return "flutter.pub: `swift_package_sha256[{identity}]` is not 64 lowercase hex characters.".format(identity = repr(identity))
    for identity in sorted(build_files.keys()):
        if identity not in pinned:
            return "flutter.pub: `swift_package_build_files[{identity}]` names a package pinned nowhere in {label}.".format(identity = repr(identity), label = resolved_label)
        target = build_files[identity]
        if "\n" in target or "\\" in target or "\"" in target:
            return "flutter.pub: `swift_package_build_files[{identity}]` is not a Bazel label.".format(identity = repr(identity))
        if not target.startswith("@") and not target.startswith("//"):
            return "flutter.pub: `swift_package_build_files[{identity}]` must be an absolute label (`@...` or `//...`), got {target}.".format(identity = repr(identity), target = repr(target))
    return ""
