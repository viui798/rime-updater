import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/rime_profile.dart';
import 'package:rime_updater/models.dart';

void main() {
  test('只接受存在且看起来像 Rime 的目录', () {
    final rimeDir = Directory.systemTemp.createTempSync('rime-manual-');
    final plainDir = Directory.systemTemp.createTempSync('plain-');
    addTearDown(() {
      rimeDir.deleteSync(recursive: true);
      plainDir.deleteSync(recursive: true);
    });

    File(p.join(rimeDir.path, 'tiger.schema.yaml')).writeAsStringSync('x');
    final profiles = profilesFromPaths([
      rimeDir.path,
      plainDir.path,
      '/not/exist/rime',
    ]);

    expect(profiles.length, 1);
    expect(profiles.single.path, p.normalize(rimeDir.path));
    expect(profiles.single.kind, 'unknown');
  });

  test('手动添加的目录与隐藏目录会写进设置', () {
    final settings = Settings(
      customDirs: [p.join('/tmp', 'Rime'), p.join('/tmp', 'Weasel')],
      customNames: {p.join('/tmp', 'Rime'): '我的鼠须管'},
      hiddenDirs: [p.join('/tmp', 'old-ime')],
    );
    final decoded = Settings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.customDirs, settings.customDirs);
    expect(decoded.customNames, settings.customNames);
    expect(decoded.hiddenDirs, settings.hiddenDirs);
    expect(decoded.copyWith(customDirs: ['/one']).customDirs, ['/one']);
    expect(decoded.copyWith(hiddenDirs: ['/two']).hiddenDirs, ['/two']);
  });

  test('SAF 目录会随设置保存与读取', () {
    final settings = Settings(
      safDirs: [
        {
          'uri': 'content://com.ihsiao.apps.hamster.documents/tree/x',
          'label': '元书',
          'root': 'content://root',
          'sub': 'cheese-tiger-v0',
        }
      ],
    );
    final decoded = Settings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.safDirs, hasLength(1));
    expect(decoded.safDirs.single['label'], '元书');
    // copyWith 不应丢字段
    expect(decoded.copyWith(token: 't').safDirs, decoded.safDirs);
  });

  test('自定义名称会替换目录名作为显示名', () {
    final rimeDir = Directory.systemTemp.createTempSync('rime-named-');
    addTearDown(() => rimeDir.deleteSync(recursive: true));
    File(p.join(rimeDir.path, 'default.custom.yaml')).writeAsStringSync('x');

    final profiles = profilesFromPaths(
      [rimeDir.path],
      names: {p.normalize(rimeDir.path): '工作机'},
    );
    expect(profiles.single.label, '工作机');

    final fallback = profilesFromPaths([rimeDir.path]);
    expect(fallback.single.label, p.basename(rimeDir.path));
  });
}
