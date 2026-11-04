import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'core/android_platform.dart';
import 'core/deployer.dart';
import 'core/github_client.dart';
import 'core/local_package.dart';
import 'core/package_preparer.dart';
import 'core/rime_profile.dart' as rime;
import 'core/scheme_switcher.dart';
import 'core/settings_store.dart';
import 'core/zip_installer.dart';
import 'models.dart';
import 'ui/local_zip_dialog.dart';
import 'ui/remote_scheme_dialog.dart';
import 'ui/settings_dialog.dart';
import 'ui/switch_scheme_dialog.dart';
import 'ui/sync_dialog.dart';
import 'ui/sync_library_dialog.dart';

void main() {
  runApp(const RimeUpdaterApp());
}

class RimeUpdaterApp extends StatelessWidget {
  const RimeUpdaterApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFB45309);
    return MaterialApp(
      title: '芝士虎整 · 更新器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Settings _settings = const Settings();
  List<Profile> _profiles = const [];
  final Set<String> _selected = {};
  final Set<String> _known = {};
  final Map<String, List<BackupInfo>> _backups = {};

  String _remoteVersion = '';
  String _remoteAsset = '';
  bool _remoteDelta = false;

  // 检查更新后缓存结果，随后的更新 / 预演在 10 分钟内复用它，避免重复请求 GitHub
  ReleaseInfo? _releaseCache;
  DateTime? _releaseCacheAt;
  String _releaseCacheRepo = '';

  static const _releaseCacheTtl = Duration(minutes: 10);

  bool _busy = false;
  double _progress = 0;
  double _deviceHeight = 210;
  double _backupHeight = 130;
  String _status = '就绪';
  bool _statusError = false;

  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _settings = loadSettings();
    _refreshProfiles();
    _refreshBackups();
    // 启动时不自动请求 GitHub：只有用户点「检查更新」或其他操作时才联网
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureAndroidAccess();
      });
    }
  }

  /// Android 上需要「所有文件访问权限」才能读写 /storage/emulated/0/rime。
  Future<void> _ensureAndroidAccess() async {
    if (!Platform.isAndroid) return;
    if (await hasAllFilesAccess()) {
      if (mounted) _refreshProfiles();
      return;
    }
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要文件访问权限'),
        content: const Text(
          '更新器要读写手机里的 Rime 用户目录（同文输入法通常是 '
          '/storage/emulated/0/rime）。\n\n'
          '请在接下来的系统设置里打开「允许访问所有文件」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await requestAllFilesAccess();
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) _refreshProfiles();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _refreshProfiles() {
    final profiles = rime.detectProfiles();
    for (final custom in rime.profilesFromPaths(
      _settings.customDirs,
      names: _settings.customNames,
    )) {
      if (!profiles.any((profile) => profile.path == custom.path)) {
        profiles.add(custom);
      }
    }
    for (final profile in profiles) {
      // 只对首次出现的设备默认勾选，用户取消后不会被重新勾上
      if (_known.add(profile.path)) {
        _selected.add(profile.path);
      }
    }
    _selected.removeWhere(
      (path) => !profiles.any((profile) => profile.path == path),
    );
    setState(() => _profiles = profiles);
  }

  Future<void> _addRimeDir() async {
    if (_busy) return;
    final selected = await pickDirectory();
    if (selected == null) return;
    final normalized = p.normalize(selected);

    if (_settings.customDirs.contains(normalized) ||
        _profiles.any((profile) => profile.path == normalized)) {
      _setStatus('该目录已在列表中');
      return;
    }

    if (!rime.looksLikeRimeDir(normalized)) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认添加'),
          content: Text(
            '这个目录里没有找到 Rime 配置（如 tiger.schema.yaml、default.custom.yaml）。\n'
            '$normalized\n\n仍要添加吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍然添加'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final updated = _settings.copyWith(
      customDirs: [..._settings.customDirs, normalized],
    );
    saveSettings(updated);
    setState(() => _settings = updated);
    _refreshProfiles();
    setState(() => _selected.add(normalized));
    _setStatus('已添加 ${p.basename(normalized)}');
  }

  void _refreshBackups() {
    final backups = <String, List<BackupInfo>>{};
    for (final profile in _profiles) {
      backups[profile.path] = rime.listBackups(profile.path);
    }
    setState(() {
      _backups
        ..clear()
        ..addAll(backups);
    });
  }

  void _logLine(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = text;
      _statusError = error;
      if (error) _busy = false;
    });
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在检查…';
      _statusError = false;
      _log.clear();
    });
    _logLine('检查远端版本…');
    try {
      final client = GithubClient(settings: _settings, log: _logLine);
      final release = await client.fetchLatest();
      client.close();
      if (!mounted) return;
      setState(() {
        _remoteVersion = release.version;
        _remoteAsset = release.assetName;
        _remoteDelta = release.isDelta;
      });
      final outdated = _profiles.any((profile) {
        final current = rime.readLocalVersion(profile.path);
        return current.isNotEmpty && current != release.version;
      });
      _logLine('远端最新：v${release.version}（${release.assetName}）'
          '${outdated ? '（可更新）' : '（最新）'}');
      _logLine('包类型：${release.isDelta ? '增量包' : '完整包'}');
      _releaseCache = release;
      _releaseCacheAt = DateTime.now();
      _releaseCacheRepo = _settings.repo.trim();
      _setStatus('检查完成');
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ReleaseInfo? get _usableRelease {
    final cached = _releaseCache;
    final at = _releaseCacheAt;
    if (cached == null || at == null) return null;
    if (DateTime.now().difference(at) > _releaseCacheTtl) return null;
    if (_releaseCacheRepo != _settings.repo.trim()) return null;
    return cached;
  }

  Future<void> _runUpdate({required bool dryRun}) async {
    if (_busy) return;
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }
    if (!dryRun) {
      final version =
          _remoteVersion.isEmpty ? '远端最新版本' : 'v$_remoteVersion';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认更新'),
          content: Text('将更新 ${targets.length} 个设备到 $version，继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _status = dryRun ? '预演中…' : '更新中…';
      _statusError = false;
    });

    try {
      final cached = _usableRelease;
      if (cached != null) {
        _logLine('复用最近 ${_releaseCacheTtl.inMinutes} 分钟内的检查结果'
            '（v${cached.version}），不再请求 GitHub');
      }
      final package = await preparePackage(
        settings: _settings,
        log: _logLine,
        progress: (percent) {
          if (mounted) setState(() => _progress = percent / 100);
        },
        release: cached,
      );
      _logLine('目标版本：v${package.version}（${package.assetName}）');
      _logLine('准备更新 ${targets.length} 个用户目录'
          '（${dryRun ? '预演' : '正式'}）');

      final picked = _profiles.where((p) => targets.contains(p.path)).toList();
      for (var index = 0; index < picked.length; index++) {
        final profile = picked[index];
        _logLine('');
        _logLine('[${profile.label}] ${profile.path}');
        final base = 55 + index * 45 ~/ picked.length;
        final span = 45 ~/ picked.length;

        final stats = applyZip(
          zipPath: package.zipPath,
          target: profile.path,
          version: package.version,
          dryRun: dryRun,
          snapshot: _settings.snapshot,
          log: _logLine,
          onFile: (done, total) {
            if (!mounted) return;
            setState(() {
              _progress = (base + (total > 0 ? span * done ~/ total : span)) /
                  100;
            });
          },
        );
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }

        if (_settings.deploy && !dryRun) {
          deployProfile(profile, restart: _settings.restart, log: _logLine);
        }
      }

      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus(dryRun ? '预演完成' : '更新完成');
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rollback(Profile profile, BackupInfo backup) async {
    if (_busy) return;
    final from = backup.version.isEmpty ? '未知' : 'v${backup.version}';
    final to =
        backup.previousVersion.isEmpty ? '未知' : 'v${backup.previousVersion}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认回滚'),
        content: Text('把「${profile.label}」从 $from 回滚到 $to？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在回滚…';
      _statusError = false;
    });
    _logLine('');
    _logLine('[${profile.label}] ${profile.path}');
    try {
      rollback(target: profile.path, stamp: backup.stamp, log: _logLine);
      if (_settings.deploy) {
        deployProfile(profile, restart: _settings.restart, log: _logLine);
      }
      setState(() => _progress = 1);
      _setStatus('回滚完成');
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installLocalZip() async {
    if (_busy) return;
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }

    final options = await showDialog<LocalPackageOptions>(
      context: context,
      builder: (context) => LocalZipDialog(deviceCount: targets.length),
    );
    if (options == null) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在安装本地包…';
      _statusError = false;
      _log.clear();
    });
    _logLine('本地安装：${options.path}');

    final picked = _profiles.where((p) => targets.contains(p.path)).toList();
    try {
      for (var index = 0; index < picked.length; index++) {
        final profile = picked[index];
        _logLine('');
        _logLine('[${profile.label}] ${profile.path}');
        final base = index * 100 ~/ picked.length;
        final span = 100 ~/ picked.length;

        final stats = applyZip(
          zipPath: options.path,
          target: profile.path,
          version: options.version,
          dryRun: false,
          snapshot: _settings.snapshot,
          log: _logLine,
          onFile: (done, total) {
            if (!mounted) return;
            setState(() {
              _progress =
                  (base + (total > 0 ? span * done ~/ total : span)) / 100;
            });
          },
        );
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }
        if (_settings.deploy) {
          deployProfile(profile, restart: _settings.restart, log: _logLine);
        }
      }
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('安装完成');
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchScheme() async {
    if (_busy) return;
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }

    final options = await showDialog<LocalPackageOptions>(
      context: context,
      builder: (context) => SwitchSchemeDialog(deviceCount: targets.length),
    );
    if (options == null) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在切换方案…';
      _statusError = false;
      _log.clear();
    });
    _logLine('换方案：${options.path}');

    final picked = _profiles.where((p) => targets.contains(p.path)).toList();
    var failures = 0;
    try {
      for (var index = 0; index < picked.length; index++) {
        final profile = picked[index];
        _logLine('');
        _logLine('[${profile.label}] ${profile.path}');
        final base = index * 100 ~/ picked.length;
        final span = 100 ~/ picked.length;

        try {
          final backup = backupUserData(
            profile.path,
            label: profile.label,
            log: _logLine,
          );
          cleanScheme(profile.path, log: _logLine);
          final stats = applyZip(
            zipPath: options.path,
            target: profile.path,
            version: options.version,
            dryRun: false,
            snapshot: false,
            log: _logLine,
            onFile: (done, total) {
              if (!mounted) return;
              setState(() {
                _progress =
                    (base + (total > 0 ? span * done ~/ total : span)) / 100;
              });
            },
          );
          restoreUserData(backup, log: _logLine);
          if (_settings.deploy) {
            deployProfile(profile, restart: _settings.restart, log: _logLine);
          }
          _logLine('  ${profile.label} 已切换到 ${stats.copied} 个新文件');
        } catch (error) {
          failures++;
          _logLine('  ✗ ${profile.label} 切换失败：$error');
        }
      }

      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus(
        failures == 0 ? '方案切换完成' : '$failures 个设备切换失败',
        error: failures > 0,
      );
      _refreshProfiles();
      _refreshBackups();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameProfile(Profile profile) async {
    if (_busy) return;
    final controller = TextEditingController(
      text: _settings.customNames[profile.path] ?? profile.label,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '显示名称',
            hintText: '留空则使用目录名',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;

    final trimmed = name.trim();
    final names = {..._settings.customNames};
    if (trimmed.isEmpty) {
      names.remove(profile.path);
    } else {
      names[profile.path] = trimmed;
    }
    final updated = _settings.copyWith(customNames: names);
    saveSettings(updated);
    setState(() => _settings = updated);
    _refreshProfiles();
    _setStatus('已重命名为 ${trimmed.isEmpty ? p.basename(profile.path) : trimmed}');
  }

  Future<void> _clearBackups() async {
    if (_busy) return;
    final total = _profiles.fold<int>(
      0,
      (sum, profile) => sum + (_backups[profile.path]?.length ?? 0),
    );
    if (total == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理备份'),
        content: Text('删除全部 $total 份快照？\n个人数据与当前方案文件不会受影响，但删除后无法再回滚。'),
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
    if (confirmed != true) return;

    var removed = 0;
    for (final profile in _profiles) {
      removed += rime.clearBackups(profile.path);
    }
    _refreshBackups();
    _setStatus('已清理 $removed 份备份');
  }

  Future<void> _installFromGithub() async {
    if (_busy) return;
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }

    final options = await showDialog<RemoteSchemeOptions>(
      context: context,
      builder: (context) => RemoteSchemeDialog(settings: _settings),
    );
    if (options == null) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在下载方案…';
      _statusError = false;
      _log.clear();
    });
    _logLine('GitHub 方案：${options.repo} v${options.version}');
    _logLine('安装包：${options.asset.name}');

    final client = GithubClient(
      settings: _settings.copyWith(repo: options.repo),
      log: _logLine,
    );
    try {
      final cacheDir = _settings.cacheDir.trim().isEmpty
          ? defaultCacheDir
          : _settings.cacheDir.trim();
      final cachePath = p.join(cacheDir, options.asset.name);
      final cached = File(cachePath);
      if (cached.existsSync() &&
          options.asset.size > 0 &&
          cached.lengthSync() == options.asset.size) {
        _logLine('复用缓存 $cachePath');
        if (mounted) setState(() => _progress = 0.55);
      } else {
        _logLine('下载 ${options.asset.name} ...');
        await client.downloadTo(
          options.asset.url,
          cachePath,
          onPercent: (percent) {
            if (!mounted) return;
            setState(() => _progress = percent / 100 * 0.55);
          },
        );
      }

      if (!zipLooksLikeRime(cachePath)) {
        _logLine('  ! 包内没有找到 yaml/lua，可能不是 Rime 方案，仍继续安装');
      }

      final picked =
          _profiles.where((profile) => targets.contains(profile.path)).toList();
      for (var index = 0; index < picked.length; index++) {
        final profile = picked[index];
        _logLine('');
        _logLine('[${profile.label}] ${profile.path}');
        final base = 55 + index * 45 ~/ picked.length;
        final span = 45 ~/ picked.length;

        final stats = applyZip(
          zipPath: cachePath,
          target: profile.path,
          version: options.version,
          dryRun: false,
          snapshot: _settings.snapshot,
          log: _logLine,
          onFile: (done, total) {
            if (!mounted) return;
            setState(() {
              _progress =
                  (base + (total > 0 ? span * done ~/ total : span)) / 100;
            });
          },
        );
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }
        if (_settings.deploy) {
          deployProfile(profile, restart: _settings.restart, log: _logLine);
        }
      }

      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('安装完成');
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSync() async {
    if (_busy) return;
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }

    final picked = _profiles
        .where((profile) => targets.contains(profile.path))
        .toList();
    final result = await showDialog<Settings>(
      context: context,
      barrierDismissible: false,
      builder: (context) => SyncDialog(settings: _settings, profiles: picked),
    );
    if (result == null) return;
    saveSettings(result);
    setState(() => _settings = result);
    _refreshProfiles();
    _setStatus('云同步设置已保存');
  }

  Future<void> _openSyncLibrary() async {
    if (_busy) return;
    if (_settings.syncUrl.trim().isEmpty) {
      _setStatus('请先点「云同步」配置 WebDAV 地址', error: true);
      return;
    }
    final targets = _selected.toList();
    if (targets.isEmpty) {
      _setStatus('请先勾选至少一个设备', error: true);
      return;
    }
    final picked = _profiles
        .where((profile) => targets.contains(profile.path))
        .toList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) =>
          SyncLibraryDialog(settings: _settings, profiles: picked),
    );
  }

  Future<void> _openSettings() async {
    final result = await showDialog<Settings>(
      context: context,
      builder: (context) => SettingsDialog(settings: _settings),
    );
    if (result == null) return;
    saveSettings(result);
    setState(() => _settings = result);
    _setStatus('设置已保存');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final padding = compact ? 12.0 : 20.0;
            return Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 12),
              child: compact
                  ? _buildCompactBody(theme)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(theme),
                        const SizedBox(height: 12),
                        _buildRemoteLine(theme),
                        const SizedBox(height: 4),
                        _buildProgress(theme),
                        const SizedBox(height: 8),
                        Expanded(child: _buildResizableBody(theme)),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  /// 手机窄屏：三块区域改为一张可滚动的页面，避免固定高度留下大片空白。
  Widget _buildCompactBody(ThemeData theme) {
    final deviceHeight = math.min(300.0, 58.0 * _profiles.length + 46.0);
    final backupCount =
        _backups.values.fold<int>(0, (sum, list) => sum + list.length);
    final backupHeight =
        backupCount == 0 ? 120.0 : math.min(220.0, 60.0 + 56.0 * backupCount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCompactHeader(theme),
        const SizedBox(height: 10),
        _buildStatusPill(theme),
        const SizedBox(height: 10),
        _buildMainButtonRow(),
        const SizedBox(height: 4),
        _buildShortcutRow(theme),
        const SizedBox(height: 4),
        _buildProgress(theme, compact: true),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: math.max(96, deviceHeight),
                  child: _buildDevices(theme),
                ),
                const SizedBox(height: 10),
                SizedBox(height: 220, child: _buildLog(theme)),
                const SizedBox(height: 10),
                SizedBox(
                  height: backupHeight,
                  child: _buildBackups(theme),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactHeader(ThemeData theme) {
    return Row(
      children: [
        _buildLogo(theme),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '芝士虎整 · 更新器',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '虎码 Rime 整合包 · 多设备更新',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '设置',
          onPressed: _busy ? null : _openSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }

  Widget _buildStatusPill(ThemeData theme) {
    final checked = _remoteVersion.isNotEmpty;
    final outdated = checked &&
        _profiles.any((profile) {
          final current = rime.readLocalVersion(profile.path);
          return current.isNotEmpty && current != _remoteVersion;
        });
    final color = !checked
        ? theme.colorScheme.onSurfaceVariant
        : (outdated ? theme.colorScheme.primary : const Color(0xFF15803D));
    final text = checked
        ? '远端最新：v$_remoteVersion · ${_remoteDelta ? '增量包' : '完整包'}'
        : '远端最新：未检查';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            checked ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          if (checked)
            Text(
              outdated ? '可更新' : '已最新',
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMainButtonRow() {
    final style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size.fromHeight(42)),
    );
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: style,
            onPressed: _busy ? null : _check,
            child: const Text('检查更新'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            style: style,
            onPressed: _busy ? null : () => _runUpdate(dryRun: true),
            child: const Text('仅预演'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            style: style,
            onPressed: _busy ? null : () => _runUpdate(dryRun: false),
            child: const Text('一键更新'),
          ),
        ),
      ],
    );
  }

  Widget _buildShortcutRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: _busy ? null : _openSync,
            icon: const Icon(Icons.cloud_sync_outlined, size: 18),
            label: const Text('云同步'),
          ),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: _busy ? null : _openSyncLibrary,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('同步库'),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多功能',
          icon: const Icon(Icons.more_horiz),
          onSelected: (value) {
            switch (value) {
              case 'github':
                _installFromGithub();
                break;
              case 'switch':
                _switchScheme();
                break;
              case 'zip':
                _installLocalZip();
                break;
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'github',
              child: Row(
                children: [
                  Icon(Icons.cloud_download_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('GitHub 方案'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'switch',
              child: Row(
                children: [
                  Icon(Icons.swap_horiz, size: 20),
                  SizedBox(width: 12),
                  Text('换方案'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'zip',
              child: Row(
                children: [
                  Icon(Icons.archive_outlined, size: 20),
                  SizedBox(width: 12),
                  Text('从本地 zip 安装'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResizableBody(ThemeData theme) {
    const handleHeight = 12.0;
    const minDevice = 110.0;
    const minBackup = 80.0;
    const minLog = 120.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight;
        final deviceMax =
            math.max(minDevice, total - _backupHeight - handleHeight * 2 - minLog);
        final backupMax =
            math.max(minBackup, total - _deviceHeight - handleHeight * 2 - minLog);
        final deviceHeight = _deviceHeight.clamp(minDevice, deviceMax);
        final backupHeight = _backupHeight.clamp(minBackup, backupMax);

        return Column(
          children: [
            SizedBox(height: deviceHeight, child: _buildDevices(theme)),
            _buildSplitter(
              'device-splitter',
              theme,
              (delta) => setState(() {
                _deviceHeight =
                    (_deviceHeight + delta).clamp(minDevice, deviceMax);
              }),
              () => setState(() => _deviceHeight = 210),
            ),
            Expanded(child: _buildLog(theme)),
            _buildSplitter(
              'backup-splitter',
              theme,
              (delta) => setState(() {
                _backupHeight =
                    (_backupHeight - delta).clamp(minBackup, backupMax);
              }),
              () => setState(() => _backupHeight = 130),
            ),
            SizedBox(height: backupHeight, child: _buildBackups(theme)),
          ],
        );
      },
    );
  }

  Widget _buildSplitter(
    String key,
    ThemeData theme,
    void Function(double delta) onDrag,
    VoidCallback onReset,
  ) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        key: ValueKey(key),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        onDoubleTap: onReset,
        child: SizedBox(
          height: 12,
          child: Center(
            child: Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(ThemeData theme) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary,
            theme.colorScheme.primary.withValues(alpha: 0.75),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Text(
        '虎',
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        _buildLogo(theme),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '芝士虎整 · 更新器',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '虎码 Rime 整合包 · 多设备一键更新',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const Spacer(),
        TextButton(onPressed: _busy ? null : _openSettings, child: const Text('设置')),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: _busy ? null : _check,
          child: const Text('检查更新'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _busy ? null : () => _runUpdate(dryRun: true),
          child: const Text('仅预演'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy ? null : () => _runUpdate(dryRun: false),
          child: const Text('一键更新'),
        ),
      ],
    );
  }

  List<Widget> _remoteActions() {
    return [
      TextButton.icon(
        onPressed: _busy ? null : _openSync,
        icon: const Icon(Icons.cloud_sync_outlined, size: 18),
        label: const Text('云同步'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _openSyncLibrary,
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text('同步库'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _installFromGithub,
        icon: const Icon(Icons.cloud_download_outlined, size: 18),
        label: const Text('GitHub 方案'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _switchScheme,
        icon: const Icon(Icons.swap_horiz, size: 18),
        label: const Text('换方案'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _installLocalZip,
        icon: const Icon(Icons.archive_outlined, size: 18),
        label: const Text('从本地 zip 安装'),
      ),
    ];
  }

  Widget _buildRemoteLine(ThemeData theme) {
    final text = _remoteVersion.isEmpty
        ? '远端最新：未检查'
        : '远端最新：v$_remoteVersion'
            '（${_remoteDelta ? '增量包' : '完整包'} · $_remoteAsset）';
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ..._remoteActions(),
      ],
    );
  }

  Widget _buildDevices(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Text(
                    '设备 ${_profiles.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_settings.customDirs.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '手动 ${_settings.customDirs.length}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (!Platform.isAndroid)
                    IconButton(
                      tooltip: '添加 Rime 目录',
                      onPressed: _busy ? null : _addRimeDir,
                      icon: const Icon(Icons.add, size: 20),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            Expanded(
              child: _profiles.isEmpty
                  ? Center(
                      child: Text(
                        '没有识别到 Rime 用户目录，点右上角「+」手动添加',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _profiles.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final profile = _profiles[index];
                        final current = rime.readLocalVersion(profile.path);
                        final selected = _selected.contains(profile.path);
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: selected,
                          onChanged: _busy
                              ? null
                              : (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selected.add(profile.path);
                                    } else {
                                      _selected.remove(profile.path);
                                    }
                                  });
                                },
                          title: Row(
                            children: [
                              Text(
                                profile.label,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(width: 8),
                              _buildStatusChip(theme, current),
                              if (_settings.customDirs.contains(profile.path)) ...[
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: _busy
                                      ? null
                                      : () => _renameProfile(profile),
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: Icon(
                                      Icons.edit_outlined,
                                      size: 14,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            profile.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontSize: 11,
                            ),
                          ),
                          secondary: Text(
                            current.isEmpty ? '未知' : 'v$current',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
    );
  }

  Widget _buildStatusChip(ThemeData theme, String current) {
    String label;
    Color color;
    if (_remoteVersion.isEmpty) {
      label = '未检查';
      color = theme.colorScheme.onSurfaceVariant;
    } else if (current.isEmpty) {
      label = '版本未知';
      color = theme.colorScheme.onSurfaceVariant;
    } else if (current == _remoteVersion) {
      label = '已最新';
      color = const Color(0xFF15803D);
    } else {
      label = '可更新到 $_remoteVersion';
      color = theme.colorScheme.primary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildProgress(ThemeData theme, {bool compact = false}) {
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: compact ? 150 : 220,
          child: Text(
            _status,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _statusError
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  List<InlineSpan> _logSpans(ThemeData theme) {
    const latest = '（最新）';
    const updatable = '（可更新）';
    const green = Color(0xFF15803D);
    final spans = <InlineSpan>[];

    for (var i = 0; i < _log.length; i++) {
      final line = _log[i];
      if (line.endsWith(latest) || line.endsWith(updatable)) {
        final suffix = line.endsWith(latest) ? latest : updatable;
        final head = line.substring(0, line.length - suffix.length);
        spans.add(TextSpan(text: head));
        spans.add(TextSpan(
          text: suffix,
          style: TextStyle(
            color: line.endsWith(latest) ? green : theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: line,
          style: line.startsWith('✗')
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ));
      }
      if (i != _log.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  Widget _buildLog(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Text(
                  '运行日志',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _log.isEmpty
                  ? Center(
                      child: Text(
                        '等待操作。建议先「检查更新」，再「仅预演」确认文件，最后「一键更新」。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _logScroll,
                      child: SelectableText.rich(
                        TextSpan(children: _logSpans(theme)),
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackups(ThemeData theme) {
    final rows = <Widget>[];
    for (final profile in _profiles) {
      final backups = _backups[profile.path] ?? const <BackupInfo>[];
      for (final backup in backups) {
        final from = backup.previousVersion.isEmpty
            ? '未知'
            : 'v${backup.previousVersion}';
        final to = backup.version.isEmpty ? '未知' : 'v${backup.version}';
        rows.add(
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text(
              '${profile.label} · ${backup.stamp}',
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text('$from → $to', style: const TextStyle(fontSize: 11)),
            trailing: TextButton(
              onPressed: _busy ? null : () => _rollback(profile, backup),
              child: const Text('回滚'),
            ),
          ),
        );
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            child: Row(
              children: [
                Text(
                  '备份与回滚',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (rows.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _clearBackups,
                    child: const Text('清理备份'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      '还没有备份。勾选“更新前完整快照”后执行一次更新即可生成。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(children: rows),
          ),
        ],
      ),
    );
  }
}
