# Findings

Facts established by measurement or by reading the code. Each one says how it
was established, so it can be rechecked when Flutter, Dart or Bazel moves.
Unless stated otherwise: rules_flutter `51b22bb`, Flutter 3.47.6 (bundled Dart
3.13.5), Bazel 9.2.0, Linux x64.

## Baseline: root workspace

`bazel test //... --jobs=16`, run clean against the published rules_dart 0.7.2:

- 338 tests pass, 2 iOS tests skip, 464 targets analysed.
- 360 s wall time, of which about 112 s is first-time downloads.
- Critical path 59.7 s.
- 14,287 processes.

Against rules_dart `main` at `95089ce`, through `--override_module` with
`--lockfile_mode=off`, the suite stays green:

- The 85 tests that re-ran, all `dart_test`s in `//tools/dev_tool` and
  `//flutter/private/tools` plus the two analyze fixtures, pass.
- The other 253 results were cached. Their inputs did not change, so that is
  sound.
- The e2e workspaces were not run, and they hold nearly all real Flutter
  compiles (plan 0.1).

## Where a Flutter target's cost goes (read from the code)

- **Every `flutter_test` and application compiles its whole program.**
  - `flutter_compile_kernel` (`flutter/private/common.bzl`) and
    `_flutter_test_impl` (`flutter/private/flutter_test.bzl`) hand
    frontend_server every transitive source.
  - `package:flutter` alone is 695 `.dart` files (24 MB), compiled again for
    every test.
  - Nothing is shared between targets.
- **Every Flutter action takes the whole SDK.**
  - `FlutterSdkInfo.tool_files` (`flutter/toolchain.bzl`) is all of `dart-sdk/`
    plus the patched SDK: 1,049 files, 654 MB.
  - It is an input of every `FlutterKernelCompile`, `FlutterShaderCompile` and
    `FlutterAssetBundle` action, and part of every `flutter_test`'s runfiles.
  - The kernel compile itself reads `dartaotruntime` (5.7 MB), the
    frontend_server snapshot (17 MB) and a platform dill.
- **Build-step scripts are JIT-compiled on every action.**
  - `kernel_filter.dart`, `compile_shader.dart`, `generate_asset_manifest.dart`,
    `bundle_app.dart`, the manifest and plist mergers and `web_template.dart`
    are run as `dart <script>.dart` straight from source
    (`flutter/private/tools/BUILD.bazel` says so).
  - Only `flutter_test_runner` and `pub_runner` are compiled (`compile_mode =
    "exe"`).
- **Every test repeats the same shader and asset work.**
  - Each `flutter_test` compiles `package:flutter`'s two shaders
    (`ink_sparkle.frag`, `stretch_effect.frag`) under its own output path, so N
    tests run 2N identical compiles.
  - Each compile goes through the `compile_shader.dart` wrapper with the whole
    SDK as input, because the `tester` stage list has SkSL plus Vulkan.
  - Each test also builds its own `flutter_assets/` tree.
- **Analysis repeats work.** `_flutter_test_impl` flattens
  `DartInfo.transitive_packages` three times (`_can_bootstrap`,
  `_has_flutter_test`, `check_unreplaced_hooks`), as well as the transitive
  sources. This is not profiled yet.

## Two Dart SDKs in every Flutter workspace

- rules_dart's `MODULE.bazel` registers its default toolchain (Dart 3.13.5) for
  every consumer: `register_toolchains("@dart_toolchains//:all")`, not a dev
  dependency.
- rules_flutter's engine repository (`flutter_engine_artifacts`,
  `flutter/repositories.bzl`) ships the Flutter-bundled Dart SDK under
  `dart-sdk/`.
- Both were fetched in the baseline run, 642 MB each:
  `rules_dart++dart+dart_linux-x64` and `+flutter+flutter_linux-x64/dart-sdk`.
- Who uses which:
  - **Flutter's Dart** (`FlutterSdkInfo.dart`/`dartaotruntime`/`tool_files`):
    the kernel compile, shader and asset-bundle steps, and every script in
    `flutter/private/tools`.
  - **rules_dart's Dart** (`@rules_dart//dart:toolchain_type` and
    `:exec_tools_toolchain_type`):
    - the `dart_analyze` aspect over Flutter targets (analysis, format check,
      fix);
    - `dart_codegen`;
    - every `dart_test` and `dart_binary`, including rules_flutter's own
      `flutter_test_runner`;
    - `flutter_application`'s link hooks (`flutter_application.bzl:205`).
- Nothing ties the two versions together. They are both 3.13.5 today because
  rules_dart's default and Flutter 3.47.6's bundled Dart happen to match.
  `flutter/private/versions.bzl` lists 17 Flutter releases and records no Dart
  version for any of them.
- The layouts match. `dart-sdk/` in the Flutter engine repository has the same
  `bin/`, `lib/` and `version` layout as the root of rules_dart's SDK
  repository. rules_dart's `dart_toolchain`, `compile_files` and
  `runtime_files` declarations would apply to it unchanged, with a path prefix.
- The separate toolchain has no recorded rationale. `flutter/toolchain.bzl`
  dates from the initial scaffolding (`e5fbb95`) and mirrors the shape of
  rules_dart's `dart/toolchain.bzl`.
- What is genuinely Flutter's and not Dart's varies by target platform:
  - `gen_snapshot` (per target), the engine library, `flutter_tester`;
  - `impellerc` and `shader_lib`, `font-subset` and `const_finder`;
  - the patched platform dills that carry `dart:ui`;
  - the ICU data, the isolate snapshots, the Material font, the Linux sysroot.

## Modular compilation is possible with Flutter's own SDK

- Flutter's bundled `dart-sdk/bin/snapshots/` includes
  `kernel_worker_aot.dart.snapshot`. Its `--help` lists `--target` with `vm,
  flutter, flutter_runner, dart2js, dart2js_summary, dart2wasm, ddc`, and
  `--input-linked`, `--multi-root` and `--multi-root-scheme`.
- `patched-sdk/flutter_patched_sdk/` holds `platform_strong.dill` and
  `vm_outline_strong.dill`, the Flutter platform as a full kernel and as an
  outline.
- rules_dart's modules (their plan #7) can't be reused for Flutter as they
  are. They are compiled for `--target vm` against the standalone Dart
  platform, while Flutter code needs `--target flutter` against a platform
  that has `dart:ui`. Conditional imports on `dart.library.ui` also resolve
  differently.

## Tooling

- `bazel analyze-profile` no longer exists. Bazel 9.2.0, 9.3.0 and 10.0.0rc1
  all answer `'analyze-profile' is not a known command`.
- The `--profile` JSON trace is still written. rules_dart's
  `harness/prof.py` summarises it per mnemonic. Use `--noslim_profile`.

## Bazel versions (root `bazel test //...`, selected by `USE_BAZEL_VERSION`)

- **9.3.0**: 338 pass, 2 skipped, 353 s, with `--lockfile_mode=off`.
  - With the repository default `--lockfile_mode=error`, Bazel stops with
    `Missing checksum for registry file
    https://bcr.bazel.build/modules/apple_support/2.5.2/MODULE.bazel`.
  - Bumping needs the lockfile refresh `.bazelrc` describes.
- **10.0.0rc1**: analysis fails in C toolchain auto-configuration, not in
  these rules. Not diagnosed.
  - First `Cannot find gcc or CC`, although `gcc` is on PATH and 9.3.0 finds
    it.
  - With `--repo_env=CC=/usr/bin/gcc`, it fails with `key "ar" not found in
    dictionary`.

## Download checksums (audit, 2026-10-14)

- **rules_dart's SDK download is strict.** `dart/repositories.bzl` indexes
  `TOOL_VERSIONS[version][platform]`, so a missing checksum fails the fetch.
- **rules_flutter's checksums are optional.** Every engine download in
  `flutter/repositories.bzl` reads `ARTIFACT_CHECKSUMS.get(version,
  {}).get(path, "")`, and Bazel accepts any bytes for an empty `sha256`.
  - `ARTIFACT_CHECKSUMS` has 8 Flutter versions, 30–31 artifacts each,
    including `dart-sdk-<host>.zip` for all five hosts.
  - The Android engine artifacts (`android-<arch>-<mode>/artifacts.zip`) and
    Android `gen_snapshot` (`android-<arch>-release/<host>.zip`) are not in the
    table for any version, so today they download unverified.
  - `flutter_source_sha256()` and `LINUX_SYSROOT_CHECKSUMS[...]` are strict.
- **Pub packages:** `flutter.pub` takes each hosted package's `sha256` from
  `pubspec.lock` (`description.sha256`). An entry without one downloads
  unverified (`flutter/extensions.bzl`, `flutter_pub_package.bzl`).

## Plan T is feasible on rules_dart 0.7.2 (read from the code)

- **Finding the SDK.** rules_dart derives the SDK directory from the `dart`
  binary (`sdk_path_from_dart`: strip `/bin/dart`), not from the repository
  root. So an SDK under `dart-sdk/` in Flutter's engine repository resolves
  correctly.
- **What T1 must mirror.** rules_dart registers, per host:
  - a `toolchain_type` toolchain, with exec and target both the host;
  - an `exec_tools_toolchain_type` toolchain, with exec constraints only;
  - desktop cross toolchains (`CROSS_TARGETS`, which reuse the host `dart`).
  T1 has to mirror all three, or the remaining resolutions fall back to
  rules_dart's registration and fetch its SDK.
- **The 0.7.2 attributes.** `dart_toolchain` in 0.7.2 takes `dart`,
  `sdk_root`, `version`, `target_os` and `target_arch`. `compile_files` and
  `runtime_files` exist only on rules_dart `main` (`b3c8dc3`).

## e2e against rules_dart `main` (plan 0.1, 2026-10-14)

- **What ran.** rules_dart `87e6772` (`--override_module`, run B) against the
  published 0.7.2 (run A), with `--nocache_test_results` on B.
- **Workspaces.** The CI Linux pair (`hello_world`, `codegen`), plus `smoke`,
  `dual_hub`, `plugin_example`, `ffi_example`, `ffi_plugin_example` and
  `web_example`.
- **Android stand-ins.** `hello_world` and `plugin_example` need an Android
  NDK and SDK that this host lacks. They ran with the NDK repository stubbed
  (`--override_repository=...androidndk=<empty repo>`); their Android targets
  then fail to load, the same way in A and B.
- **No regressions.** Every workspace has identical results in A and B:
  - `codegen`: 10 pass;
  - `smoke` and `dual_hub`: 1 pass each;
  - `ffi_example`: 4 pass;
  - `ffi_plugin_example`: 3 pass;
  - `web_example`: 12 pass;
  - `hello_world`: 14 pass, Android targets environmental;
  - `plugin_example`: 2 pass, Android environmental, plus bug B1 in both runs.
- **What B actually exercised** (from its `--profile`):
  - Re-ran: `DartAnalyze`, `DartFormat`, `DartCompile` and every `TestRunner`.
  - Cache hits: every `FlutterKernelCompile`, `FlutterShaderCompile` and
    `FlutterAssetBundle`. rules_dart `main` doesn't change their action keys,
    so bumping rules_dart is safe for Flutter's compile path, and its
    analysis/format/test changes pass on Flutter targets.
- **Rough per-action costs on `codegen`** (32-way parallel, so contended):
  - `TestRunner`: 17.8 s mean over 10 Flutter tests;
  - `DartAnalyze`: 8.3 s mean;
  - `DartFormat`: 5.9 s mean;
  - `CopyToDirectory`: 1.9 s mean.
  The benchmark (0.2) will measure these properly.
