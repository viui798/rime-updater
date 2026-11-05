import 'dart:io';

import 'package:path/path.dart' as p;

/// 下载缓存的统计与管理。
///
/// 只处理本工具自己产生的文件（`.zip`、`.zip.sha256`、`MODEL.json`、`*.part`），
/// 因为缓存目录允许用户自定义，绝不能误删目录里的其他内容。
class CacheSummary {
  const CacheSummary({
    required this.directory,
    required this.files,
    required this.bytes,
  });

  final String directory;
  final int files;
  final int bytes;

  bool get isEmpty => files == 0;

  String get humanSize {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

bool isCacheArtifact(String name) {
  if (name == 'MODEL.json') return true;
  return name.endsWith('.zip') ||
      name.endsWith('.zip.sha256') ||
      name.endsWith('.part');
}

List<File> cacheFiles(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) return const [];
  try {
    return root
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => isCacheArtifact(p.basename(f.path)))
        .toList();
  } on FileSystemException {
    return const [];
  }
}

CacheSummary cacheSummary(String dir) {
  final files = cacheFiles(dir);
  var bytes = 0;
  for (final file in files) {
    try {
      bytes += file.lengthSync();
    } on FileSystemException {
      // 读不到就跳过，不影响统计其他文件
    }
  }
  return CacheSummary(directory: dir, files: files.length, bytes: bytes);
}

/// 只保留 [keep] 里的文件名（通常是当前版本用到的包与校验文件），
/// 其余缓存文件删除。返回删掉的字节数。
int pruneCache(String dir, {required Set<String> keep}) {
  var removed = 0;
  for (final file in cacheFiles(dir)) {
    final name = p.basename(file.path);
    if (keep.contains(name)) continue;
    try {
      removed += file.lengthSync();
      file.deleteSync();
    } on FileSystemException {
      // 占用中或已删除，忽略
    }
  }
  return removed;
}

/// 清空全部缓存文件，返回删掉的字节数。
int clearCache(String dir) => pruneCache(dir, keep: const {});
