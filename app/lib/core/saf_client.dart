import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

/// 一个通过 Android SAF（Storage Access Framework）选择的目录，
/// 例如元书暴露出来的 `RimeUserData`。
///
/// 这类目录不在文件系统路径上，只能用 content:// URI 操作；
/// 权限由系统选择器授予，并通过 takePersistableUriPermission 持久化。
class SafRoot {
  const SafRoot({required this.uri, required this.label});

  /// 目录树根的 content:// URI（DocumentFile tree URI）。
  final String uri;

  /// 展示名，例如「元书」。
  final String label;

  Map<String, dynamic> toJson() => {'uri': uri, 'label': label};

  factory SafRoot.fromJson(Map<String, dynamic> json) => SafRoot(
        uri: json['uri'] as String,
        label: json['label'] as String? ?? '',
      );
}

class SafEntry {
  const SafEntry({
    required this.uri,
    required this.name,
    required this.isDir,
    required this.length,
  });

  final String uri;
  final String name;
  final bool isDir;
  final int length;

  /// 相对根目录的路径，用 `/` 分隔，与 File 系统的相对路径保持一致。
  String get relativePath => name;
}

/// SAF 文件系统操作。所有方法都基于 URI，不依赖 dart:io 的目录路径。
class SafClient {
  SafClient({SafUtil? util, SafStream? stream})
      : _util = util ?? SafUtil(),
        _stream = stream ?? SafStream();

  final SafUtil _util;
  final SafStream _stream;

  /// 目录列表缓存：SAF 每次 list() 都是一次跨进程查询，
  /// 写入大量文件时逐级解析会非常慢，这里按 URI 缓存。
  final Map<String, List<SafEntry>> _listCache = {};

  void clearCache() => _listCache.clear();

  /// 让用户在系统文件选择器里挑一个目录，并持久化授权。
  /// 返回 null 表示用户取消。
  ///
  /// 注意：必须显式要求 persistablePermission，否则授权只在本次进程
  /// 有效，重启后读取会得到 Permission Denial。
  Future<SafRoot?> pickDirectory({String label = 'SAF 目录'}) async {
    final picked = await _util.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (picked == null) return null;
    return SafRoot(uri: picked.uri, label: label);
  }

  /// 检查持久化授权是否仍然有效。
  Future<bool> hasPermission(String uri) async {
    try {
      return await _util.hasPersistedPermission(uri);
    } catch (_) {
      return false;
    }
  }

  /// 释放持久化授权（用户移除该目录时调用）。
  Future<void> releasePermission(String uri) =>
      _util.releasePersistedPermission(uri, read: true, write: true);

  Future<List<SafEntry>> list(String uri) async {
    final cached = _listCache[uri];
    if (cached != null) return cached;
    final items = await _util.list(uri);
    final entries = items
        .map((item) => SafEntry(
              uri: item.uri,
              name: item.name,
              isDir: item.isDir,
              length: item.length,
            ))
        .toList();
    _listCache[uri] = entries;
    return entries;
  }

  /// 按相对路径（`a/b/c`）逐级查找子项。
  Future<SafEntry?> resolve(String rootUri, String relative) async {
    if (relative.isEmpty || relative == '.') {
      final root = await _util.documentFileFromUri(rootUri, true);
      if (root == null) return null;
      return SafEntry(
          uri: root.uri, name: root.name, isDir: true, length: root.length);
    }
    final parts = relative.split('/').where((s) => s.isNotEmpty).toList();
    SafEntry? current;
    var currentUri = rootUri;
    for (final part in parts) {
      final children = await list(currentUri);
      current = children.where((e) => e.name == part).firstOrNull;
      if (current == null) return null;
      currentUri = current.uri;
    }
    return current;
  }

  /// 递归列出目录下全部文件（不包含目录本身），返回相对路径 -> 条目。
  /// [skipDirs] 中的目录名及其子树会被跳过（例如 `build`）。
  Future<Map<String, SafEntry>> walk(
    String uri, {
    Set<String> skipDirs = const {},
    int maxEntries = 15000,
  }) async {
    final result = <String, SafEntry>{};
    Future<void> visit(String dirUri, String prefix) async {
      final children = await list(dirUri);
      for (final item in children) {
        final rel = prefix.isEmpty ? item.name : '$prefix/${item.name}';
        if (item.isDir) {
          if (skipDirs.contains(item.name)) continue;
          await visit(item.uri, rel);
        } else {
          if (result.length >= maxEntries) {
            throw const SafException('文件过多，请先清理目录');
          }
          result[rel] = item;
        }
      }
    }

    await visit(uri, '');
    return result;
  }

  Future<Uint8List> readBytes(String fileUri) => _stream.readFileBytes(fileUri);

  Future<String> readText(String fileUri) async =>
      utf8.decode(await readBytes(fileUri), allowMalformed: true);

  /// 写入（覆盖）指定目录下的文件和内容；文件不存在时创建。
  Future<void> writeBytes(String dirUri, String name, Uint8List data) async {
    await _stream.writeFileBytes(
      dirUri,
      name,
      _mimeOf(name),
      data,
      overwrite: true,
    );
    _listCache.remove(dirUri);
  }

  /// 流式写入：分块上传，内存占用只与 [chunkSize] 相关，
  /// 因此可以写入几百 MB 的模型文件而不会 OOM。
  Future<void> writeStream(
    String dirUri,
    String name, {
    required Stream<List<int>> source,
    int chunkSize = 1024 * 1024,
    void Function(int written)? onProgress,
  }) async {
    final info = await _stream.startWriteStream(
      dirUri,
      name,
      _mimeOf(name),
      overwrite: true,
    );
    var written = 0;
    final buffer = BytesBuilder(copy: false);
    try {
      await for (final piece in source) {
        buffer.add(piece);
        if (buffer.length < chunkSize) continue;
        final bytes = buffer.takeBytes();
        await _stream.writeChunk(info.session, bytes);
        written += bytes.length;
        onProgress?.call(written);
      }
      if (buffer.length > 0) {
        final bytes = buffer.takeBytes();
        await _stream.writeChunk(info.session, bytes);
        written += bytes.length;
        onProgress?.call(written);
      }
    } finally {
      await _stream.endWriteStream(info.session);
      _listCache.remove(dirUri);
    }
  }

  /// 直接覆盖已存在的文件 URI。
  Future<void> writeBytesToUri(String fileUri, Uint8List data) =>
      _stream.writeFileUriBytes(fileUri, data);

  static String _mimeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
      return 'application/x-yaml';
    }
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.lua') || lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<void> delete(String uri, {required bool isDir}) async {
    await _util.delete(uri, isDir);
    _listCache.clear();
  }

  Future<SafEntry> makeDir(String dirUri, String name) async {
    final created = await _util.mkdirp(dirUri, [name]);
    _listCache.remove(dirUri);
    return SafEntry(
        uri: created.uri,
        name: created.name,
        isDir: true,
        length: created.length);
  }

  /// 尝试识别目录里是否像 Rime 用户目录：
  /// 根目录或某个子目录里存在 *.schema.yaml / default.yaml。
  Future<String?> detectRimeSubdir(SafRoot root,
      {Set<String> skipDirs = const {'build', 'conf', 'themes', 'logs', 'sync'}}) async {
    final children = await list(root.uri);
    var hasRootConfig = false;
    for (final item in children) {
      if (!item.isDir &&
          (item.name.endsWith('.schema.yaml') ||
              item.name == 'default.yaml' ||
              item.name == 'installation.yaml')) {
        hasRootConfig = true;
        break;
      }
    }
    if (hasRootConfig) return '';

    for (final item in children) {
      if (!item.isDir || skipDirs.contains(item.name)) continue;
      final grand = await list(item.uri);
      final looksRime = grand.any((e) =>
          !e.isDir &&
          (e.name.endsWith('.schema.yaml') ||
              e.name == 'default.yaml' ||
              e.name == 'installation.yaml'));
      if (looksRime) return item.name;
    }
    return null;
  }
}

class SafException implements Exception {
  const SafException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 把 SAF 相对路径规范成 `/` 分隔形式。
String normalizeSafRelative(String relative) =>
    p.posix.normalize(relative.replaceAll('\\', '/'));
