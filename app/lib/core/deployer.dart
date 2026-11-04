import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';

const _weaselKey = r'HKLM\SOFTWARE\WOW6432Node\Rime\Weasel';

Future<void> _run(
  String program,
  List<String> args,
  void Function(String) log,
) async {
  log('  \$ $program${args.isEmpty ? '' : ' ${args.join(' ')}'}');
  try {
    final result = await Process.run(program, args);
    if (result.exitCode != 0) {
      log('  ! 命令退出码 ${result.exitCode}');
    }
  } catch (error) {
    log('  ! $error');
  }
}

String _registryValue(String key, String value) {
  try {
    final result = Process.runSync('reg', ['query', key, '/v', value]);
    for (final line in (result.stdout as String).split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3 &&
          parts.first.toLowerCase() == value.toLowerCase()) {
        return parts.sublist(2).join(' ');
      }
    }
  } catch (_) {
    // 注册表不可用时退回默认路径
  }
  return '';
}

/// 小狼毫（Weasel）的 WeaselServer.exe 路径；未安装时返回 null。
String? weaselServerPath() {
  final root = _registryValue(_weaselKey, 'WeaselRoot');
  final exe = _registryValue(_weaselKey, 'ServerExecutable');
  if (root.isNotEmpty && exe.isNotEmpty) {
    final server = p.join(root, exe);
    if (File(server).existsSync()) return server;
  }
  final local = Platform.environment['LOCALAPPDATA'] ?? '';
  if (local.isEmpty) return null;
  final candidates = <String>[
    p.join(local, 'Programs/Rime/weasel-x64/WeaselServer.exe'),
  ];
  final rimeRoot = Directory(p.join(local, 'Programs/Rime'));
  if (rimeRoot.existsSync()) {
    for (final entry in rimeRoot.listSync().whereType<Directory>()) {
      if (!p.basename(entry.path).startsWith('weasel')) continue;
      candidates.add(p.join(entry.path, 'WeaselServer.exe'));
    }
  }
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

String? _tigrimeIn(String home) {
  final install = File(p.join(home, 'install.json'));
  if (install.existsSync()) {
    try {
      final data = jsonDecode(install.readAsStringSync());
      if (data is Map<String, dynamic>) {
        final generation = data['generation'];
        if (generation is String && generation.isNotEmpty) {
          final path = p.join(
            home,
            'versions',
            generation,
            'shared',
            'Tigrime.Deployer.exe',
          );
          if (File(path).existsSync()) return path;
        }
      }
    } catch (_) {
      // 安装记录损坏时退回扫描版本目录
    }
  }
  final versions = Directory(p.join(home, 'versions'));
  if (!versions.existsSync()) return null;
  String? best;
  DateTime? bestAt;
  for (final entry in versions.listSync().whereType<Directory>()) {
    final path = p.join(entry.path, 'shared', 'Tigrime.Deployer.exe');
    final file = File(path);
    if (!file.existsSync()) continue;
    final at = file.lastModifiedSync();
    if (bestAt == null || at.isAfter(bestAt)) {
      best = path;
      bestAt = at;
    }
  }
  return best;
}

/// 虎韵（Tigrime）的 Tigrime.Deployer.exe 路径；未安装时返回 null。
String? tigrimeDeployerPath() {
  final roots = <String>[
    Platform.environment['ProgramFiles'] ?? '',
    Platform.environment['ProgramFiles(x86)'] ?? '',
  ];
  final local = Platform.environment['LOCALAPPDATA'] ?? '';
  if (local.isNotEmpty) roots.add(p.join(local, 'Programs'));
  for (final root in roots) {
    if (root.isEmpty) continue;
    final path = _tigrimeIn(p.join(root, 'Tigrime'));
    if (path != null) return path;
  }
  return null;
}

/// 小狼毫的用户目录：注册表记录的 RimeUserDir，退回 %APPDATA%\Rime。
String weaselUserDir() {
  final dir = _registryValue(r'HKCU\SOFTWARE\Rime\Weasel', 'RimeUserDir');
  if (dir.isNotEmpty) return p.normalize(dir);
  if (weaselServerPath() == null) return '';
  final appData = Platform.environment['APPDATA'] ?? '';
  return appData.isEmpty ? '' : p.join(appData, 'Rime');
}

/// 虎韵的用户目录：Tigrime 用自己的用户根目录 %LOCALAPPDATA%\Tigrime\Rime。
String tigrimeUserDir() {
  final local = Platform.environment['LOCALAPPDATA'] ?? '';
  if (local.isEmpty) return '';
  final path = p.join(local, 'Tigrime', 'Rime');
  return Directory(path).existsSync() ? path : '';
}

Future<void> _deployWeasel(void Function(String) log) async {
  final server = weaselServerPath();
  if (server == null) {
    log('  提示：未找到 WeaselServer.exe，请手动重新部署');
    return;
  }
  await _run(server, ['/q'], log);
  final deployer = p.join(p.dirname(server), 'WeaselDeployer.exe');
  if (File(deployer).existsSync()) {
    await _run(deployer, ['/deploy'], log);
  } else {
    log('  提示：未找到 WeaselDeployer.exe，请手动重新部署');
  }
  await Process.start(server, const [], mode: ProcessStartMode.detached);
}

Future<void> _deployTigrime(void Function(String) log) async {
  final deployer = tigrimeDeployerPath();
  if (deployer == null) {
    log('  提示：未找到 Tigrime.Deployer.exe，请手动重新部署');
    return;
  }
  log('  \$ $deployer');
  try {
    // 不带参数即完整部署：停服务、重建方案、重新拉起服务，耗时约半分钟。
    final result = await Process.run(
      deployer,
      const [],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final out = (result.stdout as String).trim();
    if (out.isNotEmpty) log('  $out');
    if (result.exitCode != 0) {
      log('  ! 部署退出码 ${result.exitCode}，请手动重新部署');
    }
  } catch (error) {
    log('  ! $error');
  }
}

Future<void> deployProfile(
  Profile profile, {
  required bool restart,
  required void Function(String line) log,
}) async {
  if (Platform.isMacOS) {
    if (profile.kind == 'squirrel') {
      const squirrel = '/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel';
      if (File(squirrel).existsSync()) {
        await _run(squirrel, ['--reload'], log);
        return;
      }
      const deployer =
          '/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer';
      const shared =
          '/Library/Input Methods/Squirrel.app/Contents/SharedSupport';
      if (File(deployer).existsSync()) {
        await _run(deployer, ['--build', profile.path, shared], log);
      } else {
        log('  提示：未找到鼠须管部署程序，请手动重新部署');
      }
      return;
    }
    if (profile.kind == 'fcitx5') {
      const curl = '/Library/Input Methods/Fcitx5.app/Contents/bin/fcitx5-curl';
      if (File(curl).existsSync()) {
        await _run(
          curl,
          ['/config/addon/rime/deploy', '-X', 'POST', '-d', '{}'],
          log,
        );
        return;
      }
      if (restart) {
        await _run('killall', ['Fcitx5'], log);
        await _run('open', ['/Library/Input Methods/Fcitx5.app'], log);
      } else {
        log('  提示：未找到 fcitx5-curl，请手动重新部署');
      }
      return;
    }
    if (profile.kind == 'cobra') {
      if (restart) {
        await _run('killall', ['Cobra'], log);
        await _run('open', ['/Library/Input Methods/Cobra.app'], log);
      } else {
        log('  提示：元书需要重新部署，或勾选“部署后重启前端”');
      }
      return;
    }
  } else if (Platform.isWindows) {
    if (profile.kind == 'weasel') {
      await _deployWeasel(log);
      return;
    }
    if (profile.kind == 'tigrime') {
      await _deployTigrime(log);
      return;
    }
  } else if (Platform.isAndroid) {
    log('  提示：请在 Trime（同文输入法）里点右上角刷新图标重新部署');
    return;
  }
  log('  提示：未知前端，请手动重新部署');
}
