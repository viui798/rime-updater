import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'rime_profile.dart';
import 'saf_client.dart';
import 'zip_installer.dart' show FullPackageRequired;

/// 通过 SAF 目录（如元书暴露的 RimeUserData）安装 / 更新 Rime 方案。
///
/// 与 [applyZip] 的行为保持一致：
/// - 沿用同一套 `shouldCopy` 白名单，个人数据永不覆盖；
/// - 覆盖前把原文件写进 `.cheese-tiger-backup/<时间戳>/`（UTF-8 文本与小型二进制）；
/// - 成功写 `.cheese-tiger-version`。
/// 区别在于所有文件操作都走 content:// URI，而不是文件系统路径。
class SafApplyResult {
  const SafApplyResult({
    required this.copied,
    required this.skipped,
    required this.backupStamp,
    required this.removed,
  });

  final int copied;
  final int skipped;
  final String backupStamp;
  final List<String> removed;
}

/// SAF 目录的版本标记。元书等 DocumentsProvider 会拒绝以点开头的文件名
/// （创建目录 .cheese-tiger-backup 时已实测失败），所以 SAF 用不带点的名字。
const safMarkerFile = 'cheese-tiger-version.txt';

/// 单文件内存上限：超过就走流式分块，避免 OOM。
const int safMaxInMemoryBytes = 64 * 1024 * 1024;

/// 流式写入的分块大小。
const int safChunkBytes = 1024 * 1024;

String _stampNow() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

String _zipPrefix(Archive archive) {
  final names = archive.files
      .where((f) => f.isFile)
      .map((f) => f.name.replaceAll('\\', '/'))
      .toList();
  if (names.any((n) => n.startsWith('update/'))) return 'update/';
  for (final candidate in const [
    'default.yaml',
    'installation.yaml',
  ]) {
    if (names.any((n) => n == candidate)) return '';
    final nested = names.where((n) => n.endsWith('/$candidate')).toList();
    if (nested.length == 1) {
      final prefix = nested.first.substring(0, nested.first.length - candidate.length);
      if (!prefix.contains('/')) return prefix;
    }
  }
  final first = names.any((n) => n.contains('/'))
      ? '${names.first.split('/').first}/'
      : '';
  if (first.isEmpty) return '';
  final allUnder = names.every((n) => n.startsWith(first));
  return allUnder ? first : '';
}

/// 读取 SAF 目录的版本标记。
Future<String> readSafLocalVersion(SafClient client, String rootUri) async {
  // 1) 本工具写的版本标记（先试不带点的 SAF 版本，再试桌面端的带点版本）
  for (final name in <String>[safMarkerFile, markerFile]) {
    final marker = await client.resolve(rootUri, name);
    if (marker != null && !marker.isDir && marker.length < safMaxInMemoryBytes) {
      final text = (await client.readText(marker.uri)).trim();
      if (text.isNotEmpty) {
        return text.startsWith('v') ? text.substring(1) : text;
      }
    }
  }
  // 2) 退回 CHANGELOG.md，与桌面端 readLocalVersion 语义一致。
  final changelog = await client.resolve(rootUri, 'CHANGELOG.md');
  if (changelog != null && !changelog.isDir && changelog.length < safMaxInMemoryBytes) {
    final text = await client.readText(changelog.uri);
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('## v')) {
        var version = line.substring(3).split('（').first.trim();
        if (version.startsWith('v')) version = version.substring(1);
        return version.trim();
      }
    }
  }
  return '';
}

/// 把 zip 内文件应用到 SAF 目录。
Future<SafApplyResult> applyZipToSaf({
  required SafClient client,
  required String rootUri,
  required String zipPath,
  required String version,
  required bool snapshot,
  /// 预演：只统计与记录，绝不写盘、不建快照、不写版本标记。
  bool dryRun = false,
  required void Function(String line) log,
}) async {
  final input = InputFileStream(zipPath);
  Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } catch (error) {
    input.close();
    throw SafException('无法打开安装包：$error');
  }

  try {
    final prefix = _zipPrefix(archive);
    // 基座校验：与桌面端 applyZip 语义一致。增量包底子不符时必须回退完整包，
    // 否则会出现「版本号前进了、文件底子没跟上」的坏安装。
    final deltaEntry = archive.files
        .where((f) => f.isFile && f.name.replaceAll('\\', '/') == '${prefix}DELTA.json')
        .firstOrNull;
    if (deltaEntry != null) {
      final delta = jsonDecode(utf8.decode(deltaEntry.content as List<int>))
          as Map<String, dynamic>;
      if (delta['full_required'] == true) {
        throw FullPackageRequired('该增量包要求完整包（模型有变更）');
      }
      final deltaBase = delta['from']?.toString() ?? '';
      if (deltaBase.isNotEmpty) {
        final local = (await readSafLocalVersion(client, rootUri))
            .replaceAll(RegExp('^v'), '')
            .trim();
        final base =
            deltaBase.startsWith('v') ? deltaBase.substring(1) : deltaBase;
        if (local.isEmpty || local != base) {
          throw FullPackageRequired(
              '增量包基座 $base 与已装版本 ${local.isEmpty ? '未知' : local} 不一致，请改用完整包');
        }
      }
    }

    final entries = archive.files
        .where((f) => f.isFile && f.name.replaceAll('\\', '/').startsWith(prefix))
        .toList();

    final stamp = _stampNow();
    // 快照失败（例如元书的 DocumentsProvider 不允许建点开头目录）不能中断更新，
    // 降级为「无快照更新」并明确告知，与桌面端「超大文件只登记不备份」的思路一致。
    String? backupDirUri;
    if (snapshot && !dryRun) {
      try {
        backupDirUri = (await _ensureBackupDir(client, rootUri, stamp)).uri;
      } catch (error) {
        log('  ⚠ 无法创建 SAF 快照目录（$error），本次不备份旧文件');
        backupDirUri = null;
      }
    }
    final overwritten = <String>[];
    final created = <String>[];
    final tooBig = <String>[];
    var copied = 0;
    var skipped = 0;

    for (final file in entries) {
      final rel = file.name.replaceAll('\\', '/').substring(prefix.length);
      if (rel == 'DELTA.json' || rel.isEmpty) {
        skipped++;
        continue;
      }
      if (!shouldCopy(rel, size: file.size)) {
        skipped++;
        continue;
      }
      final existing = await client.resolve(rootUri, rel);

      // 超大文件（完整包里的模型可达几百 MB）走流式：分块解压、分块写入，
      // 内存占用只和一个分块相关。内容比较按大小判断，不整份读入。
      if (file.size > safMaxInMemoryBytes) {
        if (existing != null && !existing.isDir &&
            existing.length == file.size) {
          log('  未变化 $rel（大小一致）');
          skipped++;
          continue;
        }
        if (existing != null) {
          if (backupDirUri != null) tooBig.add(rel);
          overwritten.add(rel);
        } else {
          created.add(rel);
        }
        if (!dryRun) {
          await _writeStreamRelative(client, rootUri, rel, file,
              onProgress: (done) {
            if (done % (8 * 1024 * 1024) < safChunkBytes) {
              log('  写入 $rel ${(done / 1048576).toStringAsFixed(0)}MB'
                  ' / ${(file.size / 1048576).toStringAsFixed(0)}MB');
            }
          });
        }
        copied++;
        log('  ${dryRun ? '将写入' : (existing == null ? '新增' : '覆盖')} '
            '$rel（流式）');
        continue;
      }

      final data = Uint8List.fromList(file.content as List<int>);

      // 大于阈值的文件（如 387MB 模型）绝不整份读进内存比较，
      // 否则 SAF 上会直接 OOM；大小相同即视为未变化。
      final tooLargeToCompare = data.length > backupMaxBytes;

      if (existing != null && !existing.isDir) {
        if (existing.length == data.length) {
          if (tooLargeToCompare) {
            log('  未变化 $rel（大小一致）');
            skipped++;
            continue;
          }
          final current = await client.readBytes(existing.uri);
          if (_bytesEqual(current, data)) {
            log('  未变化 $rel');
            skipped++;
            continue;
          }
        }
      }

      if (existing != null) {
        if (backupDirUri != null) {
          // 超大文件只登记不备份，与桌面端快照语义一致。
          if (!tooLargeToCompare) {
            try {
              final old = await client.readBytes(existing.uri);
              final parent = await _backupDirFor(client, backupDirUri, rel);
              await client.writeBytes(parent, p.posix.basename(rel), old);
            } catch (error) {
              tooBig.add(rel);
            }
          } else {
            tooBig.add(rel);
          }
        }
        overwritten.add(rel);
      } else {
        created.add(rel);
      }

      if (!dryRun) {
        await _writeRelative(client, rootUri, rel, data);
      }
      copied++;
      log('  ${dryRun ? '将写入' : (existing == null ? '新增' : '覆盖')} $rel');
    }

    // 版本标记：用不带点的文件名，否则会被 DocumentsProvider 拒绝。
    if (!dryRun) {
      await _writeRelative(client, rootUri, safMarkerFile,
          Uint8List.fromList(utf8.encode('$version\n')));
    }

    if (snapshot && backupDirUri != null) {
      final manifest = {
        'version': version,
        'previous_version': '',
        'overwritten': overwritten,
        'created': created,
        'deleted': <String>[],
        'too_big': tooBig,
      };
      await client.writeBytes(
        backupDirUri,
        'manifest.json',
        Uint8List.fromList(
            utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest))),
      );
    }

    return SafApplyResult(
      copied: copied,
      skipped: skipped,
      backupStamp: snapshot ? stamp : '',
      removed: const [],
    );
  } finally {
    input.close();
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<SafEntry> _ensureBackupDir(
    SafClient client, String rootUri, String stamp) async {
  final root = await client.resolve(rootUri, backupDirName);
  if (root != null) {
    return client.makeDir(root.uri, stamp);
  }
  // 部分 DocumentsProvider 拒绝创建点开头的目录，退回不带点的名字。
  final fallbackName = backupDirName.replaceFirst(RegExp(r'^\.'), '');
  Object? firstError;
  for (final name in <String>[backupDirName, fallbackName]) {
    if (name.isEmpty) continue;
    try {
      final container = await client.makeDir(rootUri, name);
      return await client.makeDir(container.uri, stamp);
    } catch (error) {
      firstError ??= error;
    }
  }
  throw SafException('$firstError');
}

Future<String> _backupDirFor(
    SafClient client, String backupDirUri, String rel) async {
  final parts = p.posix.split(rel);
  var current = backupDirUri;
  for (var i = 0; i < parts.length - 1; i++) {
    final next = await client.resolve(current, parts[i]);
    if (next?.isDir == true) {
      current = next!.uri;
    } else {
      current = (await client.makeDir(current, parts[i])).uri;
    }
  }
  return current;
}

/// 写入相对路径文件，自动创建缺失的中间目录。
Future<void> _writeRelative(
    SafClient client, String rootUri, String rel, Uint8List data) async {
  final parts = p.posix.split(rel);
  var current = rootUri;
  for (var i = 0; i < parts.length - 1; i++) {
    final next = await client.resolve(current, parts[i]);
    if (next?.isDir == true) {
      current = next!.uri;
    } else {
      current = (await client.makeDir(current, parts[i])).uri;
    }
  }
  await client.writeBytes(current, parts.last, data);
}

/// 把 zip 里的一个大文件分块解压并流式写入 SAF，内存只占一个分块的量。
Future<void> _writeStreamRelative(
  SafClient client,
  String rootUri,
  String rel,
  ArchiveFile file, {
  void Function(int written)? onProgress,
}) async {
  final parts = p.posix.split(rel);
  var dirUri = rootUri;
  for (var i = 0; i < parts.length - 1; i++) {
    final next = await client.resolve(dirUri, parts[i]);
    if (next?.isDir == true) {
      dirUri = next!.uri;
    } else {
      dirUri = (await client.makeDir(dirUri, parts[i])).uri;
    }
  }

  final input = file.getContent();
  if (input == null) {
    throw SafException('无法读取包内文件：$rel');
  }
  final buffer = Uint8List(safChunkBytes);

  Stream<List<int>> source() async* {
    while (!input.isEOS) {
      final got = input.readInto(buffer, 0, safChunkBytes);
      if (got <= 0) break;
      yield Uint8List.fromList(buffer.sublist(0, got));
    }
  }

  try {
    await client.writeStream(
      dirUri,
      parts.last,
      source: source(),
      chunkSize: safChunkBytes,
      onProgress: onProgress,
    );
  } finally {
    input.closeSync();
  }
}

/// 元书等 DocumentsProvider 会把点开头的文件名改写成「数字.原名」，
/// 所以历史上每次写 `.cheese-tiger-version` 都会留下一个新文件
/// （实际见过 1./2./3.cheese-tiger-version）。这里只清理这一类明确残留，
/// 不碰正确的 `cheese-tiger-version.txt`，也不碰任何备份目录。
final RegExp _staleMarkerPattern =
    RegExp(r'^\d+\.cheese-tiger-version(\.txt)?$');

Future<int> cleanStaleSafMarkers(
  SafClient client,
  String rootUri, {
  void Function(String line)? log,
}) async {
  List<SafEntry> entries;
  try {
    entries = await client.list(rootUri);
  } catch (_) {
    return 0;
  }
  var removed = 0;
  final suspicious = <String>[];
  for (final entry in entries) {
    if (entry.isDir) continue;
    // 有些 provider 会在名字里插入空白（实际见过「 1.cheese-tiger-version」），
    // 先去掉空白再判断，避免漏删。
    final compact = entry.name.replaceAll(RegExp(r'\s+'), '');
    final isMarker = compact.contains('cheese-tiger-version');
    if (!isMarker) continue;
    if (entry.name == safMarkerFile || entry.name == markerFile) continue;
    if (!_staleMarkerPattern.hasMatch(compact)) {
      suspicious.add('[${entry.name}]');
      continue;
    }
    try {
      await client.delete(entry.uri, isDir: false);
      removed++;
      log?.call('  清理残留标记 ${entry.name}');
    } catch (error) {
      suspicious.add('[${entry.name}: $error]');
    }
  }
  if (suspicious.isNotEmpty) {
    log?.call('  ⚠ 有 ${suspicious.length} 个疑似残留标记未能清理：'
        '${suspicious.take(5).join(' ')}');
  }
  return removed;
}
