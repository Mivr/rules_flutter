# Asks for rules_dart

What rules_flutter needs from rules_dart's performance work, so that the two
reviews don't build the same thing twice. Sent to the rules_dart review's cloud
session on 2026-10-14. Its answers go in rules_dart's
`ai-docs/performance/for-rules-flutter.md` on `main`, where this review reads
them.

Status: **open** until rules_dart's docs say otherwise.

## A. Export modular compilation with the target as a parameter (rules_dart #7)

rules_flutter will compile Flutter code in modules too (plan 2.1). It can't
reuse `dart_library`'s own modules:

- Flutter code needs `--target flutter` against Flutter's platform outline
  (`flutter_patched_sdk/vm_outline_strong.dill`, which has `dart:ui`).
- Conditional imports on `dart.library.ui` resolve differently from the `vm`
  target.

The ask: export, through `@rules_dart//dart:utils.bzl`:

- the module-compile action helper;
- the drop-and-retry `kernel_module` tool;
- the `kernel_link` tool.

The helper should take as parameters the target, the SDK summary, the worker
(from `DartSdkInfo`) and extra inputs. Flutter then adds an aspect that
compiles each `DartInfo` target as a Flutter module with the same tools.
Flutter's bundled SDK ships `kernel_worker_aot`, which accepts `--target
flutter` (see `findings.md`).

## B. Analyzer summaries need Flutter's `dart:ui` (rules_dart #8)

The analyzer finds `dart:ui` only through `package:sky_engine`'s
`lib/_embedder.yaml`. That is why rules_flutter adds `@flutter_sky_engine` to
every `DartAnalyzableInfo` (`SKY_ENGINE_ATTR`). An SDK summary built from the
Dart SDK alone won't contain it, so Flutter targets in summary mode would fail
to resolve `dart:ui`. The ask: let the SDK summary take an embedder (the
sky_engine package), or say how Flutter should provide one.

## C. One stable URI scheme (rules_dart #9)

rules_flutter's kernel compile already mounts `org-dartlang-app` (multi-root)
for the plugin registrant and for a `main` outside `lib/`. Hot reload depends on
it. frontend_server mounts one scheme at a time. Before rules_dart settles on
`org-dartlang-bazel` for its compiles, check that one scheme can serve both. For
example, Flutter could mount the exec root and `bin_dir` under its existing
scheme with the same path convention. The ask: agree on the convention, so that
`generate_dev_package_config` and Flutter's compile agree with rules_dart's.

## D. A version rules_flutter can depend on

rules_flutter takes rules_dart from the BCR (`bazel_dep(name = "rules_dart",
version = "0.7.2")`). `--override_module` only helps local work. The ask: say
when the performance work will be released, or which `main` commit is safe to
pin for testing.

## E. Declare an SDK toolchain over a directory (plan T adopted 2026-10-14)

rules_flutter will register the Flutter-bundled `dart-sdk/` as
a `dart_toolchain`. Its layout matches the root of rules_dart's SDK repository.
The ask: export the `sdk_root`, `compile_files`, `runtime_files` and
`dart_toolchain` declaration that `dart/repositories.bzl` generates as a macro
that takes a path prefix. Flutter's engine repository would call it, and the
file lists would stay in one place. Also confirm that a root-registered
`dart_toolchain` wins over rules_dart's default registration without fetching
the default SDK.

## F. The Dart version comes from Flutter (plan T adopted)

A Flutter workspace's Dart is the one its Flutter release bundles, not
rules_dart's default. The ask: keep rules_dart's features correct, or falling
back, on SDKs other than the default. The analyzer-summary linter is vendored
for one analyzer version, and the runner snapshot and `kernel_worker`
availability depend on the SDK.

## G. Bazel 9.3.0 in step

Both repositories pin 9.2.0. rules_flutter's root suite passes on 9.3.0 after a
lockfile refresh. The ask: bump together when the user schedules it, so that CI
on the pinned pair uses one Bazel.

## H. `bazel_lib` (rules_dart #11)

`flutter_test` lists `COPY_TO_DIRECTORY_TOOLCHAINS`, and rules_flutter depends
on `bazel_lib` only for rules_dart's `colocate_packages`. The ask: note in
`for-rules-flutter.md` when #11 lands, so rules_flutter drops the dependency in
the same release.

## I. Fail on pub packages without a checksum (the user's hermeticity rule)

The user requires every downloaded SDK, artifact and package to be pinned by
sha256, with a missing checksum failing the fetch. rules_dart's SDK download is
already strict. Its pub path is not:

- `dart/pub/extensions.bzl` passes `desc.get("sha256", "")`;
- `pub_lock_package` and `pub_repository` then download with `sha256 = ""`.

So a lock entry without a checksum downloads unverified. rules_flutter's
`flutter.pub` has the same gap and closes it in plan H0. The ask: the same
rule for `pub.from_lock()`, preferably with the same error text.

## J. Keep finding the SDK from `dart`

Plan T places the SDK under `dart-sdk/` inside Flutter's engine repository, not
at a repository root. That works because rules_dart derives the SDK directory
from the `dart` binary (`sdk_path_from_dart`). The ask: keep that contract,
with nothing deriving SDK paths from `sdk_root`'s repository root, or tell
rules_flutter before it changes.
