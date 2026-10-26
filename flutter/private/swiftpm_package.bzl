"""The `swiftpm_package` repository rule: one fetched SwiftPM spoke.

Each SwiftPM pin in `Package.resolved` becomes a `<hub>__swiftpm-<identity>`
repo holding the pinned sources and a generated BUILD file. The fetch is
fail-closed throughout: an unpinned entry fails before any download (naming
the `swift_package_sha256` fix), the archive must hold one top-level
directory with the plain `Package.swift` manifest, and every source
refusal from the translator fails here. A `swift_package_build_files`
override still downloads the pinned archive but skips the translation,
writing the hand-written file as-is.
"""

load(":download.bzl", "pinned_download_and_extract")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_bound_error")
load(":swiftpm_manifest.bzl", "parse_swiftpm_package")
load(":swiftpm_translate.bzl", "swiftpm_reachable_targets", "translate_swiftpm_package")

_SWIFTPM_DEFAULT_DIRS = ["Sources", "Source", "src", "srcs"]

def _swiftpm_repo_fail(identity, detail):
    """The fetch failure for fetch-level (non-manifest) refusals.

    Args:
        identity: The SwiftPM package identity.
        detail: What was found and why it is unsupported.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return "SwiftPM package {identity}: {detail}.".format(identity = repr(identity), detail = detail)

def _swiftpm_check_entry(identity, target_name, entry, kind):
    """Refuse an exclude/sources entry that could escape the target dir.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the entry, for messages.
        entry: The manifest entry string.
        kind: `"exclude:"` or `"sources:"`, for messages.

    Returns:
        "" or the fetch failure.
    """
    for segment in entry.split("/"):
        if segment == "" or segment == "." or segment == "..":
            return _swiftpm_repo_fail(identity, "target {target} has an {kind} entry {entry} escaping the target directory".format(target = repr(target_name), kind = kind, entry = repr(entry)))
    return ""

def _swiftpm_package_root(ctx, identity):
    """Read the archive's single top-level directory as the package root.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.

    Returns:
        `struct(ok, error, root)`: `root` is the repo-relative directory.
    """
    children = ctx.path(".").readdir()
    dirs = [child.basename for child in children if child.is_dir]
    if len(children) != 1 or len(dirs) != 1:
        shown = sorted([child.basename for child in children])
        if len(shown) > 8:
            shown = shown[:8] + ["... ({count} entries)".format(count = len(children))]
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "expected the archive to hold one top-level directory (the package root), got {entries}".format(entries = shown)), root = "")
    return struct(ok = True, error = "", root = dirs[0])

def _swiftpm_manifest_filename(ctx, identity, root):
    """Require the plain `Package.swift` manifest at the package root.

    A versioned `Package@swift-*.swift` sitting next to it fails the
    fetch naming it: the translator reads only the plain manifest, and
    silently ignoring a versioned sibling could build stale sources.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.

    Returns:
        `struct(ok, error, filename)`: the manifest basename.
    """
    if not ctx.path(root + "/Package.swift").exists:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "no `Package.swift` manifest at the archive top level"), filename = "")
    versioned = [child.basename for child in ctx.path(root).readdir() if not child.is_dir and child.basename.startswith("Package@swift-") and child.basename.endswith(".swift")]
    if versioned:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "versioned manifest(s) ({names}) sit next to `Package.swift`: only the plain manifest is translated, so remove them or point at a hand-written BUILD file with swift_package_build_files[{identity}]".format(names = sorted(versioned), identity = repr(identity))), filename = "")
    return struct(ok = True, error = "", filename = "Package.swift")

def _swiftpm_resolve_target_dir(ctx, identity, root, target):
    """Resolve one reached target's directory.

    An explicit `path:` must name an existing directory inside the package
    root; otherwise the first existing `Sources/<name>`, `Source/<name>`,
    `src/<name>` or `srcs/<name>` wins.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.
        target: The target struct.

    Returns:
        `struct(ok, error, rel_dir)`: the repo-relative directory.
    """
    if target.path:
        bad = _swiftpm_check_entry(identity, target.name, target.path, "`path:`")
        if bad:
            return struct(ok = False, error = bad, rel_dir = "")
        rel_dir = root + "/" + target.path
        node = ctx.path(rel_dir)
        if not node.exists or not node.is_dir:
            return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} names a missing directory in `path:` ({dir})".format(target = repr(target.name), dir = repr(target.path))), rel_dir = "")
        return struct(ok = True, error = "", rel_dir = rel_dir)
    for base in _SWIFTPM_DEFAULT_DIRS:
        rel_dir = root + "/" + base + "/" + target.name
        node = ctx.path(rel_dir)
        if node.exists and node.is_dir:
            return struct(ok = True, error = "", rel_dir = rel_dir)
    return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} has no `path:` and none of {dirs} exist".format(target = repr(target.name), dirs = [base + "/" + target.name for base in _SWIFTPM_DEFAULT_DIRS])), rel_dir = "")

def _swiftpm_validate_entries(ctx, identity, target, rel_dir):
    """Validate exclude/sources entries and sort them into sets.

    Every entry must stay inside the target dir and match an existing file
    or directory; otherwise the fetch fails naming it.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        target: The target struct.
        rel_dir: The repo-relative target directory.

    Returns:
        `struct(ok, error, excluded, listed)`: repo-relative excluded
        paths and the validated `sources:` entries (None when
        unrestricted).
    """
    excluded = {}
    for entry in target.exclude:
        bad = _swiftpm_check_entry(identity, target.name, entry, "`exclude:`")
        if bad:
            return struct(ok = False, error = bad, excluded = {}, listed = None)
        full = rel_dir + "/" + entry
        if not ctx.path(full).exists:
            return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} has an `exclude:` entry matching nothing ({entry})".format(target = repr(target.name), entry = repr(entry))), excluded = {}, listed = None)
        excluded[full] = True
    listed = None
    if target.sources != None:
        listed = []
        for entry in target.sources:
            bad = _swiftpm_check_entry(identity, target.name, entry, "`sources:`")
            if bad:
                return struct(ok = False, error = bad, excluded = {}, listed = None)
            full = rel_dir + "/" + entry
            if not ctx.path(full).exists:
                return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} has a `sources:` entry matching nothing ({entry})".format(target = repr(target.name), entry = repr(entry))), excluded = {}, listed = None)
            listed.append(full)
    return struct(ok = True, error = "", excluded = excluded, listed = listed)

def _swiftpm_walk_swift(ctx, identity, target, rel_dir, excluded):
    """Walk a target dir for Swift sources, bounded and all-Swift.

    Prunes excluded subtrees; any other non-Swift file fails the fetch
    naming it, since the translator would otherwise silently drop code
    SwiftPM compiles.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        target: The target struct, for messages.
        rel_dir: The repo-relative target directory.
        excluded: The repo-relative excluded paths.

    Returns:
        `struct(ok, error, srcs)`: the repo-relative `.swift` paths.
    """
    srcs = []
    stack = [rel_dir]
    for _ in range(PUB_WALK_BOUND):
        if not stack:
            break
        current = stack.pop()
        for child in ctx.path(current).readdir():
            full = current + "/" + child.basename
            if full in excluded:
                continue
            if child.is_dir:
                stack.append(full)
            elif child.basename.endswith(".swift"):
                srcs.append(full)
            else:
                return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} holds a non-Swift file with no Bazel translation ({path})".format(target = repr(target.name), path = repr(full))), srcs = [])
    if stack:
        return struct(ok = False, error = has_files_bound_error(identity, rel_dir, PUB_WALK_BOUND), srcs = [])
    return struct(ok = True, error = "", srcs = srcs)

def _swiftpm_collect_sources(ctx, identity, root, target):
    """Resolve one reached target's directory and explicit `srcs` list.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.
        target: The target struct.

    Returns:
        `struct(ok, error, files)`: `files` is `struct(dir, srcs)` with
        the repo-relative directory and Swift sources.
    """
    resolved = _swiftpm_resolve_target_dir(ctx, identity, root, target)
    if not resolved.ok:
        return struct(ok = False, error = resolved.error, files = None)
    validated = _swiftpm_validate_entries(ctx, identity, target, resolved.rel_dir)
    if not validated.ok:
        return struct(ok = False, error = validated.error, files = None)
    walked = _swiftpm_walk_swift(ctx, identity, target, resolved.rel_dir, validated.excluded)
    if not walked.ok:
        return struct(ok = False, error = walked.error, files = None)
    srcs = walked.srcs
    if validated.listed != None:
        kept = []
        for full in srcs:
            for entry in validated.listed:
                if full == entry or full.startswith(entry + "/"):
                    kept.append(full)
                    break
        srcs = kept
    if not srcs:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} reaches zero Swift files".format(target = repr(target.name))), files = None)
    return struct(ok = True, error = "", files = struct(dir = resolved.rel_dir, srcs = sorted(srcs)))

def _swiftpm_package_impl(ctx):
    identity = ctx.attr.identity
    if ctx.attr.unpinned_error:
        fail(ctx.attr.unpinned_error)
    pinned_download_and_extract(ctx, url = ctx.attr.archive_url, sha256 = ctx.attr.sha256)
    if ctx.attr.build_file:
        ctx.file("BUILD.bazel", ctx.read(ctx.path(Label(ctx.attr.build_file))))
        return
    root = _swiftpm_package_root(ctx, identity)
    if not root.ok:
        fail(root.error)
    manifest = _swiftpm_manifest_filename(ctx, identity, root.root)
    if not manifest.ok:
        fail(manifest.error)
    parsed = parse_swiftpm_package(identity, ctx.read(root.root + "/" + manifest.filename))
    if not parsed.ok:
        fail(parsed.error)
    reached = swiftpm_reachable_targets(identity, parsed.model, ctx.attr.pin_identities, ctx.attr.hub_name)
    if not reached.ok:
        fail(reached.error)
    by_name = {target.name: target for target in parsed.model.targets}
    files_by_target = {}
    for name in reached.names:
        collected = _swiftpm_collect_sources(ctx, identity, root.root, by_name[name])
        if not collected.ok:
            fail(collected.error)
        files_by_target[name] = collected.files
    translated = translate_swiftpm_package(identity, ctx.attr.hub_name, parsed.model, ctx.attr.pin_identities, files_by_target)
    if not translated.ok:
        fail(translated.error)
    ctx.file("BUILD.bazel", translated.text)

swiftpm_package = repository_rule(
    implementation = _swiftpm_package_impl,
    doc = "One fetched SwiftPM spoke: the pinned GitHub archive plus a BUILD file translated from its plain `Package.swift`, or the `swift_package_build_files` override.",
    attrs = {
        "archive_url": attr.string(doc = "The pinned archive URL to download (always downloaded, even with a build_file override)."),
        "build_file": attr.string(default = "", doc = "Absolute label string of a hand-written BUILD file replacing the generated one; skips the manifest translation only, not the download."),
        "hub_name": attr.string(mandatory = True, doc = "The flutter.pub hub name, for cross-package dep labels."),
        "identity": attr.string(mandatory = True, doc = "The SwiftPM package identity (the spoke suffix)."),
        "pin_identities": attr.string_list(doc = "Every identity pinned in Package.resolved, for dependency resolution."),
        "sha256": attr.string(doc = "The pinned SHA-256 of the archive (empty when unpinned, which fails before downloading)."),
        "unpinned_error": attr.string(default = "", doc = "The fetch failure for an unpinned entry; failing first keeps unpinned bytes out."),
    },
)
