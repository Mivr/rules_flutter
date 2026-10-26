"""Byte codec and segment resolution for asset URI normalization (RT35-flutter:01, opus-2026-10-26:L-7).

Provides byte encoding/decoding and RFC 3986 §5.2.4 dot-segment resolution
matching Dart 3.13.5 `Uri.parse` and `Uri(pathSegments:)`.
"""

_BYTES = (
    "\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017" +
    "\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037" +
    "\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057" +
    "\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077" +
    "\100\101\102\103\104\105\106\107\110\111\112\113\114\115\116\117" +
    "\120\121\122\123\124\125\126\127\130\131\132\133\134\135\136\137" +
    "\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157" +
    "\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177" +
    "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217" +
    "\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237" +
    "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257" +
    "\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277" +
    "\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317" +
    "\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337" +
    "\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357" +
    "\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377"
)

_HEX_DIGITS = "0123456789ABCDEF"
_HEX_LOOKUP = "0123456789abcdefABCDEF"

_LITERAL_SEGMENT_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@"
_UNRESERVED_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

def _hex_byte(text, i):
    """The byte value of the two hex digits at `text[i:i + 2]`, or -1.

    Args:
        text: The string holding the digits.
        i: Index of the first digit.

    Returns:
        The byte value, or -1 when either character is not a hex digit.
    """
    hi = _HEX_LOOKUP.find(text[i])
    lo = _HEX_LOOKUP.find(text[i + 1])
    if hi < 0 or lo < 0:
        return -1
    if hi >= 16:
        hi -= 6
    if lo >= 16:
        lo -= 6
    return hi * 16 + lo

def _lead_window(lead):
    """The continuation window a UTF-8 lead byte opens, strictly.

    Args:
        lead: The lead byte value (>= 0x80; ASCII never reaches here).

    Returns:
        `struct(ok, need, lo, hi)`: `need` continuations, each within
        `lo..hi`; `ok = False` for a byte that opens no valid sequence.
    """
    if lead < 0xC2:
        return struct(ok = False, need = 0, lo = 0, hi = 0)
    if lead < 0xE0:
        return struct(ok = True, need = 1, lo = 0x80, hi = 0xBF)
    if lead == 0xE0:
        return struct(ok = True, need = 2, lo = 0xA0, hi = 0xBF)
    if lead < 0xED:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0xBF)
    if lead == 0xED:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0x9F)
    if lead < 0xF0:
        return struct(ok = True, need = 2, lo = 0x80, hi = 0xBF)
    if lead == 0xF0:
        return struct(ok = True, need = 3, lo = 0x90, hi = 0xBF)
    if lead < 0xF4:
        return struct(ok = True, need = 3, lo = 0x80, hi = 0xBF)
    if lead == 0xF4:
        return struct(ok = True, need = 3, lo = 0x80, hi = 0x8F)
    return struct(ok = False, need = 0, lo = 0, hi = 0)

def _ascii_byte_refusal(v, need):
    """The refusal reason for one ASCII byte, or "" when it bundles.

    Args:
        v: The byte value (below 0x80).
        need: Continuations still owed to an open sequence, if any.

    Returns:
        "" when the byte bundles, else why the spelling is not supported.
    """
    if need:
        return "an escape is cut off mid-sequence and is not valid UTF-8"
    if v == 0x2F:
        return "an escape decodes to `/`"
    if v == 0x5C:
        return "it holds a backslash"
    if v == 0x3A:
        return "it holds a `:`"
    if v < 0x20 or v == 0x7F:
        return "it holds a control character"
    return ""

def _step_multibyte(v, need, lo, hi):
    """Fold one non-ASCII byte into the open UTF-8 sequence, if any.

    Args:
        v: The byte value (0x80 or above).
        need: Continuations still owed to an open sequence, if any.
        lo: The low end of the continuation window the lead opened.
        hi: The high end of the continuation window the lead opened.

    Returns:
        `struct(refusal, need, lo, hi)`: the refusal reason ("" when the
        byte fits) and the updated sequence state.
    """
    if need:
        if v < lo or v > hi:
            return struct(refusal = "an escape is not valid UTF-8", need = 0, lo = 0, hi = 0)
        return struct(refusal = "", need = need - 1, lo = 0x80, hi = 0xBF)
    window = _lead_window(v)
    if not window.ok:
        return struct(refusal = "an escape is not valid UTF-8", need = 0, lo = 0, hi = 0)
    return struct(refusal = "", need = window.need, lo = window.lo, hi = window.hi)

def check_segment_bytes(values):
    """The refusal reason for decoded segment bytes, or "" when bundlable.

    Args:
        values: The decoded byte values of one segment.

    Returns:
        "" when the bytes bundle, else why the spelling is not supported.
    """
    need = 0
    lo = 0
    hi = 0
    for v in values:
        if v < 0x80:
            refusal = _ascii_byte_refusal(v, need)
            if refusal:
                return refusal
        else:
            step = _step_multibyte(v, need, lo, hi)
            if step.refusal:
                return step.refusal
            need = step.need
            lo = step.lo
            hi = step.hi
    if need:
        return "an escape is cut off mid-sequence and is not valid UTF-8"
    return ""

def encode_segment(text, first = False):
    """Percent-encode one decoded segment exactly like Dart's `Uri(pathSegments:)`.

    Args:
        text: The decoded segment text.
        first: Whether this is the key's first segment.

    Returns:
        The encoded segment string.
    """
    chars = []
    for unit in text.elems():
        if unit in _LITERAL_SEGMENT_CHARS and not (first and unit == ":"):
            chars.append(unit)
        else:
            v = _BYTES.find(unit)
            chars.append("%" + _HEX_DIGITS[v // 16] + _HEX_DIGITS[v % 16])
    return "".join(chars)

def decode_segment(raw):
    """Decode one string-form raw `/`-separated piece.

    Valid `%XX` escapes decode to UTF-8 in `text` and `values`. In `key`,
    unreserved escapes (`A-Z a-z 0-9 - . _ ~`) decode, reserved pchar
    escapes (`! $ & ' ( ) * + , ; = @`) stay uppercase `%XX`, literal
    unreserved/reserved characters stay literal, and all other bytes
    (spaces, lone `%`, non-ASCII) encode as uppercase `%XX`.

    Args:
        raw: The segment as written in the entry.

    Returns:
        `struct(ok, values, text, key, reason)`: the byte values, decoded text,
        `Uri.parse`-matching key, or the refusal reason.
    """
    values = []
    decoded_chars = []
    key_chars = []
    i = 0
    n = len(raw)
    for _ in range(n + 1):
        if i >= n:
            break
        if raw[i] == "%" and i + 3 <= n and _hex_byte(raw, i + 1) >= 0:
            v = _hex_byte(raw, i + 1)
            values.append(v)
            ch = _BYTES[v:v + 1]
            decoded_chars.append(ch)
            if ch in _UNRESERVED_CHARS:
                key_chars.append(ch)
            else:
                key_chars.append("%" + _HEX_DIGITS[v // 16] + _HEX_DIGITS[v % 16])
            i += 3
        elif raw[i] == "%":
            values.append(37)
            decoded_chars.append("%")
            key_chars.append("%25")
            i += 1
        else:
            unit = raw[i]
            v = _BYTES.find(unit)
            if v < 0:
                return struct(ok = False, values = [], text = "", key = "", reason = "it holds a byte outside 0-255")
            values.append(v)
            decoded_chars.append(unit)
            if unit in _LITERAL_SEGMENT_CHARS:
                key_chars.append(unit)
            else:
                key_chars.append("%" + _HEX_DIGITS[v // 16] + _HEX_DIGITS[v % 16])
            i += 1
    return struct(ok = True, values = values, text = "".join(decoded_chars), key = "".join(key_chars), reason = "")

def literal_segment(raw):
    """Read one raw `/`-separated piece literally, for map-form entries.

    Mirrors `Uri(pathSegments: path.split('/'))`: no byte is special, so
    `%XX` never decodes and `%` encodes to `%25`.

    Args:
        raw: The segment as written in the entry.

    Returns:
        `struct(ok, values, text, key, reason)`: the byte values, unchanged
        text, encoded key, or the refusal reason.
    """
    values = []
    for unit in raw.elems():
        v = _BYTES.find(unit)
        if v < 0:
            return struct(ok = False, values = [], text = "", key = "", reason = "it holds a byte outside 0-255")
        values.append(v)
    return struct(ok = True, values = values, text = raw, key = encode_segment(raw, False), reason = "")

def resolve_segments(items):
    """Dot-resolve decoded segment items per RFC 3986 §5.2.4.

    Removes `.` segments and resolves `x/..` pairs. When `.` or `..` is the
    final segment, preserves a trailing empty segment `""` to mark directory
    entries. A `..` with nothing left to pop escapes the package and is refused,
    as is a resolution with no non-empty collapsed segments.

    Args:
        items: List of `struct(decoded, key, pkg_key)` per segment.

    Returns:
        `struct(ok, decoded_segments, key_segments, pkg_key_segments, reason)`:
        the resolved segments or the refusal reason.
    """
    out_decoded = []
    out_key = []
    out_pkg_key = []
    n = len(items)
    for i, item in enumerate(items):
        is_last = (i == n - 1)
        if item.decoded == ".":
            if is_last:
                out_decoded.append("")
                out_key.append("")
                out_pkg_key.append("")
            continue
        if item.decoded == "..":
            if not out_decoded:
                return struct(
                    ok = False,
                    decoded_segments = [],
                    key_segments = [],
                    pkg_key_segments = [],
                    reason = "a `..` segment escapes the package",
                )
            out_decoded.pop(len(out_decoded) - 1)
            out_key.pop(len(out_key) - 1)
            out_pkg_key.pop(len(out_pkg_key) - 1)
            if is_last:
                out_decoded.append("")
                out_key.append("")
                out_pkg_key.append("")
            continue
        out_decoded.append(item.decoded)
        out_key.append(item.key)
        out_pkg_key.append(item.pkg_key)
    return struct(
        ok = True,
        decoded_segments = out_decoded,
        key_segments = out_key,
        pkg_key_segments = out_pkg_key,
        reason = "",
    )
