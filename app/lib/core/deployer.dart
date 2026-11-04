import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';

void _run(String program, List<String> args, void Function(String) log) {
  log('  \$ $program${args.isEmpty ? '' : ' ${args.join(' ')}'}');
  try {
    final result = Process.runSync(program, args);
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

bool _weaselPaths(void Function(String) log) {
  const key = r'HKLM\SOFTWARE\WOW6432Node\Rime\Weasel';
  final root = _registryValue(key, 'WeaselRoot');
  final exe = _registryValue(key, 'ServerExecutable');
  String server;
  String deployer;
  if (root.isNotEmpty && exe.isNotEmpty) {
    server = p.join(root, exe);
    deployer = p.join(p.dirname(server), 'WeaselDeployer.exe');
  } else {
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    server = p.join(local, 'Programs/Rime/weasel-x64/WeaselServer.exe');
    deployer = p.join(local, 'Programs/Rime/weasel-x64/WeaselDeployer.exe');
  }
  if (!File(server).existsSync()) {
    log('  提示：未找到 WeaselServer.exe，请手动重新部署');
    return false;
  }
  _run(server, ['/q'], log);
  if (File(deployer).existsSync()) {
    _run(deployer, ['/deploy'], log);
  } else {
    log('  提示：未找到 WeaselDeployer.exe，请手动重新部署');
  }
  Process.start(server, const [], mode: ProcessStartMode.detached);
  return true;
}

void deployProfile(
  Profile profile, {
  required bool restart,
  required void Function(String line) log,
}) {
  if (Platform.isMacOS) {
    if (profile.kind == 'squirrel') {
      const squirrel = '/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel';
      if (File(squirrel).existsSync()) {
        _run(squirrel, ['--reload'], log);
        return;
      }
      const deployer =
          '/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer';
      const shared =
          '/Library/Input Methods/Squirrel.app/Contents/SharedSupport';
      if (File(deployer).existsSync()) {
        _run(deployer, ['--build', profile.path, shared], log);
      } else {
        log('  提示：未找到鼠须管部署程序，请手动重新部署');
      }
      return;
    }
    if (profile.kind == 'fcitx5') {
      const curl = '/Library/Input Methods/Fcitx5.app/Contents/bin/fcitx5-curl';
      if (File(curl).existsSync()) {
        _run(
          curl,
          ['/config/addon/rime/deploy', '-X', 'POST', '-d', '{}'],
          log,
        );
        return;
      }
      if (restart) {
        _run('killall', ['Fcitx5'], log);
        _run('open', ['/Library/Input Methods/Fcitx5.app'], log);
      } else {
        log('  提示：未找到 fcitx5-curl，请手动重新部署');
      }
      return;
    }
    if (profile.kind == 'cobra') {
      if (restart) {
        _run('killall', ['Cobra'], log);
        _run('open', ['/Library/Input Methods/Cobra.app'], log);
      } else {
        log('  提示：元书需要重新部署，或勾选“部署后重启前端”');
      }
      return;
    }
  } else if (Platform.isWindows) {
    if (profile.kind == 'weasel') {
      _weaselPaths(log);
      return;
    }
  } else if (Platform.isAndroid) {
    log('  提示：请在 Trime（同文输入法）里点右上角刷新图标重新部署');
    return;
  }
  log('  提示：未知前端，请手动重新部署');
}
