import 'dart:io';

import 'package:flutter/material.dart';

import '../core/local_package.dart';

class LocalPackageOptions {
  const LocalPackageOptions({required this.path, required this.version});

  final String path;
  final String version;
}

class LocalZipDialog extends StatefulWidget {
  const LocalZipDialog({super.key, required this.deviceCount});

  final int deviceCount;

  @override
  State<LocalZipDialog> createState() => _LocalZipDialogState();
}

class _LocalZipDialogState extends State<LocalZipDialog> {
  final TextEditingController _path = TextEditingController();
  final TextEditingController _version = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    _version.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final path = await pickLocalZip();
    if (path == null) return;
    setState(() {
      _path.text = path;
      if (_version.text.trim().isEmpty) {
        _version.text = versionFor(path);
      }
    });
  }

  void _submit() {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请先选择 zip 文件');
      return;
    }
    if (!File(path).existsSync()) {
      setState(() => _error = '找不到文件：$path');
      return;
    }
    if (!path.toLowerCase().endsWith('.zip')) {
      setState(() => _error = '目前只支持 zip 格式');
      return;
    }
    var version = _version.text.trim();
    if (version.isEmpty) version = 'local';
    if (version.startsWith('v')) version = version.substring(1);
    Navigator.pop(context, LocalPackageOptions(path: path, version: version));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('从本地 zip 安装'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将把压缩包里的方案文件安装到当前勾选的 ${widget.deviceCount} 个设备，'
                '个人数据（词库、开关记忆）不会被覆盖。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: '压缩包路径',
                  hintText: '/Users/…/rime-ice.zip',
                  errorText: _error,
                  suffixIcon: IconButton(
                    tooltip: '选择文件',
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _version,
                decoration: const InputDecoration(
                  labelText: '版本号（可选）',
                  hintText: '例如 1.0.0',
                  helperText: '会显示在设备列表里；留空则记为 local',
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '换成完全不同的方案时，建议先清空旧方案的运行文件，'
                  '否则新旧方案可能混在一起。个人数据不受影响。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始安装')),
      ],
    );
  }
}
