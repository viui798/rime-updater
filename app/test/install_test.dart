import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/local_package.dart';
import 'package:rime_updater/core/rime_profile.dart';
import 'package:rime_updater/core/zip_installer.dart';

void cleanupDir(Directory dir) {
  addTearDown(() {
    // Windows 上 zip 读取句柄可能晚于断言释放，删除重试几次避免误报。
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        sleep(const Duration(milliseconds: 100));
      }
    }
  });
}


Digest cryptoTestSha(String content) =>
    sha256.convert(utf8.encode(content));

void main() {
  test('应用增量包、跳过用户数据、快照与回滚', () {
    final dir = Directory.systemTemp.createTempSync('rime-install-');
    cleanupDir(dir);

    File(p.join(dir.path, 'lua/db.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('OLD-DB');
    File(p.join(dir.path, 'lua/old.lua')).writeAsStringSync('OLD-OLD');
    File(p.join(dir.path, 'user.yaml')).writeAsStringSync('KEEP-USER');

    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('update/lua/db.lua', 'NEW-DB');
    add('update/lua/new.lua', 'NEW-FILE');
    add('update/user.yaml', 'SHOULD-NOT-OVERWRITE');
    add(
      'update/DELTA.json',
      jsonEncode({
        'to': '0.3.24',
        'full_required': false,
        'deletions': ['lua/old.lua'],
      }),
    );

    final zipPath = p.join(dir.path, 'delta.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    final logs = <String>[];
    final stats = applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '0.3.24',
      dryRun: false,
      snapshot: true,
      log: logs.add,
      onFile: (_, __) {},
    );

    expect(stats.copied, 2);
    expect(stats.backupStamp, isNotNull);
    expect(File(p.join(dir.path, 'lua/db.lua')).readAsStringSync(), 'NEW-DB');
    expect(File(p.join(dir.path, 'lua/new.lua')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'lua/old.lua')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'user.yaml')).readAsStringSync(), 'KEEP-USER');
    expect(readLocalVersion(dir.path), '0.3.24');

    rollback(target: dir.path, stamp: stats.backupStamp!, log: logs.add);

    expect(File(p.join(dir.path, 'lua/db.lua')).readAsStringSync(), 'OLD-DB');
    expect(File(p.join(dir.path, 'lua/new.lua')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'lua/old.lua')).readAsStringSync(), 'OLD-OLD');
    expect(readLocalVersion(dir.path), '');
  });

  test('设备模型比对：缺失/不一致/一致', () async {
    final dir = Directory.systemTemp.createTempSync('rime-model-');
    final modelFile = File(p.join(dir.path, 'models', 'sentence-fivegram-mobile.bin'));
    modelFile.createSync(recursive: true);
    modelFile.writeAsStringSync('MODEL-V2');
    void ignoreLog(String line) {}

    final good = cryptoTestSha('MODEL-V2');
    expect(await deviceModelMatches([dir.path], good.toString(), ignoreLog), isTrue);
    expect(await deviceModelMatches([dir.path], 'deadbeef', ignoreLog), isFalse);
    expect(await deviceModelMatches([dir.path], '', ignoreLog), isFalse);

    final missing = Directory.systemTemp.createTempSync('rime-model-miss-');
    expect(await deviceModelMatches([missing.path], good.toString(), ignoreLog), isFalse);
  });

  test('增量包基座不匹配会拒绝，匹配则放行', () {
    final dir = Directory.systemTemp.createTempSync('rime-base-');
    cleanupDir(dir);
    File(p.join(dir.path, 'tiger_sentence.schema.yaml')).writeAsStringSync('SCHEMA');
    File(p.join(dir.path, '.cheese-tiger-version')).writeAsStringSync('0.3.9\n');

    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('update/lua/db.lua', 'NEW-DB');
    add(
      'update/DELTA.json',
      jsonEncode({'from': 'v0.3.23', 'to': 'v0.3.24', 'deletions': <String>[]}),
    );
    final zipPath = p.join(dir.path, 'delta.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    // 底子 0.3.9 ≠ 基座 0.3.23 → 必须拒绝且不动任何文件
    expect(
      () => applyZip(
        zipPath: zipPath,
        target: dir.path,
        version: '0.3.24',
        dryRun: false,
        snapshot: true,
        log: (_) {},
        onFile: (_, __) {},
      ),
      throwsA(isA<FullPackageRequired>()),
    );
    expect(File(p.join(dir.path, 'lua/db.lua')).existsSync(), isFalse);
    expect(readLocalVersion(dir.path), '0.3.9');

    // 底子改成 0.3.23 → 放行
    File(p.join(dir.path, '.cheese-tiger-version')).writeAsStringSync('0.3.23\n');
    final logs = <String>[];
    final stats = applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '0.3.24',
      dryRun: false,
      snapshot: true,
      log: logs.add,
      onFile: (_, __) {},
    );
    expect(stats.copied, 1);
    expect(File(p.join(dir.path, 'lua/db.lua')).readAsStringSync(), 'NEW-DB');
    expect(readLocalVersion(dir.path), '0.3.24');
  });

  test('full_required 的增量包会被识别', () {
    final dir = Directory.systemTemp.createTempSync('rime-full-');
    cleanupDir(dir);

    final archive = Archive();
    final bytes = utf8.encode(jsonEncode({'full_required': true}));
    archive.addFile(ArchiveFile('update/DELTA.json', bytes.length, bytes));
    final zipPath = p.join(dir.path, 'delta.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    expect(zipRequiresFull(zipPath), isTrue);
  });

  test('从包内 DELTA.json 读取版本', () {
    final dir = Directory.systemTemp.createTempSync('rime-version-zip-');
    cleanupDir(dir);

    final archive = Archive();
    final bytes = utf8.encode(jsonEncode({'to': '0.3.24'}));
    archive.addFile(ArchiveFile('update/DELTA.json', bytes.length, bytes));
    final zipPath = p.join(dir.path, 'pkg.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    expect(readZipVersion(zipPath), '0.3.24');
    expect(versionFor(zipPath), '0.3.24');
  });

  test('能判断压缩包是否像 Rime 方案', () {
    final dir = Directory.systemTemp.createTempSync('rime-looks-');
    cleanupDir(dir);

    final archive = Archive();
    final yaml = utf8.encode('schema');
    archive.addFile(ArchiveFile('rime-ice/default.yaml', yaml.length, yaml));
    final good = p.join(dir.path, 'good.zip');
    File(good).writeAsBytesSync(ZipEncoder().encode(archive));
    expect(zipLooksLikeRime(good), isTrue);

    final other = Archive();
    final txt = utf8.encode('hello');
    other.addFile(ArchiveFile('readme.txt', txt.length, txt));
    final bad = p.join(dir.path, 'bad.zip');
    File(bad).writeAsBytesSync(ZipEncoder().encode(other));
    expect(zipLooksLikeRime(bad), isFalse);
  });

  test('推断不出时从文件名取版本', () {
    expect(versionFor('/tmp/rime-ice-v1.2.3.zip'), '1.2.3');
    expect(versionFor('/tmp/unknown.zip'), '');
  });

  test('扁平 zip 直接安装到根目录', () {
    final dir = Directory.systemTemp.createTempSync('rime-flat-');
    cleanupDir(dir);

    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('default.yaml', 'SCHEMA');
    add('lua/db.lua', 'LUA');
    add('user.yaml', 'KEEP');

    final zipPath = p.join(dir.path, 'flat.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '1.0.0',
      dryRun: false,
      snapshot: false,
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(File(p.join(dir.path, 'default.yaml')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'lua/db.lua')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'user.yaml')).existsSync(), isFalse);
  });

  test('内容相同的文件不会重复写入，也不会生成快照', () {
    final dir = Directory.systemTemp.createTempSync('rime-same-');
    cleanupDir(dir);

    File(p.join(dir.path, 'lua/db.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('SAME');

    final archive = Archive();
    final bytes = utf8.encode('SAME');
    archive.addFile(ArchiveFile('update/lua/db.lua', bytes.length, bytes));
    final zipPath = p.join(dir.path, 'same.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    final stats = applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '0.3.23',
      dryRun: false,
      snapshot: true,
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(stats.copied, 0);
    expect(stats.backupStamp, isNull);
    expect(File(p.join(dir.path, 'lua/db.lua')).readAsStringSync(), 'SAME');
    expect(
      Directory(p.join(dir.path, backupDirName)).existsSync(),
      isFalse,
    );
  });

  test('带一层方案目录的 zip 会剥掉目录前缀', () {
    final dir = Directory.systemTemp.createTempSync('rime-wrapped-');
    cleanupDir(dir);

    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('rime-ice/default.yaml', 'SCHEMA');
    add('rime-ice/lua/db.lua', 'LUA');

    final zipPath = p.join(dir.path, 'wrapped.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '1.0.0',
      dryRun: false,
      snapshot: false,
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(File(p.join(dir.path, 'default.yaml')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'lua/db.lua')).existsSync(), isTrue);
    expect(Directory(p.join(dir.path, 'rime-ice')).existsSync(), isFalse);
  });

  test('铺底只复制方案文件、保留用户数据并写入基座标记', () async {
    final root = Directory.systemTemp.createTempSync('rime-mirror-');
    cleanupDir(root);
    final src = Directory(p.join(root.path, 'source'))..createSync();
    final dst = Directory(p.join(root.path, 'target'))..createSync();

    File(p.join(src.path, 'lua/db.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('SRC-DB');
    File(p.join(src.path, 'tiger_sentence.schema.yaml'))
      .writeAsStringSync('SRC-SCHEMA');
    File(p.join(src.path, 'user.yaml')).writeAsStringSync('SRC-USER');
    File(p.join(src.path, 'lua/kc_count.txt')).writeAsStringSync('1');
    File(p.join(src.path, 'lua/kc_total.txt')).writeAsStringSync('9');
    File(p.join(src.path, '.cheese-tiger-version')).writeAsStringSync('0.3.26\n');
    File(p.join(src.path, backupDirName, 'x/manifest.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');

    File(p.join(dst.path, 'user.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('MY-USER');
    File(p.join(dst.path, 'lua/db.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('OLD-DB');
    File(p.join(dst.path, '.cheese-tiger-version'))
      .writeAsStringSync('0.3.24\n');

    final stats = await mirrorProfile(
      source: src.path,
      target: dst.path,
      version: '0.3.26',
      dryRun: false,
      snapshot: true,
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(File(p.join(dst.path, 'lua/db.lua')).readAsStringSync(), 'SRC-DB');
    expect(File(p.join(dst.path, 'tiger_sentence.schema.yaml')).existsSync(),
        isTrue);
    expect(File(p.join(dst.path, 'user.yaml')).readAsStringSync(), 'MY-USER');
    expect(File(p.join(dst.path, 'lua/kc_count.txt')).existsSync(), isFalse);
    expect(File(p.join(dst.path, 'lua/kc_total.txt')).existsSync(), isFalse);
    expect(Directory(p.join(dst.path, backupDirName)).existsSync(), isTrue);
    expect(readLocalVersion(dst.path), '0.3.26');
    expect(stats.backupStamp, isNotNull);
  });

  test('铺底预演不写文件、不改版本标记', () async {
    final root = Directory.systemTemp.createTempSync('rime-mirror-dry-');
    cleanupDir(root);
    final src = Directory(p.join(root.path, 'source'))..createSync();
    final dst = Directory(p.join(root.path, 'target'))..createSync();
    File(p.join(src.path, 'lua/new.lua'))
      ..createSync(recursive: true)
      ..writeAsStringSync('NEW');
    File(p.join(dst.path, '.cheese-tiger-version')).writeAsStringSync('0.3.24\n');

    final stats = await mirrorProfile(
      source: src.path,
      target: dst.path,
      version: '0.3.27',
      dryRun: true,
      snapshot: true,
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(File(p.join(dst.path, 'lua/new.lua')).existsSync(), isFalse);
    expect(readLocalVersion(dst.path), '0.3.24');
    expect(stats.copied, 1);
    expect(stats.backupStamp, isNull);
  });

  test('增量基座允许未知设备铺底，但拒绝版本不一致', () {
    final dir = Directory.systemTemp.createTempSync('rime-base-seed-');
    cleanupDir(dir);
    final archive = Archive();
    final bytes = utf8.encode(jsonEncode({
      'from': 'v0.3.26',
      'to': 'v0.3.27',
      'full_required': false,
      'deletions': <String>[],
    }));
    archive.addFile(ArchiveFile('update/DELTA.json', bytes.length, bytes));
    final zipPath = p.join(dir.path, 'delta.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    expect(deltaBaseUsable(zipPath, ['0.3.26', '0.3.26'], seedUnknown: true),
        isTrue);
    // 一台基座匹配 + 一台版本未知，且允许铺底 → 可用
    expect(deltaBaseUsable(zipPath, ['v0.3.26', ''], seedUnknown: true), isTrue);
    // 不允许铺底时，版本未知必须退回完整包
    expect(deltaBaseUsable(zipPath, ['v0.3.26', '']), isFalse);
    // 已知设备版本与基座不一致 → 不可用
    expect(deltaBaseUsable(zipPath, ['0.3.24', '0.3.24', ''], seedUnknown: true),
        isFalse);
    // 没有任何已知基座设备 → 无法铺底
    expect(deltaBaseUsable(zipPath, ['', ''], seedUnknown: true), isFalse);
  });

  test('预演可用 baseOverride 通过基座校验', () {
    final dir = Directory.systemTemp.createTempSync('rime-base-override-');
    cleanupDir(dir);
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('update/lua/db.lua', 'NEW-DB');
    add(
      'update/DELTA.json',
      jsonEncode({'from': 'v0.3.26', 'to': 'v0.3.27', 'deletions': <String>[]}),
    );
    final zipPath = p.join(dir.path, 'delta.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive));

    final stats = applyZip(
      zipPath: zipPath,
      target: dir.path,
      version: '0.3.27',
      dryRun: true,
      snapshot: false,
      baseOverride: 'v0.3.26',
      log: (_) {},
      onFile: (_, __) {},
    );

    expect(stats.copied, 1);
    expect(File(p.join(dir.path, 'lua/db.lua')).existsSync(), isFalse);
    expect(readLocalVersion(dir.path), '');
  });
}
