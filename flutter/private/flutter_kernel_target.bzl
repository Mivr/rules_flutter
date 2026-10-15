"""Internal rule for compiling Flutter sources to a kernel .dill file.

This is the base compilation step shared by all Flutter platform targets.
"""

load("//flutter/private:common.bzl", "AGENT_EXTENSIONS_ATTR", "COPY_TO_DIRECTORY_TOOLCHAINS", "KERNEL_COMPILE_ATTRS", "flutter_compile_kernel", "resolve_flutter_sdk_info")

def _flutter_kernel_target_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    # flutter_compile_kernel handles mode-aware platform dill selection.
    # If the user explicitly requests AOT, force it regardless of mode.
    # None lets flutter_compile_kernel decide based on COMPILATION_MODE;
    # True forces AOT even in debug mode.
    aot = True if ctx.attr.aot else None
    kernel_dill = flutter_compile_kernel(ctx, flutter_sdk_info, aot = aot).kernel_dill

    return [
        DefaultInfo(files = depset([kernel_dill])),
    ]

flutter_kernel_target = rule(
    implementation = _flutter_kernel_target_impl,
    # The compile inputs come from the shared bundle rather than a copy of it,
    # so this rule cannot drift from what `flutter_compile_kernel` reads.
    attrs = KERNEL_COMPILE_ATTRS | {
        "aot": attr.bool(
            doc = "If True, compile for AOT (--aot --tfa). Automatically True in opt/fastbuild mode.",
            default = False,
        ),
    } | AGENT_EXTENSIONS_ATTR,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles Flutter sources to a kernel .dill file.",
)
