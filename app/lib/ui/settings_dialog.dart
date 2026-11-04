import 'package:flutter/material.dart';

import '../core/settings_store.dart';
import '../models.dart';
import 'dialog_size.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});

  final Settings settings;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _repo =
      TextEditingController(text: widget.settings.repo);
  late final TextEditingController _proxy =
      TextEditingController(text: widget.settings.proxy);
  late final TextEditingController _token =
      TextEditingController(text: widget.settings.token);
  late final TextEditingController _cacheDir =
      TextEditingController(text: widget.settings.cacheDir);

  late bool _deploy = widget.settings.deploy;
  late bool _restart = widget.settings.restart;
  late bool _snapshot = widget.settings.snapshot;

  @override
  void dispose() {
    _repo.dispose();
    _proxy.dispose();
    _token.dispose();
    _cacheDir.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      Settings(
        repo: _repo.text.trim(),
        proxy: _proxy.text.trim(),
        token: _token.text.trim(),
        cacheDir: _cacheDir.text.trim(),
        deploy: _deploy,
        restart: _restart,
        snapshot: _snapshot,
        customDirs: widget.settings.customDirs,
        customNames: widget.settings.customNames,
        hiddenDirs: widget.settings.hiddenDirs,
        syncUrl: widget.settings.syncUrl,
        syncUser: widget.settings.syncUser,
        syncPassword: widget.settings.syncPassword,
        deviceName: widget.settings.deviceName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: dialogWidth(context, 500),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SwitchRow(
                title: '更新后自动部署',
                subtitle: '复制完成后自动让输入法重新加载，立即生效。建议保持开启。',
                value: _deploy,
                onChanged: (value) => setState(() => _deploy = value),
              ),
              _SwitchRow(
                title: '部署后重启前端',
                subtitle: '自动加载不生效时，重启一次输入法程序。元书通常需要这个。',
                value: _restart,
                onChanged: (value) => setState(() => _restart = value),
              ),
              _SwitchRow(
                title: '更新前完整快照',
                subtitle: '先备份将被覆盖的旧文件，出问题可以一键回滚。建议保持开启。',
                value: _snapshot,
                onChanged: (value) => setState(() => _snapshot = value),
              ),
              const Divider(height: 20),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text('高级设置'),
                subtitle: const Text('一般不需要修改：下载来源、代理、令牌与缓存位置'),
                children: [
                  TextField(
                    controller: _repo,
                    decoration: const InputDecoration(
                      labelText: '方案仓库',
                      hintText: 'viui798/viui-tiger-sentense',
                      helperText: '默认是芝士虎整方案仓库，可改成任意 Rime 方案仓库',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _proxy,
                    decoration: const InputDecoration(
                      labelText: '网络代理',
                      hintText: 'http://127.0.0.1:7890',
                      helperText: '访问 GitHub 需要代理时才填，直连正常就留空',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'GitHub Token（可选）',
                      hintText: '留空即可',
                      helperText: '只用于避开 GitHub 每小时限流，平时不用填',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _cacheDir,
                    decoration: const InputDecoration(
                      labelText: '下载缓存目录',
                      hintText: '留空使用系统默认位置',
                      helperText: '安装包下载后存放的位置，一般不用改',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '设置保存在 $settingsFilePath',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
