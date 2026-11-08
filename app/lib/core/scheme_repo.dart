import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'local_package.dart';
import 'settings_store.dart';

/// 方案仓库就是一个放 zip 的目录（默认与下载缓存同一个位置）：
/// GitHub 下载的包和用户导入的包都放在这里，一键更新时优先复用。
const _indexName = '.scheme-index.json';

class SchemeEntry {
  const SchemeEntry({
    required this.name,
    required this.path,
    required this.bytes,
    required this.version,
    required this.imported,
  });

  final String name;
  final String path;
  final int bytes;
  final String version;
  final bool imported;

  String get humanSize {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

String schemeRepoDir(Settings settings) => resolveCacheDir(settings);

Map<String, dynamic> _readIndex(String dir) {
  final file = File(p.join(dir, _indexName));
  if (!file.existsSync()) return {};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {
    // 索引损坏当作没有，文件本身仍在
  }
  return {};
}

void _writeIndex(String dir, Map<String, dynamic> data) {
  try {
    Directory(dir).createSync(recursive: true);
    File(p.join(dir, _indexName)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  } on FileSystemException {
    // 索引只是标注来源，写不了不影响使用
  }
}

/// 列出仓库里的全部 zip（按文件名排序），并标注下载 / 导入来源。
List<SchemeEntry> listSchemes(Settings settings) {
  final dir = schemeRepoDir(settings);
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  final index = _readIndex(dir);
  final imported = (index['imported'] as List? ?? const []).cast<String>();
  final entries = <SchemeEntry>[];
  try {
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.toLowerCase().endsWith('.zip')) continue;
      var bytes = 0;
      try {
        bytes = entity.lengthSync();
      } on FileSystemException {
        // 读不到大小就显示 0
      }
      entries.add(SchemeEntry(
        name: name,
        path: entity.path,
        bytes: bytes,
        version: versionFor(entity.path),
        imported: imported.contains(name),
      ));
    }
  } on FileSystemException {
    return const [];
  }
  entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return entries;
}

/// 把外部 zip 复制进方案仓库；同名时自动加序号，返回新文件路径。
Future<String> importScheme(Settings settings, String sourcePath) async {
  final dir = schemeRepoDir(settings);
  await Directory(dir).create(recursive: true);
  final base = p.basename(sourcePath);
  var name = base;
  var counter = 2;
  while (File(p.join(dir, name)).existsSync()) {
    final ext = p.extension(base);
    final stem = base.substring(0, base.length - ext.length);
    name = '$stem-$counter$ext';
    counter += 1;
  }
  final dest = p.join(dir, name);
  await File(sourcePath).copy(dest);
  final index = _readIndex(dir);
  final imported = (index['imported'] as List? ?? const []).cast<String>().toList()
    ..add(name);
  index['imported'] = imported;
  _writeIndex(dir, index);
  return dest;
}

/// 清理旧包时要保留的文件名：当前版本 + 用户导入 + 勾选的方案。
Set<String> schemeKeepNames(Settings settings, Set<String> current) {
  final keep = <String>{...current};
  final dir = schemeRepoDir(settings);
  final index = _readIndex(dir);
  keep.addAll((index['imported'] as List? ?? const []).cast<String>());
  final selected = settings.selectedScheme.trim();
  if (selected.isNotEmpty) keep.add(selected);
  return keep;
}

/// 删除仓库里的某个包（同时从索引里移除）。
void removeScheme(Settings settings, String name) {
  final dir = schemeRepoDir(settings);
  final file = File(p.join(dir, name));
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // 占用中时由调用方提示
  }
  final index = _readIndex(dir);
  final imported = (index['imported'] as List? ?? const []).cast<String>().toList()
    ..remove(name);
  index['imported'] = imported;
  _writeIndex(dir, index);
}
