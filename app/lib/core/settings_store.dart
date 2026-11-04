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

String get defaultCacheDir {
  if (Platform.isAndroid) {
    return p.join(Directory.systemTemp.path, 'cheese-tiger');
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
