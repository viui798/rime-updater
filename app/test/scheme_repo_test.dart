import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/scheme_repo.dart';
import 'package:rime_updater/models.dart';

void main() {
  test('导入方案会复制进仓库，同名自动加序号', () async {
    final repo = Directory.systemTemp.createTempSync('scheme-repo-');
    final src = Directory.systemTemp.createTempSync('scheme-src-');
    addTearDown(() {
      repo.deleteSync(recursive: true);
      src.deleteSync(recursive: true);
    });
    final settings = Settings(cacheDir: repo.path);
    final file = File(p.join(src.path, 'cheese-tiger-v0.3.27-update.zip'))
      ..writeAsStringSync('zip');

    final first = await importScheme(settings, file.path);
    expect(p.basename(first), 'cheese-tiger-v0.3.27-update.zip');
    expect(File(first).existsSync(), isTrue);

    final second = await importScheme(settings, file.path);
    expect(p.basename(second), 'cheese-tiger-v0.3.27-update-2.zip');

    final entries = listSchemes(settings);
    expect(entries, hasLength(2));
    expect(entries.every((entry) => entry.imported), isTrue);
    expect(entries.first.version, '0.3.27');
  });

  test('清理旧包时保留导入的方案与勾选的方案', () {
    final repo = Directory.systemTemp.createTempSync('scheme-keep-');
    addTearDown(() => repo.deleteSync(recursive: true));
    final settings = Settings(
      cacheDir: repo.path,
      selectedScheme: 'chosen.zip',
    );
    File(p.join(repo.path, 'imported.zip')).writeAsStringSync('x');
    File(p.join(repo.path, '.scheme-index.json'))
        .writeAsStringSync('{"imported":["imported.zip"]}');

    final keep = schemeKeepNames(settings, {'current.zip'});
    expect(keep, containsAll(['current.zip', 'imported.zip', 'chosen.zip']));
  });
}
