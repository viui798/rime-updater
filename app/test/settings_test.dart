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

  test('手动添加的目录会写进设置', () {
    final settings = Settings(
      customDirs: [p.join('/tmp', 'Rime'), p.join('/tmp', 'Weasel')],
      customNames: {p.join('/tmp', 'Rime'): '我的鼠须管'},
    );
    final decoded = Settings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.customDirs, settings.customDirs);
    expect(decoded.customNames, settings.customNames);
    expect(decoded.copyWith(customDirs: ['/one']).customDirs, ['/one']);
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
