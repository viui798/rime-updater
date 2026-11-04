import 'package:flutter/material.dart';

import '../core/github_client.dart';
import '../models.dart';

class RemoteSchemeOptions {
  const RemoteSchemeOptions({
    required this.repo,
    required this.version,
    required this.asset,
  });

  final String repo;
  final String version;
  final Asset asset;
}

class RemoteSchemeDialog extends StatefulWidget {
  const RemoteSchemeDialog({super.key, required this.settings});

  final Settings settings;

  @override
  State<RemoteSchemeDialog> createState() => _RemoteSchemeDialogState();
}

class _RemoteSchemeDialogState extends State<RemoteSchemeDialog> {
  late final TextEditingController _repo = TextEditingController(
    text: widget.settings.repo.isEmpty
        ? 'viui798/viui-tiger-sentense'
        : widget.settings.repo,
  );

  bool _loading = false;
  String? _error;
  ReleaseInfo? _release;
  Asset? _selected;

  @override
  void dispose() {
    _repo.dispose();
    super.dispose();
  }

  String _normalizeRepo(String input) {
    var value = input.trim();
    if (value.contains('github.com/')) {
      value = value.split('github.com/').last;
    }
    value = value.replaceFirst(RegExp(r'^https?://'), '');
    value = value.split('#').first.split('?').first;
    value = value.replaceFirst(RegExp(r'\.git$'), '');
    return value.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  Future<void> _load() async {
    final repo = _normalizeRepo(_repo.text);
    if (!repo.contains('/')) {
      setState(() => _error = '请填写 owner/repo 或 GitHub 仓库地址');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _release = null;
      _selected = null;
    });

    try {
      final client = GithubClient(
        settings: widget.settings.copyWith(repo: repo),
        log: (_) {},
      );
      final release = await client.fetchLatest();
      client.close();

      final zips = release.assets
          .where((asset) => asset.name.toLowerCase().endsWith('.zip'))
          .toList();
      if (zips.isEmpty) {
        setState(() {
          _error = '该 Release 没有 zip 资产，无法安装';
          _loading = false;
        });
        return;
      }

      Asset chosen = zips.first;
      for (final asset in zips) {
        if (asset.name.endsWith('-update.zip')) {
          chosen = asset;
          break;
        }
        if (asset.size > chosen.size) chosen = asset;
      }

      setState(() {
        _release = release;
        _selected = chosen;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _submit() {
    final release = _release;
    final asset = _selected;
    if (release == null || asset == null) return;
    Navigator.pop(
      context,
      RemoteSchemeOptions(
        repo: _normalizeRepo(_repo.text),
        version: release.version,
        asset: asset,
      ),
    );
  }

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / 1024 / 1024;
    return ' · ${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('从 GitHub 安装方案'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '填写任意 Rime 方案仓库，读取它的 Releases，选择 zip 资产安装到勾选的设备。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _repo,
                decoration: InputDecoration(
                  labelText: '方案仓库',
                  hintText: 'https://github.com/iDvel/rime-ice',
                  errorText: _error,
                  suffixIcon: IconButton(
                    tooltip: '读取 Releases',
                    onPressed: _loading ? null : _load,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '支持 owner/repo 或完整 GitHub 网址；读取最近一次 Release。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_release != null) ...[
                const SizedBox(height: 16),
                Text(
                  '版本 v${_release!.version}',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Asset>(
                  initialValue: _selected,
                  decoration: const InputDecoration(labelText: '安装包资产'),
                  items: [
                    for (final asset in _release!.assets
                        .where((a) => a.name.toLowerCase().endsWith('.zip')))
                      DropdownMenuItem(
                        value: asset,
                        child: Text(
                          '${asset.name}${_sizeLabel(asset.size)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _selected = value),
                ),
              ],
              if (_release == null && !_loading && _error == null) ...[
                const SizedBox(height: 16),
                Text(
                  '先点输入框右侧的刷新按钮读取 Releases。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected == null ? null : _submit,
          child: const Text('下载并安装'),
        ),
      ],
    );
  }
}
