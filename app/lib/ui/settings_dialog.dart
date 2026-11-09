import 'package:flutter/material.dart';

import '../core/cache_manager.dart';
import '../core/scheme_repo.dart';
import '../core/settings_store.dart';
import '../models.dart';
import 'app_update_card.dart';
import 'dialog_size.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    this.embedded = false,
    this.onSaved,
  });

  final Settings settings;

  /// 作为页面内容渲染时不再包 AlertDialog，由调用方提供滚动与保存位置。
  final bool embedded;

  /// 内嵌模式下的保存回调（弹窗模式走 Navigator.pop 返回结果）。
  final ValueChanged<Settings>? onSaved;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _repo =
      TextEditingController(text: widget.settings.repo);
  late final TextEditingController _proxy =
      TextEditingController(text: widget.settings.proxy);
  late final TextEditingController _mirror =
      TextEditingController(text: widget.settings.mirror);
  late final TextEditingController _token =
      TextEditingController(text: widget.settings.token);
  late final TextEditingController _cacheDir =
      TextEditingController(text: widget.settings.cacheDir);

  late bool _deploy = widget.settings.deploy;
  late bool _restart = widget.settings.restart;
  late bool _snapshot = widget.settings.snapshot;

  CacheSummary? _cache;
  String _cacheNote = '';

  /// 清理时以输入框当前填写的目录为准，留空则用平台默认位置。
  String get _effectiveCacheDir {
    final custom = _cacheDir.text.trim();
    return custom.isNotEmpty ? custom : defaultCacheDir;
  }

  void _refreshCache() {
    final summary = cacheSummary(_effectiveCacheDir);
    if (!mounted) return;
    setState(() {
      _cache = summary;
      _cacheNote = '';
    });
  }

  void _clearCache() {
    // 方案仓库和缓存是同一个目录：清理只删下载的旧包，用户导入与勾选的方案保留。
    final effective = widget.settings.copyWith(cacheDir: _cacheDir.text.trim());
    final freed = pruneCache(
      _effectiveCacheDir,
      keep: schemeKeepNames(effective, const {}),
    );
    final summary = cacheSummary(_effectiveCacheDir);
    if (!mounted) return;
    setState(() {
      _cache = summary;
      _cacheNote = freed == 0
          ? '缓存已经是空的'
          : '已清理 ${(freed / 1024 / 1024).toStringAsFixed(1)} MB';
    });
  }

  @override
  void initState() {
    super.initState();
    _cache = cacheSummary(_effectiveCacheDir);
  }

  @override
  void dispose() {
    _repo.dispose();
    _proxy.dispose();
    _token.dispose();
    _cacheDir.dispose();
    super.dispose();
  }

  Settings _collect() {
    return Settings(
        repo: _repo.text.trim(),
        proxy: _proxy.text.trim(),
        token: _token.text.trim(),
        mirror: _mirror.text.trim(),
        cacheDir: _cacheDir.text.trim(),
        deploy: _deploy,
        restart: _restart,
        snapshot: _snapshot,
        customDirs: widget.settings.customDirs,
        customNames: widget.settings.customNames,
        hiddenDirs: widget.settings.hiddenDirs,
        safDirs: widget.settings.safDirs,
        syncUrl: widget.settings.syncUrl,
        syncUser: widget.settings.syncUser,
        syncPassword: widget.settings.syncPassword,
        deviceName: widget.settings.deviceName,
        deviceOrder: widget.settings.deviceOrder,
        selectedScheme: widget.settings.selectedScheme,
    );
  }

  void _submit() {
    final settings = _collect();
    if (widget.embedded) {
      widget.onSaved?.call(settings);
      return;
    }
    Navigator.pop(context, settings);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final form = Column(
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
                    controller: _mirror,
                    decoration: const InputDecoration(
                      labelText: '下载镜像（可选）',
                      hintText: 'https://gh-proxy.com/',
                      helperText: 'GitHub 下载 504/超时时可填镜像前缀；'
                          '失败时还会自动改用 GitHub API 资产地址',
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
                    onChanged: (_) => _refreshCache(),
                    decoration: const InputDecoration(
                      labelText: '方案存放位置',
                      hintText: '留空使用系统默认位置',
                      helperText: '下载的方案包与导入的方案都放在这里，一般不用改',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _cache == null
                              ? '正在统计缓存…'
                              : _cache!.isEmpty
                                  ? '缓存为空'
                                  : '缓存占用 ${_cache!.humanSize}'
                                      '（${_cache!.files} 个文件）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _cache == null || _cache!.isEmpty
                            ? null
                            : _clearCache,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text('清理缓存'),
                      ),
                    ],
                  ),
                  if (_cacheNote.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _cacheNote,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              AppUpdateCard(
                cacheDir: resolveCacheDir(widget.settings),
                proxy: widget.settings.proxy,
                token: widget.settings.token,
              ),
              const SizedBox(height: 12),
              Text(
                '设置保存在 $settingsFilePath',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
      ],
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: SingleChildScrollView(child: form)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存设置'),
            ),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: dialogWidth(context, 500),
        child: SingleChildScrollView(child: form),
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
