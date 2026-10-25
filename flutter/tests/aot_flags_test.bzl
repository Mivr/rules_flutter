"""Analysis tests for the shared gen_snapshot flag construction.

`flutter_application` and `flutter_aot_target` build their AOT command line
from one helper (`flutter_aot_gen_snapshot_flags`), so these tests pin the
properties every public path must keep:

- `obfuscate` forces `--strip`, even in fastbuild: gen_snapshot embeds full
  DWARF carrying the original names unless stripped, so an unstripped
  "obfuscated" snapshot still leaks every class name.
- Every flag the rules add appears exactly once, even when the user also
  lists it in `extra_gen_snapshot_options`.
- `split_debug_info` keeps `--dwarf-stack-traces` and `--save-debugging-info`
  without `--resolve-dwarf-paths` (which cannot handle the rules'
  `org-dartlang-app:` URIs and would embed host paths).
- `extra_gen_snapshot_options` is an allow-list: a file-writing, output- or
  kind-changing, or unknown flag fails analysis naming the flag;
  `--save-obfuscation-map` and `--save-debugging-info` fail naming
  `obfuscate` and `split_debug_info` instead.
- With `obfuscate`, gen_snapshot writes a declared `<name>.obfuscation_map.json`
  exposed through the `obfuscation_map` output group (and
  `FlutterApplicationInfo.obfuscation_map`); without it no map exists.
- `--no-strip` without `obfuscate` strips nothing and reports
  `strip = False`; with `obfuscate` it fails, since obfuscation needs
  stripping.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_PACKAGE = "aot_flags_fixture"
_MAIN = "lib/language_version_main.dart"

def _aot_argv(env):
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic in ("FlutterAotElf", "FlutterAotMacho")
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected exactly one AOT action, got %s" % ([a.mnemonic for a in actions]),
    )
    return actions[0].argv if actions else []

def _count(argv, flag):
    return len([a for a in argv if a == flag])

def _obfuscate_strips_test_impl(ctx):
    """`obfuscate` forces `--strip`, even where the mode would not strip."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

def _obfuscate_dedup_test_impl(ctx):
    """A user-supplied `--obfuscate` is not emitted a second time."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

def _split_debug_flags_test_impl(ctx):
    """`split_debug_info` keeps DWARF traces and saved info, resolves nothing."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--dwarf-stack-traces"), "expected exactly one --dwarf-stack-traces, got %s" % (argv,))
    save_info = [a for a in argv if a.startswith("--save-debugging-info=")]
    asserts.equals(env, 1, len(save_info), "expected exactly one --save-debugging-info=, got %s" % (argv,))
    asserts.false(
        env,
        "--resolve-dwarf-paths" in argv,
        "must not pass --resolve-dwarf-paths, got %s" % (argv,),
    )
    asserts.false(
        env,
        "--strip" in argv,
        "split_debug_info alone must not strip, got %s" % (argv,),
    )
    return analysistest.end(env)

def _obfuscate_split_debug_flags_test_impl(ctx):
    """`obfuscate` + `split_debug_info` strips the binary, keeps the symbols file."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    asserts.equals(env, 1, _count(argv, "--dwarf-stack-traces"), "expected exactly one --dwarf-stack-traces, got %s" % (argv,))
    save_info = [a for a in argv if a.startswith("--save-debugging-info=")]
    asserts.equals(env, 1, len(save_info), "expected exactly one --save-debugging-info=, got %s" % (argv,))
    asserts.false(
        env,
        "--resolve-dwarf-paths" in argv,
        "must not pass --resolve-dwarf-paths, got %s" % (argv,),
    )
    return analysistest.end(env)

def _application_obfuscate_strips_test_impl(ctx):
    """`flutter_application(obfuscate = True)` strips like `flutter_aot_target` does."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    asserts.equals(env, 1, _count(argv, "--obfuscate"), "expected exactly one --obfuscate, got %s" % (argv,))
    asserts.true(env, "--strip" in argv, "obfuscate must force --strip, got %s" % (argv,))
    return analysistest.end(env)

def _refuse_write_profile_test_impl(ctx):
    """A file-writing flag fails analysis naming the flag."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "write-v8-snapshot-profile-to")
    return analysistest.end(env)

def _refuse_unknown_test_impl(ctx):
    """An unknown flag fails analysis."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "frobnicate-the-snapshot")
    return analysistest.end(env)

def _refuse_obfuscation_map_test_impl(ctx):
    """`--save-obfuscation-map` fails naming `obfuscate` and the output group."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "obfuscation_map")
    return analysistest.end(env)

def _refuse_debugging_info_test_impl(ctx):
    """`--save-debugging-info` fails naming `split_debug_info`."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "split_debug_info")
    return analysistest.end(env)

def _refuse_snapshot_kind_test_impl(ctx):
    """`--snapshot-kind` fails analysis: the rules own the snapshot kind."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "snapshot-kind")
    return analysistest.end(env)

def _refuse_no_strip_obfuscate_test_impl(ctx):
    """`--no-strip` with `obfuscate` fails: obfuscation needs stripping."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "needs stripping")
    return analysistest.end(env)

def _assert_unstripped_argv(env, argv):
    """`--no-strip` is the only strip flag on the AOT argv."""
    asserts.true(env, "--no-strip" in argv, "expected --no-strip, got %s" % (argv,))
    asserts.false(env, "--strip" in argv, "must not pass --strip with --no-strip, got %s" % (argv,))

def _assert_no_obfuscation_map(env, argv, target):
    """Without `obfuscate` no map is on the argv or in an output group."""
    asserts.equals(
        env,
        [],
        [a for a in argv if a.startswith("--save-obfuscation-map=")],
        "must not declare a map without obfuscate, got %s" % (argv,),
    )
    has_map = OutputGroupInfo in target and getattr(target[OutputGroupInfo], "obfuscation_map", None) != None
    asserts.false(env, has_map, "must not expose obfuscation_map without obfuscate")

def _no_strip_unstripped_test_impl(ctx):
    """`--no-strip` without `obfuscate` strips nothing and declares no map."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    _assert_unstripped_argv(env, argv)
    _assert_no_obfuscation_map(env, argv, analysistest.target_under_test(env))
    return analysistest.end(env)

def _application_no_strip_unstripped_test_impl(ctx):
    """`--no-strip` without `obfuscate` reports `aot_strip = False`."""
    env = analysistest.begin(ctx)
    argv = _aot_argv(env)
    _assert_unstripped_argv(env, argv)
    tut = analysistest.target_under_test(env)
    _assert_no_obfuscation_map(env, argv, tut)
    asserts.equals(env, False, tut[FlutterApplicationInfo].aot_strip, "aot_strip must report the --no-strip the snapshot was told")
    return analysistest.end(env)

def _obfuscation_map_path(env, argv):
    """The single `--save-obfuscation-map=` value on the AOT argv."""
    maps = [a.split("=", 1)[1] for a in argv if a.startswith("--save-obfuscation-map=")]
    asserts.equals(env, 1, len(maps), "expected exactly one --save-obfuscation-map=, got %s" % (argv,))
    if maps:
        return maps[0]
    return None

def _assert_obfuscation_map_group(env, target, map_path):
    """The `obfuscation_map` output group carries exactly the argv-named file."""
    group = target[OutputGroupInfo].obfuscation_map.to_list()
    asserts.equals(env, 1, len(group), "expected exactly one obfuscation_map file, got %s" % (group,))
    asserts.equals(env, map_path, group[0].path, "the output group must carry the argv-named map")

def _obfuscation_map_test_impl(ctx):
    """With `obfuscate` the argv-named map is the `obfuscation_map` group."""
    env = analysistest.begin(ctx)
    map_path = _obfuscation_map_path(env, _aot_argv(env))
    _assert_obfuscation_map_group(env, analysistest.target_under_test(env), map_path)
    return analysistest.end(env)

def _application_obfuscation_map_test_impl(ctx):
    """With `obfuscate` the provider field is the argv-named map file."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    map_path = _obfuscation_map_path(env, _aot_argv(env))
    _assert_obfuscation_map_group(env, tut, map_path)
    asserts.equals(env, map_path, tut[FlutterApplicationInfo].obfuscation_map.path, "the provider field must be the argv-named map")
    return analysistest.end(env)

def _application_no_map_test_impl(ctx):
    """Without `obfuscate` no map is declared, grouped or reported."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    _assert_no_obfuscation_map(env, _aot_argv(env), tut)
    asserts.equals(env, None, tut[FlutterApplicationInfo].obfuscation_map, "obfuscation_map must be None without obfuscate")
    return analysistest.end(env)

_FASTBUILD = {
    "//command_line_option:compilation_mode": "fastbuild",
    str(Label("//flutter:profile")): False,
}

# `-c opt`: the mode whose default strips, so `--no-strip` observably
# disables stripping (in fastbuild nothing strips either way).
_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}

_obfuscate_strips_test = analysistest.make(
    _obfuscate_strips_test_impl,
    config_settings = _FASTBUILD,
)
_obfuscate_dedup_test = analysistest.make(
    _obfuscate_dedup_test_impl,
    config_settings = _FASTBUILD,
)
_split_debug_flags_test = analysistest.make(
    _split_debug_flags_test_impl,
    config_settings = _FASTBUILD,
)
_obfuscate_split_debug_flags_test = analysistest.make(
    _obfuscate_split_debug_flags_test_impl,
    config_settings = _FASTBUILD,
)
_application_obfuscate_strips_test = analysistest.make(
    _application_obfuscate_strips_test_impl,
    config_settings = _FASTBUILD,
)
_refuse_write_profile_test = analysistest.make(
    _refuse_write_profile_test_impl,
    expect_failure = True,
)
_refuse_unknown_test = analysistest.make(
    _refuse_unknown_test_impl,
    expect_failure = True,
)
_refuse_obfuscation_map_test = analysistest.make(
    _refuse_obfuscation_map_test_impl,
    expect_failure = True,
)
_refuse_debugging_info_test = analysistest.make(
    _refuse_debugging_info_test_impl,
    expect_failure = True,
)
_refuse_snapshot_kind_test = analysistest.make(
    _refuse_snapshot_kind_test_impl,
    expect_failure = True,
)
_refuse_no_strip_obfuscate_test = analysistest.make(
    _refuse_no_strip_obfuscate_test_impl,
    expect_failure = True,
)
_no_strip_unstripped_test = analysistest.make(
    _no_strip_unstripped_test_impl,
    config_settings = _OPT,
)
_application_no_strip_unstripped_test = analysistest.make(
    _application_no_strip_unstripped_test_impl,
    config_settings = _OPT,
)
_obfuscation_map_test = analysistest.make(
    _obfuscation_map_test_impl,
    config_settings = _FASTBUILD,
)
_application_obfuscation_map_test = analysistest.make(
    _application_obfuscation_map_test_impl,
    config_settings = _FASTBUILD,
)
_application_no_map_test = analysistest.make(
    _application_no_map_test_impl,
    config_settings = _FASTBUILD,
)

def _missing_aot_strip_app_impl(_ctx):
    """Application fixture omitting `aot_strip`, which the provider requires."""
    return [FlutterApplicationInfo(
        aot_output = None,
        kernel_dill = None,
    )]

_missing_aot_strip_app = rule(
    implementation = _missing_aot_strip_app_impl,
)

def _missing_aot_strip_test_impl(ctx):
    """Omitting `aot_strip` fails analysis with the provider's message."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "FlutterApplicationInfo: aot_strip is required")
    return analysistest.end(env)

_missing_aot_strip_test = analysistest.make(
    _missing_aot_strip_test_impl,
    expect_failure = True,
)

def aot_flags_test_suite(name):
    """Defines analysis tests for the shared gen_snapshot flags.

    Args:
        name: The test_suite target name.
    """
    flutter_aot_target(
        name = "_flags_obf_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_obf_dup_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        extra_gen_snapshot_options = ["--obfuscate"],
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_split_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        split_debug_info = True,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_obf_split_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        split_debug_info = True,
        tags = ["manual"],
    )
    flutter_application(
        name = "_flags_application_obf",
        package_name = _PACKAGE,
        main = _MAIN,
        obfuscate = True,
        tags = ["manual"],
    )
    flutter_application(
        name = "_flags_application_plain",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    _missing_aot_strip_app(
        name = "_flags_missing_aot_strip_app",
        tags = ["manual"],
    )

    for fixture, options in {
        "_flags_write_profile_eq_target": ["--write-v8-snapshot-profile-to=/tmp/x.json"],
        "_flags_write_profile_sep_target": ["-write_v8_snapshot_profile_to", "/tmp/x.json"],
        "_flags_unknown_target": ["--frobnicate-the-snapshot"],
        "_flags_obfuscation_map_target": ["--save-obfuscation-map=/tmp/x.json"],
        "_flags_debugging_info_target": ["--save-debugging-info=/tmp/x.json"],
        "_flags_snapshot_kind_target": ["--snapshot-kind=app-aot-assembly"],
    }.items():
        flutter_aot_target(
            name = fixture,
            package_name = _PACKAGE,
            main = _MAIN,
            srcs = [_MAIN],
            extra_gen_snapshot_options = options,
            tags = ["manual"],
        )
    flutter_aot_target(
        name = "_flags_no_strip_obfuscate_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        obfuscate = True,
        extra_gen_snapshot_options = ["--no-strip"],
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_flags_no_strip_target",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        extra_gen_snapshot_options = ["--no-strip"],
        tags = ["manual"],
    )

    for fixture, options in {
        "_flags_application_write_profile_eq": ["--write-v8-snapshot-profile-to=/tmp/x.json"],
        "_flags_application_write_profile_sep": ["-write_v8_snapshot_profile_to", "/tmp/x.json"],
        "_flags_application_unknown": ["--frobnicate-the-snapshot"],
        "_flags_application_obfuscation_map": ["--save-obfuscation-map=/tmp/x.json"],
        "_flags_application_debugging_info": ["--save-debugging-info=/tmp/x.json"],
        "_flags_application_snapshot_kind": ["--snapshot-kind=app-aot-assembly"],
    }.items():
        flutter_application(
            name = fixture,
            package_name = _PACKAGE,
            main = _MAIN,
            extra_gen_snapshot_options = options,
            tags = ["manual"],
        )
    flutter_application(
        name = "_flags_application_no_strip_obfuscate",
        package_name = _PACKAGE,
        main = _MAIN,
        obfuscate = True,
        extra_gen_snapshot_options = ["--no-strip"],
        tags = ["manual"],
    )
    flutter_application(
        name = "_flags_application_no_strip",
        package_name = _PACKAGE,
        main = _MAIN,
        extra_gen_snapshot_options = ["--no-strip"],
        tags = ["manual"],
    )

    _obfuscate_strips_test(
        name = name + "_obfuscate_strips",
        target_under_test = ":_flags_obf_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _obfuscate_dedup_test(
        name = name + "_obfuscate_dedup",
        target_under_test = ":_flags_obf_dup_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _split_debug_flags_test(
        name = name + "_split_debug",
        target_under_test = ":_flags_split_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _obfuscate_split_debug_flags_test(
        name = name + "_obfuscate_split_debug",
        target_under_test = ":_flags_obf_split_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_obfuscate_strips_test(
        name = name + "_application_obfuscate_strips",
        target_under_test = ":_flags_application_obf",
        target_compatible_with = HOST_COMPATIBLE,
    )
    for test_rule, fixture in [
        (_refuse_write_profile_test, "write_profile_eq"),
        (_refuse_write_profile_test, "write_profile_sep"),
        (_refuse_unknown_test, "unknown"),
        (_refuse_obfuscation_map_test, "obfuscation_map"),
        (_refuse_debugging_info_test, "debugging_info"),
        (_refuse_snapshot_kind_test, "snapshot_kind"),
    ]:
        test_rule(
            name = name + "_refuse_" + fixture,
            target_under_test = ":_flags_" + fixture + "_target",
            target_compatible_with = HOST_COMPATIBLE,
        )
        test_rule(
            name = name + "_application_refuse_" + fixture,
            target_under_test = ":_flags_application_" + fixture,
            target_compatible_with = HOST_COMPATIBLE,
        )
    _refuse_no_strip_obfuscate_test(
        name = name + "_refuse_no_strip_obfuscate",
        target_under_test = ":_flags_no_strip_obfuscate_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _refuse_no_strip_obfuscate_test(
        name = name + "_application_refuse_no_strip_obfuscate",
        target_under_test = ":_flags_application_no_strip_obfuscate",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _no_strip_unstripped_test(
        name = name + "_no_strip_unstripped",
        target_under_test = ":_flags_no_strip_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_no_strip_unstripped_test(
        name = name + "_application_no_strip_unstripped",
        target_under_test = ":_flags_application_no_strip",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _obfuscation_map_test(
        name = name + "_obfuscation_map",
        target_under_test = ":_flags_obf_target",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_obfuscation_map_test(
        name = name + "_application_obfuscation_map",
        target_under_test = ":_flags_application_obf",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _application_no_map_test(
        name = name + "_application_no_map",
        target_under_test = ":_flags_application_plain",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _missing_aot_strip_test(
        name = name + "_missing_aot_strip",
        target_under_test = ":_flags_missing_aot_strip_app",
        target_compatible_with = HOST_COMPATIBLE,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_obfuscate_strips",
            ":" + name + "_obfuscate_dedup",
            ":" + name + "_split_debug",
            ":" + name + "_obfuscate_split_debug",
            ":" + name + "_application_obfuscate_strips",
            ":" + name + "_missing_aot_strip",
            ":" + name + "_refuse_write_profile_eq",
            ":" + name + "_refuse_write_profile_sep",
            ":" + name + "_refuse_unknown",
            ":" + name + "_refuse_obfuscation_map",
            ":" + name + "_refuse_debugging_info",
            ":" + name + "_refuse_snapshot_kind",
            ":" + name + "_refuse_no_strip_obfuscate",
            ":" + name + "_application_refuse_write_profile_eq",
            ":" + name + "_application_refuse_write_profile_sep",
            ":" + name + "_application_refuse_unknown",
            ":" + name + "_application_refuse_obfuscation_map",
            ":" + name + "_application_refuse_debugging_info",
            ":" + name + "_application_refuse_snapshot_kind",
            ":" + name + "_application_refuse_no_strip_obfuscate",
            ":" + name + "_no_strip_unstripped",
            ":" + name + "_application_no_strip_unstripped",
            ":" + name + "_obfuscation_map",
            ":" + name + "_application_obfuscation_map",
            ":" + name + "_application_no_map",
        ],
    )
