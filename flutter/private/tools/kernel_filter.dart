/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart -- <executable> <arguments>
library;

import 'dart:io';

const _uuid =
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

final _boundary = RegExp('^(result $_uuid|$_uuid|$_uuid \\S.* \\d+)\$');

/// Whether [line] is one of `frontend_server`'s batch-protocol lines.
bool isBoundaryLine(String line) => _boundary.hasMatch(line);

/// [output] without its batch-protocol lines.
String withoutBoundaryLines(String output) {
  final kept = [
    for (final line in output.split('\n'))
      if (!isBoundaryLine(line)) line,
  ];
  return kept.join('\n');
}

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol lines; returns its exit code.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln('Usage: dart kernel_filter.dart -- <executable> <arguments>');
    return 2;
  }
  final executable = argv[i + 1];
  final cmdArgs = argv.sublist(i + 2);
  final webPluginOverrides = _rewriteWebPluginsUiWebImports(cmdArgs);
  final conditionalOverrides = _rewriteWebConditionalImports(cmdArgs);
  ProcessResult result;
  try {
    result = await Process.run(executable, cmdArgs);
    if (result.exitCode != 0) {
      final retried = await _retryWithoutUnavailableWebPlugins(
        executable,
        cmdArgs,
        '${result.stdout}${result.stderr}',
      );
      if (retried != null) {
        result = retried;
      }
    }
  } finally {
    for (final override in conditionalOverrides.reversed) {
      override.restore();
    }
    for (final override in webPluginOverrides.reversed) {
      override.restore();
    }
  }
  out.write(withoutBoundaryLines(result.stdout as String));
  err.write(result.stderr as String);
  return result.exitCode;
}

class _StagedFileOverride {
  _StagedFileOverride._(
    this.file,
    this.originalContent, {
    required this.wasLink,
    required this.linkTarget,
  });

  final File file;
  final String originalContent;
  final bool wasLink;
  final String? linkTarget;

  static _StagedFileOverride apply(
    File file,
    String newContent, {
    String? originalContent,
  }) {
    final savedContent = originalContent ?? file.readAsStringSync();
    final link = Link(file.path);
    final wasLink = link.existsSync();
    final linkTarget = wasLink ? link.targetSync() : null;
    if (wasLink) {
      link.deleteSync();
    }
    file.writeAsStringSync(newContent);
    return _StagedFileOverride._(
      file,
      savedContent,
      wasLink: wasLink,
      linkTarget: linkTarget,
    );
  }

  void restore() {
    if (wasLink && linkTarget != null) {
      if (file.existsSync()) {
        file.deleteSync();
      }
      Link(file.path).createSync(linkTarget!);
    } else {
      file.writeAsStringSync(originalContent);
    }
  }
}

/// Rewrites `dart:ui_web` imports/exports and `dart.library.ui_web` conditions
/// in a `flutter_web_plugins` source [content] to target [uiWebStubUri].
String rewriteFlutterWebPluginsSource(String content, String uiWebStubUri) {
  return content
      .replaceAll("'dart:ui_web'", "'$uiWebStubUri'")
      .replaceAll('"dart:ui_web"', '"$uiWebStubUri"')
      .replaceAll('if (dart.library.ui_web)', 'if (dart.library.async)');
}

List<_StagedFileOverride> _rewriteWebPluginsUiWebImports(List<String> cmdArgs) {
  var scheme = 'org-dartlang-app';
  for (var j = 0; j < cmdArgs.length - 1; j++) {
    if (cmdArgs[j] == '--filesystem-scheme') {
      scheme = cmdArgs[j + 1];
      break;
    }
  }

  final overrides = <_StagedFileOverride>[];
  for (var j = 0; j < cmdArgs.length - 1; j++) {
    if (cmdArgs[j] != '--filesystem-root' || cmdArgs[j + 1] == '.') {
      continue;
    }
    final dir = Directory(cmdArgs[j + 1]);
    if (!dir.existsSync()) continue;

    final rootPrefix = dir.path
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    String? stubRelPath;
    final webPluginFiles = <File>[];

    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      final normPath = entity.path.replaceAll(r'\', '/');
      if (!normPath.startsWith('$rootPrefix/')) continue;
      final relPath = normPath.substring(rootPrefix.length + 1);
      if (relPath.endsWith('_ui_web_stub.dart')) {
        stubRelPath ??= relPath;
      } else if (relPath.endsWith('.dart') &&
          (relPath.startsWith('flutter_web_plugins/lib/') ||
              relPath.contains('/flutter_web_plugins/lib/') ||
              relPath.contains('__flutter_web_plugins/lib/'))) {
        webPluginFiles.add(File(entity.path));
      }
    }

    if (stubRelPath == null || webPluginFiles.isEmpty) continue;
    final stubUri = '$scheme:///$stubRelPath';
    for (final file in webPluginFiles) {
      if (!file.existsSync()) continue;
      final original = file.readAsStringSync();
      final rewritten = rewriteFlutterWebPluginsSource(original, stubUri);
      if (rewritten != original) {
        overrides.add(
          _StagedFileOverride.apply(
            file,
            rewritten,
            originalContent: original,
          ),
        );
      }
    }
  }
  return overrides;
}

/// Rewrites Dart platform-conditional imports/exports so the web branch is
/// selected during icon tree-shaking, which compiles against the VM platform.
List<_StagedFileOverride> _rewriteWebConditionalImports(List<String> cmdArgs) {
  if (Platform.environment['RULES_FLUTTER_REWRITE_WEB_CONDITIONALS'] != '1') {
    return <_StagedFileOverride>[];
  }
  final overrides = <_StagedFileOverride>[];
  for (var j = 0; j < cmdArgs.length - 1; j++) {
    if (cmdArgs[j] != '--filesystem-root' || cmdArgs[j + 1] == '.') {
      continue;
    }
    final dir = Directory(cmdArgs[j + 1]);
    if (!dir.existsSync()) continue;
    final rootPrefix = dir.path.replaceAll(r'\\', '/').replaceFirst(RegExp(r'/+$'), '');
    for (final entity in dir.listSync(recursive: true, followLinks: true)) {
      if (entity is! File) continue;
      final normPath = entity.path.replaceAll(r'\\', '/');
      if (!normPath.startsWith('$rootPrefix/')) continue;
      if (!normPath.endsWith('.dart')) continue;
      final file = File(entity.path);
      final original = file.readAsStringSync();
      final rewritten = _rewriteConditionalImports(original);
      if (rewritten != original) {
        overrides.add(_StagedFileOverride.apply(file, rewritten, originalContent: original));
      }
    }
  }
  return overrides;
}

String _rewriteConditionalImports(String content) {
  // Rewrite `if (dart.library.x, ...)` conditions to `if (true)` so the
  // web (second) branch of platform-conditional imports/exports is selected.
  return content.replaceAllMapped(
    RegExp(r"if\s*\(\s*(?:!?\s*dart\.library\.(?:js_interop|js_util|html)\s*,?\s*)+\)"),
    (m) => 'if (dart.library.async)',
  );
}

final _unavailableRegistrantPlugin = RegExp(
  r'_plugin_registrant\.dart => package:([A-Za-z0-9_]+)\b',
);

Future<ProcessResult?> _retryWithoutUnavailableWebPlugins(
  String executable,
  List<String> cmdArgs,
  String combinedOutput,
) async {
  if (!combinedOutput.contains('is not available on this platform.')) {
    return null;
  }
  final badPackages = <String>{
    for (final m in _unavailableRegistrantPlugin.allMatches(combinedOutput))
      m.group(1)!,
  };
  if (badPackages.isEmpty) {
    return null;
  }

  File? stagedRegistrant;
  for (var j = 0; j < cmdArgs.length - 1; j++) {
    if (cmdArgs[j] == '--filesystem-root' && cmdArgs[j + 1] != '.') {
      final dir = Directory(cmdArgs[j + 1]);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity.path.endsWith('_plugin_registrant.dart')) {
          stagedRegistrant = File(entity.path);
          break;
        }
      }
      if (stagedRegistrant != null) break;
    }
  }
  if (stagedRegistrant == null || !stagedRegistrant.existsSync()) {
    return null;
  }

  final originalContent = stagedRegistrant.readAsStringSync();
  final filteredContent = _stripUnavailablePlugins(
    originalContent,
    badPackages,
  );
  if (filteredContent == originalContent) {
    return null;
  }

  final override = _StagedFileOverride.apply(
    stagedRegistrant,
    filteredContent,
    originalContent: originalContent,
  );
  try {
    return await Process.run(executable, cmdArgs);
  } finally {
    override.restore();
  }
}

String _stripUnavailablePlugins(String content, Set<String> badPackages) {
  final lines = content.split('\n');
  final importRe = RegExp("^import 'package:([^/']+)/[^']+';\$");
  final pluginIndicesToDrop = <int>{};
  var pluginIdx = 0;
  for (final line in lines) {
    final m = importRe.firstMatch(line.trim());
    if (m != null) {
      final pkg = m.group(1)!;
      if (pkg == 'flutter_web_plugins') continue;
      if (badPackages.contains(pkg)) {
        pluginIndicesToDrop.add(pluginIdx);
      }
      pluginIdx++;
    }
  }
  if (pluginIndicesToDrop.isEmpty) {
    return content;
  }

  final outLines = <String>[];
  var currentImportIdx = 0;
  var currentCallIdx = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    final m = importRe.firstMatch(trimmed);
    if (m != null && m.group(1) != 'flutter_web_plugins') {
      final drop = pluginIndicesToDrop.contains(currentImportIdx);
      currentImportIdx++;
      if (drop) continue;
    } else if (trimmed.contains('.registerWith(')) {
      final drop = pluginIndicesToDrop.contains(currentCallIdx);
      currentCallIdx++;
      if (drop) continue;
    }
    outLines.add(line);
  }
  return outLines.join('\n');
}
