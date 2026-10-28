"""Implementation of the flutter_library rule."""

load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info_with_package", "dart_info", "dart_package_identity", "derive_lib_root", "derive_package_name")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:asset_keys.bzl", "library_asset_entries")
load("//flutter/private:asset_uri.bzl", "normalize_asset_uri")
load("//flutter/private:flutter_font_family.bzl", "FONTS_ATTR", "check_unclaimed_font_files", "font_family_contributions", "font_file_table", "font_json_contribution")
load("//flutter/private:flutter_info.bzl", "LINK_HOOK_ATTR", "flutter_asset_channels", "flutter_info", "flutter_pub_channels")

def pub_asset_matches_target(flavors, platforms, target_platform, flavor = None):
    """Whether a pub asset entry bundles on the target platform.

    Mirrors flutter_tools' `_Asset` (`packages/flutter_tools/lib/src/asset.dart`):
    `matchesFlavor` runs first — a flavor-restricted entry bundles only when
    the selected flavor is listed (rules_flutter selects no flavor yet, so
    such entries bundle nowhere) — then `matchesPlatform`: an empty list or
    the `tester` platform keeps the asset, anything else must name the
    target's `osName` (`build_info.dart` `TargetPlatform.osName`: `android`,
    `ios`, `macos`, `linux`, `windows`, `web`).

    Args:
        flavors: The entry's `flavors` list (empty = unconditional).
        platforms: The entry's `platforms` list (empty = every platform).
        target_platform: The bundle's platform (`tester` for test bundles).
        flavor: The selected flavor, or None (always None for now).

    Returns:
        True when the entry belongs in the bundle.
    """
    if flavors:
        if flavor == None or flavor not in flavors:
            return False
    if not platforms or target_platform == "tester":
        return True
    return target_platform in platforms

def _entry_conditions(decoded_path, pkg_asset_platforms, pkg_asset_flavors):
    """The `(platforms, flavors)` condition lists for one asset path.

    Args:
        decoded_path: The normalized package-relative asset path (decoded,
            a `pkg_assets` value through `normalize_asset_uri`).
        pkg_asset_platforms: `ctx.attr.pkg_asset_platforms` — label string
            (`":" + path`) to platform list, only for restricted entries.
        pkg_asset_flavors: `ctx.attr.pkg_asset_flavors` — same shape.

    Returns:
        A `(platforms, flavors)` tuple of lists (empty = unconditional).
    """
    key = ":" + decoded_path
    return (
        list(pkg_asset_platforms.get(key, [])),
        list(pkg_asset_flavors.get(key, [])),
    )

def _normalize_attr_value(package_name, attr_name, value):
    """Normalize one `pkg_assets` / `pkg_shaders` value.

    Values arrive as raw entry text (handwritten attrs) or decoded labels
    (spoke attrs); normalization is idempotent, so both land on the same
    decoded path and encoded bundle key. The decoded path joins the
    conditions dicts and the key is what bundles. Fonts go through
    `font_file_table` and `font_json_contribution`, which normalize their
    own asset values the same way.

    Args:
        package_name: The contribution's package name, for the failure.
        attr_name: The attr the value came from, for the failure.
        value: The attr value string.

    Returns:
        The `normalize_asset_uri` struct; fails on a spelling that is not
        supported, naming the attr and the value.
    """
    norm = normalize_asset_uri(value)
    if not norm.ok:
        fail("package \"%s\": %s value %s uses a spelling that is not supported: %s" % (package_name, attr_name, repr(value), norm.reason))
    return norm

def _contribution_context(package_name, font_files_dict):
    """The package name and target label a contribution's failures name.

    A rule passes a `struct(package_name, label)` so a failure names its own
    label. A caller that passes only a package name (the shader aspect, or a
    pub spoke) gets the first font file's label, which names the package the
    declarations live in.

    Args:
        package_name: The first argument `build_pub_contributions` received:
            a `struct(package_name, label)` or a bare package name string.
        font_files_dict: The rule's `font_files`, read for a fallback label.

    Returns:
        A struct(package_name, label).
    """
    if type(package_name) == "struct":
        return package_name
    label = package_name
    if not label:
        for target in font_files_dict:
            label = str(target.label)
            break
    return struct(
        package_name = package_name,
        label = label or "the target declaring fonts_json",
    )

def build_pub_contributions(package_name, fonts_json, font_files_dict, pkg_assets_dict, pkg_shaders_dict, shader_includes = [], pkg_asset_platforms = {}, pkg_asset_flavors = {}):
    """Build pub_fonts/pub_assets/pub_shaders contribution structs from rule attrs.

    Decodes the JSON-encoded font declarations and walks the file dicts,
    producing the contribution structs that `build_flutter_providers` accepts
    as `extra_pub_fonts` / `extra_pub_assets` / `extra_pub_shaders`.

    Fonts pair with files by asset path, never by position. Every
    `fonts_json` asset must name a `font_files` entry, every `font_files`
    entry must be named by a family, and a weight or style flutter_tools
    refuses fails analysis, naming the target, the family and the path.

    Args:
        package_name: A `struct(package_name, label)` carrying the
            contribution's package name and the declaring target's label, or
            a bare string (the label then falls back to the first font file).
            The empty package name is the sentinel for non-package
            contributions (no `packages/<pkg>/` prefix at bundle time);
            any other value prefixes family and asset paths.
        fonts_json: str — JSON-encoded list of
            `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`.
            Empty string when the rule declares no fonts. Each `asset` is
            normalized; the contribution keeps the encoded bundle key.
        font_files_dict: dict[Target, str] — `ctx.attr.font_files`. Each
            target must resolve to exactly one File. The string value is the
            package-relative asset path matching an entry in fonts_json;
            matched on the normalized decoded path.
        pkg_assets_dict: dict[Target, str] — `ctx.attr.pkg_assets`. Same
            shape, for non-font assets. Contributions keep the encoded key,
            so the bundle never reads a raw path.
        pkg_shaders_dict: dict[Target, str] — `ctx.attr.pkg_shaders`. Same
            shape, for shaders.
        shader_includes: list[File] — `ctx.files.shader_includes`, the files
            this package's shaders may `#include`. Each shader carries them
            as `includes` to its compile.
        pkg_asset_platforms: dict[str, list[str]] — `ctx.attr.pkg_asset_platforms`,
            `":" + path` to the entry's `platforms`. Absent = unconditional.
        pkg_asset_flavors: dict[str, list[str]] — `ctx.attr.pkg_asset_flavors`,
            same shape for the entry's `flavors`.

    Returns:
        Tuple of (extra_pub_fonts, extra_pub_assets, extra_pub_shaders) lists.
    """
    context = _contribution_context(package_name, font_files_dict)
    path_to_file = font_file_table(context.label, font_files_dict)

    # Tuples (not lists) inside the struct because depset elements must
    # be fully immutable — mutable fields propagate to the struct's
    # mutability check.
    extra_pub_fonts = []
    decoded = json.decode(fonts_json) if fonts_json else []
    if type(decoded) != "list":
        fail("%s: fonts_json must decode to a list of font-family maps." % context.label)
    for family_entry in decoded:
        if type(family_entry) != "dict":
            fail("%s: fonts_json must hold font-family maps; got %s." % (context.label, type(family_entry)))
        extra_pub_fonts.append(font_json_contribution(
            context.label,
            context.package_name,
            family_entry.get("family", ""),
            family_entry.get("fonts", []),
            path_to_file,
        ))
    if font_files_dict:
        check_unclaimed_font_files(context.label, decoded, path_to_file)

    extra_pub_assets = []
    for target, asset_path in pkg_assets_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_assets entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        norm = _normalize_attr_value(context.package_name, "pkg_assets", asset_path)
        platforms, flavors = _entry_conditions(norm.decoded, pkg_asset_platforms, pkg_asset_flavors)
        extra_pub_assets.append(struct(
            package_name = context.package_name,
            asset_path = norm.key,
            file = files[0],
            platforms = tuple(platforms),
            flavors = tuple(flavors),
        ))

    extra_pub_shaders = []
    for target, shader_path in pkg_shaders_dict.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("pkg_shaders entry %s must resolve to exactly one File; got %d" % (target.label, len(files)))
        extra_pub_shaders.append(struct(
            package_name = context.package_name,
            shader_path = _normalize_attr_value(context.package_name, "pkg_shaders", shader_path).key,
            file = files[0],
            includes = tuple(shader_includes),
        ))

    return (extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

def _pub_family_origin(deps, entry):
    """The contribution's own label, else the first direct dep that carries it.

    Only runs on the failure path: naming the two libraries that carry one
    family name with two different font lists. A contribution built by
    `build_pub_contributions` or `font_family_contribution` carries its
    declaring target as `origin`, so an application's own families name
    themselves. Older contributions without it are found through the deps;
    a miss returns None rather than guessing, and the caller names that
    honestly.

    Args:
        deps: The bundle's direct deps.
        entry: The pub_fonts contribution struct to find.

    Returns:
        The declaring target's label string, or None.
    """
    origin = getattr(entry, "origin", "")
    if origin:
        return origin
    for dep in deps:
        if FlutterInfo in dep and entry in dep[FlutterInfo].pub_fonts.to_list():
            return str(dep.label)
    return None

def _fail_font_family_conflict(family, first_origin, origin):
    """Fail analysis: one font family name carries two different font lists.

    Args:
        family: The bundle-relative family name both lists claim.
        first_origin: Where the first list came from (a label).
        origin: Where the second list came from (a label).
    """
    fail("font family '%s' is carried with two different font lists by %s and %s; keep one font list for the family." % (family, first_origin, origin))

def _pub_prefix(package_name):
    """The bundle-path prefix for one pub contribution's package.

    Args:
        package_name: The contribution's package name; the empty string
            sentinel means a non-package contribution bundled at a bare path.

    Returns:
        `"packages/<name>/"`, or `""` for the empty sentinel.
    """
    return "packages/{}/".format(package_name) if package_name else ""

def _font_entry_file(entry, font):
    """The file a font struct carries, with a one-font legacy fallback.

    New contributions carry `font.file`, so the pairing is by asset path and
    every codepath sees the same answer. Contributions built before that
    field (the toolchain MaterialIcons target) have only the parallel `files`
    tuple; with exactly one font and one file, position and path agree. A
    multi-font legacy contribution cannot be paired safely and fails.

    Args:
        entry: The pub_fonts contribution struct.
        font: One font struct from `entry.fonts`.

    Returns:
        The File that font declares.
    """
    file = getattr(font, "file", None)
    if file != None:
        return file
    if len(entry.fonts) == 1 and len(entry.files) == 1:
        return entry.files[0]
    fail("%s: font family '%s' has fonts with no paired files; declare it with flutter_font_family or a paired fonts_json/font_files." % (
        getattr(entry, "origin", "") or "the target declaring the family",
        entry.family,
    ))

def _font_descriptors(entry, prefix, extra_asset_copies, pub_claims):
    """One pub font entry's FontManifest descriptors, recording its copies.

    Each font's own file comes from the font struct, so a descriptor's asset
    path and the bytes bundled at it always name the same declaration.

    Args:
        entry: The pub_fonts contribution struct.
        prefix: The entry's bundle-path prefix, from `_pub_prefix`.
        extra_asset_copies: Dict to record each font file's bundle dest in.
        pub_claims: Optional list to append one `struct(key, file, channel)`
            claim per font file to, or None.

    Returns:
        The descriptors list for the family's FontManifest entry.
    """
    fonts_descriptors = []
    for font in entry.fonts:
        file = _font_entry_file(entry, font)
        descriptor = {"asset": prefix + font.asset_path}
        if font.weight != None:
            descriptor["weight"] = font.weight
        if font.style != None:
            descriptor["style"] = font.style
        fonts_descriptors.append(descriptor)
        extra_asset_copies[prefix + font.asset_path] = file
        if pub_claims != None:
            pub_claims.append(struct(key = prefix + font.asset_path, file = file, channel = "pub"))
    return fonts_descriptors

def _record_pub_family(deps, families, fonts, family_str, fonts_descriptors, entry):
    """Record one family's descriptors, failing on a conflicting repeat.

    The first list wins its position; an identical repeat is a non-event.
    One family name carried with two different font lists fails analysis,
    naming the family and both libraries.

    Args:
        deps: The bundle's direct deps, read only to name an origin.
        families: Dict of family name to the winning descriptors + entry.
        fonts: The FontManifest entries list to append a first sighting to.
        family_str: The prefixed family name.
        fonts_descriptors: This entry's descriptors.
        entry: The pub_fonts contribution struct behind them.
    """
    prev = families.get(family_str)
    if prev == None:
        families[family_str] = struct(fonts = fonts_descriptors, entry = entry)
        fonts.append({"family": family_str, "fonts": fonts_descriptors})
    elif prev.fonts != fonts_descriptors:
        _fail_font_family_conflict(
            family_str,
            _pub_family_origin(deps, prev.entry) or "an unknown dependency",
            _pub_family_origin(deps, entry) or "an unknown dependency",
        )

def _collect_pub_fonts(deps, pub_fonts, extra_asset_copies, pub_claims):
    """FontManifest entries for one flattened pub_fonts channel.

    Args:
        deps: The bundle's direct deps, read only to name an origin.
        pub_fonts: The flattened pub font contributions, in bundle order.
        extra_asset_copies: Dict to record each font file's bundle dest in.
        pub_claims: Optional list to append each font file's claim to.

    Returns:
        The FontManifest entries list.
    """
    fonts = []
    families = {}
    for entry in pub_fonts:
        prefix = _pub_prefix(entry.package_name)
        _record_pub_family(
            deps,
            families,
            fonts,
            prefix + entry.family,
            _font_descriptors(entry, prefix, extra_asset_copies, pub_claims),
            entry,
        )
    return fonts

def _collect_pub_assets(pub_assets, target_platform, extra_asset_copies, pub_claims):
    """Copies and claims for one flattened pub_assets channel.

    Args:
        pub_assets: The flattened pub asset contributions, in bundle order.
        target_platform: The bundle's platform; entries whose `platforms` /
            `flavors` conditions exclude it are skipped.
        extra_asset_copies: Dict to record each asset's bundle dest in.
        pub_claims: Optional list to append each asset's claim to.
    """
    for entry in pub_assets:
        if not pub_asset_matches_target(
            getattr(entry, "flavors", []),
            getattr(entry, "platforms", []),
            target_platform,
        ):
            continue
        prefix = _pub_prefix(entry.package_name)
        extra_asset_copies[prefix + entry.asset_path] = entry.file
        if pub_claims != None:
            pub_claims.append(struct(key = prefix + entry.asset_path, file = entry.file, channel = "pub"))

def aggregate_pub_contributions(deps, target_platform, pub_claims = None, own_font_targets = []):
    """Walk transitive `FlutterInfo.pub_fonts` / `pub_assets` from deps.

    Each contribution carries `package_name` — the empty string sentinel
    means "non-package contribution, bundle at bare path"; any other value
    triggers a `packages/<package_name>/` prefix on the family name and
    every asset path. This matches Flutter's CLI behavior and the const
    finder's tree-shaking key shape (`packages/<pkg>/<family>` only when
    the IconData has a non-null `fontPackage`).

    `own_font_targets` are the bundling rule's own `flutter_font_family`
    targets — an application's `fonts`, whose bare names come before the
    packages' as the root pubspec's do. They take part in the same dedupe and
    conflict checks as the deps' contributions.

    Pub assets additionally carry `platforms` / `flavors` conditions from
    the `flutter.assets` entry that listed them. Only entries matching
    `target_platform` (via `pub_asset_matches_target`: flavor first, then
    platform, with the `tester` exception) are bundled — the same filter
    `ManifestAssetBundle` applies. `getattr` defaults keep contributions
    from older spokes (which state no conditions) unconditional.

    Each channel flattens once, through one `depset` union over the deps, so
    a bundle's analysis cost is linear in the contributions it ships rather
    than growing with the number of deps that reach them. The union lists
    each contribution once in first-reached order, so bundles without a
    repeat keep exactly today's fonts and copies.

    A family reached along several paths, with the same fonts, is written
    once, at its first position. One family name carried with two different
    font lists fails analysis, naming the family and both libraries.

    Args:
        deps: List of Targets — typically `ctx.attr.deps`.
        target_platform: The bundle's platform (`android`, `ios`, `macos`,
            `linux`, `windows`, `web`, or `tester` for test bundles).
        pub_claims: Optional list to append one
            `struct(key, file, channel)` claim per bundled pub file to, in
            bundle order (font files first, then assets). The bundle's
            cross-channel key check reads these; callers that discard the
            copies (`flutter_web_application`'s font-only read) pass nothing.
        own_font_targets: The bundling rule's own `flutter_font_family`
            targets, in declaration order, ahead of the deps' families.

    Returns:
        Tuple of:
          - fonts: list of FontManifest entries (dicts) with prefixed family
            + per-font asset paths and optional weight/style.
          - extra_asset_copies: dict[str, File] mapping bundle dest path to
            File for both fonts and non-font pub-package assets.
    """
    infos = [dep[FlutterInfo] for dep in deps if FlutterInfo in dep]
    own_pub_fonts = font_family_contributions(own_font_targets, "")
    pub_fonts = own_pub_fonts + depset(transitive = [info.pub_fonts for info in infos]).to_list()
    pub_assets = depset(transitive = [info.pub_assets for info in infos]).to_list()

    extra_asset_copies = {}
    fonts = _collect_pub_fonts(deps, pub_fonts, extra_asset_copies, pub_claims)
    _collect_pub_assets(pub_assets, target_platform, extra_asset_copies, pub_claims)

    return (fonts, extra_asset_copies)

def resolve_font_subset_tools(flutter_sdk_info):
    """Resolve `(const_finder, font_subset)` from the app rule's `flutter_sdk_info`.

    Font subsetting tools are resolved directly from the app rule's toolchain
    for the execution platform, never from library targets in `deps`.

    Args:
        flutter_sdk_info: `FlutterSdkInfo` from the active Flutter toolchain, or `None`.

    Returns:
        A `(const_finder, font_subset)` tuple of `File` or `None`.
    """
    const_finder = flutter_sdk_info.const_finder if flutter_sdk_info else None
    font_subset = flutter_sdk_info.font_subset if flutter_sdk_info else None
    return (const_finder, font_subset)

# Analysis-only: `package:sky_engine`'s `lib/_embedder.yaml` is the only way the
# analyzer resolves `dart:ui`. Reaches `flutter_analyzable_info` alone.
SKY_ENGINE_ATTR = attr.label(
    doc = "Analysis-only: supplies `lib/_embedder.yaml`, the only way the analyzer resolves `dart:ui`.",
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

def flutter_analyzable_info(ctx, package_name, lib_root):
    """The package a Flutter library rule declares, as the analyzer sees it.

    The same package its `DartInfo` records, with `package:sky_engine` added.
    Compilation gets `dart:ui` from the patched SDK; the analyzer resolves it
    only through `sky_engine`'s `lib/_embedder.yaml`, so without this every
    `dart:ui` import is unresolved. `DartInfo` is untouched, so no compile input
    changes, and the analyzer prefers this provider when a target has both.

    Args:
      ctx: The rule context. Reads `deps`, `srcs`, `resources`, `code_assets`,
        `language_version`, `version` and `_sky_engine` (`SKY_ENGINE_ATTR`).
      package_name: The Dart package name the rule's `DartInfo` uses.
      lib_root: The package root the rule's `DartInfo` uses.

    Returns:
      A `DartAnalyzableInfo`.
    """
    return dart_analyzable_info_with_package(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
            version = ctx.attr.version,
        ),
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        package_srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        code_assets = ctx.attr.code_assets,
    )

def _library_pub_contributions(ctx, package_name):
    """The library's pub_fonts/pub_assets/pub_shaders contributions.

    Fonts arrive from the deprecated `fonts_json`/`font_files` pair and from
    the `fonts` attribute's `flutter_font_family` targets; both share the
    validation in `flutter_font_family.bzl`.

    Args:
        ctx: The `flutter_library` rule context.
        package_name: The asset-prefix package name, verbatim from the rule's
            `package_name` attribute (empty sentinel = bare paths).

    Returns:
        A `(pub_fonts, pub_assets, pub_shaders)` tuple of contribution lists.
    """
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(
        struct(package_name = package_name, label = ctx.label),
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
        ctx.files.shader_includes,
        ctx.attr.pkg_asset_platforms,
        ctx.attr.pkg_asset_flavors,
    )
    extra_pub_fonts.extend(font_family_contributions(ctx.attr.fonts, package_name))
    return (extra_pub_fonts, extra_pub_assets, extra_pub_shaders)

def _flutter_library_impl(ctx):
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # The asset-prefix package name uses the rule's `package_name` attr
    # verbatim (empty string sentinel = bare paths, non-empty = `packages/X/`).
    # Distinct from the Dart package name in DartInfo, which always derives a
    # value via derive_package_name. Users opting out of asset prefixing leave
    # `package_name` unset.
    asset_pkg = ctx.attr.package_name
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = _library_pub_contributions(ctx, asset_pkg)

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

    # Both providers are built by their own constructor, and each merges its
    # dependencies' closures itself. This rule states only what a
    # `flutter_library` contributes, which is what keeps a field added to
    # either provider from becoming a change here.
    #
    # `resources` and the pub-asset attrs are orthogonal channels. `resources`
    # says a file is part of the package's `lib/` tree — addressable as
    # `package:<name>/<path>`, staged wherever the whole package is staged
    # (the analyzer's project tree, `dart_test`/`dart_binary` runfiles).
    # `pkg_assets`/`pkg_shaders`/`font_files` say a file is transformed and
    # bundled into flutter_assets. A shader under `lib/` is legitimately both.
    #
    # Code assets go on the package record, which is what makes them propagate
    # the way pub does: depending on a package that owns one is enough, and no
    # consumer has to name it. rules_dart owns the declaration
    # (`DartCodeAssetInfo`) and enforces that each asset id is namespaced to the
    # package declaring it; everything Flutter adds — bundle filename, the
    # per-platform bundle slot — is applied later by the application rule.
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs + ctx.files.resources),
            runfiles = ctx.runfiles(
                files = ctx.files.srcs + ctx.files.resources + ctx.files.assets,
            ),
        ),
        dart_info(
            label = ctx.label,
            package = dart_package_identity(
                package_name = package_name,
                lib_root = lib_root,
                language_version = ctx.attr.language_version,
                version = ctx.attr.version,
            ),
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
            link_hook = ctx.file.link_hook,
        ),
        flutter_analyzable_info(ctx, package_name, lib_root),
        flutter_info(
            deps = ctx.attr.deps,
            asset_channels = flutter_asset_channels(
                asset_dirs = ctx.files.assets,
                assets = library_asset_entries(ctx.label, package_name, ctx.files.assets),
                shader_srcs = [
                    struct(
                        file = shader,
                        includes = tuple(ctx.files.shader_includes),
                    )
                    for shader in ctx.files.shaders
                ],
            ),
            pub_channels = flutter_pub_channels(
                pub_fonts = extra_pub_fonts,
                pub_assets = extra_pub_assets,
                pub_shaders = extra_pub_shaders,
            ),
        ),
    ]

flutter_library = rule(
    implementation = _flutter_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Dart source files for this library.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other `dart_library` or `flutter_library` targets this library depends on.",
            providers = [DartInfo],
        ),
        "resources": attr.label_list(
            doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled. Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged (the analyzer's project tree, `dart_test`/`dart_binary` runfiles), mirroring `dart_library`. Orthogonal to `pkg_assets`/`pkg_shaders`/`font_files`, which name flutter_assets bundle contributions — a `lib/` shader is legitimately both. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "assets": attr.label_list(
            doc = "Flutter asset files (images, fonts, etc.) declared in pubspec.yaml.",
            allow_files = True,
        ),
        "shaders": attr.label_list(
            doc = "Shader source files (.frag/.glsl) to compile per-platform and include in the asset bundle.",
            allow_files = [".frag", ".glsl"],
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, defaults to the last component of the Bazel package path.",
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets standing in for this package's " +
                  "`hook/build.dart` output. Declared on the owning package " +
                  "rather than on the consuming application so they propagate " +
                  "the way pub's own do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a build hook this package ships that nothing " +
                  "replaces, or empty. Recorded at repo generation; the " +
                  "application that depends on the package fails on it.",
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). " +
                  "Set automatically by the generated pub spokes; leave it empty on " +
                  "hand-written targets, which have no resolved version to state. " +
                  "Mirrors `dart_library`'s attribute, and has its one use: when a " +
                  "single package name arrives from two hubs, two records stating " +
                  "different versions fail the build instead of the first one " +
                  "silently standing in for the second. An empty version never " +
                  "conflicts.",
        ),
        "link_hook": LINK_HOOK_ATTR,
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "fonts": FONTS_ATTR,
        "fonts_json": attr.string(
            doc = "Deprecated; use `fonts` with `flutter_font_family` targets. JSON-encoded list of font-family declarations (mirrors `flutter.fonts` in pubspec.yaml). Each entry: `{family: str, fonts: [{asset: str, weight: int?, style: str?}]}`. Every `asset` must name a `font_files` entry, every `font_files` entry must be named by a family, and `weight`/`style` must be values flutter_tools accepts, or analysis fails naming the target, the family and the path. The asset bundle aggregator prefixes family + asset paths with `packages/<package_name>/` when this rule's `package_name` is non-empty (empty = bare paths, used for non-package contributions like the toolchain MaterialIcons target).",
            default = "",
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Deprecated with `fonts_json`; `flutter_font_family` names its own files. Map of font File label -> package-relative asset path. The string value must match an `asset` field in `fonts_json`; a value no family names fails analysis. The file is bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty).",
            allow_files = True,
        ),
        "pkg_assets": attr.label_keyed_string_dict(
            doc = "Map of asset File label -> package-relative path (mirrors `flutter.assets` in pubspec.yaml). Bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty); also included in AssetManifest.",
            allow_files = True,
        ),
        "pkg_asset_platforms": attr.string_list_dict(
            doc = "Per-asset `platforms` conditions (mirrors the `platforms` key of `flutter.assets` entries). Maps the `\":\" + path` label string of a `pkg_assets` entry to its platform list. An entry listed here bundles only on those platforms (`tester` bundles every platform entry); an entry absent here is unconditional.",
        ),
        "pkg_asset_flavors": attr.string_list_dict(
            doc = "Per-asset `flavors` conditions (mirrors the `flavors` key of `flutter.assets` entries). Same shape as `pkg_asset_platforms`. Rules_flutter selects no flavor yet, so an entry listed here bundles nowhere.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
        "shader_includes": attr.label_list(
            doc = "Files this package's `shaders` and `pkg_shaders` may `#include` (e.g. " +
                  "`glob([\"shaders/**/*.glsl\"])`). A shader compiles in a " +
                  "sandbox holding only its declared inputs, so an include " +
                  "not listed here is not found.",
            allow_files = True,
        ),
        "pkg_shaders": attr.label_keyed_string_dict(
            doc = "Map of shader File label -> package-relative path (mirrors `flutter.shaders` in pubspec.yaml). Routed through the impellerc compile and bundled at `packages/<package_name>/<path>` (or bare `<path>` when `package_name` is empty).",
            allow_files = True,
        ),
    },
    doc = "Collects Flutter sources and assets, propagates DartInfo and FlutterInfo. Does not compile.",
)
