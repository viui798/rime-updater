import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'rime_profile.dart';

String get settingsFilePath {
  if (Platform.isAndroid) {
    // Android 的临时目录在应用私有 cache 下，上一级就是 files
    return p.join(
      p.dirname(Directory.systemTemp.path),
      'files/cheese-tiger/updater-settings.json',
    );
  }
  if (Platform.isWindows) {
    return p.join(localAppDataDir, 'cheese-tiger', 'updater-settings.json');
  }
  if (Platform.isMacOS) {
    return p.join(
      homeDir,
      'Library/Application Support/CheeseTigerUpdater/settings.json',
    );
  }
  return p.join(homeDir, '.config/cheese-tiger/updater-settings.json');
}

/// 解析实际的下载缓存目录：设置里填了就用它，否则用平台默认值。
String resolveCacheDir(Settings settings) {
  final custom = settings.cacheDir.trim();
  if (custom.isNotEmpty) return custom;
  return defaultCacheDir;
}

/// Android 旧版把缓存放在可被系统回收的 cache/ 下；迁移到 files/ 后
/// 不再需要重复下载几百 MB 的完整包。这里把旧目录里的文件搬过去。
Future<void> migrateLegacyAndroidCache() async {
  if (!Platform.isAndroid) return;
  final legacy = Directory(p.join(Directory.systemTemp.path, 'cheese-tiger'));
  final target = Directory(defaultCacheDir);
  if (!legacy.existsSync()) return;
  await target.create(recursive: true);
  try {
    for (final entity in legacy.listSync()) {
      if (entity is! File) continue;
      final dest = File(p.join(target.path, p.basename(entity.path)));
      if (dest.existsSync()) continue;
      await entity.rename(dest.path);
    }
  } on FileSystemException {
    // 迁移失败不影响使用，最多重新下载一次。
  }
}

String get defaultCacheDir {
  if (Platform.isAndroid) {
    // 放在 files/ 而不是 cache/：cache 属于「可随时清空」，MIUI 等系统会主动
    // 回收，导致每次更新都重新下载几百 MB 的完整包。
    return p.join(
      p.dirname(Directory.systemTemp.path),
      'files/cheese-tiger/cache',
    );
  }
  if (Platform.isWindows) {
    return p.join(localAppDataDir, 'cheese-tiger', 'cache');
  }
  if (Platform.isMacOS) {
    return p.join(homeDir, 'Library/Caches/cheese-tiger');
  }
  return p.join(homeDir, '.cache/cheese-tiger');
}

Settings loadSettings() {
  final file = File(settingsFilePath);
  if (!file.existsSync()) return const Settings();
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) return Settings.fromJson(decoded);
  } catch (_) {
    // 配置损坏时回到默认值
  }
  return const Settings();
}

void saveSettings(Settings settings) {
  final file = File(settingsFilePath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(settings.toJson()),
  );
}
