import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/deployer.dart';
import '../core/local_package.dart';
import '../core/settings_store.dart';
import '../core/sync_service.dart';
import '../core/webdav_client.dart';
import '../models.dart';
import 'dialog_size.dart';

/// 云同步弹窗：配置 WebDAV，管理同步库文件，并上传 / 下载个人数据。
/// 关闭时返回最新的设置，由调用方写入设置文件。
class SyncDialog extends StatefulWidget {
  const SyncDialog({
    super.key,
    required this.settings,
    required this.profiles,
  });

  final Settings settings;
  final List<Profile> profiles;

  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  late final TextEditingController _url =
      TextEditingController(text: widget.settings.syncUrl);
  late final TextEditingController _user =
      TextEditingController(text: widget.settings.syncUser);
  late final TextEditingController _password =
      TextEditingController(text: widget.settings.syncPassword);
  late final TextEditingController _device = TextEditingController(
    text: widget.settings.deviceName.trim().isEmpty
        ? defaultDeviceName()
        : widget.settings.deviceName,
  );

  final Map<String, SyncLibrary> _libraries = {};
  final List<String> _log = [];
  bool _busy = false;
  String _status = '';
  bool _error = false;

  @override
  void initState() {
    super.initState();
    // 已经配置过地址时，打开弹窗就直接读取同步库，省一次点「刷新云端」
    if (_configured && widget.profiles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _device.dispose();
    super.dispose();
  }

  Settings _current() {
    return widget.settings.copyWith(
      syncUrl: _url.text.trim(),
      syncUser: _user.text.trim(),
      syncPassword: _password.text,
      deviceName: _device.text.trim(),
    );
  }

  WebDavClient _client() {
    final settings = _current();
    return WebDavClient(
      baseUrl: settings.syncUrl,
      user: settings.syncUser,
      password: settings.syncPassword,
    );
  }

  String get _deviceName => _device.text.trim().isEmpty
      ? defaultDeviceName()
      : _device.text.trim();

  bool get _configured {
    final url = _url.text.trim();
    return url.startsWith('http://') || url.startsWith('https://');
  }

  void _line(String text) {
    if (!mounted) return;
    setState(() => _log.add(text));
  }

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _error = error;
    });
  }

  /// 操作前先落盘配置，避免用户按 Esc 关窗后丢失刚填的地址。
  void _persist() {
    try {
      saveSettings(_current());
    } catch (_) {
      // 设置写入失败时仍允许继续操作
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    if (!_configured) {
      _setStatus('请先填写 WebDAV 地址（http:// 或 https://）', error: true);
      return;
    }
    _persist();
    setState(() {
      _busy = true;
      _log.clear();
      _error = false;
      _status = '正在读取云端同步库…';
    });

    final client = _client();
    try {
      for (final profile in widget.profiles) {
        final library = await fetchLibrary(client, syncKey(profile));
        _libraries[profile.path] = library;
        _line('[${profile.label}] 同步库 ${library.files.length} 个文件');
      }
      if (widget.profiles.isEmpty) _line('没有勾选任何设备');
      _setStatus('同步库已读取');
    } catch (error) {
      _line('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload(Profile profile) async {
    if (_busy) return;
    if (!_configured) {
      _setStatus('请先填写 WebDAV 地址', error: true);
      return;
    }
    _persist();
    setState(() {
      _busy = true;
      _error = false;
      _status = '正在上传 ${profile.label}…';
    });
    _line('');
    _line('[${profile.label}] 上传个人数据');

    final client = _client();
    try {
      final count = await pushFiles(
        client: client,
        profile: profile,
        deviceName: _deviceName,
        log: _line,
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus('${profile.label} 已上传 $count 个文件');
    } catch (error) {
      _line('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFile(Profile profile) async {
    if (_busy) return;
    if (!_configured) {
      _setStatus('请先填写 WebDAV 地址', error: true);
      return;
    }
    _persist();

    final picked = await pickSyncFile(initialDir: profile.path);
    if (picked == null) return;
    final normalized = p.normalize(picked);
    if (!p.isWithin(profile.path, normalized)) {
      _setStatus('只能选择「${profile.label}」目录内的文件', error: true);
      return;
    }
    final rel =
        p.relative(normalized, from: profile.path).replaceAll('\\', '/');
    if (rel.isEmpty || rel.split('/').any((part) => part == '..')) {
      _setStatus('无法识别的文件路径', error: true);
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _status = '正在添加 ${p.basename(rel)}…';
    });
    _line('');
    _line('[${profile.label}] 加入同步：$rel');

    final client = _client();
    try {
      await pushFiles(
        client: client,
        profile: profile,
        deviceName: _deviceName,
        files: [rel],
        log: _line,
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus('已加入同步库：$rel');
    } catch (error) {
      _line('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteGroup(Profile profile, _SyncGroup group) async {
    if (_busy) return;
    if (!_configured) {
      _setStatus('请先填写 WebDAV 地址', error: true);
      return;
    }
    _persist();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从同步库删除'),
        content: Text(
          group.paths.length == 1
              ? '把「${group.label}」从云端同步库删除？\n本机文件不受影响。'
              : '把「${group.label}」从云端同步库删除？\n'
                  '这会删除该目录下的 ${group.paths.length} 个文件，本机文件不受影响。',
        ),
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
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = false;
      _status = '正在删除…';
    });
    final client = _client();
    try {
      final removed = await deleteCloudFiles(
        client: client,
        profile: profile,
        paths: group.paths,
        log: _line,
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus(removed > 0
          ? '已从同步库删除 ${group.label}（$removed 个文件）'
          : '云端没有 ${group.label}');
    } catch (error) {
      _line('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Profile profile) async {
    if (_busy) return;
    if (!_configured) {
      _setStatus('请先填写 WebDAV 地址', error: true);
      return;
    }
    _persist();

    final library = _libraries[profile.path];
    if (library == null) {
      _setStatus('请先点「刷新云端」读取同步库', error: true);
      return;
    }
    if (library.files.isEmpty) {
      _setStatus('云端同步库还没有文件', error: true);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认下载'),
        content: Text(
          '将把同步库里的 ${library.files.length} 个文件写入本机「${profile.label}」。\n'
          '覆盖前会自动备份本机个人数据，可在「备份与回滚」中看到。\n\n继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('覆盖并下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = false;
      _status = '正在下载 ${profile.label}…';
    });
    _line('');
    _line('[${profile.label}] 下载同步库');

    final client = _client();
    try {
      final count = await pullLibrary(
        client: client,
        profile: profile,
        log: _line,
      );
      if (count > 0 && widget.settings.deploy) {
        await deployProfile(
          profile,
          restart: widget.settings.restart,
          log: _line,
        );
      }
      _setStatus(count > 0 ? '${profile.label} 已同步 $count 个文件' : '没有文件被下载');
    } catch (error) {
      _line('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _cloudText(Profile profile) {
    final library = _libraries[profile.path];
    if (library == null) return '未读取云端同步库';
    if (library.files.isEmpty) {
      return library.devices.isEmpty ? '同步库还是空的' : '同步库还没有文件';
    }
    final latest = library.latestAt;
    return '${library.files.length} 个文件'
        '${latest == null ? '' : ' · 最新 ${formatSyncTime(latest)}'}';
  }

  Widget _buildFileList(ThemeData theme, Profile profile) {
    final library = _libraries[profile.path];
    if (library == null) return const SizedBox.shrink();
    final groups = _groupFiles(library.files);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      dense: true,
      title: Text('同步库文件（${library.files.length}）', style: hintStyle),
      subtitle:
          library.files.isEmpty ? null : Text('点右端垃圾桶可删除云端文件', style: hintStyle),
      children: groups.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '还没有文件：点「上传本机」批量上传个人数据，或「添加文件」选单个文件。',
                    style: hintStyle,
                  ),
                ),
              ),
            ]
          : [
              for (final group in groups)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 8, right: 0),
                  title: Text(
                    group.isDir
                        ? '${group.label}/（${group.paths.length} 个文件）'
                        : group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'], fontSize: 11),
                  ),
                  subtitle: Text(
                    '${group.byName.isEmpty ? '未知设备' : group.byName}'
                    ' · ${formatSyncTime(group.at)}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  trailing: IconButton(
                    tooltip: '从同步库删除',
                    onPressed:
                        _busy ? null : () => _deleteGroup(profile, group),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ),
            ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.cloud_sync_outlined, size: 22),
          SizedBox(width: 8),
          Text('云同步（WebDAV）'),
        ],
      ),
      content: SizedBox(
        width: dialogWidth(context, 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '同步库按前端分目录，所有设备共用一份。可以只上传个人数据，'
                '也可以单独添加 / 删除某个文件；方案文件与模型不建议放进来。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'https://dav.example.com/remote.php/dav/files/me/',
                  helperText: '坚果云、Nextcloud 等都可以，地址要以 / 结尾更稳妥',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _user,
                      decoration: const InputDecoration(labelText: '用户名'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _device,
                decoration: const InputDecoration(
                  labelText: '本机名称',
                  helperText: '云端用这个名字区分设备，例如「家里的 Mac」',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('设备同步', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新云端'),
                  ),
                ],
              ),
              if (widget.profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '请先在主界面勾选要同步的设备。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final profile in widget.profiles) ...[
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              profile.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _cloudText(profile),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: _busy ? null : () => _upload(profile),
                              icon: const Icon(Icons.cloud_upload_outlined,
                                  size: 18),
                              label: const Text('上传本机'),
                            ),
                            TextButton.icon(
                              onPressed: _busy ? null : () => _addFile(profile),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('添加文件'),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _busy ? null : () => _download(profile),
                              icon: const Icon(Icons.cloud_download_outlined,
                                  size: 18),
                              label: const Text('下载云端'),
                            ),
                          ],
                        ),
                        _buildFileList(theme, profile),
                      ],
                    ),
                  ),
                ),
              ],
              if (_log.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  height: 110,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _log.join('\n'),
                      style: TextStyle(
                        fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
                        fontSize: 11,
                        height: 1.6,
                        color: _error
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _error
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _current()),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 同步库里的一“项”：普通文件一项；`*.userdb` 目录合并成一项，避免误删数据库内部文件。
class _SyncGroup {
  _SyncGroup({
    required this.label,
    required this.paths,
    required this.at,
    required this.byName,
    required this.isDir,
  });

  final String label;
  final List<String> paths;
  final bool isDir;
  DateTime at;
  String byName;
}

List<_SyncGroup> _groupFiles(List<SyncFile> files) {
  final groups = <String, _SyncGroup>{};
  for (final file in files) {
    final parts = file.path.split('/');
    final index = parts.indexWhere((part) => part.endsWith('.userdb'));
    final isDir = index >= 0;
    final key = isDir ? parts.sublist(0, index + 1).join('/') : file.path;
    final existing = groups[key];
    if (existing == null) {
      groups[key] = _SyncGroup(
        label: key,
        paths: [file.path],
        at: file.at,
        byName: file.byName,
        isDir: isDir,
      );
    } else {
      existing.paths.add(file.path);
      if (file.at.isAfter(existing.at)) {
        existing.at = file.at;
        existing.byName = file.byName;
      }
    }
  }
  return groups.values.toList()..sort((a, b) => a.label.compareTo(b.label));
}
