import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/cache_manager.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cache-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File touch(String name, int bytes) {
    final file = File(p.join(dir.path, name));
    file.writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  test('只统计缓存文件，忽略用户自己的文件', () {
    touch('cheese-tiger-v0.3.26.zip', 100);
    touch('cheese-tiger-v0.3.26-update.zip', 50);
    touch('cheese-tiger-v0.3.26.zip.sha256', 10);
    touch('MODEL.json', 5);
    touch('我的笔记.txt', 999);

    final summary = cacheSummary(dir.path);
    expect(summary.files, 4);
    expect(summary.bytes, 165);
  });

  test('清理只删缓存文件，绝不碰其他内容', () {
    touch('a.zip', 10);
    final keepFile = touch('notes.md', 20);

    clearCache(dir.path);

    expect(File(p.join(dir.path, 'a.zip')).existsSync(), isFalse);
    expect(keepFile.existsSync(), isTrue, reason: '非缓存文件必须保留');
  });

  test('保留当前版本，其余旧包被删', () {
    final keepZip = touch('cheese-tiger-v0.3.26.zip', 100);
    final keepSha = touch('cheese-tiger-v0.3.26.zip.sha256', 10);
    final oldZip = touch('cheese-tiger-v0.3.24.zip', 80);
    final oldDelta = touch('cheese-tiger-v0.3.24-update.zip', 30);
    touch('MODEL.json', 5);

    final freed = pruneCache(dir.path, keep: {
      'cheese-tiger-v0.3.26.zip',
      'cheese-tiger-v0.3.26.zip.sha256',
      'MODEL.json',
    });

    expect(freed, 110);
    expect(keepZip.existsSync(), isTrue);
    expect(keepSha.existsSync(), isTrue);
    expect(oldZip.existsSync(), isFalse);
    expect(oldDelta.existsSync(), isFalse);
    expect(File(p.join(dir.path, 'MODEL.json')).existsSync(), isTrue);
  });

  test('目录不存在时返回空结果', () {
    final missing = p.join(dir.path, 'nope');
    expect(cacheSummary(missing).files, 0);
    expect(clearCache(missing), 0);
  });

  test('人类可读的体积格式', () {
    expect(const CacheSummary(directory: '', files: 1, bytes: 512).humanSize,
        '512 B');
    expect(
        const CacheSummary(directory: '', files: 1, bytes: 2048).humanSize,
        '2 KB');
    expect(
        const CacheSummary(directory: '', files: 1, bytes: 5 * 1024 * 1024)
            .humanSize,
        '5.0 MB');
  });
}
