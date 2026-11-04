import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings_store.dart';

const _userDataFiles = {
  'user.yaml',
  'installation.yaml',
  'reverse_freq.txt',
  'custom_phrase.txt',
};

const _runtimeDirs = ['lua', 'opencc', 'models', 'dicts', 'tiger_dicts', 'zuci', 'build'];

const _luaStats = [
  'lua/kc_count.txt',
  'lua/kc_total.txt',
  'lua/kc_last.txt',
  'lua/quote.txt',
];

class SwitchBackup {
  const SwitchBackup({required this.directory, required this.files, required this.target});

  final String directory;
  final List<String> files;
  final String target;
}

String get switchBackupRoot =>
    p.join(p.dirname(settingsFilePath), 'switch-backups');

String _stamp() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

bool _isUserDataFile(String name) {
  return name.endsWith('.custom.yaml') ||
      name.endsWith('.options.yaml') ||
      _userDataFiles.contains(name);
}

/// 收集需要保留的个人数据（相对路径，可能是文件或 *.userdb 目录）。
List<String> collectUserData(String target) {
  final dir = Directory(target);
  if (!dir.existsSync()) return const [];

  final result = <String>[];
  for (final entity in dir.listSync()) {
    final name = p.basename(entity.path);
    if (entity is File &&
        (_isUserDataFile(name) ||
            (name.startsWith('自学习-') && name.endsWith('.txt')))) {
      result.add(name);
    } else if (entity is Directory && name.endsWith('.userdb')) {
      result.add(name);
    }
  }
  for (final rel in _luaStats) {
    if (File(p.join(target, rel)).existsSync()) result.add(rel);
  }
  final lua = Directory(p.join(target, 'lua'));
  if (lua.existsSync()) {
    for (final entity in lua.listSync()) {
      final name = p.basename(entity.path);
      if (name.startsWith('input_stats_') && name.endsWith('.lua')) {
        result.add('lua/$name');
      }
      if (entity is Directory && name.endsWith('.userdb')) {
        result.add('lua/$name');
      }
    }
  }
  return result;
}

/// 把个人数据复制到应用支持目录，返回备份信息。
SwitchBackup backupUserData(
  String target, {
  required String label,
  required void Function(String line) log,
  String? destinationRoot,
}) {
  final stamp = _stamp();
  final safeLabel = label.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_');
  final dest = p.join(destinationRoot ?? switchBackupRoot, stamp, safeLabel);
  Directory(dest).createSync(recursive: true);

  final files = collectUserData(target);
  for (final rel in files) {
    final src = p.join(target, rel);
    final dst = p.join(dest, rel);
    if (FileSystemEntity.isDirectorySync(src)) {
      _copyDirectory(Directory(src), Directory(dst));
    } else if (File(src).existsSync()) {
      File(dst).parent.createSync(recursive: true);
      File(src).copySync(dst);
    }
    log('  备份 $rel');
  }

  final manifest = File(p.join(dest, 'manifest.json'));
  manifest.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'stamp': stamp,
      'target': target,
      'label': label,
      'files': files,
    }),
  );
  log('  个人数据已备份到 $dest');
  return SwitchBackup(directory: dest, files: files, target: target);
}

void _copyDirectory(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync()) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      _copyDirectory(entity, Directory(p.join(dst.path, name)));
    } else if (entity is File) {
      entity.copySync(p.join(dst.path, name));
    }
  }
}

/// 删除旧方案的运行文件，保留个人数据、用户词库与本工具自己的备份。
void cleanScheme(String target, {required void Function(String line) log}) {
  for (final name in _runtimeDirs) {
    final dir = Directory(p.join(target, name));
    if (!dir.existsSync()) continue;
    dir.deleteSync(recursive: true);
    log('  清理 $name/');
  }

  final root = Directory(target);
  for (final entity in root.listSync()) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!name.endsWith('.yaml')) continue;
    if (_isUserDataFile(name)) continue;
    entity.deleteSync();
    log('  删除旧方案配置 $name');
  }
}

/// 新方案装完后，把备份中缺失的个人数据补回去（主要是 lua 统计文件）。
void restoreUserData(SwitchBackup backup, {required void Function(String line) log}) {
  for (final rel in backup.files) {
    final src = p.join(backup.directory, rel);
    final dst = p.join(backup.target, rel);
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) continue;
    if (FileSystemEntity.isDirectorySync(src)) {
      _copyDirectory(Directory(src), Directory(dst));
    } else if (File(src).existsSync()) {
      File(dst).parent.createSync(recursive: true);
      File(src).copySync(dst);
    }
    log('  恢复个人数据 $rel');
  }
}
