"""Common Flutter application compilation pipeline.

Chains: sources → kernel .dill → AOT native code → asset bundle.

In debug mode (-c dbg): produces kernel .dill + assets (JIT, no gen_snapshot).
In fastbuild/opt mode: produces AOT native code + assets (release).
With -c opt and `--@rules_flutter//flutter:profile`: AOT for profile mode,
compiled by the profile gen_snapshot the toolchain selects.

This rule produces outputs that platform-specific wrappers consume:
1. AOT compiled native code (.so/.dylib) or kernel .dill (debug)
2. flutter_assets/ tree artifact
3. ICU data file (icudtl.dat)
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_dart//dart:utils.bzl", "dart_link_hook_actions", "link_hook_runner_attr")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load("//flutter/private:common.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "android_platform_for_abi", "check_unreplaced_hooks", "collect_binding_contracts", "collect_native_libs", "declare_flutter_assets_dir", "detect_target_platform", "flutter_build_assets", "flutter_build_mode", "flutter_compile_kernel", "flutter_compile_shaders", "flutter_dev_loop_inputs", "flutter_kernel_source_inputs", "host_target_arch", "kernel_file_stem", "launch_build_args", "resolve_flutter_sdk_info", "shader_sources")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_gen_snapshot_flags", "flutter_aot_macho_action")
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load("//flutter/private:flutter_native_assets.bzl", "bridge_dart_code_assets", "collect_bundled_code_asset_files", "write_native_assets_manifest")
load("//flutter/private:flutter_shader_compile.bzl", "shader_tree_shareable_with_android")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs")
load("//flutter/private:plugin_registrant.bzl", "debug_kernel_inputs_shareable")

def debug_kernel_transition_impl(settings, _attr):
    """Canonical debug-kernel configuration shared by host and Android (H17).

    One FlutterKernelCompile per distinct kernel serves the host application
    and the Android debug app, as H10 did for the AOT kernel by pinning the
    configuration rather than the artifacts.

    Args:
        settings: The incoming configuration. Only `platforms`,
            `android_platforms`, `cpu` and `@rules_go//go/config:pure` are
            read; everything else passes through untouched.
        _attr: Unused (the transition is unconditional, not attribute-driven).

    Returns:
        The canonical debug-kernel configuration: Android platforms picked
        like `_android_platform_transition_platforms` (an edge already on
        Android keeps its platforms, so this configuration IS the Android
        app's), `dynamic_mode` off as in H10, `compilation_mode` dbg, and
        `@rules_go//go/config:pure` on to match the Android subtree behind
        `flutter_android_pure_go_transition` (the flag feeds only Go actions,
        nothing the kernel compile runs).
    """
    platforms = None
    for platform in settings["//command_line_option:platforms"]:
        platform_str = str(platform).lower()
        if "android" in platform_str:
            platforms = list(settings["//command_line_option:platforms"])
            break
        if "x86_64" in platform_str or "x64" in platform_str or "amd64" in platform_str:
            platforms = [android_platform_for_abi("x86_64")]
            break
        if "arm64" in platform_str or "aarch64" in platform_str:
            platforms = [android_platform_for_abi("arm64-v8a")]
            break
    if platforms == None:
        android_platforms = settings["//command_line_option:android_platforms"]
        if android_platforms:
            platforms = list(android_platforms)
        else:
            cpu = settings["//command_line_option:cpu"]
            if cpu in ("x86_64", "x86", "x64", "amd64"):
                platforms = [android_platform_for_abi("x86_64")]
            else:
                platforms = [android_platform_for_abi("arm64-v8a")]
    return {
        "//command_line_option:platforms": platforms,
        "//command_line_option:dynamic_mode": "off",
        "//command_line_option:compilation_mode": "dbg",
        "@rules_go//go/config:pure": True,
    }

_debug_kernel_transition = transition(
    implementation = debug_kernel_transition_impl,
    inputs = [
        "//command_line_option:platforms",
        "//command_line_option:android_platforms",
        "//command_line_option:cpu",
        "@rules_go//go/config:pure",
    ],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:dynamic_mode",
        "//command_line_option:compilation_mode",
        "@rules_go//go/config:pure",
    ],
)

DEBUG_KERNEL_ATTRS = {
    "build_label": attr.string(
        doc = "Canonical label string baked into `rules_flutter.build_info` instead " +
              "of this target's own label. Set by the `flutter_application` macro on " +
              "the canonical debug-kernel target it creates beside the application, " +
              "so the shared kernel reports the application it serves. Empty " +
              "means the target's own label (every directly-declared application).",
        default = "",
    ),
    "debug_kernel": attr.label(
        doc = "The canonical debug-kernel target the `flutter_application` macro " +
              "creates beside this application. A debug build whose kernel inputs " +
              "are platform-identical serves this target's kernel instead of " +
              "compiling its own. Reserved for the macro: None for " +
              "directly-declared applications and for the canonical target " +
              "itself, which always compile locally.",
        default = None,
        providers = [FlutterApplicationInfo],
        cfg = _debug_kernel_transition,
    ),
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
}

def _flutter_application_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    mode = flutter_build_mode(ctx)
    is_debug = mode == "debug"

    # Profile strips like release, as `flutter build --profile` does: the
    # profiler names Dart code from the snapshot, not from native symbols.
    strip = ctx.var["COMPILATION_MODE"] == "opt"

    # Guard: AOT cross-compilation between desktop OSes is not supported.
    # target_os is non-empty only for cross-compilation toolchains.
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            (
                "No target-compatible AOT gen_snapshot toolchain is registered for this " +
                "host and target platform (target_os=%s). Apple AOT snapshots require a " +
                "Darwin-target gen_snapshot on a macOS host; build on macOS or use debug mode (-c dbg)."
            ) % (
                flutter_sdk_info.target_os or "native",
            ),
        )

    # Detect the target platform for platform-aware plugin registration.
    is_macos = ctx.target_platform_has_constraint(
        ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
    )
    is_ios = ctx.target_platform_has_constraint(
        ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
    )
    is_linux = ctx.target_platform_has_constraint(
        ctx.attr._linux_constraint[platform_common.ConstraintValueInfo],
    )
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    is_android = ctx.target_platform_has_constraint(
        ctx.attr._android_constraint[platform_common.ConstraintValueInfo],
    )
    target_platform = detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android)

    # A pub package that builds its native code with `hook/build.dart` has no
    # library to contribute unless something stands in for the hook. The
    # application is where that is knowable and where it matters: the whole
    # package closure is visible, and it is this target whose manifest would
    # otherwise be quietly short an entry and die at runtime on an unresolved
    # `@Native` symbol. Checked before any compilation so the build fails on
    # the cause rather than minutes later on a symptom.
    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    # Aggregate transitive Native Assets so the manifest exists before
    # kernel compile (the frontend_server reads it via --native-assets).
    transitive_native_asset_depsets = []
    transitive_data_asset_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        transitive_native_asset_depsets.append(info.native_assets)
        transitive_data_asset_depsets.append(info.data_assets)
    transitive_native_assets = depset(transitive = transitive_native_asset_depsets)
    transitive_data_assets = depset(transitive = transitive_data_asset_depsets)

    # Plus any code assets rules_dart propagated through the Dart package
    # graph — a pub package that owns a native library contributes it just by
    # being depended on. Declarations made here with `flutter_native_asset`
    # win, since they are the deliberate ones.
    native_assets_list = transitive_native_assets.to_list()
    declared_ids = {asset.asset_id: True for asset in native_assets_list}
    native_assets_list = native_assets_list + [
        asset
        for asset in bridge_dart_code_assets(ctx, ctx.attr.deps)
        if asset.asset_id not in declared_ids
    ]

    # Aggregate the plugin channels from deps. These are what the platform
    # registrant generators and desktop runners read back off this target —
    # via FlutterApplicationInfo, since an application is the end of the
    # library graph and does not contribute to another one. Aggregated before
    # the kernel compile (rather than beside the bundle below) because the
    # H17 sharing decision reads the plugin list: a kernel whose registrant
    # is platform-identical is compiled once and served to every
    # configuration.
    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    android_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
            apple_plugin_lib_depsets.append(dep[FlutterInfo].apple_plugin_libraries)
            android_plugin_lib_depsets.append(dep[FlutterInfo].android_plugin_libraries)
            linux_plugin_lib_depsets.append(dep[FlutterInfo].linux_plugin_libraries)
            windows_plugin_lib_depsets.append(dep[FlutterInfo].windows_plugin_libraries)
            apple_privacy_manifest_depsets.append(dep[FlutterInfo].apple_privacy_manifests)
    all_plugins = dedup_plugins(all_dep_plugins)
    apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets)
    android_plugin_libraries = depset(transitive = android_plugin_lib_depsets)
    linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets)
    windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets)
    apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets)

    # H17 shared debug kernel: one FlutterKernelCompile per distinct kernel,
    # compiled once in the Android configuration by the canonical kernel
    # target the `flutter_application` macro creates beside the application.
    # A debug build serves the canonical kernel, asset tree, manifest and
    # package config instead of compiling a second one when its own kernel
    # would be byte-identical: no native/shader/data assets in its view, a
    # platform-invariant registrant, and the canonical target's kernel
    # shareable in its (Android) view. The transitive depset materializations
    # below run only on this path — the dep itself is analyzed regardless,
    # but its actions execute only if some consumer's build requests files.
    # A label with a cfg transition reads back as a list, not a Target (set:
    # single element; unset: empty), so normalize before the None check. (The
    # macro-created inner target never sets debug_kernel; the outer always
    # does.)
    _debug_kernel = ctx.attr.debug_kernel
    if type(_debug_kernel) == "list":
        _debug_kernel = _debug_kernel[0] if _debug_kernel else None
    own_kernel_shareable = False
    if is_debug:
        has_data_assets = len(transitive_data_assets.to_list()) > 0

        # Shaders are shareable when this configuration's compiled shaders
        # come out of the same impellerc invocation Android uses (same flags,
        # verified byte-identical outputs), so the canonical tree serves here.
        # A Metal/SkSL-JSON platform keeps its own tree — and its own kernel.
        # Shader *presence* never blocks sharing: the SDK always contributes
        # shaders, so presence gating would never share; the canonical target
        # mirrors every input attribute, so its tree carries the same compiled
        # shaders (hence `has_shaders = False` below — the flags check above
        # is the gate, not the source list).
        shader_ok = shader_tree_shareable_with_android(target_platform)
        if not native_assets_list and not has_data_assets and shader_ok:
            agent_src = getattr(ctx.attr, "_agent_extensions_src", None)
            stem = kernel_file_stem(ctx)
            own_kernel_shareable = debug_kernel_inputs_shareable(
                plugins = all_plugins,
                has_native_assets = False,
                has_shaders = False,
                has_data_assets = False,
                agent_import = (stem + ".agent_extensions.dart") if agent_src != None else None,
                native_agent_import = (stem + ".native_agent_extensions.dart") if agent_src != None else None,
            )
    shared_kernel = None
    if own_kernel_shareable and _debug_kernel != None and _debug_kernel[FlutterApplicationInfo].debug_kernel_shareable:
        shared_kernel = _debug_kernel[FlutterApplicationInfo]

    target_arch = host_target_arch(ctx, flutter_sdk_info)
    if shared_kernel != None:
        # The canonical manifest: empty (sharing requires it), keyed by the
        # canonical Android target string. The kernel was compiled against
        # this file, so this configuration serves it rather than writing an
        # identical map under its own target string.
        native_assets_manifest_file = shared_kernel.native_assets_manifest
    else:
        native_assets_manifest_file = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
        write_native_assets_manifest(
            ctx = ctx,
            output_file = native_assets_manifest_file,
            native_assets = native_assets_list,
            target_os = target_platform,
            target_arch = target_arch,
        )

    bundled_code_assets = collect_bundled_code_asset_files(native_assets_list)

    # Declared before the kernel compile that will later feed it, because a
    # debug app carries this path inside itself: `flutter_compile_kernel`
    # bakes it into `rules_flutter.build_info.assetsDir`, and the dev tool
    # matches the running app's reported value against the tree it watches
    # and rebuilds. Declaring an output is independent of registering the
    # action that fills it, so the ordering costs nothing. A build serving
    # the shared kernel serves the canonical tree with it: the baked path
    # must name the tree the kernel was compiled against.
    if shared_kernel != None:
        flutter_assets = shared_kernel.flutter_assets
    elif ctx.attr.build_label != "" and own_kernel_shareable:
        # The canonical kernel target, shareable in its own (Android) view:
        # name the tree off the served application's stem, not this target's
        # own label, so the baked `assetsDir` lands on the same path as the
        # application-local tree this kernel replaces (H17 byte-identity with
        # main's Android dill). Unshareable canonical targets keep their own
        # name: nothing serves them, and the stem name could collide with a
        # non-sharing application's own tree in the same configuration.
        flutter_assets = declare_flutter_assets_dir(ctx, name = kernel_file_stem(ctx))
    else:
        flutter_assets = declare_flutter_assets_dir(ctx)

    # Link hooks run over the uses the AOT compile records, so only a
    # release or profile build has any: a JIT compile tree-shakes nothing and
    # records nothing, and a debug build runs no hook and bundles no asset.
    run_link_hooks = bool(ctx.attr.link_hook_assets) and not is_debug
    recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if run_link_hooks else None

    # Step 1: Kernel compilation (mode-aware: debug uses debug dill, no AOT).
    # A build serving the shared kernel still emits its own configuration's
    # dev-loop metadata (live sources, generated roots, per-platform
    # registrants) for `_dev_config.json` — but no compile, so the canonical
    # FlutterKernelCompile is the only one in the build.
    if shared_kernel != None:
        kernel_dill = shared_kernel.kernel_dill
        package_config = shared_kernel.package_config
        source = flutter_kernel_source_inputs(ctx)
        agent_src = getattr(ctx.attr, "_agent_extensions_src", None)
        dev = flutter_dev_loop_inputs(ctx, source, mode, agent_src != None)
        compilation = struct(
            kernel_dill = kernel_dill,
            package_config = package_config,
            dev_plugin_registrants = dev.dev_plugin_registrants,
            dart_defines = dev.user_defines,
            app_entrypoint_uri = source.app_entrypoint_uri,
            dev_package_config = dev.dev_package_config,
            dev_filesystem_roots = dev.dev_filesystem_roots,
            dev_filesystem_scheme = dev.dev_filesystem_scheme,
            dev_generated_source_paths = dev.dev_generated_source_paths,
            dev_generated_source_uris = dev.dev_generated_source_uris,
            dev_generated_source_files = dev.dev_generated_source_files,
            dev_source_packages = dev.dev_source_packages,
            dev_app_sources = dev.dev_app_sources,
        )
    else:
        compilation = flutter_compile_kernel(
            ctx,
            flutter_sdk_info,
            target_platform = target_platform,
            native_assets_manifest = native_assets_manifest_file,
            track_widget_creation = ctx.attr.track_widget_creation,
            assets_dir = flutter_assets,
            recorded_uses = recorded_uses,
            platform_build_args = launch_build_args(
                target_platform,
                is_simulator = is_ios and apple_support.target_environment_from_rule_ctx(ctx) == "simulator",
                is_arm64 = ctx.target_platform_has_constraint(
                    ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo],
                ),
                is_x86_64 = ctx.target_platform_has_constraint(
                    ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo],
                ),
            ),
        )
    kernel_dill = compilation.kernel_dill
    package_config = compilation.package_config

    aot_output = None
    debug_info_output = None
    if not is_debug:
        # Collect gen_snapshot extra flags from user attrs (shared with
        # flutter_aot_target so the two stay in step). Obfuscation forces
        # `--strip`: unstripped DWARF would leak the original names.
        extra_flags, extra_outputs, debug_info_output, strip = flutter_aot_gen_snapshot_flags(ctx, strip)

        # Step 2: AOT compile — choose format based on target platform.
        if is_ios or is_macos:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".dylib")
            flutter_aot_macho_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                kernel_dill = kernel_dill,
                output = aot_output,
                strip = strip,
                extra_flags = extra_flags,
                extra_outputs = extra_outputs,
                min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
            )
        else:
            aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
            flutter_aot_elf_action(
                ctx = ctx,
                gen_snapshot = flutter_sdk_info.gen_snapshot,
                kernel_dill = kernel_dill,
                output = aot_output,
                strip = strip,
                extra_flags = extra_flags,
                extra_outputs = extra_outputs,
            )

    # Collect native shared libraries from native_deps + transitive plugin deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())

    # Step 2b: package link hooks over the recorded uses. Each emits the data
    # assets declared in `link_hook_assets`, bundled below beside the native
    # assets' data assets.
    link_hook_validation = []
    if run_link_hooks:
        link = dart_link_hook_actions(
            ctx,
            runner = ctx.executable._link_hook_runner,
            sdk = ctx.toolchains["@rules_dart//dart:exec_tools_toolchain_type"].dart_sdk_info,
            recorded_uses = recorded_uses,
            deps = ctx.attr.deps,
            data_asset_ids = ctx.attr.link_hook_assets,
            name = ctx.label.name + "_link_hooks",
        )
        transitive_data_assets = depset(link.assets, transitive = [transitive_data_assets])
        link_hook_validation = link.validation_outputs

    # Step 3: Shader compilation + asset bundle. Pass data assets so the
    # bundler places them under flutter_assets/packages/<pkg>/<name>. A build
    # serving the shared kernel serves the canonical tree with it — whose
    # compiled shaders match this configuration's impellerc invocation — so
    # it bundles nothing itself. (Sharing requires shaders this configuration
    # can reuse, and no data assets, so the canonical tree's content is this
    # configuration's content.)
    if shared_kernel == None:
        compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, target_platform)
        flutter_build_assets(
            ctx,
            flutter_sdk_info,
            flutter_assets,
            compiled_shaders,
            kernel_dill = kernel_dill,
            is_debug = is_debug,
            data_assets = transitive_data_assets,
        )

    # Every loose native library this app carries, by both routes in: the
    # `native_deps` set above, and the Native Assets `CodeAsset` libraries
    # `native_assets.json` already points at. Deduplicated by path because
    # nothing stops one library arriving twice.
    bundled_native_libs = {}
    for lib in native_libs + bundled_code_assets.to_list():
        bundled_native_libs[lib.path] = lib

    # What each of those libraries' bindings were generated from, when its build
    # said so — see `flutter_native_library`. Keyed by the same paths, so a
    # library with no contract is an empty list rather than a missing key: the dev
    # tool has to tell "nothing describes this one" from "this one is not
    # bundled", and they mean opposite things for a reload.
    binding_contracts = {path: [] for path in bundled_native_libs}
    contract_files = []
    for pair in collect_binding_contracts(ctx.attr.native_deps) + [
        p
        for dep in ctx.attr.deps
        if FlutterInfo in dep
        for p in dep[FlutterInfo].binding_contracts.to_list()
    ]:
        if pair.library.path in binding_contracts:
            binding_contracts[pair.library.path] = [
                f.path
                for f in pair.contract
            ]
            contract_files.extend(pair.contract)

    # And what each is built from, on the same keys, so a reload can tell that a
    # library went stale in an app that runs no build of its own.
    native_lib_sources = {path: [] for path in bundled_native_libs}
    for pair in collect_native_source_pairs(ctx.attr.native_deps) + [
        p
        for dep in ctx.attr.deps
        if FlutterInfo in dep
        for p in dep[FlutterInfo].native_lib_sources.to_list()
    ]:
        if pair.library.path in native_lib_sources:
            native_lib_sources[pair.library.path] = [
                f.path
                for f in pair.sources
            ]

    # The code-asset libraries join `default_files` with the manifest that names
    # them. Declaring an output is what makes its path true: the manifest is
    # built here and the dev tool reads these files back off this target, and a
    # path named by a build that did not write it fails far from its cause.
    default_files = [
        flutter_assets,
        package_config,
        native_assets_manifest_file,
    ] + bundled_native_libs.values()
    if aot_output:
        default_files.append(aot_output)
    if is_debug:
        default_files.append(kernel_dill)

    # Hot-reload dev config (debug only), mirroring flutter_web_application's
    # `_dev_config.json`. Tells the dev tool the authoritative entrypoint URI
    # and — for a source-assembled (codegen) app — the multi-root layout +
    # generated source paths/URIs, so it never infers any of this from
    # package_config rootUri shapes. The dev tool discovers this by building the
    # flutter_application target directly (its DefaultInfo). When
    # `generatedSourceUris` is non-empty the dev tool rebuilds this same app
    # target on change to regenerate codegen outputs (a narrow codegen-only
    # rebuild would prune the flutter SDK from the execroot symlink forest and
    # break the next full compile).
    if is_debug and compilation.dev_package_config != None:
        dev_config_file = ctx.actions.declare_file(ctx.label.name + "_dev_config.json")
        ctx.actions.write(
            output = dev_config_file,
            content = json.encode({
                "engineRevision": flutter_sdk_info.engine_revision,
                "flutterVersion": flutter_sdk_info.version,
                "dartSdkRoot": flutter_sdk_info.dartaotruntime.path.rsplit("/bin/", 1)[0],
                "dartaotruntime": flutter_sdk_info.dartaotruntime.path,
                "frontendServer": flutter_sdk_info.frontend_server.path,
                "patchedSdkRoot": flutter_sdk_info.platform_kernel_dill.path.rsplit("/", 1)[0],
                "appEntrypoint": compilation.app_entrypoint_uri,
                # Merged user defines (attr + extra_dart_defines flag). The
                # dev tool replays these as -D on its resident frontend_server
                # so hot reload/restart recompiles keep the same environment.
                "dartDefines": compilation.dart_defines,
                # Generated plugin registrants, keyed by platform
                # (exec-relative paths, "" when that platform has no Dart
                # plugins and no agent). One per platform because this dev
                # build runs in the host configuration while the app can be
                # running elsewhere; the dev tool selects by the platform the
                # app reports (build_info.targetPlatform), compiles that file
                # into its dills via --source, and advertises it with
                # -Dflutter.dart_plugin_registrant so the engine's pre-main
                # hook keeps firing — with the right plugin set — after hot
                # restart.
                "dartPluginRegistrants": {
                    platform: registrant.path if registrant else ""
                    for platform, registrant in compilation.dev_plugin_registrants.items()
                },
                "devPackageConfig": compilation.dev_package_config.path,
                "filesystemRoots": compilation.dev_filesystem_roots,
                "filesystemScheme": compilation.dev_filesystem_scheme,
                "generatedSourcePaths": compilation.dev_generated_source_paths,
                "generatedSourceUris": compilation.dev_generated_source_uris,
                # Every bundled shader, by bundle path, with the workspace
                # files it is compiled from. The dev tool watches those and
                # has the app reload a shader whose compiled bytes changed.
                "shaders": shader_sources(ctx),
                # The loose native libraries this build writes, from the
                # same list `default_files` carries so the two cannot drift —
                # `native_deps` and Native Assets code assets alike, because a
                # process maps both and can replace neither. A `dlopen`ing app has these mapped for the life
                # of its process, and a hot reload that rebuilds this target to
                # regenerate codegen sources rebuilds them too — so comparing
                # them across those rebuilds is how the dev tool learns that an
                # increment would be injected over stale machine code, without
                # paying a second build in the app's launch configuration.
                # Empty unless the app bundles `native_deps`.
                "nativeLibs": bundled_native_libs.keys(),
                # Per library, the files its bindings were generated from. A
                # reload compares these bytes to decide whether an increment is
                # one the library the running process already has can serve —
                # see `NativeLibsWatch` in the dev tool. Empty list: nothing
                # declared, so the reload cannot know and will not guess.
                "nativeLibContracts": binding_contracts,
                # Per library, the first-party sources it is built from, so a
                # reload can see a native edit in an app that runs no build of
                # its own — every app without generated sources. Stat-ed on each
                # reload; see `native_sources.bzl`.
                "nativeLibSources": native_lib_sources,
                # First-party source packages (app + local deps) the dev tool
                # maps live edits back to via its SourceUriResolver. libRoot is
                # workspace-relative.
                "sourcePackages": [
                    {"name": sp[0], "libRoot": sp[1]}
                    for sp in compilation.dev_source_packages
                ],
                # The sources outside every package the app compiles under the
                # app scheme — a `main` outside its package's `lib/` and the
                # `srcs` beside it — with the URI the compiler keys each by.
                # Empty for a `main` with a `package:` URI.
                "appSources": compilation.dev_app_sources,
            }),
        )
        default_files.append(dev_config_file)
        default_files.append(compilation.dev_package_config)

        # The dev registrants are inputs to no action — without this they are
        # declared but never materialized by the bare build, and the dev tool
        # would absolutize a dangling path.
        for registrant in compilation.dev_plugin_registrants.values():
            if registrant:
                default_files.append(registrant)

        # The generated sources `_dev_config.json` points the frontend_server
        # at. These *are* inputs to the kernel compile, which is why they
        # looked safe — but an input is materialized on the machine that ran
        # the action, and a cache hit runs none. Declaring them is what makes
        # the paths in the config true.
        default_files.extend(compilation.dev_generated_source_files)

        # And the binding contracts, which have it worse than the generated
        # sources: a contract is an input to no action of this target at all.
        # Nothing but the dev tool ever reads its bytes, so a *generated*
        # contract is written only if some other action happens to produce it —
        # a bridge generator that emits its interface description beside the
        # Dart it also emits does, and a rule that emits the description alone
        # does not. The first case works by luck and the second one names a
        # path in the config that this build never writes, which the dev tool
        # reports at launch as a build that declared a file it did not write.
        # Declaring them is what makes the paths true, and what makes the
        # reload's own rebuild refresh them.
        default_files.extend(contract_files)

    output_groups = {
        "native_assets_manifest": depset([native_assets_manifest_file]),
        "bundled_code_assets": bundled_code_assets,
    }
    if debug_info_output:
        output_groups["debug_info"] = depset([debug_info_output])
    if link_hook_validation:
        # Every hook runs whenever the app builds, even one that emits no
        # asset, so its verdict on the program is never skipped.
        output_groups["_validation"] = depset(link_hook_validation)

    providers = [
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            kernel_dill = kernel_dill if is_debug else None,
            flutter_assets = flutter_assets,
            icu_data = flutter_sdk_info.icu_data,
            native_libs = native_libs,
            is_debug = is_debug,
            package_config = package_config,
            native_assets_manifest = native_assets_manifest_file,
            bundled_code_assets = bundled_code_assets,
            bundled_data_assets = transitive_data_assets,
            apple_privacy_manifests = apple_privacy_manifests,
            plugins = all_plugins,
            apple_plugin_libraries = apple_plugin_libraries,
            android_plugin_libraries = android_plugin_libraries,
            linux_plugin_libraries = linux_plugin_libraries,
            windows_plugin_libraries = windows_plugin_libraries,
            debug_kernel_shareable = is_debug and ctx.attr.build_label != "" and own_kernel_shareable,
        ),
    ]
    providers.append(OutputGroupInfo(**output_groups))
    return providers

flutter_application = rule(
    implementation = _flutter_application_impl,
    attrs = dicts.add(
        FLUTTER_APPLICATION_ATTRS,
        DEBUG_KERNEL_ATTRS,
        PLATFORM_CONSTRAINT_ATTRS,
        link_hook_runner_attr(),
        # Simulator-vs-device is an Apple *environment* constraint, not an OS
        # one, so it needs apple_support's own attrs on top of the OS set.
        # `launch_build_args` turns it into `--ios_multi_cpus=sim_arm64` or
        # `=arm64`, which is the difference between a dev-loop rebuild landing
        # in the app's output tree and landing in one it never reads.
        apple_support.platform_constraint_attrs(),
    ),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Flutter application to AOT native code + asset bundle (release) or kernel .dill + assets (debug).",
)
