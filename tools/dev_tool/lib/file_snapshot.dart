/// A file's stat stamp with the content behind it, and the rule that decides
/// which of the two answers whether the file moved.
///
/// Two readers share this. [NativeLibsWatch] asks on every reload whether a
/// rebuild moved the app's native libraries, and [NativeHotPatcher] asks
/// whether a native source moved since the last patch — and both have to ask
/// cheaply: a debug-build Rust or C++ library is tens of megabytes (measured
/// at 126ms to hash 20MB, against 33µs for a `stat`), and a Dart-only reload
/// must read no contents at all.
///
/// So a matching `size:mtime` stamp answers "unchanged" without reading — but
/// only when the file's mtime predates its last content read by more than
/// [racyWindow]. Linux stamps a file's mtime from a coarse clock, which ticks
/// every 1-10 ms on many kernels (FAT/exFAT: 2 s): a same-size rewrite within
/// the tick the baseline was read in leaves `size:mtime` exactly as it was,
/// so a stamp alone would answer "unchanged" over changed bytes — the same
/// race git calls "racy git". Anything younger has its content read even when
/// its stamp matches, and the content token decides.
library;

import 'dart:io';

import 'native_libs_fingerprint.dart';

/// How much older than the last content read a file's mtime must be before a
/// matching stamp proves its bytes unchanged.
///
/// Two seconds covers the coarsest tick on any filesystem this tool runs on
/// (FAT/exFAT's 2 s), so a file whose mtime is not older than its last read
/// by more than this window has its content read even when its stamp matches.
/// Files written before the window stay on the stat-only path: neither reader
/// ever reads them.
const racyWindow = Duration(seconds: 2);

/// One file as a reader last saw it: the two facts a `stat` answers, and the
/// content token behind them.
class FileSnapshot {
  /// `size:mtime`, which is what bazel moves when it re-runs an action and
  /// leaves alone when it serves one from cache — or [missingStamp] for a
  /// path that is not there.
  final String stamp;

  /// The content token from [nativeLibsFingerprintOfFiles] — the authority,
  /// and read only when [stamp] cannot prove the bytes unchanged.
  final String content;

  /// Wall-clock microseconds since epoch, taken just before [content] was
  /// read. A matching stamp proves the bytes unchanged only when the file's
  /// mtime predates this by more than [racyWindow].
  final int readAtMicros;

  const FileSnapshot(this.stamp, this.content, this.readAtMicros);

  /// The snapshot of a path that is not there. Equal only to itself: a file
  /// that stays missing is not a change, and one that appears or disappears
  /// is.
  const FileSnapshot.missing()
    : stamp = missingStamp,
      content = '',
      readAtMicros = 0;

  /// Whether this is the snapshot of a path that was not there.
  bool get isMissing => stamp == missingStamp;
}

/// The stamp of a path that is not there. It answers a stamp of its own
/// rather than throwing: the throw belongs to the content read, which says
/// which file the build declared and did not write.
const missingStamp = 'missing';

/// A file's size and mtime as one token.
String stampForStat(FileStat stat) =>
    '${stat.size}:${stat.modified.microsecondsSinceEpoch}';

/// Whether a matching stamp proves a file unchanged: only when its mtime
/// predates its last content read by more than [racyWindow].
bool stampProvesUnchanged({
  required int mtimeMicros,
  required int readAtMicros,
}) => readAtMicros - mtimeMicros > racyWindow.inMicroseconds;

/// Snapshot [paths] as they are on disk now.
///
/// The moment each file's content is read is taken before the read: a file
/// whose mtime is not older than this by more than the window may have been
/// written in the same tick, after the read. A path that does not exist
/// throws, through the content read — a build that declared a path and did
/// not write it is broken, and answering anything else would bless bytes that
/// are not there.
Future<Map<String, FileSnapshot>> readFileSnapshots(
  Iterable<String> paths,
) async {
  final readStart = DateTime.now().microsecondsSinceEpoch;
  final content = await nativeLibsFingerprintOfFiles(paths);
  final snapshots = <String, FileSnapshot>{};
  for (final path in paths) {
    snapshots[path] = FileSnapshot(
      stampForStat(await File(path).stat()),
      content[path]!,
      readStart,
    );
  }
  return snapshots;
}

/// The paths in [paths] whose bytes differ from [live], advancing [live] for
/// the files proven current.
///
/// A file whose stamp moved is always read. A file whose stamp matched is
/// read too unless its mtime predates its last content read by more than
/// [racyWindow] — anything younger may have been rewritten in the same tick
/// the baseline was read in, which leaves the stamp exactly as it was. A
/// file whose bytes did not move after all has its snapshot recorded, which
/// is what keeps it out of the hashing stage for the rest of the run once
/// its mtime ages past the window; a file that really moved is left
/// un-advanced on purpose, so the next command reaches the same verdict.
/// Only a new baseline changes that.
///
/// A path that is not there counts as moved against a snapshot that has it.
/// What happens next depends on [readMissing]: when true, it joins the
/// content read, which throws — the same loud answer as a snapshot that
/// never had it, since neither describes bytes the app could be running
/// (this is the watch's rule). When false, it counts as moved without
/// reading anything, and the caller runs whatever decides the outcome — a
/// build, in the hot patcher's case — and reports that instead (this is the
/// patcher's rule: a deleted source is a move by itself, never a throw).
Future<List<String>> findMovedFiles({
  required Iterable<String> paths,
  required Map<String, FileSnapshot> live,
  bool readMissing = true,
}) async {
  final restamped = <String, String>{};
  final moved = <String>[];
  for (final path in paths) {
    final stat = await File(path).stat();
    final known = live[path];
    if (stat.type == FileSystemEntityType.notFound) {
      if (known == null || !known.isMissing) {
        if (readMissing) {
          restamped[path] = missingStamp;
        } else {
          moved.add(path);
        }
      }
      continue;
    }
    final stamp = stampForStat(stat);
    if (known == null ||
        known.isMissing ||
        stamp != known.stamp ||
        !stampProvesUnchanged(
          mtimeMicros: stat.modified.microsecondsSinceEpoch,
          readAtMicros: known.readAtMicros,
        )) {
      restamped[path] = stamp;
    }
  }
  if (restamped.isEmpty) return moved..sort();

  // The moment each file's content is read, taken before the read: a file
  // whose mtime is not older than this by more than the window may have been
  // written in the same tick, after the read.
  final readStart = DateTime.now().microsecondsSinceEpoch;
  final content = await nativeLibsFingerprintOfFiles(restamped.keys);
  for (final entry in restamped.entries) {
    final path = entry.key;
    if (content[path] != live[path]?.content) {
      moved.add(path);
    } else {
      live[path] = FileSnapshot(entry.value, content[path]!, readStart);
    }
  }
  return moved..sort();
}
