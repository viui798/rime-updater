import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/local_package.dart';
import '../core/scheme_repo.dart';
import '../models.dart';
import 'dialog_size.dart';

/// 本地方案仓库：改存放位置、导入 zip、单选某个方案优先用于一键更新。
class LocalSchemesDialog extends StatefulWidget {
  const LocalSchemesDialog({
    super.key,
    required this.settings,
    required this.onSave,
    required this.onImported,
  });

  final Settings settings;
  final ValueChanged<Settings> onSave;

  /// 导入成功后通知主界面刷新（方案仓库内容变了）。
  final VoidCallback onImported;

  @override
  State<LocalSchemesDialog> createState() => _LocalSchemesDialogState();
}

class _LocalSchemesDialogState extends State<LocalSchemesDialog> {
  late final TextEditingController _dir =
      TextEditingController(text: widget.settings.cacheDir);
  late List<SchemeEntry> _entries = const [];
  String _note = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _dir.dispose();
    super.dispose();
  }

  Settings get _settings => widget.settings;

  void _refresh() {
    final entries = listSchemes(_settings);
    setState(() => _entries = entries);
  }

  void _apply(Settings next) {
    widget.onSave(next);
    setState(() {});
    _refresh();
  }

  void _saveDir() {
    final value = _dir.text.trim();
    _apply(_settings.copyWith(cacheDir: value));
    setState(() => _note = value.isEmpty ? '已恢复默认存放位置' : '存放位置已改到 $value');
    _refresh();
  }

  Future<void> _pickDir() async {
    final path = await pickDirectory();
    if (path == null) {
      setState(() => _note = '当前平台没有目录选择框，请在上面的输入框里手动填写路径');
      return;
    }
    _dir.text = path;
    _saveDir();
  }

  Future<void> _import() async {
    if (_busy) return;
    final picked = await pickLocalZip();
    if (picked == null) return;
    setState(() {
      _busy = true;
      _note = '';
    });
    try {
      final dest = await importScheme(_settings, picked);
      setState(() => _note = '已导入 ${p.basename(dest)}');
      widget.onImported();
      _refresh();
    } on FileSystemException catch (error) {
      setState(() => _note = '导入失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(SchemeEntry entry) {
    final selected = _settings.selectedScheme == entry.name;
    _apply(_settings.copyWith(selectedScheme: selected ? '' : entry.name));
    setState(() {
      _note = selected ? '已取消优先方案' : '一键更新将优先使用 ${entry.name}';
    });
  }

  Future<void> _delete(SchemeEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除方案包'),
        content: Text('从方案仓库删除 ${entry.name}？不会影响已经安装到设备上的方案。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    removeScheme(_settings, entry.name);
    if (_settings.selectedScheme == entry.name) {
      _apply(_settings.copyWith(selectedScheme: ''));
    }
    setState(() => _note = '已删除 ${entry.name}');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = schemeRepoDir(_settings);
    final totalBytes = _entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
    return AlertDialog(
      title: const Text('本地方案'),
      content: SizedBox(
        width: dialogWidth(context, 640),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '这里放更新器从 GitHub 下载的方案包，以及你自己导入的包。'
                '勾选一个方案后，一键更新会优先用它；仓库里已有同版本包时不会再重复下载。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _dir,
                decoration: InputDecoration(
                  labelText: '方案存放位置',
                  hintText: dir,
                  helperText: _entries.isEmpty
                      ? '仓库里还没有方案包'
                      : '仓库里 ${_entries.length} 个包，共 '
                          '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  suffixIcon: IconButton(
                    tooltip: '选择目录',
                    onPressed: _busy ? null : _pickDir,
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
                onSubmitted: (_) => _saveDir(),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _saveDir,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('保存位置'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.upload_file_outlined, size: 16),
                  label: const Text('导入方案'),
                ),
              ]),
              if (_note.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 6),
              Text('方案仓库', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '还没有方案包。点「导入方案」选一个 zip，或先回更新器点「检查更新」下载。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final entry in _entries)
                InkWell(
                  onTap: _busy ? null : () => _toggle(entry),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _settings.selectedScheme == entry.name,
                          onChanged: _busy ? null : (_) => _toggle(entry),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${entry.version.isEmpty ? '版本未知' : 'v${entry.version}'}'
                                ' · ${entry.humanSize}'
                                ' · ${entry.imported ? '导入' : '下载'}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '删除方案包',
                          onPressed: _busy ? null : () => _delete(entry),
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                      ],
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
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
