"""iOS simulator support for the `flutter_integration_test` macro.

The `platform = "ios"` branch of `flutter_integration_test` lives here so
`flutter_integration_test.bzl` does not grow: that file only creates the
test bootstrap and dispatches to `assemble_ios_integration_test` below. The
shared helpers the branch needs (`exposes_package`, `test_tag_env`,
`RESERVED_TAG_ENV_KEYS`, `resolve_main_and_srcs` and
`build_analyzable_and_coverage_infos`) moved here from
`flutter_integration_test.bzl`, which loads them back. The test bootstrap
itself reuses the Linux generator, so it stays in
`flutter_integration_test.bzl` next to it: this file cannot load it back
(the macro file loads this one). Starlark does not re-export load-bound
names, so loaders of those helpers import them from this file now.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "dart_analyzable_info_with_package",
    "dart_package_identity",
    "derive_lib_root",
    "runfiles_path",
)
load("//flutter/private:app_entrypoint.bzl", "package_lib_prefix")
load(
    "//flutter/private:common.bzl",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "extract_library_tags_action",
)
load("//flutter/private:flutter_application.bzl", _flutter_application = "flutter_application")
load("//flutter/private:ios_app.bzl", "flutter_ios_app")
load("//flutter/private:ios_sim_debug.bzl", "ios_sim_debug_app")

def exposes_package(deps, names):
    """True if any dep transitively exposes one of `names`.

    Args:
        deps: Dependency targets carrying `DartInfo`.
        names: Dart package names to look for.

    Returns:
        True when some dep's transitive packages include one of `names`.
    """
    for dep in deps:
        if DartInfo not in dep:
            continue
        for pkg in dep[DartInfo].transitive_packages.to_list():
            if pkg.package_name in names:
                return True
    return False

def test_tag_env(ctx, env):
    """Forward `include_tags` / `exclude_tags` as the runner's tag env vars.

    Forwarded under `_ATTR` keys: a `--test_env=FLUTTER_TEST_TAGS=...` (or
    `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute,
    and it can only do that when the rule leaves those keys alone — Bazel lets
    a rule-set variable win over `--test_env` for the same key. Set only when
    the attribute names tags. Called before the `env` merge so a colliding
    `env` key is rejected like the rule's other keys.

    Args:
        ctx: Rule context carrying `include_tags` / `exclude_tags`.
        env: Env dict to add the `_ATTR` keys to.
    """
    if ctx.attr.include_tags:
        env["FLUTTER_TEST_TAGS_ATTR"] = ",".join(ctx.attr.include_tags)
    if ctx.attr.exclude_tags:
        env["FLUTTER_TEST_EXCLUDE_TAGS_ATTR"] = ",".join(ctx.attr.exclude_tags)

# Runner-contract tag keys the rule reserves for `--test_env` overrides (see
# `test_tag_env`): an `env` entry for any of these is rejected in the
# implementations so the flag stays the one override channel.
RESERVED_TAG_ENV_KEYS = [
    "FLUTTER_TEST_TAGS",
    "FLUTTER_TEST_EXCLUDE_TAGS",
    "FLUTTER_TEST_TAGS_ATTR",
    "FLUTTER_TEST_EXCLUDE_TAGS_ATTR",
    "FLUTTER_TEST_LIBRARY_TAGS",
]

def ios_integration_test_env(
        target_name,
        ipa_runfiles_path,
        bundle_id,
        test_path,
        user_env,
        library_tags_runfiles_path,
        include_tags,
        exclude_tags):
    """Builds the runner-contract env dict for an iOS integration test.

    The simulator runner locates everything through these keys: the platform,
    the `.ipa` runfiles path, the app's bundle id, the test entrypoint path,
    the build-time `@Tags` path, and the JSON-encoded declared env. A
    `user_env` key colliding with a rule-set key (or a reserved `--test_env`
    tag key) fails: the rule-set value must win so `--test_env` stays the tag
    override channel.

    Args:
        target_name: The test target name (for the collision error).
        ipa_runfiles_path: Runfiles path of the simulator-debug `.ipa`.
        bundle_id: CFBundleIdentifier of the app under test.
        test_path: Short path of the test entrypoint `.dart` file.
        user_env: The rule's `env` attribute (declared extra variables).
        library_tags_runfiles_path: Runfiles path of the extracted `@Tags`.
        include_tags: The rule's `include_tags` attribute.
        exclude_tags: The rule's `exclude_tags` attribute.

    Returns:
        The env dict for `testing.TestEnvironment`.
    """
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "ios",
        "FLUTTER_INTEGRATION_TEST_IOS_APP": ipa_runfiles_path,
        "FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID": bundle_id,
        "FLUTTER_INTEGRATION_TEST_PATH": test_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(user_env),
        "FLUTTER_TEST_LIBRARY_TAGS": library_tags_runfiles_path,
    }
    if include_tags:
        env["FLUTTER_TEST_TAGS_ATTR"] = ",".join(include_tags)
    if exclude_tags:
        env["FLUTTER_TEST_EXCLUDE_TAGS_ATTR"] = ",".join(exclude_tags)
    for key, value in user_env.items():
        if key in env or key in RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = target_name, key = key))
        env[key] = value
    return env

def resolve_main_and_srcs(ctx):
    """Resolve the integration test entrypoint File and additional source Files.

    Prefers `main`, then a single `srcs` file, then a single `*_test.dart`
    candidate; anything ambiguous fails telling the caller to set `main`.

    Args:
        ctx: Rule context carrying `main`, `srcs`, and `app_srcs`.

    Returns:
        A `(main_file, extra_srcs)` tuple.
    """
    if ctx.file.main != None:
        main_file = ctx.file.main
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    if len(ctx.files.srcs) == 1:
        main_file = ctx.files.srcs[0]
        extra_srcs = [f for f in ctx.files.app_srcs if f != main_file]
        return main_file, extra_srcs

    test_candidates = [
        f
        for f in ctx.files.srcs
        if f.short_path.endswith("_test.dart")
    ]
    if len(test_candidates) == 1:
        main_file = test_candidates[0]
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    fail(
        "%s: specify `main` (or pass a single test file in `srcs`)." % ctx.label,
    )

def build_analyzable_and_coverage_infos(ctx, package_name, lib_root, main_file, extra_srcs):
    """Build the coverage and analyzable providers for an integration test.

    Args:
        ctx: Rule context carrying `deps`, `language_version`, and `_sky_engine`.
        package_name: Dart package name (from `pubspec.yaml`).
        lib_root: Package `lib/` root the entrypoint resolves against.
        main_file: The resolved test entrypoint File.
        extra_srcs: Additional source Files compiled with the entrypoint.

    Returns:
        An `(instrumented_files_info, analyzable_info)` tuple.
    """
    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "app_srcs", "main"],
        dependency_attributes = ["deps"],
    )

    prefix = package_lib_prefix(lib_root)
    in_pkg_srcs = []
    non_pkg_srcs = []
    for f in [main_file] + extra_srcs:
        if f.short_path.startswith(prefix):
            in_pkg_srcs.append(f)
        else:
            non_pkg_srcs.append(f)

    analyzable_info = dart_analyzable_info_with_package(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
        ),
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = non_pkg_srcs,
        package_srcs = in_pkg_srcs,
    )
    return instrumented_files_info, analyzable_info

def sanitize_ios_bundle_id_segment(raw):
    """Sanitizes a string into a valid iOS bundle ID segment.

    A segment holds letters, digits and hyphens; anything else becomes a
    hyphen, hyphen runs collapse to one, and a leading digit gains an `id-`
    prefix, since Apple reads a digit-led segment as a version.

    Args:
        raw: The raw string to sanitize.

    Returns:
        The sanitized segment.
    """
    chars = []
    for c in raw.elems():
        if c.isalnum() or c == "-":
            chars.append(c.lower())
        elif not chars or chars[-1] != "-":
            chars.append("-")
    segment = "".join(chars).strip("-")
    if not segment:
        return "app"
    if segment[0].isdigit():
        segment = "id-" + segment
    return segment

def default_ios_bundle_id(package_name, target_name):
    """Default `ios_bundle_id`: `com.example.<package>.<target>`.

    Combines the package and the target name so two tests in one package
    never share a bundle id: the simulator refuses to install a second app
    with an id it already knows.

    Args:
        package_name: Dart package name (from pubspec.yaml).
        target_name: The `flutter_integration_test` target name.

    Returns:
        The default bundle ID string.
    """
    return "com.example.%s.%s" % (
        sanitize_ios_bundle_id_segment(package_name),
        sanitize_ios_bundle_id_segment(target_name),
    )

# `flutter_application` attributes the iOS branch forwards from the macro's
# `**kwargs`. `main`/`srcs`/`app_srcs` also feed the bootstrap rule; the rest
# go to the `flutter_application` unchanged. (`profile` is absent: the
# application rule reads the build mode from the configuration.)
IOS_APP_KWARG_KEYS = (
    "srcs",
    "main",
    "app_srcs",
    "assets",
    "shaders",
    "shader_includes",
    "require_sksl_shaders",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "language_version",
    "defines",
    "native_deps",
)

# The iOS branch needs the Apple toolchain, so its app, debug-app and test
# targets run on macOS only; `bazel test //...` skips them on Linux. The
# bootstrap and kernel-compile targets stay portable.
_MACOS_ONLY = ["@platforms//os:macos"]

_IOS_INTEGRATION_TEST_ATTRS = {
    "app": attr.label(
        mandatory = True,
        allow_files = True,
        doc = "The simulator-debug iOS app (an `.ipa`) to install on the simulator.",
    ),
    "ios_bundle_id": attr.string(
        mandatory = True,
        doc = "CFBundleIdentifier of the app under test (e.g. `'com.example.app_test'`).",
    ),
    "srcs": KERNEL_COMPILE_ATTRS["srcs"],
    "main": attr.label(
        doc = "The integration test .dart entry point. Optional when `srcs` " +
              "contains a single `.dart` file.",
        allow_single_file = [".dart"],
    ),
    "app_srcs": attr.label_list(
        doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
        allow_files = [".dart"],
    ),
    "package_name": attr.string(
        doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
    ),
    "language_version": KERNEL_COMPILE_ATTRS["language_version"],
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
    ),
    "platform": attr.string(
        doc = "Target platform to run the integration test on (always `'ios'` here).",
        default = "ios",
        values = ["ios"],
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Runtime data files made available in test runfiles.",
    ),
    "env": attr.string_dict(
        doc = "Extra environment variables for the test runner process.",
    ),
    "include_tags": attr.string_list(
        doc = "Run only tests matching every one of these `package:test` tag " +
              "selectors, as `flutter test --tags` intersects them.",
    ),
    "exclude_tags": attr.string_list(
        doc = "Skip tests matching any of these `package:test` tag selectors, " +
              "as `flutter test --exclude-tags` unions them. Wins over " +
              "`include_tags`.",
    ),
    "_tool": attr.label(
        default = Label("//flutter/private/tools:flutter_integration_test_runner"),
        executable = True,
        cfg = "exec",
        doc = "The integration test runner binary.",
    ),
    "_library_tags_tool": LIBRARY_TAGS_TOOL_ATTR,
    "_sky_engine": attr.label(
        default = Label("@flutter_sky_engine//:sky_engine"),
        providers = [DartInfo],
        doc = "The sky_engine Dart SDK libraries.",
    ),
}
_IOS_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)

def _flutter_ios_integration_test_impl(ctx):
    if ctx.attr.platform != "ios":
        fail(
            "%s: flutter_ios_integration_test requires platform = 'ios', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = resolve_main_and_srcs(ctx)
    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    ipa_files = [f for f in ctx.files.app if f.path.endswith(".ipa")]
    if not ipa_files:
        fail(
            "flutter_integration_test %s: expected an .ipa from %s, got %s" % (
                ctx.label.name,
                ctx.attr.app.label,
                [f.short_path for f in ctx.files.app],
            ),
        )
    ipa_file = ipa_files[0]

    tool = ctx.attr._tool
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    workspace_name = ctx.workspace_name

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env = ios_integration_test_env(
        ctx.label.name,
        runfiles_path(ipa_file, workspace_name),
        ctx.attr.ios_bundle_id,
        main_file.short_path,
        ctx.attr.env,
        runfiles_path(library_tags, workspace_name),
        ctx.attr.include_tags,
        ctx.attr.exclude_tags,
    )

    env_info = testing.TestEnvironment(env)

    runfiles = ctx.runfiles(
        files = [ipa_file, library_tags] + ctx.files.data,
    )
    runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info, analyzable_info = build_analyzable_and_coverage_infos(
        ctx,
        package_name,
        lib_root,
        main_file,
        extra_srcs,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        analyzable_info,
    ]

flutter_ios_integration_test = rule(
    implementation = _flutter_ios_integration_test_impl,
    attrs = _IOS_INTEGRATION_TEST_ATTRS,
    test = True,
    doc = "Installs a simulator-debug Flutter iOS app on a booted simulator and runs its in-app integration test.",
)

def assemble_ios_integration_test(
        name,
        bootstrap,
        package_name = "",
        deps = [],
        ios_bundle_id = "",
        ios_runner_srcs = None,
        ios_info_plist = None,
        platform = "ios",
        **kwargs):
    """Builds the iOS simulator app and test target for one integration test.

    This is the `platform = "ios"` branch of `flutter_integration_test`: it
    bundles the test bootstrap (the `flutter_application` main, resolved by
    the caller into `bootstrap`) into a `flutter_ios_app`, rebuilds that app
    for the simulator in debug through `ios_sim_debug_app` (`-c dbg` plus
    `--ios_multi_cpus=sim_arm64` on the app only), and runs it through
    `flutter_ios_integration_test` on macOS.

    Args:
        name: Target name.
        bootstrap: Label of the test bootstrap `.dart` source (a
            `flutter_ios_integration_bootstrap` target created by the caller).
        package_name: Dart package name (from `pubspec.yaml`). Defaults to `name`.
        deps: Dependencies (`dart_library` / `flutter_library`) for the test and app.
        ios_bundle_id: CFBundleIdentifier of the app under test. Defaults to
            `com.example.<package>.<target>` via `default_ios_bundle_id`, so
            two tests never share an id.
        ios_runner_srcs: Runner Swift sources for `flutter_ios_app`. Defaults
            to `None`, which discovers the package's `ios/Runner/*.swift`
            (as generated by `flutter create --platforms=ios .`).
        ios_info_plist: `Info.plist` override for `flutter_ios_app`. Defaults
            to `None`, which preprocesses the package's
            `ios/Runner/Info.plist`.
        platform: Target platform (always `"ios"` here).
        **kwargs: Additional attributes forwarded to the application
            (`srcs`, `app_srcs`, `assets`, `shaders`, `defines`,
            `native_deps`, etc.) or the test rule (`main`, `srcs`, `app_srcs`,
            `data`, `env`, `include_tags`, `exclude_tags`).
    """
    resolved_package_name = package_name or name
    resolved_bundle_id = ios_bundle_id or default_ios_bundle_id(
        resolved_package_name,
        name,
    )
    helper_tags = ["manual"]
    app_kwargs = {
        k: kwargs[k]
        for k in IOS_APP_KWARG_KEYS
        if k in kwargs
    }
    bootstrap_srcs = app_kwargs.pop("srcs", [])
    bootstrap_app_srcs = app_kwargs.pop("app_srcs", [])

    # The test entrypoint (`main`) is superseded by the bootstrap: the
    # application compiles the bootstrap, while the test rule below still
    # reads `main`/`srcs`/`app_srcs` from `kwargs` to re-resolve the
    # entrypoint for tag extraction.
    app_kwargs.pop("main", None)

    _flutter_application(
        name = "__%s_app" % name,
        package_name = resolved_package_name,
        main = bootstrap,
        srcs = bootstrap_srcs + bootstrap_app_srcs,
        deps = deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        **app_kwargs
    )

    flutter_ios_app(
        name = "__%s_ios" % name,
        application = ":__%s_app" % name,
        bundle_id = resolved_bundle_id,
        srcs = ios_runner_srcs,
        info_plist = ios_info_plist,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        target_compatible_with = _MACOS_ONLY,
    )

    ios_sim_debug_app(
        name = "__%s_sim_debug" % name,
        app = ":__%s_ios" % name,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        target_compatible_with = _MACOS_ONLY,
    )

    # `srcs`, `main`, `app_srcs`, and `language_version` feed both the
    # application build above and the test rule below (the test rule
    # re-resolves the entrypoint for tag extraction); everything else the
    # test rule does not declare is dropped here. `size`, `timeout`, and
    # `target_compatible_with` are owned by this macro (a simulator run is
    # enormous/eternal/macOS-only), so user values for them are dropped
    # rather than colliding with the forced keywords below.
    test_kwargs = {
        k: v
        for k, v in kwargs.items()
        if (k not in IOS_APP_KWARG_KEYS or k in ("srcs", "main", "app_srcs", "language_version")) and
           k not in ("size", "timeout", "target_compatible_with")
    }

    flutter_ios_integration_test(
        name = name,
        app = ":__%s_sim_debug" % name,
        ios_bundle_id = resolved_bundle_id,
        package_name = resolved_package_name,
        deps = deps,
        platform = platform,
        size = "enormous",
        timeout = "eternal",
        target_compatible_with = _MACOS_ONLY,
        **test_kwargs
    )
