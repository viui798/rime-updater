import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/local_package.dart';
import '../core/sync_service.dart';
import '../core/webdav_client.dart';
import '../models.dart';
import 'dialog_size.dart';

const _textExtensions = [
  '.yaml',
  '.yml',
  '.txt',
  '.lua',
  '.json',
  '.md',
  '.conf',
  '.ini',
];

/// 同步库文件管理器：文件夹式浏览云端同步库，可上传、编辑、删除文件。
class SyncLibraryDialog extends StatefulWidget {
  const SyncLibraryDialog({
    super.key,
    required this.settings,
    required this.profiles,
  });

  final Settings settings;
  final List<Profile> profiles;

  @override
  State<SyncLibraryDialog> createState() => _SyncLibraryDialogState();
}

class _SyncLibraryDialogState extends State<SyncLibraryDialog> {
  WebDavClient? _client;
  final Map<String, SyncLibrary> _libraries = {};
  Profile? _profile;
  String _path = '';
  bool _busy = false;
  String _status = '';
  bool _error = false;

  String get _deviceName => widget.settings.deviceName.trim().isEmpty
      ? defaultDeviceName()
      : widget.settings.deviceName.trim();

  bool get _configured {
    final url = widget.settings.syncUrl.trim();
    return url.startsWith('http://') || url.startsWith('https://');
  }

  @override
  void initState() {
    super.initState();
    if (_configured) {
      _client = WebDavClient(
        baseUrl: widget.settings.syncUrl.trim(),
        user: widget.settings.syncUser,
        password: widget.settings.syncPassword,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshAll();
      });
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _error = error;
    });
  }

  Future<void> _refreshAll() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = false;
      _status = '正在读取同步库…';
    });
    try {
      for (final profile in widget.profiles) {
        _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      }
      _setStatus('');
    } catch (error) {
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _enter(Profile profile) {
    setState(() {
      _profile = profile;
      _path = '';
      _status = '';
      _error = false;
    });
  }

  void _goUp() {
    final profile = _profile;
    if (profile == null) return;
    if (_path.isEmpty) {
      setState(() => _profile = null);
      return;
    }
    final parent = p.posix.dirname(_path);
    setState(() => _path = parent == '.' || parent == '/' ? '' : parent);
  }

  Future<void> _showUploadPicker() async {
    if (_busy) return;
    final client = _client;
    if (client == null) {
      _setStatus('请先在主界面「云同步」里配置 WebDAV 地址', error: true);
      return;
    }

    final current = _profile;
    if (current != null) {
      await _upload(current);
      return;
    }

    final chosen = await showDialog<Profile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('从哪个端上传文件'),
        children: [
          for (final profile in widget.profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, profile),
              child: Text(profile.label),
            ),
        ],
      ),
    );
    if (chosen != null) await _upload(chosen);
  }

  Future<void> _upload(Profile profile) async {
    final client = _client;
    if (client == null) return;

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
      _status = '正在上传 $rel…';
    });
    try {
      await pushFiles(
        client: client,
        profile: profile,
        deviceName: _deviceName,
        files: [rel],
        log: (_) {},
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus('已上传 $rel');
    } catch (error) {
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _editable(String name) {
    final lower = name.toLowerCase();
    return _textExtensions.any((ext) => lower.endsWith(ext));
  }

  Future<void> _openEntry(Profile profile, LibraryEntry entry) async {
    if (_busy) return;
    if (entry.isDir) {
      setState(() => _path = entry.path);
      return;
    }
    if (entry.isUserDb) {
      await _showEntryInfo(
        profile,
        entry,
        '这是用户词典目录（*.userdb），包含 ${entry.fileCount} 个数据库文件，'
        '不能在线编辑。删除会整组从云端移除，本机文件不受影响。',
      );
      return;
    }
    if (!_editable(entry.name)) {
      await _showEntryInfo(
        profile,
        entry,
        '这个文件不是常见的文本格式，不能在应用内编辑。'
        '可以删除云端这份，本机文件不受影响。',
      );
      return;
    }
    await _editFile(profile, entry);
  }

  Future<void> _editFile(Profile profile, LibraryEntry entry) async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = false;
      _status = '正在读取 ${entry.name}…';
    });
    String? text;
    try {
      text = await readCloudFile(client, profile, entry.path);
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _setStatus('$error', error: true);
      return;
    }
    if (mounted) setState(() => _busy = false);
    if (text == null) {
      _setStatus('云端没有 ${entry.path}', error: true);
      return;
    }
    if (!mounted) return;

    final result = await showDialog<_EditorResult>(
      context: context,
      builder: (_) => _FileEditorDialog(
        name: entry.name,
        path: entry.path,
        initialText: text!,
      ),
    );
    if (result == null) return;
    if (result.deleted) {
      await _deleteEntry(profile, entry);
      return;
    }
    if (result.text == null) return;

    setState(() {
      _busy = true;
      _error = false;
      _status = '正在保存 ${entry.path}…';
    });
    try {
      await writeCloudFile(
        client: client,
        profile: profile,
        deviceName: _deviceName,
        rel: entry.path,
        text: result.text!,
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus('已保存 ${entry.path}');
    } catch (error) {
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showEntryInfo(
    Profile profile,
    LibraryEntry entry,
    String message,
  ) async {
    if (!mounted) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name),
        content: Text('${entry.path}\n\n$message'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('从云端删除'),
          ),
        ],
      ),
    );
    if (remove == true) await _deleteEntry(profile, entry);
  }

  Future<void> _deleteEntry(Profile profile, LibraryEntry entry) async {
    final client = _client;
    if (client == null || _busy) return;

    final paths = entry.isUserDb ? entry.paths : [entry.path];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从同步库删除'),
        content: Text(
          paths.length == 1
              ? '把「${entry.path}」从云端同步库删除？\n本机文件不受影响。'
              : '把「${entry.path}」从云端同步库删除？\n'
                  '这会删除该目录下的 ${paths.length} 个文件，本机文件不受影响。',
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
      _status = '正在删除 ${entry.path}…';
    });
    try {
      final removed = await deleteCloudFiles(
        client: client,
        profile: profile,
        paths: paths,
        log: (_) {},
      );
      _libraries[profile.path] = await fetchLibrary(client, syncKey(profile));
      _setStatus('已从云端删除 ${entry.path}（$removed 个文件）');
    } catch (error) {
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _title {
    final profile = _profile;
    if (profile == null) return '同步库';
    if (_path.isEmpty) return '同步库 / ${profile.label}';
    return '同步库 / ${profile.label} / ${_path.split('/').join(' / ')}';
  }

  int get _totalFiles {
    var total = 0;
    for (final library in _libraries.values) {
      total += library.files.length;
    }
    return total;
  }

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _profile == null ? Icons.folder_open : Icons.folder,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '上传本机文件',
                onPressed: _busy ? null : _showUploadPicker,
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: '刷新同步库',
                onPressed: _busy || _client == null ? null : _refreshAll,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (_profile != null)
            Row(
              children: [
                IconButton(
                  tooltip: '返回上一级',
                  visualDensity: VisualDensity.compact,
                  onPressed: _busy ? null : _goUp,
                  icon: const Icon(Icons.arrow_back, size: 18),
                ),
                Text(
                  _path.isEmpty ? '全部文件' : _path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (!_configured || _client == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '还没有配置 WebDAV。\n请先在主界面点「云同步」，填好地址、账号与密码。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    if (_busy && _libraries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final profile = _profile;
    if (profile == null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final item in widget.profiles)
            _buildRootRow(theme, item),
        ],
      );
    }

    final library = _libraries[profile.path];
    final entries =
        library == null ? <LibraryEntry>[] : listEntries(library.files, _path);
    if (entries.isEmpty) {
      return Center(
        child: Text(
          library == null
              ? '还没有读取到这个同步库，可点右上角刷新。'
              : '这个位置还没有文件，点右上角「+」上传本机文件。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) => _buildEntryRow(theme, profile, entries[index]),
    );
  }

  Widget _buildRootRow(ThemeData theme, Profile profile) {
    final library = _libraries[profile.path];
    final latest = library?.latestAt;
    final subtitle = library == null
        ? '读取中…'
        : '${library.files.length} 个文件'
            '${latest == null ? '' : ' · 最新 ${formatSyncTime(latest)}'}';
    return ListTile(
      leading: Icon(Icons.folder, color: theme.colorScheme.primary),
      title: Text(profile.label),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: _busy ? null : () => _enter(profile),
    );
  }

  Widget _buildEntryRow(
    ThemeData theme,
    Profile profile,
    LibraryEntry entry,
  ) {
    final IconData icon;
    if (entry.isDir) {
      icon = Icons.folder;
    } else if (entry.isUserDb) {
      icon = Icons.storage;
    } else {
      icon = Icons.insert_drive_file_outlined;
    }
    final title = entry.isDir
        ? entry.name
        : entry.isUserDb
            ? '${entry.name}/（${entry.fileCount} 个文件）'
            : entry.name;
    final subtitle = entry.isDir
        ? '${entry.fileCount} 个文件 · ${entry.byName.isEmpty ? '未知设备' : entry.byName}'
        : '${entry.byName.isEmpty ? '未知设备' : entry.byName}'
            ' · ${formatSyncTime(entry.at)}';
    return ListTile(
      dense: true,
      leading: Icon(
        icon,
        size: 18,
        color: entry.isDir
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.isDir)
            const Icon(Icons.chevron_right, size: 18)
          else
            IconButton(
              tooltip: '从云端删除',
              visualDensity: VisualDensity.compact,
              onPressed:
                  _busy ? null : () => _deleteEntry(profile, entry),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
        ],
      ),
      onTap: _busy ? null : () => _openEntry(profile, entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = _error;
    return Dialog(
      child: SizedBox(
        width: dialogWidth(context, 700),
        height: dialogHeight(context, 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(theme),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _status.isNotEmpty
                    ? _status
                    : '同步库共 $_totalFiles 个文件 · 点文件可在线编辑，点「+」上传本机文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: hasError
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorResult {
  const _EditorResult({this.text, this.deleted = false});

  final String? text;
  final bool deleted;
}

class _FileEditorDialog extends StatefulWidget {
  const _FileEditorDialog({
    required this.name,
    required this.path,
    required this.initialText,
  });

  final String name;
  final String path;
  final String initialText;

  @override
  State<_FileEditorDialog> createState() => _FileEditorDialogState();
}

class _FileEditorDialogState extends State<_FileEditorDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.name),
          Text(
            widget.path,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFamily: 'Menlo',
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth(context, 660),
        height: dialogHeight(context, 420),
        child: TextField(
          controller: _controller,
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 12, height: 1.5),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.all(10),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const _EditorResult(deleted: true)),
          child: const Text('删除云端文件'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _EditorResult(text: _controller.text)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
