import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_client.dart';
import 'rime_profile.dart';

class FullPackageRequired implements Exception {
  FullPackageRequired(this.message);
  final String message;

  @override
  String toString() => message;
}

String _stampNow() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

String _zipPrefix(Archive archive) {
  final names = <String>[];
  for (final file in archive) {
    if (file.isFile) names.add(file.name);
  }
  if (names.isEmpty) return '';
  if (names.any((name) => name.startsWith('update/'))) return 'update/';

  final tops = names.map((name) => name.split('/').first).toSet();
  final hasRootFile = names.any((name) => !name.contains('/'));

  // 扁平包：文件直接放在根目录，或根目录下就是 lua/ opencc/ 等运行目录
  if (hasRootFile || tops.length > 1) return '';
  final top = tops.single;
  if (runtimeDirs.contains('$top/')) return '';
  return '$top/';
}

ArchiveFile? _findEntry(Archive archive, String name) {
  for (final file in archive) {
    if (file.isFile && file.name == name) return file;
  }
  return null;
}

/// 目标文件与包内内容完全一致时返回 true，用于跳过无变化的写入与快照。
bool _sameContent(ArchiveFile file, String dst) {
  final target = File(dst);
  if (!target.existsSync() || target.lengthSync() != file.size) return false;
  final incoming = file.content as List<int>;
  final existing = target.readAsBytesSync();
  if (existing.length != incoming.length) return false;
  for (var i = 0; i < incoming.length; i++) {
    if (existing[i] != incoming[i]) return false;
  }
  return true;
}

/// 粗略判断压缩包里是否包含 Rime 方案文件（yaml / lua / opencc）。
bool zipLooksLikeRime(String zipPath) {
  if (!File(zipPath).existsSync()) return false;
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeStream(input);
    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name.toLowerCase();
      if (name.endsWith('.yaml') ||
          name.startsWith('lua/') ||
          name.contains('/lua/') ||
          name.contains('/opencc/')) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    input?.close();
  }
}

bool zipRequiresFull(String zipPath) {
  if (!File(zipPath).existsSync()) return false;
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeStream(input);
    final prefix = _zipPrefix(archive);
    final entry = _findEntry(archive, '${prefix}DELTA.json');
    if (entry == null) return false;
    final data = entry.content as List<int>;
    final decoded = jsonDecode(utf8.decode(data));
    return decoded is Map && (decoded['full_required'] as bool? ?? false);
  } catch (_) {
    return false;
  } finally {
    input?.close();
  }
}

/// 从包内 DELTA.json 读取基座版本（增量包适用的已装版本），没有返回空串。
String deltaBaseVersion(String zipPath) {
  if (!File(zipPath).existsSync()) return '';
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeStream(input);
    final prefix = _zipPrefix(archive);
    final entry = _findEntry(archive, '${prefix}DELTA.json');
    if (entry == null) return '';
    final decoded = jsonDecode(utf8.decode(entry.content as List<int>));
    if (decoded is! Map) return '';
    return decoded['from']?.toString() ?? '';
  } catch (_) {
    return '';
  } finally {
    input?.close();
  }
}

String readZipVersion(String zipPath) {
  if (!File(zipPath).existsSync()) return '';
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeStream(input);
    final prefix = _zipPrefix(archive);
    final entry = _findEntry(archive, '${prefix}DELTA.json');
    if (entry == null) return '';
    final decoded = jsonDecode(utf8.decode(entry.content as List<int>));
    if (decoded is! Map) return '';
    return decoded['to']?.toString() ?? '';
  } catch (_) {
    return '';
  } finally {
    input?.close();
  }
}

ApplyStats applyZip({
  required String zipPath,
  required String target,
  required String version,
  required bool dryRun,
  required bool snapshot,
  required void Function(String line) log,
  required void Function(int done, int total) onFile,
}) {
  final input = InputFileStream(zipPath);
  Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } catch (error) {
    input.close();
    throw UpdateException('无法打开安装包：$error');
  }

  try {
    final prefix = _zipPrefix(archive);
    final deltaEntry = _findEntry(archive, '${prefix}DELTA.json');
    final delta = deltaEntry == null
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(deltaEntry.content as List<int>)) as Map<String, dynamic>;
    if (delta['full_required'] == true) {
      throw FullPackageRequired('该增量包要求完整包（模型有变更）');
    }
    final deltaBase = delta['from']?.toString() ?? '';
    if (deltaBase.isNotEmpty) {
      // 基座校验：底子不对（或版本未知）一律完整包，宁重勿缺。
      final local = (readLocalVersion(target)).replaceAll(RegExp('^v'), '').trim();
      final base = deltaBase.startsWith('v') ? deltaBase.substring(1) : deltaBase;
      if (local.isEmpty || local != base) {
        throw FullPackageRequired(
            '增量包基座 $base 与已装版本 ${local.isEmpty ? '未知' : local} 不一致，请改用完整包');
      }
    }

    final stamp = _stampNow();
    final previousVersion = readLocalVersion(target);
    final backupRoot = p.join(target, backupDirName, stamp);
    final overwritten = <String>[];
    final created = <String>[];
    final deleted = <String>[];
    final tooBig = <String>[];

    final entries = archive.files
        .where((file) => file.isFile && file.name.startsWith(prefix))
        .toList();
    final planned = entries
        .where((file) => shouldCopy(
              file.name.substring(prefix.length),
              size: file.size,
              target: target,
            ))
        .length;

    var done = 0;
    var copied = 0;
    var skipped = 0;
    for (final file in entries) {
      final rel = file.name.substring(prefix.length);
      if (rel == 'DELTA.json' ||
          !shouldCopy(rel, size: file.size, target: target)) {
        skipped++;
        continue;
      }

      final dst = p.join(target, rel);
      final targetFile = File(dst);
      final existed = targetFile.existsSync();

      if (_sameContent(file, dst)) {
        log('  未变化 $rel');
        skipped++;
        done++;
        onFile(done, planned);
        continue;
      }

      if (dryRun) {
        log('  会更新 $rel');
        copied++;
      } else {
        if (existed && (snapshot || rel.endsWith('.custom.yaml'))) {
          final size = targetFile.lengthSync();
          if (size > backupMaxBytes) {
            if (snapshot) tooBig.add(rel);
            log('  ! $rel 体积过大，未纳入备份');
          } else {
            final bak = p.join(backupRoot, rel);
            File(bak).parent.createSync(recursive: true);
            targetFile.copySync(bak);
            if (snapshot) overwritten.add(rel);
          }
        } else if (snapshot && !existed) {
          created.add(rel);
        }

        targetFile.parent.createSync(recursive: true);
        final output = OutputFileStream(dst);
        file.writeContent(output);
        output.close();
        copied++;
      }

      done++;
      onFile(done, planned);
    }

    for (final raw in (delta['deletions'] as List? ?? const [])) {
      final rel = raw.toString();
      if (rel.isEmpty || !shouldCopy(rel)) continue;
      final dst = File(p.join(target, rel));
      if (!dst.existsSync()) continue;
      log(dryRun ? '  删除 $rel' : '  已删除 $rel');
      if (dryRun) continue;

      if (snapshot) {
        if (dst.lengthSync() > backupMaxBytes) {
          tooBig.add(rel);
        } else {
          final bak = p.join(backupRoot, rel);
          File(bak).parent.createSync(recursive: true);
          dst.copySync(bak);
          overwritten.add(rel);
        }
        deleted.add(rel);
      }
      dst.deleteSync();
    }

    if (!dryRun) {
      File(p.join(target, markerFile)).writeAsStringSync('$version\n');
      if (snapshot &&
          (overwritten.isNotEmpty ||
              created.isNotEmpty ||
              deleted.isNotEmpty ||
              tooBig.isNotEmpty)) {
        final manifest = {
          'stamp': stamp,
          'version': version,
          'previous_version': previousVersion,
          'target': target,
          'overwritten': overwritten,
          'created': created,
          'deleted': deleted,
          'too_big': tooBig,
        };
        final manifestFile = File(p.join(backupRoot, 'manifest.json'));
        manifestFile.parent.createSync(recursive: true);
        manifestFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(manifest),
        );
        log('${dryRun ? '预演' : '完成'}：更新 $copied 个文件，跳过 $skipped 个');
        return ApplyStats(
          copied: copied,
          skipped: skipped,
          backupStamp: stamp,
        );
      }
    }

    log('${dryRun ? '预演' : '完成'}：更新 $copied 个文件，跳过 $skipped 个');
    return ApplyStats(copied: copied, skipped: skipped);
  } finally {
    input.close();
  }
}

void rollback({
  required String target,
  required String stamp,
  required void Function(String line) log,
}) {
  final root = p.join(target, backupDirName, stamp);
  final manifest = File(p.join(root, 'manifest.json'));
  if (!manifest.existsSync()) {
    throw UpdateException('备份 $stamp 没有 manifest.json，只能手动恢复');
  }

  final data = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  final overwritten = (data['overwritten'] as List? ?? const []).cast<String>();
  final created = (data['created'] as List? ?? const []).cast<String>();
  final deleted = (data['deleted'] as List? ?? const []).cast<String>();
  final tooBig = (data['too_big'] as List? ?? const []).cast<String>();

  for (final rel in created) {
    final file = File(p.join(target, rel));
    if (file.existsSync()) {
      file.deleteSync();
      log('  移除新增 $rel');
    }
  }
  for (final rel in [...overwritten, ...deleted]) {
    final src = File(p.join(root, rel));
    if (!src.existsSync()) continue;
    final dst = File(p.join(target, rel));
    dst.parent.createSync(recursive: true);
    if (dst.existsSync()) dst.deleteSync();
    src.copySync(dst.path);
    log('  恢复 $rel');
  }
  for (final rel in tooBig) {
    log('  ! $rel 体积过大未备份，无法恢复');
  }

  final previous = data['previous_version'] as String? ?? '';
  final marker = File(p.join(target, markerFile));
  if (previous.isNotEmpty) {
    marker.writeAsStringSync('$previous\n');
  } else if (marker.existsSync()) {
    marker.deleteSync();
  }
  log('  回滚完成，当前版本：${previous.isEmpty ? '未知' : previous}');
}
