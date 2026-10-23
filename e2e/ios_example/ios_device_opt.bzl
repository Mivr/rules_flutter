"""Transition a release iOS framework dependency to a device, optimized build.

A physical iPhone runs the release/AOT engine, so a release proof must build
the framework with `-c opt --ios_multi_cpus=arm64`. Applying that via a
transition on just the framework and its application keeps the surrounding
`dart_test` runner in the default configuration.

The rule also forwards the application's `debug_info` output group (the
`.symbols` file `split_debug_info` writes) from that same transitioned build,
so the test reads the symbols of the very build it inspects.
"""

def _ios_device_opt_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:ios_multi_cpus": ["arm64"],
    }

_ios_device_opt_transition = transition(
    implementation = _ios_device_opt_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
    ],
)

def _ios_device_opt_bundle_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        ctx.attr.framework[DefaultInfo].files,
        ctx.attr.application[OutputGroupInfo].debug_info,
    ]))]

ios_device_opt_bundle = rule(
    implementation = _ios_device_opt_bundle_impl,
    attrs = {
        "application": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            doc = "The flutter_application to rebuild for the device in release.",
        ),
        "framework": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            doc = "The flutter_ios_framework_gen to rebuild for the device in release.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes a release App.framework and its .symbols built for the device (AOT).",
)
