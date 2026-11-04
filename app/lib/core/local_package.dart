import 'dart:io';

import 'package:path/path.dart' as p;

import 'android_platform.dart';
import 'zip_installer.dart';

/// 打开系统文件选择框，返回选中的 zip 路径；取消时返回 null。
Future<String?> pickLocalZip() => pickFile(
      prompt: '选择方案压缩包（zip）',
      windowsFilter: 'Zip 包|*.zip',
    );

/// 打开系统文件选择框，用于把单个文件加入云同步库。
Future<String?> pickSyncFile({String? initialDir}) =>
    pickFile(prompt: '选择要加入同步的文件', initialDir: initialDir);

Future<String?> pickFile({
  required String prompt,
  String? windowsFilter,
  String? initialDir,
}) async {
  try {
    if (Platform.isAndroid) return await pickAndroidFile();
    if (Platform.isMacOS) {
      final script = initialDir == null
          ? 'POSIX path of (choose file with prompt "$prompt")'
          : 'POSIX path of (choose file with prompt "$prompt" '
              'default location POSIX file "$initialDir")';
      final result = await Process.run('osascript', ['-e', script]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    }
    if (Platform.isWindows) {
      final filter = windowsFilter ?? '所有文件|*.*';
      final initial = initialDir == null
          ? ''
          : "\\\$dialog.InitialDirectory = '$initialDir'\n";
      final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Filter = '$filter'
$initial if (\$dialog.ShowDialog() -eq 'OK') { Write-Output \$dialog.FileName }
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-STA', '-Command', script],
      );
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    }
  } catch (_) {
    // 系统对话框不可用时由调用方提示手动输入路径
  }
  return null;
}

/// 打开系统目录选择框，返回选中的目录；取消时返回 null。
Future<String?> pickDirectory() async {
  try {
    if (Platform.isMacOS) {
      final result = await Process.run('osascript', [
        '-e',
        'POSIX path of (choose folder with prompt "选择 Rime 用户目录")',
      ]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    }
    if (Platform.isWindows) {
      const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = '选择 Rime 用户目录'
if ($dialog.ShowDialog() -eq 'OK') { Write-Output $dialog.SelectedPath }
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-STA', '-Command', script],
      );
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    }
  } catch (_) {
    // 系统对话框不可用时忽略
  }
  return null;
}

/// 从包内 DELTA.json 或文件名推断版本号，推断不出时返回空字符串。
String versionFor(String zipPath) {
  final fromZip = readZipVersion(zipPath);
  if (fromZip.isNotEmpty) return fromZip;
  final name = p.basename(zipPath);
  final match = RegExp(r'v?(\d+\.\d+(?:\.\d+)?)').firstMatch(name);
  return match?.group(1) ?? '';
}
