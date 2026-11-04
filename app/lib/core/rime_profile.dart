import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'deployer.dart';

const markerFile = '.cheese-tiger-version';
const backupDirName = '.cheese-tiger-backup';
const bigModel = 'models/sentence-fivegram-mobile.bin';
const backupMaxBytes = 32 * 1024 * 1024;

/// Trime（同文输入法）默认的用户目录。
const androidRimeDir = '/storage/emulated/0/rime';

const runtimeDirs = [
  'lua/',
  'opencc/',
  'models/',
  'dicts/',
  'tiger_dicts/',
  'zuci/'
];
const excludeDirs = [
  'tools/',
  'docs/',
  'sync/',
  'validation/',
  '手机精简版/',
  'build/'
];
const excludeNames = {
  'AGENTS.md',
  'README.md',
  'CHANGELOG.md',
  'LICENSE',
  '安装说明.txt',
  '安装与更新说明.txt',
  'RELEASE.json',
  'SHA256SUMS.txt',
  'SOURCE_BASELINE.md',
  'RIME_CORRECTNESS.md',
  'IOS_TEST_README.md',
};
const userDataFiles = {
  'user.yaml',
  'installation.yaml',
  'reverse_freq.txt',
  'custom_phrase.txt',
};
const userDataSuffixes = [
  '.userdb',
  '.options.yaml',
  '.log',
  '.md',
  '.zip',
  '.sha256',
];
const userDataLua = {'kc_count.txt', 'kc_total.txt'};

String get homeDir {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? '';
  }
  return Platform.environment['HOME'] ?? '';
}

String get appDataDir => Platform.environment['APPDATA'] ?? '';

String get localAppDataDir => Platform.environment['LOCALAPPDATA'] ?? '';

bool looksLikeRimeDir(String path) {
  for (final name in const [
    'tiger_sentence.schema.yaml',
    'tiger.schema.yaml',
    'default.custom.yaml',
    'rime.lua',
    'installation.yaml',
  ]) {
    if (File(p.join(path, name)).existsSync()) return true;
  }
  try {
    return Directory(path).listSync(followLinks: false).whereType<File>().any(
        (file) =>
            p.basename(file.path).endsWith('.schema.yaml') ||
            p.basename(file.path) == 'default.yaml');
  } on FileSystemException {
    return false;
  }
}

List<Profile> detectProfiles({List<String> hidden = const []}) {
  final profiles = <Profile>[];
  final seen = <String>{};
  final skipped = hidden.map(p.normalize).toSet();

  void add(String label, String path, String kind) {
    final clean = p.normalize(path);
    if (skipped.contains(clean)) return;
    if (!Directory(clean).existsSync()) return;
    if (!looksLikeRimeDir(clean)) return;
    if (!seen.add(clean)) return;
    profiles.add(Profile(label: label, path: clean, kind: kind));
  }

  if (Platform.isMacOS) {
    add('鼠须管', p.join(homeDir, 'Library/Rime'), 'squirrel');
    add('小企鹅', p.join(homeDir, '.local/share/fcitx5/rime'), 'fcitx5');
    add(
      '元书',
      p.join(
        homeDir,
        'Library/Application Support/com.ihsiao.inputmethod.Cobra/RimeUserData',
      ),
      'cobra',
    );
  } else if (Platform.isAndroid) {
    for (final profile in detectAndroidPublicProfiles('/storage/emulated/0')) {
      add(profile.label, profile.path, profile.kind);
    }
    // Android/data 通过 Shizuku 单独探测，普通文件权限无法访问。
  } else if (Platform.isWindows) {
    // 小狼毫用 %APPDATA%\Rime（由注册表记录），虎韵用自己的
    // %LOCALAPPDATA%\Tigrime\Rime，两者用户目录并不相同。
    final weaselDir = weaselUserDir();
    final tigrimeDir = tigrimeUserDir();
    if (weaselDir.isNotEmpty) add('小狼毫', weaselDir, 'weasel');
    if (tigrimeDir.isNotEmpty) add('虎韵', tigrimeDir, 'tigrime');

    for (final root in [appDataDir, localAppDataDir]) {
      if (root.isEmpty || !Directory(root).existsSync()) continue;
      _scanWindows(root, 1, (found) {
        // 跳过已识别目录的子目录（如 Rime/build）。
        for (final profile in profiles) {
          if (p.isWithin(profile.path, found)) return;
        }
        if (p.basename(found) == 'build') return;
        final kind =
            found.toLowerCase().contains('tigrime') ? 'tigrime' : 'unknown';
        add(p.basename(found), found, kind);
      });
    }
  }
  return profiles;
}

/// Scan only input-method-named public folders, never Android/data, downloads,
/// backups or the whole shared storage tree. Custom paths can be added manually.
List<Profile> detectAndroidPublicProfiles(String storageRoot) {
  final profiles = <Profile>[];
  final seen = <String>{};
  void add(String label, String path) {
    final clean = p.normalize(path);
    if (!looksLikeRimeDir(clean) || !seen.add(clean.toLowerCase())) return;
    profiles.add(Profile(label: label, path: clean, kind: 'trime'));
  }

  // These frontends use public folders outside the usual top-level rime path.
  // 中文输入法2 and 元书 share one directory, so it must be updated only once.
  add('中文输入法', p.join(storageRoot, 'Android', 'rime'));
  final shared = p.join(storageRoot, 'Documents', 'rime');
  const sharedLabel = '中文输入法2 / 元书（共用）';
  if (looksLikeRimeDir(shared)) {
    add(sharedLabel, shared);
  } else {
    // Multi-scheme frontends store runnable Rime directories under schemas/.
    for (final container in [shared, p.join(shared, 'schemas')]) {
      try {
        for (final entry in Directory(container)
            .listSync(followLinks: false)
            .whereType<Directory>()) {
          if (const {
            'build',
            'conf',
            'themes',
            'themes_disabled',
            'scripts',
            'logs',
            'sync'
          }.contains(p.basename(entry.path))) {
            continue;
          }
          add('$sharedLabel · ${p.basename(entry.path)}', entry.path);
        }
      } on FileSystemException {/* Container may not exist yet. */}
    }
  }
  try {
    final root = Directory(storageRoot);
    if (!root.existsSync()) return profiles;
    for (final entry
        in root.listSync(followLinks: false).whereType<Directory>()) {
      final name = p.basename(entry.path);
      if (!RegExp(r'rime|trime|hamster|fcitx|tigertyper', caseSensitive: false)
          .hasMatch(name)) {
        continue;
      }
      for (final path in [
        entry.path,
        p.join(entry.path, 'rime'),
        p.join(entry.path, 'Rime')
      ]) {
        if (looksLikeRimeDir(path)) {
          add('公共目录 · $name', path);
          break;
        }
      }
    }
  } on FileSystemException {/* Permission may still be awaiting approval. */}
  return profiles;
}

void _scanWindows(
  String path,
  int depth,
  void Function(String path) onFound,
) {
  if (depth > 4) return;
  Directory dir;
  try {
    dir = Directory(path);
    if (!dir.existsSync()) return;
  } on FileSystemException {
    return;
  }

  if (looksLikeRimeDir(path)) onFound(path);

  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    return;
  }

  for (final entry in entries) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    if (name == 'Cache' ||
        name == 'Code Cache' ||
        name == 'GPUCache' ||
        name == 'logs') {
      continue;
    }
    _scanWindows(entry.path, depth + 1, onFound);
  }
}

List<Profile> profilesFromPaths(
  List<String> paths, {
  Map<String, String> names = const {},
  bool allowUnrecognized = false,
}) {
  final profiles = <Profile>[];
  final seen = <String>{};
  for (final raw in paths) {
    final path = p.normalize(raw.trim());
    if (path.isEmpty || !Directory(path).existsSync()) continue;
    if (!allowUnrecognized && !looksLikeRimeDir(path)) continue;
    if (!seen.add(path)) continue;
    final label = names[path]?.trim();
    profiles.add(Profile(
      label: label != null && label.isNotEmpty ? label : p.basename(path),
      path: path,
      kind: 'unknown',
    ));
  }
  return profiles;
}

String readLocalVersion(String dir) {
  final marker = File(p.join(dir, markerFile));
  if (marker.existsSync()) {
    final text = marker.readAsStringSync().trim();
    if (text.isNotEmpty) {
      return text.startsWith('v') ? text.substring(1) : text;
    }
  }
  final changelog = File(p.join(dir, 'CHANGELOG.md'));
  if (changelog.existsSync()) {
    for (final line in changelog.readAsLinesSync()) {
      if (line.startsWith('## v')) {
        var version = line.substring(3).split('（').first.trim();
        if (version.startsWith('v')) version = version.substring(1);
        return version.trim();
      }
    }
  }
  return '';
}

bool shouldCopy(String rel, {int size = 0, String target = ''}) {
  final name = p.basename(rel);

  for (final dir in excludeDirs) {
    if (rel.startsWith(dir)) return false;
  }
  if (excludeNames.contains(name)) return false;

  for (final part in rel.split('/')) {
    if (part.endsWith('.userdb')) return false;
  }
  if (userDataFiles.contains(name)) return false;
  for (final suffix in userDataSuffixes) {
    if (name.endsWith(suffix)) return false;
  }
  if (name.endsWith('.md')) return false;

  final parts = rel.split('/');
  if (parts.length == 2 && parts.first == 'lua') {
    if (name.startsWith('input_stats_') && name.endsWith('.lua')) return false;
    if (userDataLua.contains(name)) return false;
  }

  for (final dir in runtimeDirs) {
    if (rel.startsWith(dir)) {
      if (rel == bigModel && size > 0 && target.isNotEmpty) {
        final existing = File(p.join(target, bigModel));
        if (existing.existsSync() && existing.lengthSync() == size) {
          return false;
        }
      }
      return true;
    }
  }
  return name.endsWith('.yaml') ||
      name.endsWith('.txt') ||
      name.endsWith('.json') ||
      name.endsWith('.lua');
}

/// 删除某个用户目录下的全部快照，返回删除的份数。
int clearBackups(String dir) {
  final root = Directory(p.join(dir, backupDirName));
  if (!root.existsSync()) return 0;
  final count = root
      .listSync()
      .whereType<Directory>()
      .where((entry) => !p.basename(entry.path).startsWith('.'))
      .length;
  root.deleteSync(recursive: true);
  return count;
}

List<BackupInfo> listBackups(String dir) {
  final root = Directory(p.join(dir, backupDirName));
  if (!root.existsSync()) return const [];

  final children = root.listSync().whereType<Directory>().toList()
    ..sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));

  final items = <BackupInfo>[];
  for (final child in children) {
    final manifest = File(p.join(child.path, 'manifest.json'));
    var version = '';
    var previous = '';
    var overwritten = 0;
    var created = 0;
    var deleted = 0;
    if (manifest.existsSync()) {
      try {
        final data = _decodeJson(manifest.readAsStringSync());
        version = data['version'] as String? ?? '';
        previous = data['previous_version'] as String? ?? '';
        overwritten = (data['overwritten'] as List?)?.length ?? 0;
        created = (data['created'] as List?)?.length ?? 0;
        deleted = (data['deleted'] as List?)?.length ?? 0;
      } catch (_) {
        // 损坏的 manifest 只展示时间戳
      }
    }
    items.add(
      BackupInfo(
        stamp: p.basename(child.path),
        version: version,
        previousVersion: previous,
        overwritten: overwritten,
        created: created,
        deleted: deleted,
      ),
    );
  }
  return items;
}

Map<String, dynamic> _decodeJson(String text) {
  final decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) return decoded;
  return <String, dynamic>{};
}
