import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/rime_profile.dart';
import 'package:rime_updater/main.dart';
import 'package:rime_updater/models.dart';

void main() {
  _renameTests();
  _shizukuLabelTests();
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

  group('clearRimeDir 清空目录', () {
    test('删除全部内容但保留目录与工具标记', () {
      final dir = Directory.systemTemp.createTempSync('rime-clear-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'tiger.schema.yaml')).writeAsStringSync('x');
      File(p.join(dir.path, 'user.yaml')).writeAsStringSync('x');
      File(p.join(dir.path, markerFile)).writeAsStringSync('0.3.23\n');
      Directory(p.join(dir.path, 'build')).createSync();
      Directory(p.join(dir.path, backupDirName)).createSync();
      Directory(p.join(dir.path, 'foo.userdb')).createSync();
      final removed =
          clearRimeDir(dir.path, log: (line) {});
      expect(removed, 4);
      // 目录本身仍在
      expect(Directory(dir.path).existsSync(), isTrue);
      // 方案与个人文件、build、userdb 都被删除
      expect(File(p.join(dir.path, 'tiger.schema.yaml')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'user.yaml')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'build')).existsSync(), isFalse);
      expect(Directory(p.join(dir.path, 'foo.userdb')).existsSync(), isFalse);
      // 工具标记与备份保留
      expect(File(p.join(dir.path, markerFile)).existsSync(), isTrue);
      expect(Directory(p.join(dir.path, backupDirName)).existsSync(), isTrue);
    });

    test('目录不存在时返回 0', () {
      final dir = Directory.systemTemp.createTempSync('rime-clear-miss-');
      final missing = p.join(dir.path, 'nope');
      expect(clearRimeDir(missing, log: (line) {}), 0);
      dir.deleteSync(recursive: true);
    });
  });
}

void _renameTests() {
  test('重命名对自动识别与 SAF 设备都生效', () {
    final profiles = [
      const Profile(label: '鼠须管', path: '/Users/a/Library/Rime', kind: 'squirrel'),
      const Profile(label: '元书', path: 'content://root', kind: 'saf', safUri: 'content://root'),
      const Profile(label: '小狼毫', path: '/AppData/Rime', kind: 'weasel'),
    ];
    final renamed = applyCustomNames(profiles, {
      '/Users/a/Library/Rime': '我的鼠须管',
      'content://root': '  元书（手机）  ',
      '/AppData/Rime': '   ',
    });

    expect(renamed[0].label, '我的鼠须管');
    // 空白名称忽略，保留原名
    expect(renamed[1].label, '元书（手机）');
    expect(renamed[2].label, '小狼毫');
    // 其他字段必须原样保留
    expect(renamed[1].safUri, 'content://root');
    expect(renamed[0].kind, 'squirrel');
  });

  test('没有自定义名称时原样返回', () {
    final profiles = [
      const Profile(label: '鼠须管', path: '/a', kind: 'squirrel'),
    ];
    expect(applyCustomNames(profiles, const {}), same(profiles));
  });
}

void _shizukuLabelTests() {
  test('Shizuku 按钮文案随连接状态变化', () {
    expect(shizukuActionLabel(granted: true, running: true), '已连接 Shizuku');
    // 已授权时即使 running 标记异常也应显示「已连接」
    expect(shizukuActionLabel(granted: true, running: false), '已连接 Shizuku');
    expect(shizukuActionLabel(granted: false, running: true), '授权 Shizuku');
    expect(shizukuActionLabel(granted: false, running: false), '连接 Shizuku');
  });

  test('Shizuku 状态说明不重复且区分三种情况', () {
    final granted = shizukuStatusText(granted: true, running: true);
    final running = shizukuStatusText(granted: false, running: true);
    final stopped = shizukuStatusText(granted: false, running: false);
    expect(granted, contains('已连接'));
    expect(granted, isNot(contains('尚未授权')));
    expect(running, contains('尚未授权'));
    expect(stopped, contains('尚未启动'));
    expect({granted, running, stopped}, hasLength(3));
  });
}
