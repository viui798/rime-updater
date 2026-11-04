import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/scheme_switcher.dart';

void main() {
  test('换方案：备份个人数据、清理旧文件、恢复统计', () {
    final dir = Directory.systemTemp.createTempSync('rime-switch-');
    addTearDown(() => dir.deleteSync(recursive: true));

    File(p.join(dir.path, 'user.yaml')).writeAsStringSync('user');
    File(p.join(dir.path, 'tiger.custom.yaml')).writeAsStringSync('custom');
    File(p.join(dir.path, 'default.yaml')).writeAsStringSync('old');
    File(p.join(dir.path, 'tiger.schema.yaml')).writeAsStringSync('old');
    File(p.join(dir.path, 'lua/db.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('lua');
    File(p.join(dir.path, 'lua/kc_count.txt')).writeAsStringSync('123');
    Directory(p.join(dir.path, 'opencc')).createSync(recursive: true);
    File(p.join(dir.path, 'opencc/emoji.json')).writeAsStringSync('{}');
    Directory(p.join(dir.path, 'build')).createSync(recursive: true);
    Directory(p.join(dir.path, 'lily.userdb')).createSync(recursive: true);
    File(p.join(dir.path, 'lily.userdb/data.mdb')).writeAsStringSync('db');

    final collected = collectUserData(dir.path);
    expect(collected, contains('user.yaml'));
    expect(collected, contains('tiger.custom.yaml'));
    expect(collected, contains('lily.userdb'));
    expect(collected, contains('lua/kc_count.txt'));
    expect(collected, isNot(contains('default.yaml')));

    final backupRoot = Directory.systemTemp.createTempSync('rime-switch-backup-');
    addTearDown(() => backupRoot.deleteSync(recursive: true));

    final backup = backupUserData(
      dir.path,
      label: '鼠须管',
      log: (_) {},
      destinationRoot: backupRoot.path,
    );
    expect(Directory(backup.directory).existsSync(), isTrue);
    expect(File(p.join(backup.directory, 'lua/kc_count.txt')).existsSync(), isTrue);

    cleanScheme(dir.path, log: (_) {});
    expect(Directory(p.join(dir.path, 'lua')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'opencc')).existsSync(), isFalse);
    expect(Directory(p.join(dir.path, 'build')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'default.yaml')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'tiger.schema.yaml')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'user.yaml')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'tiger.custom.yaml')).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'lily.userdb')).existsSync(), isTrue);

    restoreUserData(backup, log: (_) {});
    expect(File(p.join(dir.path, 'lua/kc_count.txt')).readAsStringSync(), '123');
    expect(File(p.join(dir.path, 'user.yaml')).existsSync(), isTrue);
  });
}
