import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/rime_profile.dart';

void main() {
  group('shouldCopy 过滤规则', () {
    test('运行文件会被更新', () {
      expect(shouldCopy('lua/db.lua'), isTrue);
      expect(shouldCopy('opencc/emoji.json'), isTrue);
      expect(shouldCopy('tiger.custom.yaml'), isTrue);
      expect(shouldCopy('default.yaml'), isTrue);
    });

    test('用户数据不会被覆盖', () {
      expect(shouldCopy('user.yaml'), isFalse);
      expect(shouldCopy('installation.yaml'), isFalse);
      expect(shouldCopy('reverse_freq.txt'), isFalse);
      expect(shouldCopy('tiger.custom.userdb'), isFalse);
      expect(shouldCopy('lua/kc_count.txt'), isFalse);
      expect(shouldCopy('lua/input_stats_20260101.lua'), isFalse);
      expect(shouldCopy('tiger.options.yaml'), isFalse);
    });

    test('文档与构建目录不会写入', () {
      expect(shouldCopy('docs/guide.md'), isFalse);
      expect(shouldCopy('tools/make_release_delta.py'), isFalse);
      expect(shouldCopy('build/tiger.schema.yaml'), isFalse);
      expect(shouldCopy('README.md'), isFalse);
      expect(shouldCopy('手机精简版/tiger.yaml'), isFalse);
    });
  });

  group('本地版本号', () {
    test('优先读取 .cheese-tiger-version', () {
      final dir = Directory.systemTemp.createTempSync('rime-version-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, markerFile)).writeAsStringSync('0.3.23\n');
      expect(readLocalVersion(dir.path), '0.3.23');
    });

    test('没有标记时退回 CHANGELOG', () {
      final dir = Directory.systemTemp.createTempSync('rime-changelog-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'CHANGELOG.md'))
          .writeAsStringSync('## v0.3.23（2026-11-04）\n- 更新\n');
      expect(readLocalVersion(dir.path), '0.3.23');
    });
  });
}
