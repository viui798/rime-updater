import 'dart:io';

import 'package:flutter/material.dart';

import '../core/local_package.dart';
import 'dialog_size.dart';
import '../core/scheme_switcher.dart';
import 'local_zip_dialog.dart';

class SwitchSchemeDialog extends StatefulWidget {
  const SwitchSchemeDialog({super.key, required this.deviceCount});

  final int deviceCount;

  @override
  State<SwitchSchemeDialog> createState() => _SwitchSchemeDialogState();
}

class _SwitchSchemeDialogState extends State<SwitchSchemeDialog> {
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
      if (_version.text.trim().isEmpty) _version.text = versionFor(path);
    });
  }

  void _submit() {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请先选择新方案的 zip 文件');
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
    if (version.startsWith('v')) version = version.substring(1);
    if (version.isEmpty) version = 'local';
    Navigator.pop(context, LocalPackageOptions(path: path, version: version));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('换方案'),
      content: SizedBox(
        width: dialogWidth(context, 540),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '把 ${widget.deviceCount} 个设备切换到另一套方案。会按顺序执行：',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              const _Step('1. 备份个人数据（自造词、开关记忆、用户词库）'),
              const _Step('2. 清空旧方案的运行文件（lua / opencc / models 等）'),
              const _Step('3. 安装新的方案包'),
              const _Step('4. 恢复个人数据并重新部署'),
              const SizedBox(height: 16),
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: '新方案压缩包',
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '切换前会先备份个人数据，备份位置：',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      switchBackupRoot,
                      style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'], fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '旧方案的运行文件会被删除，换回原方案需要重新安装。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
        FilledButton(onPressed: _submit, child: const Text('备份并切换')),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
