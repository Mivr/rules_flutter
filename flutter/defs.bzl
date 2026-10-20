"""Core rules for building Flutter applications.

This is the main entry point for rules_flutter. It exports platform-agnostic
rules that compile Dart code, bundle assets, and run tests.

## Recommended (start here)

- `flutter_application`: Compiles Dart code (kernel + AOT) and bundles assets.
    This is the primary rule — it produces a `FlutterApplicationInfo` provider
    that platform-specific packaging rules consume.
- `flutter_library`: Collects Flutter Dart sources and assets into a reusable
    dependency. Wire into `flutter_application` via `deps`.
- `flutter_plugin`: Declares a Flutter plugin with optional Dart registration
    class and/or native shared library dependencies.
- `flutter_test`: Runs Flutter widget tests using the flutter_tester runtime.
- `flutter_integration_test`: Runs end-to-end Flutter integration tests inside
    a real platform app (e.g. `platform = "web"` in headless Chrome).

## Advanced / Low-Level

Most users don't need these directly. `flutter_application` composes them
internally. They are exported for advanced use cases like custom pipelines.

- `flutter_kernel_target`: Runs the Flutter frontend compiler to produce a
    kernel .dill file from Dart sources.
- `flutter_aot_target`: Runs gen_snapshot to AOT-compile a kernel .dill into
    native code (ELF .so or Mach-O dylib).
- `flutter_asset_bundle`: Bundles Flutter assets (images, fonts, shaders)
    into a flutter_assets/ tree artifact.

## Platform packaging

After `flutter_application`, use platform-specific rules to produce runnable
artifacts:

- `@rules_flutter//flutter:macos.bzl` — `flutter_macos_app` + composable rules
- `@rules_flutter//flutter:ios.bzl` — `flutter_ios_app` + composable rules
- `@rules_flutter//flutter:linux.bzl` — `flutter_linux_app` + composable rules
- `@rules_flutter//flutter:windows.bzl` — `flutter_windows_app` + composable rules
- `@rules_flutter//flutter:web.bzl` — `flutter_web_app` + composable rules (takes source directly, not a flutter_application target)
"""

load("//flutter/private:flutter_aot_target.bzl", _flutter_aot_target = "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", _flutter_application = "flutter_application")
load("//flutter/private:flutter_asset_bundle.bzl", _flutter_asset_bundle = "flutter_asset_bundle")
load("//flutter/private:flutter_gen_l10n.bzl", _flutter_gen_l10n = "flutter_gen_l10n")
load("//flutter/private:flutter_integration_test.bzl", _flutter_integration_test = "flutter_integration_test")
load("//flutter/private:flutter_kernel_target.bzl", _flutter_kernel_target = "flutter_kernel_target")
load("//flutter/private:flutter_library.bzl", _flutter_library = "flutter_library")
load("//flutter/private:flutter_native_library.bzl", _flutter_native_library = "flutter_native_library")
load("//flutter/private:flutter_plugin.bzl", _flutter_plugin = "flutter_plugin")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test")

flutter_aot_target = _flutter_aot_target

def debug_kernel_tags(tags):
    """Tags for the macro-created canonical debug-kernel target (H17).

    The canonical kernel is an implementation detail consumed through the
    outer's `debug_kernel` edge (which transitions it into the canonical
    configuration). Left visible to `//...`, it would also build top-level
    in every requesting configuration and compile the kernel once more per
    configuration — the duplication H17 removes. `manual` keeps it out of
    wildcard builds while explicit requests still work.

    Args:
        tags: Caller-passed tags for the application, if any.

    Returns:
        The tags for the canonical target: the caller's tags plus `manual`.
    """
    tags = list(tags or [])
    if "manual" not in tags:
        tags.append("manual")
    return tags

def flutter_application(name, package_name = "", **kwargs):
    """Compiles a Flutter application with stable package: URIs for hot reload.

    Auto-derives `package_name` from the rule name if not explicitly set.
    This ensures the kernel uses `package:<name>/main.dart` URIs instead of
    sandbox `file:///` URIs, which is required for hot reload incremental
    deltas to match the running application's library URIs.

    Beside the application, creates a canonical debug-kernel target
    (`__<name>_debug_kernel`, an instance of the same rule): a debug build
    whose kernel inputs are platform-identical serves that target's kernel —
    compiled once in the Android configuration — instead of compiling its
    own (H17). The inner target shares every input attribute; it never
    shares further itself.

    Args:
        name: Target name.
        package_name: Dart package name (from pubspec.yaml). Defaults to name.
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    inner_name = "__" + name + "_debug_kernel"

    # The sharing wiring is the macro's own: a caller-passed value would wire
    # the inner target at itself or fork the outer elsewhere.
    kwargs.pop("debug_kernel", None)
    kwargs.pop("build_label", None)

    # The canonical kernel is an implementation detail consumed through the
    # outer's `debug_kernel` edge (see `debug_kernel_tags`): keep it out of
    # wildcard builds so `//...` does not compile it once per configuration.
    # Popped so it can differ from the outer's (which keeps caller tags only).
    caller_tags = kwargs.pop("tags", [])
    _flutter_application(
        name = inner_name,
        package_name = package_name or name,
        build_label = "@@//" + native.package_name() + ":" + name,
        tags = debug_kernel_tags(caller_tags),
        **kwargs
    )
    _flutter_application(
        name = name,
        package_name = package_name or name,
        debug_kernel = ":" + inner_name,
        tags = caller_tags,
        **kwargs
    )

flutter_asset_bundle = _flutter_asset_bundle
flutter_gen_l10n = _flutter_gen_l10n
flutter_integration_test = _flutter_integration_test
flutter_kernel_target = _flutter_kernel_target
flutter_library = _flutter_library
flutter_native_library = _flutter_native_library
flutter_plugin = _flutter_plugin
flutter_test = _flutter_test
