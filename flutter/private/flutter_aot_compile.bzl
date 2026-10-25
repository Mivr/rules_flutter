"""Flutter AOT compilation action using gen_snapshot.

gen_snapshot converts a kernel .dill file into native code.
Output format depends on the target platform:
- Android/Linux/Windows: ELF shared library (app.so) via --snapshot_kind=app-aot-elf
- macOS/iOS: Mach-O dylib (App.framework/App) via --snapshot_kind=app-aot-macho-dylib
"""

def _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, spec):
    """Internal helper for all AOT compilation variants.

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output native library File.
        spec: struct describing the snapshot variant: `snapshot_kind` (the
            `--snapshot_kind=` value), `output_flag` (the output flag name),
            `strip` (whether to pass `--strip`), `extra_flags` (additional
            gen_snapshot flags), `extra_outputs` (additional output Files),
            `mnemonic` (the action mnemonic).
    """
    args = ctx.actions.args()
    args.add("--deterministic")
    args.add("--snapshot_kind=" + spec.snapshot_kind)
    args.add(spec.output_flag + "=" + output.path)

    if spec.strip:
        args.add("--strip")

    args.add_all(spec.extra_flags)
    args.add(kernel_dill)

    ctx.actions.run(
        executable = gen_snapshot,
        arguments = [args],
        inputs = depset(
            direct = [kernel_dill],
        ),
        outputs = [output] + spec.extra_outputs,
        mnemonic = spec.mnemonic,
        progress_message = "AOT compiling Flutter %s %s" % (spec.snapshot_kind, ctx.label),
    )

# `extra_gen_snapshot_options` entries that take a plain-integer value, as flag
# names without the leading dashes. Heap and GC sizing for the compiler run
# itself: they bound the compiler's memory, name no file, and change neither
# the snapshot bytes nor where they go. Name matching ignores case and treats
# `-` and `_` as the same, the way the VM parses them.
_GEN_SNAPSHOT_UINT_OPTIONS = {
    # Sizes the compiler old-generation heap.
    "old-gen-heap-size": True,
    # Sizes the compiler new-generation semi space.
    "new-gen-semi-initial-size": True,
    # Caps the compiler new-generation semi space.
    "new-gen-semi-max-size": True,
    # Grows the compiler new generation while garbage stays below this share.
    "new-gen-garbage-threshold": True,
    # Grows the compiler new generation by this factor.
    "new-gen-growth-factor": True,
}

# `extra_gen_snapshot_options` entries that take no value, as flag names
# without the leading dashes. Only compiler diagnostics that print to
# stdout/stderr plus the rule-managed snapshot flags: nothing here reads or
# writes a file, and nothing changes the snapshot kind, the output path or
# format, the target OS or architecture, or the debugging-info output. A
# `--no-` prefix is recognised on these booleans the way the VM parses it.
# Everything else fails analysis: notably `--snapshot-kind`, `--elf`,
# `--macho`, `--assembly`, `--save-debugging-info`, `--save-obfuscation-map`,
# `--write-v8-snapshot-profile-to` and unknown flags.
_GEN_SNAPSHOT_BARE_OPTIONS = {
    # Logs the compiler garbage collector to stderr.
    "verbose-gc": True,
    # Collects the compiler heap concurrently.
    "concurrent-mark": True,
    # Sweeps the compiler heap concurrently.
    "concurrent-sweep": True,
    # Prints the snapshot size breakdown to stdout.
    "print-snapshot-sizes": True,
    # Renames identifiers; the rules dedup it against `obfuscate`.
    "obfuscate": True,
    # Keeps DWARF stack traces; the rules dedup it against `split_debug_info`.
    "dwarf-stack-traces": True,
}

def _normalize_gen_snapshot_name(name):
    """Unifies one gen_snapshot flag name the way the VM parses it.

    Args:
        name: The flag name without leading dashes or `=value`.

    Returns:
        The lower-cased name with every `_` replaced by `-`.
    """
    return name.lower().replace("_", "-")

def _gen_snapshot_entry_parts(label, entry):
    """Splits one `extra_gen_snapshot_options` entry into its flag parts.

    Args:
        label: The calling target's label, for error messages.
        entry: The raw string entry.

    Returns:
        A struct with `base` (the normalised flag name without any `no-`
        prefix), `negated` (whether a `no-` prefix was present) and `value`
        (the `=value`, or None when bare).
    """
    if "\n" in entry or "\r" in entry:
        fail("%s: extra_gen_snapshot_options entry %r contains a line break: argv-bound strings must be single-line" % (label, entry))
    if not entry.startswith("-") or entry == "-":
        fail("%s: extra_gen_snapshot_options entries must be gen_snapshot `--flag`s, got %r" % (label, entry))
    stripped = entry[2:] if entry.startswith("--") else entry[1:]
    if stripped == "" or stripped.startswith("-"):
        fail("%s: extra_gen_snapshot_options entries must be gen_snapshot `--flag`s, got %r" % (label, entry))
    name, eq, value = stripped.partition("=")
    norm = _normalize_gen_snapshot_name(name)
    negated = False
    if norm.startswith("no-"):
        negated = True
        norm = norm[3:]
    if norm == "":
        fail("%s: extra_gen_snapshot_options entries must be gen_snapshot `--flag`s, got %r" % (label, entry))
    return struct(base = norm, negated = negated, value = value if eq else None)

def _is_gen_snapshot_uint(value):
    """Whether `value` is a plain non-empty integer for a sizing flag.

    Args:
        value: The flag value string, or None when the flag was bare.

    Returns:
        True for a non-empty all-digit string.
    """
    if value == None or value == "":
        return False
    for c in value.elems():
        if c not in "0123456789":
            return False
    return True

def _gen_snapshot_allowed_spellings():
    """Every accepted `extra_gen_snapshot_options` flag, for error messages."""
    return ["--" + f for f in sorted(_GEN_SNAPSHOT_UINT_OPTIONS.keys() + _GEN_SNAPSHOT_BARE_OPTIONS.keys())] + ["--strip", "--no-strip", "--deterministic"]

def _refuse_gen_snapshot_entry(label, entry):
    """Fails analysis for an `extra_gen_snapshot_options` entry on no allow-list.

    Args:
        label: The calling target's label, for the message.
        entry: The raw string entry, for the message.
    """
    fail("%s: extra_gen_snapshot_options %r is not allowed: only %s may be passed; flags that write a file the action does not declare (`--save-obfuscation-map`, `--save-debugging-info`, `--write-v8-snapshot-profile-to`), flags that change the snapshot kind or its outputs (`--snapshot-kind`, `--elf`, `--macho`, `--assembly`) and unknown flags are refused" % (label, entry, ", ".join(_gen_snapshot_allowed_spellings())))

# `extra_gen_snapshot_options` bases refused with a dedicated-attribute
# message: the tail names the attribute to use instead of the flag.
_GEN_SNAPSHOT_DEDICATED = {
    # The rules emit `--save-debugging-info` themselves from `split_debug_info`.
    "save-debugging-info": "writes a debugging-info file the action does not declare: set `split_debug_info = True` instead of passing `--save-debugging-info`",
    # The rules emit `--save-obfuscation-map` themselves from `obfuscate`.
    "save-obfuscation-map": "writes an obfuscation map the action does not declare: set `obfuscate = True` and read the `obfuscation_map` output group instead of passing `--save-obfuscation-map`",
}

def _classify_gen_snapshot_entry(label, entry, parts, value):
    """Sorts one parsed `extra_gen_snapshot_options` entry, failing when refused.

    Args:
        label: The calling target's label, for error messages.
        entry: The raw string entry, for error messages.
        parts: The `_gen_snapshot_entry_parts` struct for the entry.
        value: The `=value` or paired following entry, or None when bare.

    Returns:
        A struct with `kind` (`"keep"` with `flag` holding the canonical
        `--name` / `--name=value` spelling, `"drop"` for rule-carried flags,
        or `"no-strip"`), `obfuscate` (whether the caller passed the positive
        `--obfuscate` the rules dedup) and `dwarf` (likewise for
        `--dwarf-stack-traces`).
    """
    base = parts.base
    if base == "strip":
        if value != None:
            fail("%s: extra_gen_snapshot_options %r takes no value: `--strip` is a bare flag" % (label, entry))
        if parts.negated:
            return struct(kind = "no-strip", flag = None, obfuscate = False, dwarf = False)
        return struct(kind = "drop", flag = None, obfuscate = False, dwarf = False)
    if base == "deterministic":
        if parts.negated:
            fail("%s: extra_gen_snapshot_options %r is not allowed: the rules always pass `--deterministic`; remove the flag" % (label, entry))
        if value != None:
            fail("%s: extra_gen_snapshot_options %r takes no value: `--deterministic` is a bare flag" % (label, entry))
        return struct(kind = "drop", flag = None, obfuscate = False, dwarf = False)
    if base in _GEN_SNAPSHOT_DEDICATED:
        fail("%s: extra_gen_snapshot_options %r %s" % (label, entry, _GEN_SNAPSHOT_DEDICATED[base]))
    if base in _GEN_SNAPSHOT_UINT_OPTIONS:
        if not _is_gen_snapshot_uint(value):
            fail("%s: extra_gen_snapshot_options %r needs `--%s=<bytes>` with a plain integer value" % (label, entry, base))
        return struct(kind = "keep", flag = "--" + base + "=" + value, obfuscate = False, dwarf = False)
    if base in _GEN_SNAPSHOT_BARE_OPTIONS:
        if value != None:
            fail("%s: extra_gen_snapshot_options %r takes no value: `--%s` is a bare flag" % (label, entry, base))
        return struct(
            kind = "keep",
            flag = "--" + ("no-" if parts.negated else "") + base,
            obfuscate = base == "obfuscate" and not parts.negated,
            dwarf = base == "dwarf-stack-traces" and not parts.negated,
        )
    _refuse_gen_snapshot_entry(label, entry)
    return struct(kind = "drop", flag = None, obfuscate = False, dwarf = False)

def _check_gen_snapshot_options(label, entries):
    """Validates every `extra_gen_snapshot_options` entry at analysis.

    A `--name value` pair split across two entries is recognised as one flag
    with a value, so a file-writing flag cannot hide its path in the next
    entry. Each entry is classified by `_classify_gen_snapshot_entry`, which
    fails analysis on anything outside the allow-list. Accepted flags come back
    in canonical `--name` / `--name=value` spelling; `--strip` is dropped (the
    action's `strip` parameter carries it exactly once) and `--deterministic`
    is dropped (the action passes it on every compile).

    Args:
        label: The calling target's label, for error messages.
        entries: The raw `extra_gen_snapshot_options` strings.

    Returns:
        A struct with `kept` (the canonical flags for the command line),
        `has_no_strip` (whether the caller passed `--no-strip`),
        `no_strip_raw` (its raw spelling, for the error when `obfuscate` is
        set), `saw_obfuscate` and `saw_dwarf` (whether the caller already
        passed the positive `--obfuscate` / `--dwarf-stack-traces` the rules
        would add).
    """
    kept = []
    has_no_strip = False
    no_strip_raw = None
    saw_obfuscate = False
    saw_dwarf = False
    skip_next = False
    count = len(entries)
    for i in range(count):
        if skip_next:
            skip_next = False
            continue
        entry = entries[i]
        parts = _gen_snapshot_entry_parts(label, entry)
        value = parts.value
        if value == None and i + 1 < count and not entries[i + 1].startswith("-"):
            value = entries[i + 1]
            skip_next = True
        if value != None and ("\n" in value or "\r" in value):
            fail("%s: extra_gen_snapshot_options entry %r contains a line break: argv-bound strings must be single-line" % (label, entry))
        found = _classify_gen_snapshot_entry(label, entry, parts, value)
        if found.kind == "keep":
            kept.append(found.flag)
        elif found.kind == "no-strip":
            has_no_strip = True
            no_strip_raw = entry
        if found.obfuscate:
            saw_obfuscate = True
        if found.dwarf:
            saw_dwarf = True
    return struct(
        kept = kept,
        has_no_strip = has_no_strip,
        no_strip_raw = no_strip_raw,
        saw_obfuscate = saw_obfuscate,
        saw_dwarf = saw_dwarf,
    )

def flutter_aot_gen_snapshot_flags(ctx, strip):
    """Build gen_snapshot extra flags/outputs from a rule's AOT attrs.

    Shared by `flutter_application` and `flutter_aot_target` so the two cannot
    drift on `obfuscate`, `split_debug_info`, or `extra_gen_snapshot_options`.

    `extra_gen_snapshot_options` is an allow-list (see
    `_GEN_SNAPSHOT_UINT_OPTIONS` and `_GEN_SNAPSHOT_BARE_OPTIONS`): only
    gen_snapshot flags that read no file and write no file, and that change
    neither the snapshot kind, the output path or format, the target OS or
    architecture, nor the debugging-info output. Anything else fails analysis
    naming the target, the parameter and the flag; `--save-debugging-info`
    and `--save-obfuscation-map` fail naming `split_debug_info` and
    `obfuscate` instead. `--strip` is accepted and ignored (the action's
    `strip` parameter carries it exactly once); `--no-strip` disables
    stripping and reports `strip = False`, and fails with `obfuscate`, which
    needs stripping.

    `--resolve-dwarf-paths` is deliberately omitted: it rewrites the DWARF
    script URIs to filesystem paths, which fails for the `org-dartlang-app:`
    multi-root URIs these rules compile under and would embed host paths in
    the debugging info. `--dwarf-stack-traces` keeps DWARF stack traces and
    `--save-debugging-info` keeps the split output without resolving paths.

    When `obfuscate` is set the returned `strip` is forced True: gen_snapshot
    embeds full DWARF debugging info carrying the original, unobfuscated names
    unless `--strip` is passed (it warns about this itself), so an unstripped
    "obfuscated" snapshot still leaks every class name. gen_snapshot also
    writes a declared obfuscation map then, exposed through the
    `obfuscation_map` output group; without `obfuscate` nothing extra is
    declared.

    Args:
        ctx: Rule context carrying the AOT attributes.
        strip: Whether the caller would strip for the current compilation mode.

    Returns:
        A tuple of (extra_flags, extra_outputs, debug_info_output,
        obfuscation_map_output, strip).
    """
    checked = _check_gen_snapshot_options(ctx.label, ctx.attr.extra_gen_snapshot_options)
    extra_flags = checked.kept
    extra_outputs = []
    debug_info_output = None
    obfuscation_map_output = None

    if ctx.attr.obfuscate and not checked.saw_obfuscate:
        extra_flags.append("--obfuscate")

    if ctx.attr.split_debug_info:
        debug_info_output = ctx.actions.declare_file(ctx.label.name + ".symbols")
        if not checked.saw_dwarf:
            extra_flags.append("--dwarf-stack-traces")
        extra_flags.append("--save-debugging-info=" + debug_info_output.path)
        extra_outputs.append(debug_info_output)

    if ctx.attr.obfuscate:
        if checked.has_no_strip:
            fail("%s: extra_gen_snapshot_options %r cannot be used with `obfuscate = True`: obfuscation needs stripping (gen_snapshot keeps the original names in unstripped debugging info); remove `--no-strip`" % (ctx.label, checked.no_strip_raw))
        obfuscation_map_output = ctx.actions.declare_file(ctx.label.name + ".obfuscation_map.json")
        extra_flags.append("--save-obfuscation-map=" + obfuscation_map_output.path)
        extra_outputs.append(obfuscation_map_output)

    if checked.has_no_strip:
        strip = False
        extra_flags.append("--no-strip")
    elif ctx.attr.obfuscate:
        strip = True

    return extra_flags, extra_outputs, debug_info_output, obfuscation_map_output, strip

def flutter_aot_elf_action(ctx, gen_snapshot, kernel_dill, output, strip = True, extra_flags = [], extra_outputs = []):
    """AOT compile to ELF shared library. Used for Android, Linux, Windows."""
    _flutter_aot_action(
        ctx = ctx,
        gen_snapshot = gen_snapshot,
        kernel_dill = kernel_dill,
        output = output,
        spec = struct(
            snapshot_kind = "app-aot-elf",
            output_flag = "--elf",
            strip = strip,
            extra_flags = extra_flags,
            extra_outputs = extra_outputs,
            mnemonic = "FlutterAotElf",
        ),
    )

def macho_snapshot_options(
        min_os_version = None,
        install_name = "@rpath/App.framework/App",
        rpath = "@executable_path/Frameworks,@loader_path/Frameworks"):
    """Mach-O dylib naming options for `flutter_aot_macho_action`.

    Args:
        min_os_version: Optional minimum OS version for LC_BUILD_VERSION.
        install_name: Mach-O LC_ID_DYLIB install name.
        rpath: Comma-separated LC_RPATH entries to embed in the Mach-O dylib.

    Returns:
        A struct with `install_name`, `min_os_version` and `rpath`.
    """
    return struct(
        install_name = install_name,
        min_os_version = min_os_version,
        rpath = rpath,
    )

def flutter_aot_macho_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        macho,
        strip = True,
        extra_flags = [],
        extra_outputs = []):
    """AOT compile to Mach-O dylib. Used for macOS and iOS.

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output dylib File.
        macho: Mach-O naming options from `macho_snapshot_options`.
        strip: Whether to strip debug symbols.
        extra_flags: Additional gen_snapshot flags.
        extra_outputs: Additional output Files (e.g. debug info).
    """
    macho_flags = list(extra_flags)
    macho_flags.append("--macho-install-name=" + macho.install_name)
    if macho.min_os_version:
        macho_flags.append("--macho-min-os-version=" + macho.min_os_version)
    if macho.rpath:
        macho_flags.append("--macho-rpath=" + macho.rpath)
    _flutter_aot_action(
        ctx = ctx,
        gen_snapshot = gen_snapshot,
        kernel_dill = kernel_dill,
        output = output,
        spec = struct(
            snapshot_kind = "app-aot-macho-dylib",
            output_flag = "--macho",
            strip = strip,
            extra_flags = macho_flags,
            extra_outputs = extra_outputs,
            mnemonic = "FlutterAotMacho",
        ),
    )
