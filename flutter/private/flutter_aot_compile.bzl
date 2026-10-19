"""Flutter AOT compilation action using gen_snapshot.

gen_snapshot converts a kernel .dill file into native code.
Output format depends on the target platform:
- Android/Linux/Windows: ELF shared library (app.so) via --snapshot_kind=app-aot-elf
- macOS/iOS: Mach-O dylib (App.framework/App) via --snapshot_kind=app-aot-macho-dylib
"""

def _flutter_aot_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        snapshot_kind,
        output_flag,
        strip = True,
        extra_flags = [],
        extra_outputs = [],
        mnemonic = "FlutterAot"):
    """Internal helper for all AOT compilation variants."""
    args = ctx.actions.args()
    args.add("--deterministic")
    args.add("--snapshot_kind=" + snapshot_kind)
    args.add(output_flag + "=" + output.path)

    if strip:
        args.add("--strip")

    args.add_all(extra_flags)
    args.add(kernel_dill)

    ctx.actions.run(
        executable = gen_snapshot,
        arguments = [args],
        inputs = depset(
            direct = [kernel_dill],
        ),
        outputs = [output] + extra_outputs,
        mnemonic = mnemonic,
        progress_message = "AOT compiling Flutter %s %s" % (snapshot_kind, ctx.label),
    )

def flutter_aot_gen_snapshot_flags(ctx):
    """Build gen_snapshot extra flags/outputs from a rule's AOT attrs.

    Shared by `flutter_application` and `flutter_aot_target` so the two cannot
    drift on `obfuscate`, `split_debug_info`, or `extra_gen_snapshot_options`.
    """
    extra_flags = list(ctx.attr.extra_gen_snapshot_options)
    extra_outputs = []
    debug_info_output = None
    if ctx.attr.obfuscate:
        extra_flags.append("--obfuscate")
    if ctx.attr.split_debug_info:
        debug_info_output = ctx.actions.declare_file(ctx.label.name + ".symbols")
        extra_flags.extend(["--dwarf-stack-traces", "--resolve-dwarf-paths", "--save-debugging-info=" + debug_info_output.path])
        extra_outputs.append(debug_info_output)
    return extra_flags, extra_outputs, debug_info_output


def flutter_aot_elf_action(ctx, gen_snapshot, kernel_dill, output, strip = True, extra_flags = [], extra_outputs = []):
    """AOT compile to ELF shared library. Used for Android, Linux, Windows."""
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-elf", "--elf", strip, extra_flags, extra_outputs, "FlutterAotElf")

def flutter_aot_macho_action(
        ctx,
        gen_snapshot,
        kernel_dill,
        output,
        strip = True,
        extra_flags = [],
        extra_outputs = [],
        install_name = "@rpath/App.framework/App",
        min_os_version = None,
        rpath = "@executable_path/Frameworks,@loader_path/Frameworks"):
    """AOT compile to Mach-O dylib. Used for macOS and iOS.

    Args:
        ctx: Rule context.
        gen_snapshot: gen_snapshot executable File.
        kernel_dill: Kernel .dill input.
        output: Output dylib File.
        strip: Whether to strip debug symbols.
        extra_flags: Additional gen_snapshot flags.
        extra_outputs: Additional output Files (e.g. debug info).
        install_name: Mach-O LC_ID_DYLIB install name.
        min_os_version: Optional minimum OS version for LC_BUILD_VERSION.
        rpath: Comma-separated LC_RPATH entries to embed in the Mach-O dylib.
    """
    macho_flags = list(extra_flags)
    macho_flags.append("--macho-install-name=" + install_name)
    if min_os_version:
        macho_flags.append("--macho-min-os-version=" + min_os_version)
    if rpath:
        macho_flags.append("--macho-rpath=" + rpath)
    _flutter_aot_action(ctx, gen_snapshot, kernel_dill, output, "app-aot-macho-dylib", "--macho", strip, macho_flags, extra_outputs, "FlutterAotMacho")
