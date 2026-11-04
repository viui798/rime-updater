// 诊断用脚本，直接打印到终端
// ignore_for_file: avoid_print

import 'package:rime_updater/core/package_preparer.dart';
import 'package:rime_updater/core/rime_profile.dart';
import 'package:rime_updater/core/settings_store.dart';
import 'package:rime_updater/core/zip_installer.dart';

Future<void> main() async {
  final settings = loadSettings();
  final profiles = detectProfiles();
  print('识别到 ${profiles.length} 个目录：');
  for (final profile in profiles) {
    print('  ${profile.label} ${profile.path} 当前=${readLocalVersion(profile.path)}');
  }
  if (profiles.isEmpty) return;

  final package = await preparePackage(
    settings: settings,
    installedVersions:
        profiles.map((profile) => readLocalVersion(profile.path)).toList(),
    profilePaths: profiles.map((profile) => profile.path).toList(),
    log: print,
    progress: (percent) => print('  进度 $percent%'),
  );
  print('包：${package.assetName} v${package.version} 增量=${package.isDelta}');

  final target = profiles.first;
  final stats = applyZip(
    zipPath: package.zipPath,
    target: target.path,
    version: package.version,
    dryRun: true,
    snapshot: false,
    log: print,
    onFile: (_, __) {},
  );
  print('预演结果：更新 ${stats.copied} 个，跳过 ${stats.skipped} 个');
}
