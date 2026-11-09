import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/android_profiles.dart';
import 'package:rime_updater/core/rime_profile.dart';

void main() {
  test('change plan preserves unchanged user data and guards every mutation',
      () {
    final plan = directoryChanges(
      {'old.yaml': 'a', 'delete.yaml': 'b', 'words.userdb/0001': 'user'},
      {'old.yaml': 'c', 'new.yaml': 'd', 'words.userdb/0001': 'user'},
    );
    expect(plan['expected'],
        {'delete.yaml': 'b', 'new.yaml': null, 'old.yaml': 'a'});
    expect(plan['writes'], ['new.yaml', 'old.yaml']);
  });
  test('recognizes arbitrary schemas and manually confirmed empty directories',
      () async {
    final root = await Directory.systemTemp.createTemp('rime-profiles-');
    try {
      expect(looksLikeRimeDir(root.path), false);
      expect(profilesFromPaths([root.path], allowUnrecognized: true),
          hasLength(1));
      await File('${root.path}/luna_pinyin.schema.yaml')
          .writeAsString('schema: {}');
      expect(looksLikeRimeDir(root.path), true);
      final before = await directoryDigests(root.path);
      await File('${root.path}/luna_pinyin.schema.yaml')
          .writeAsString('schema: changed');
      final after = await directoryDigests(root.path);
      expect(directoryChanges(before, after)['writes'],
          ['luna_pinyin.schema.yaml']);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('finds public frontend folders without scanning unrelated storage',
      () async {
    final root = await Directory.systemTemp.createTemp('public-rime-');
    try {
      final user = Directory('${root.path}/Hamster/rime')
        ..createSync(recursive: true);
      File('${user.path}/default.yaml').writeAsStringSync('config: {}');
      final unrelated = Directory('${root.path}/Downloads')..createSync();
      File('${unrelated.path}/tiger.schema.yaml')
          .writeAsStringSync('schema: {}');
      expect(
          detectAndroidPublicProfiles(root.path)
              .map((item) => p.normalize(item.path)),
          [p.normalize(user.path)]);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('finds known public paths and targets schema folders only once',
      () async {
    final root = await Directory.systemTemp.createTemp('extra-frontends-');
    try {
      for (final rel in [
        'Android/rime',
        'Documents/rime/schemas/芝士虎整',
        'Documents/rime/schemas/另一个方案'
      ]) {
        final dir = Directory('${root.path}/$rel')..createSync(recursive: true);
        File('${dir.path}/default.yaml').writeAsStringSync('config: {}');
      }
      final profiles = detectAndroidPublicProfiles(root.path);
      expect(profiles, hasLength(3));
      expect(profiles.map((item) => p.normalize(item.path)).toSet(), {
        p.normalize('${root.path}/Android/rime'),
        p.normalize('${root.path}/Documents/rime/schemas/芝士虎整'),
        p.normalize('${root.path}/Documents/rime/schemas/另一个方案'),
      });
      // Documents/rime 只属于中文输入法2，不能标成与元书共用。
      expect(
          profiles.where((item) => item.label.startsWith('中文输入法2')), hasLength(2));
      expect(profiles.any((item) => item.label.contains('元书')), false);
      expect(profiles.any((item) => item.label.contains('共用')), false);
      expect(profiles.any((item) => item.path == '${root.path}/Documents/rime'),
          false);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
