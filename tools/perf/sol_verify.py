#!/usr/bin/env python3
"""Bundle and output verification, move-aside/restore, and chain cleanup for SOL."""

import hashlib
import os
import shutil
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from replay import (
    spawn_output_paths,
    spawn_recorded_digests,
    tail_lines,
)
from run_rep import CONFIGS

def startup_options(out_base):
    """Bazel startup options shared by every command on one output base."""
    return ["--output_base=" + out_base]


def command_prefix(batch):
    """``bazel`` argv head: batch commands pass ``--batch``, warm ones do
    not, so they run on the config's server with identical startup options.
    """
    return ["bazel", "--batch"] if batch else ["bazel"]


def info_argv(out_base, key, batch):
    """Full ``bazel info`` argv in either mode."""
    return command_prefix(batch) + startup_options(out_base) + [
        "info", key]


def cquery_argv(out_base, target, build_flags, batch):
    """Full ``bazel cquery`` argv in either mode."""
    return (command_prefix(batch) + startup_options(out_base)
            + ["cquery", "--output=files", target] + list(build_flags))



def sha256_file(path):
    """Hex digest of a file, or None when it is missing/unreadable.

    None is not swallowed: callers record it and any mismatch (including
    a missing file) reports identical=false.
    """
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def snapshot_hashes(paths):
    """{path: hex digest} over the verify files, in sorted order."""
    return {path: sha256_file(path) for path in sorted(paths)}


def hashes_match(before, after):
    """Whether two snapshots prove the chain reproduced Bazel's outputs."""
    return (bool(before) and before == after
            and all(v is not None for v in before.values()))


def path_depth(path):
    """Sort key: parents before children (fewer separators first)."""
    return (path.count(os.sep), path)


def covered_by(path, roots):
    """Whether path equals or sits under one of the moved roots."""
    return any(path == root or path.startswith(root + os.sep)
               for root in roots)


def move_aside_chain(step_outputs, backup_dir):
    """Moves every chain-step output aside; returns {original: backup}.

    Parents move before children, so a directory output moves whole. A
    verify file inside a moved directory travels with it; a verify file
    no running step declares is never passed here at all: it stays
    Bazel's own and its unchanged bytes count as proof. A missing path
    fails loudly (after moving back what was moved): the chain must
    recreate exactly what Bazel wrote.
    """
    shutil.rmtree(backup_dir, ignore_errors=True)
    os.makedirs(backup_dir, exist_ok=True)
    mapping = {}
    try:
        for path in sorted(set(step_outputs), key=path_depth):
            if covered_by(path, mapping):
                continue
            dst = os.path.join(backup_dir, "%d%s" % (
                len(mapping), os.path.splitext(path)[1]))
            os.rename(path, dst)
            mapping[path] = dst
    except OSError as exc:
        restore_tree(mapping)
        raise RuntimeError("sol move-aside of %s failed (%s)" % (path, exc))
    return mapping


def restore_tree(mapping):
    """Removes chain-written files and moves Bazel's originals back.

    Parents move back before children, and every parent directory is
    recreated: a step that failed before recreating its output directory
    (e.g. a tree artifact holding a verify file) restores exactly what
    Bazel left. A missing backup fails loudly instead of leaving the
    next build over a hole.
    """
    for path in sorted(mapping, key=path_depth):
        backup = mapping[path]
        if not os.path.exists(backup):
            raise RuntimeError("sol backup for %s is gone" % path)
        try:
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
            parent = os.path.dirname(path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.rename(backup, path)
        except OSError as exc:
            raise RuntimeError("sol restore of %s failed (%s)" % (path, exc))


def capture_bazel_output(argv, cwd):
    """stdout of a Bazel info/query command; stderr stays separate.

    Bazel relays JVM warnings on stderr. Merging the streams (as a
    combined capture does) lets a warning line corrupt parsed output
    paths, so stdout is captured alone and stderr is shown on failure.
    """
    proc = subprocess.run(
        list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError("bazel %s failed (exit %s): %s"
                           % (" ".join(list(argv)[1:]), proc.returncode,
                              tail_lines(proc.stderr)))
    return proc.stdout


def check_under_base(path, out_base, what):
    """Fails closed unless path exists under the output base."""
    abs_path = os.path.abspath(path)
    if not abs_path.startswith(os.path.abspath(out_base) + os.sep):
        raise RuntimeError("sol %s %s is not under output base %s"
                           % (what, path, out_base))
    if not os.path.exists(abs_path):
        raise RuntimeError("sol %s %s does not exist" % (what, path))
    return abs_path


def bazel_info(capture, work, out_base, key, batch):
    """One `bazel info` path (execroot, ...), validated.

    The mode has no default: callers must pass the flow's mode, so a
    warm flow can never send a `--batch` command at a running server.
    """
    out = capture(info_argv(out_base, key, batch), cwd=work)
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) != 1:
        raise RuntimeError("bazel info %s returned %d line(s)"
                           % (key, len(lines)))
    return check_under_base(lines[0], out_base, "info " + key)


def query_target_files(capture, work, out_base, target, build_flags,
                         batch):
    """Absolute output paths of a target via `cquery --output=files`.

    Every non-blank line must resolve to an existing path under the
    output base; anything else (a warning leaked into stdout, a format
    change) fails loudly instead of becoming a bogus verify path. The
    mode has no default and covers the execution-root lookup too: both
    commands run in the flow's mode, never `--batch` against a server.
    """
    out = capture(cquery_argv(out_base, target, build_flags, batch),
                  cwd=work)
    execroot = bazel_info(capture, work, out_base, "execution_root",
                          batch)
    files = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        path = line if os.path.isabs(line) else os.path.join(execroot, line)
        files.append(check_under_base(path, out_base, "cquery " + target))
    if not files:
        raise RuntimeError("bazel cquery %s listed no files" % target)
    return files


def device_verify_files(target_files):
    """The App.framework binary among a framework target's outputs."""
    return sorted(p for p in target_files
                  if p.endswith("App.framework/App"))


def sim_bundle_roots(target_files):
    """App bundle roots among an ios_application's listed outputs."""
    roots = set()
    for path in target_files:
        if os.path.isdir(path) or path.endswith(".app"):
            roots.add(path)
        elif ".app/" in path:
            roots.add(path.split(".app/")[0] + ".app")
    return sorted(roots)


def sim_bundle_archives(target_files):
    """Declared .ipa bundle archives among a target's listed outputs."""
    return sorted(path for path in target_files if path.endswith(".ipa"))


def ipa_entry_hashes(ipa_path):
    """{entry path: hex digest} of an .ipa archive's payload.

    Only entry paths and contents prove the chain's work: archive
    metadata (timestamps, permissions, entry order) is not part of the
    proof, so an archive whose bytes differ only in metadata still
    matches. An unreadable archive or one holding no files fails loudly.
    """
    import zipfile
    try:
        archive = zipfile.ZipFile(ipa_path, "r")
    except (OSError, zipfile.BadZipFile) as exc:
        raise RuntimeError("sol cannot read bundle archive %s (%s)"
                           % (ipa_path, exc))
    try:
        entries = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            try:
                with archive.open(info, "r") as entry:
                    digest = hashlib.sha256(entry.read()).hexdigest()
            except (OSError, zipfile.BadZipFile, KeyError,
                    RuntimeError) as exc:
                raise RuntimeError("sol cannot read entry %s of %s (%s)"
                                   % (info.filename, ipa_path, exc))
            entries[info.filename] = digest
    finally:
        archive.close()
    if not entries:
        raise RuntimeError("sol bundle archive %s holds no files"
                           % ipa_path)
    return entries


def app_dir_hashes(app_dir):
    """{relative path: hex digest} of every file under an .app directory.

    File symlinks hash by content; directory symlinks (macOS framework
    version links) hash by their target string. A dangling link hashes
    None and fails the proof closed, like any missing file. An empty
    bundle fails loudly.
    """
    entries = {}
    for dirpath, dirnames, filenames in os.walk(app_dir,
                                                followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries[os.path.relpath(full, app_dir)] = sha256_file(full)
        for name in dirnames:
            full = os.path.join(dirpath, name)
            if not os.path.islink(full):
                continue
            try:
                target = os.readlink(full)
            except OSError:
                target = None
            if target is None:
                entries[os.path.relpath(full, app_dir)] = None
            else:
                entries[os.path.relpath(full, app_dir)] = hashlib.sha256(
                    ("symlink->" + target).encode("utf-8")).hexdigest()
    if not entries:
        raise RuntimeError("sol app bundle %s holds no files" % app_dir)
    return entries


def plan_verify_snapshot(capture, work, out_base, execroot, config,
                           batch):
    """Discovers the verify set from declared outputs only, never a glob.

    device_release hashes the App.framework binary among the framework
    target's listed outputs. sim_debug hashes the final app bundle's
    payload: every entry of each listed .ipa archive, and every file
    under each listed .app directory (the kernel blob and the
    App.framework binary are among those files). Anything else —
    no bundle among the listed outputs — fails loudly instead of
    globbing bazel-out, whose leftovers are not this build's outputs.
    Returns an opaque plan; read_verify_snapshot reads it right now.
    """
    spec = CONFIGS[config]
    listed = query_target_files(capture, work, out_base, spec["target"],
                                spec["build_flags"], batch)
    if config == "device_release":
        found = device_verify_files(listed)
        if not found:
            raise RuntimeError("sol found no verify files for %s" % config)
        return ("files", found)
    archives = sim_bundle_archives(listed)
    bundles = sim_bundle_roots(listed)
    if not archives and not bundles:
        raise RuntimeError("sol found no app bundle for %s" % config)
    return ("bundles", archives, bundles, execroot)


def read_verify_snapshot(plan):
    """{key: digest} over the planned verify set, read right now.

    Bundle keys are execroot-relative bundle paths plus "::" plus the
    entry path, so the chain record names payload entries portably; a
    bundle that reads empty fails loudly.
    """
    if plan[0] == "files":
        return snapshot_hashes(plan[1])
    _, archives, bundles, execroot = plan
    base = os.path.abspath(execroot)
    snapshot = {}
    for archive in archives:
        prefix = os.path.relpath(archive, base) + "::"
        for entry, digest in ipa_entry_hashes(archive).items():
            snapshot[prefix + entry] = digest
    for bundle in bundles:
        prefix = os.path.relpath(bundle, base) + "::"
        for entry, digest in app_dir_hashes(bundle).items():
            snapshot[prefix + entry] = digest
    if not snapshot:
        raise RuntimeError("sol bundle payload is empty")
    return snapshot


def snapshot_tree(root):
    """Every path under root (files, links and dirs), absolute normpaths."""
    seen = {os.path.normpath(os.path.abspath(root))}
    if not os.path.isdir(root):
        return seen
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        seen.add(os.path.normpath(dirpath))
        for name in filenames:
            seen.add(os.path.normpath(os.path.join(dirpath, name)))
        for name in dirnames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                seen.add(os.path.normpath(full))
    return seen


def _is_protected(path, declared):
    """Whether a chain path is a declared output or covers one.

    A path equal to, under, or above a declared output stays: declared
    outputs are restored separately, and anything above one is a parent
    the restore walks back through.
    """
    for root in declared:
        if (path == root or path.startswith(root + os.sep)
                or root.startswith(path + os.sep)):
            return True
    return False


def _drop_chain_file(full):
    """Removes one undeclared chain file or link, loudly on failure.

    A removal failure raises RuntimeError naming the path: the next
    build must never run over a hole the sweep left behind.
    """
    try:
        os.remove(full)
    except OSError as exc:
        raise RuntimeError("sol cannot remove chain side effect %s "
                           "(%s)" % (full, exc))


def _sweep_dir_files(dirpath, filenames, base, declared, before,
                       removed):
    """Removes undeclared chain files in one directory; appends relpaths."""
    for name in filenames:
        full = os.path.normpath(os.path.join(dirpath, name))
        if full not in before and not _is_protected(full, declared):
            _drop_chain_file(full)
            removed.append(os.path.relpath(full, base))


def _sweep_dir_links(dirpath, dirnames, base, declared, before, removed):
    """Removes undeclared chain symlinks in one directory.

    Links hide in dirnames (os.walk lists them as dirs): a link the
    chain created is removed like a file, never descended into.
    """
    for name in list(dirnames):
        full = os.path.join(dirpath, name)
        if not os.path.islink(full):
            continue
        norm = os.path.normpath(full)
        if norm not in before and not _is_protected(norm, declared):
            _drop_chain_file(full)
            removed.append(os.path.relpath(norm, base))


def _sweep_dir_entries(dirpath, dirnames, filenames, base, declared,
                       before, removed):
    """Sweeps one directory's files, then its links, in walk order.

    One top-down os.walk pass calls this per directory, so a failure
    partway leaves the same tree as removing files-then-links per
    directory in walk order: earlier directories are already swept.
    """
    _sweep_dir_files(dirpath, filenames, base, declared, before, removed)
    _sweep_dir_links(dirpath, dirnames, base, declared, before, removed)


def _sweep_empty_dirs(base, declared, before):
    """Removes dirs the sweep emptied under base; returns relpaths.

    Bottom-up, so an emptied parent goes once its children are gone;
    base itself, Bazel's own paths and anything covering a declared
    output stay.
    """
    removed = []
    for dirpath, _, _ in os.walk(base, followlinks=False, topdown=False):
        norm = os.path.normpath(dirpath)
        if norm == base or norm in before or _is_protected(norm, declared):
            continue
        try:
            if not os.listdir(norm):
                os.rmdir(norm)
                removed.append(os.path.relpath(norm, base))
        except OSError as exc:
            raise RuntimeError("sol cannot remove chain side-effect dir "
                               "%s (%s)" % (norm, exc))
    return removed


def sweep_chain_side_effects(bazel_out, declared_outputs, before):
    """Removes chain-created files/dirs under bazel-out no step declares.

    Besides restoring every declared output, the chain must leave the
    execroot as Bazel left it: an unsandboxed step may leave files next
    to its declared output (an undeclared sibling of App.framework.zip,
    say), and those leftovers would both perturb the next incremental
    build and pollute any later proof. Anything under bazel-out that is
    neither Bazel's own (in before) nor a declared output (equal to,
    under, or above one) is removed: files and links first, then the
    emptied directories. Returns {"n": removed count, "paths": first 10,
    bazel-out relative}. A removal failure raises RuntimeError naming
    the path instead of leaving the next build over a hole.
    """
    base = os.path.abspath(bazel_out)
    declared = [os.path.normpath(path) for path in declared_outputs]
    removed = []
    if not os.path.isdir(base):
        return {"n": 0, "paths": []}
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        _sweep_dir_entries(dirpath, dirnames, filenames, base, declared,
                           before, removed)
    removed.extend(_sweep_empty_dirs(base, declared, before))
    removed = sorted(set(removed))
    return {"n": len(removed), "paths": removed[:10]}


def verify_differences(before, after, execroot):
    """Verify entries that differ: {"n": count, "differ": first 10}.

    Each entry names the path with both digests ({path, before, after});
    at most 10 entries travel in the chain record, plus the total count.
    Absolute file paths show execroot-relative; bundle payload keys are
    already portable.
    """
    differ = []
    for key in sorted(set(before) | set(after)):
        if before.get(key) == after.get(key):
            continue
        if "::" in key:
            shown = key
        else:
            try:
                shown = os.path.relpath(key, execroot)
            except ValueError:
                shown = key
        differ.append({"path": shown, "before": before.get(key),
                       "after": after.get(key)})
    return {"n": len(differ), "differ": differ[:10]}


def output_drift(chainable, execroot):
    """Chain-step outputs differing from the log's digests, info only.

    Compares files the chain wrote against the digests the execution
    log recorded in actualOutputs. Missing files (steps never run),
    directories and unrecorded outputs are skipped; the count covers
    every differing file while paths keep the first 10, execroot
    relative. Never fails a flow: reproducibility detail, not proof.
    """
    base = os.path.abspath(execroot)
    differing = []
    for spawn in chainable:
        recorded = spawn_recorded_digests(spawn)
        if not recorded:
            continue
        resolved = {}
        for raw, digest in recorded.items():
            resolved[raw] = digest
            joined = (raw if os.path.isabs(raw)
                      else os.path.join(base, raw))
            resolved[os.path.normpath(joined)] = digest
        for path in spawn_output_paths(spawn, execroot):
            if path not in resolved or not os.path.isfile(path):
                continue
            if sha256_file(path) != resolved[path]:
                differing.append(os.path.relpath(path, base))
    differing = sorted(set(differing))
    return {"n": len(differing), "paths": differing[:10]}
