import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'core/android_platform.dart';
import 'core/cache_manager.dart';
import 'core/android_profiles.dart';
import 'core/deployer.dart';
import 'core/github_client.dart';
import 'core/local_package.dart';
import 'core/package_preparer.dart';
import 'core/rime_profile.dart' as rime;
import 'core/saf_client.dart';
import 'core/saf_installer.dart';
import 'core/scheme_switcher.dart';
import 'core/settings_store.dart';
import 'core/zip_installer.dart';
import 'models.dart';
import 'ui/app_theme.dart';
import 'ui/home_nav.dart';
import 'ui/local_zip_dialog.dart';
import 'ui/remote_scheme_dialog.dart';
import 'ui/settings_dialog.dart';
import 'ui/switch_scheme_dialog.dart';
import 'ui/sync_dialog.dart';
import 'ui/sync_library_dialog.dart';

/// Shizuku 弹窗里的状态说明，按「已连接 / 未授权 / 未启动」分三种。
String shizukuStatusText({required bool granted, required bool running}) {
  if (granted) return 'Shizuku：已连接，可识别并管理 Android/data 下的 Rime 目录。';
  if (running) return 'Shizuku：正在运行，尚未授权。授权后才能读取 Android/data 下的目录。';
  return 'Shizuku：尚未启动，请先打开 Shizuku 应用并启动服务。';
}

/// Shizuku 弹窗里主按钮的文案：已连上就不再提示「连接」。
String shizukuActionLabel({required bool granted, required bool running}) {
  if (granted) return '已连接 Shizuku';
  return running ? '授权 Shizuku' : '连接 Shizuku';
}

void main() {
  runApp(const RimeUpdaterApp());
}

class RimeUpdaterApp extends StatelessWidget {
  const RimeUpdaterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rime 更新器',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final Map<String, Map<String, dynamic>> _androidProfiles = {};
  List<String> _androidUnavailable = [];
  bool _discoveringAndroid = false;
  final SafClient _saf = SafClient();
  /// SAF 目录的版本号缓存（URI -> 版本），异步读取后填充。
  final Map<String, String> _safVersions = {};

  /// 本次运行已清理过残留标记的 SAF 目录，避免重复扫描。
  final Set<String> _safCleaned = {};

  /// Shizuku 连接状态：running / granted。界面据此提示，避免用户不知道
  /// 到底连没连上。
  Map<String, dynamic> _shizukuState = const {};

  /// 当前页面：0 更新器 / 1 同步 / 2 更多 / 3 设置。
  int _tab = 0;

  /// 同步页的子页：0 云同步 / 1 同步库。侧栏入口可以直接落到指定子页。
  int _syncSub = 0;

  /// 上一次停留的页面，用来决定滑动方向（往右切就从右侧滑入）。
  int _prevTab = 0;
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
  String _status = '就绪';
  bool _statusError = false;

  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings = loadSettings();
    _refreshProfiles();
    _refreshBackups();
    // 启动时不自动请求 GitHub：只有用户点「检查更新」或其他操作时才联网
    if (Platform.isAndroid) {
      // 后台迁移旧的下载缓存位置，避免用户再白下一次完整包。
      migrateLegacyAndroidCache();
      _refreshShizukuState();
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid && !_busy) {
      _refreshProfiles();
      _refreshBackups();
    }
  }

  Future<void> _discoverAndroid() async {
    if (_discoveringAndroid) return;
    _discoveringAndroid = true;
    try {
      final status = await shizukuStatus();
      if (mounted) setState(() => _shizukuState = status);
      if (status['granted'] != true) {
        if (mounted) {
          setState(() {
            _androidProfiles.clear();
            _androidUnavailable = [];
          });
        }
        return;
      }
      final found = await discoverAndroidProfiles();
      if (!mounted) return;
      setState(() {
        _androidProfiles.clear();
        _androidUnavailable = [];
        for (final item in found) {
          if (item['found'] == true) {
            _androidProfiles[item['path'] as String] = item;
          } else {
            _androidUnavailable.add(item['label'] as String);
          }
        }
      });
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      if (mounted) _setStatus('Shizuku 识别失败：$error', error: true);
    } finally {
      _discoveringAndroid = false;
    }
  }

  Future<void> _refreshShizukuState() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await shizukuStatus();
      if (!mounted) return;
      setState(() => _shizukuState = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _shizukuState = const {});
    }
  }

  /// Shizuku 状态的文字与颜色：未启动 / 未授权 / 已连接。
  (String, Color) _shizukuBadge(ThemeData theme) {
    final running = _shizukuState['running'] == true;
    final granted = _shizukuState['granted'] == true;
    if (granted) {
      return (
        'Shizuku 已连接',
        theme.brightness == Brightness.dark
            ? AppColors.successDark
            : AppColors.success
      );
    }
    if (running) return ('Shizuku 未授权', theme.colorScheme.tertiary);
    return ('Shizuku 未启动', theme.colorScheme.onSurfaceVariant);
  }

  Future<void> _openAndroidAccess() async {
    final status = await shizukuStatus();
    if (!mounted) return;
    setState(() => _shizukuState = status);
    final granted = status['granted'] == true;
    final running = status['running'] == true;
    final enable = await showDialog<bool>(
        context: context,
        builder: (context) {
          final theme = Theme.of(context);
          final okColor = theme.brightness == Brightness.dark
              ? AppColors.successDark
              : AppColors.success;
          return AlertDialog(
              title: const Text('Android 输入法访问'),
              content: SingleChildScrollView(
                  child: Text('公共目录：授权「所有文件访问」后可直接更新。点设备区「+」可添加目录，'
                      '其中「系统文件选择器」能选 Android/data 与元书这类受限目录。\n\n'
                      '${shizukuStatusText(granted: granted, running: running)}\n\n'
                      '应用内部私有目录（/data/user/0）无法通过普通 Shizuku 访问，请在输入法中使用公共用户目录或导入导出功能。\n\n'
                      '元书（Hamster）的数据存放在应用私有目录，仅通过系统文件选择器（HamsterDocumentsProvider）对外暴露，'
                      '本工具无法直接读写；如需管理，请在元书内使用导入导出，或把方案放到公共目录。'
                      '${_androidUnavailable.isEmpty ? '' : '\n\n未找到可访问目录：${_androidUnavailable.join('、')}。可能使用公共目录或内部私有目录。'}')),
              actions: [
                TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      requestAllFilesAccess();
                    },
                    child: const Text('文件权限')),
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('关闭')),
                if (granted)
                  FilledButton.icon(
                    // 表达「已连上」而不是「不可用」：禁用点击但用成功色呈现。
                    onPressed: null,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    style: FilledButton.styleFrom(
                      disabledBackgroundColor: okColor.withValues(alpha: 0.14),
                      disabledForegroundColor: okColor,
                      side: BorderSide(color: okColor.withValues(alpha: 0.5)),
                    ),
                    label: const Text('已连接 Shizuku'),
                  )
                else
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(
                        shizukuActionLabel(granted: granted, running: running)),
                  ),
              ],
          );
        });
    if (enable != true) return;
    try {
      if (await requestShizuku()) {
        await _refreshShizukuState();
        _setStatus('Shizuku 已连接');
        await _discoverAndroid();
      } else if (mounted) {
        _setStatus('未授予 Shizuku 权限');
      }
    } catch (error) {
      if (mounted) _setStatus('$error', error: true);
    }
  }

  String _profileVersion(Profile profile) {
    if (profile.isSaf) return _safVersions[profile.safUri] ?? '';
    return _androidProfiles[profile.path]?['version'] as String? ??
        rime.readLocalVersion(profile.path);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logScroll.dispose();
    super.dispose();
  }

  void _refreshProfiles() {
    if (Platform.isAndroid && !_discoveringAndroid) _discoverAndroid();
    var profiles = rime.detectProfiles(hidden: _settings.hiddenDirs);
    for (final item in _androidProfiles.values) {
      final path = item['path'] as String;
      if (_settings.hiddenDirs.contains(path)) continue;
      profiles.removeWhere((profile) => profile.path == path);
      profiles.add(Profile(
          label: '${item['label']} · Shizuku',
          path: path,
          kind: (item['package'] as String).contains('fcitx')
              ? 'fcitx5'
              : 'trime'));
    }
    for (final custom in rime.profilesFromPaths(
      _settings.customDirs,
      names: _settings.customNames,
      allowUnrecognized: true,
    )) {
      if (!profiles.any((profile) => profile.path == custom.path)) {
        profiles.add(custom);
      }
    }
    // SAF 目录（如元书）没有真实文件系统路径，用 content:// URI 表示。
    for (final item in _settings.safDirs) {
      final uri = item['uri'] as String? ?? '';
      if (uri.isEmpty) continue;
      final rootUri = item['root'] as String? ?? uri.split('|').first;
      final sub = item['sub'] as String? ?? '';
      final label = item['label'] as String? ?? 'SAF 目录';
      profiles.add(Profile(
        label: sub.isEmpty ? label : '$label · $sub',
        path: rootUri,
        kind: 'saf',
        safUri: uri,
      ));
    }
    // 重命名对所有设备生效：自动识别、Shizuku、SAF 目录一律按 customNames 覆盖。
    // 之前只在手动添加的目录上生效，导致自动识别的设备改名后仍显示原名。
    // 注意：applyCustomNames 在无自定义名称时会原样返回同一个 list，
    // 因此必须重新赋值而不是 clear + addAll（后者会把列表清空）。
    profiles = rime.applyCustomNames(profiles, _settings.customNames);

    for (final profile in profiles) {
      // 只对首次出现的设备默认勾选，用户取消后不会被重新勾上
      if (_known.add(profile.identity)) {
        _selected.add(profile.identity);
      }
    }
    _selected.removeWhere(
      (id) => !profiles.any((profile) => profile.identity == id),
    );
    _refreshSafVersions(profiles.where((p) => p.isSaf).toList());
    setState(() => _profiles = profiles);
  }

  /// 统一的「添加目录」入口。Android 上 SAF 选择器能覆盖手动填路径的全部场景，
  /// 还能选 Android/data、元书这类受限目录，所以合并成一个入口再让用户选方式。
  Future<void> _addDirectory() async {
    if (_busy) return;
    if (!Platform.isAndroid) {
      await _addRimeDir();
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('添加 Rime 目录'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'saf'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('系统文件选择器（推荐）'),
                  SizedBox(height: 2),
                  Text(
                    '可以选 Android/data 里的输入法目录，以及元书等'
                    '只在系统选择器里出现的目录。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'path'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('手动输入公共路径'),
                  SizedBox(height: 2),
                  Text(
                    '适用于 /storage/emulated/0 下的公共目录；'
                    'Android/data 与应用私有目录用上面的选择器。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'saf') {
      await _addSafDir();
    } else {
      await _addRimeDir();
    }
  }

  Future<void> _addRimeDir() async {
    if (_busy) return;
    String? selected;
    if (Platform.isAndroid) {
      final controller = TextEditingController(text: '/storage/emulated/0/');
      selected = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('添加 Rime 公共目录'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                        labelText: '用户目录路径', helperText: '填写输入法设置中的公共用户目录')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('添加'))
                ],
              ));
      // The dialog route may still be animating, so dispose after its widgets unmount.
      Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
      if (selected != null &&
          (!p.isAbsolute(selected) || !Directory(selected).existsSync())) {
        _setStatus('目录不存在或无法访问；Android/data 目录请连接 Shizuku', error: true);
        return;
      }
    } else {
      selected = await pickDirectory();
    }
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
      hiddenDirs: _settings.hiddenDirs
          .where((dir) => p.normalize(dir) != normalized)
          .toList(),
    );
    saveSettings(updated);
    setState(() => _settings = updated);
    _refreshProfiles();
    setState(() => _selected.add(normalized));  // 手动目录无 SAF，identity 即路径
    _setStatus('已添加 ${p.basename(normalized)}');
  }

  /// 从 SAF 的 document URI 推测一个默认显示名（取最后一级目录名）。
  String _safDefaultLabel(String uri) {
    const marker = '/document/';
    final index = uri.lastIndexOf(marker);
    final docId = index >= 0 ? uri.substring(index + marker.length) : uri;
    final decoded = Uri.decodeComponent(docId).replaceAll('\\', '/');
    final parts = decoded.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? 'SAF 目录' : parts.last;
  }

  /// 通过系统文件选择器添加 SAF 目录（元书 / SD 卡等）。
  /// 先用 SAF 客户端让用户选择目录，再尝试识别里面的 Rime 方案子目录。
  Future<void> _addSafDir() async {
    if (_busy) return;
    SafRoot? root;
    try {
      root = await _saf.pickDirectory(label: 'SAF 目录');
    } catch (error) {
      _setStatus('无法打开目录选择器：$error', error: true);
      return;
    }
    if (root == null) return;
    if (!mounted) return;

    final labelName = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: _safDefaultLabel(root!.uri));
        return AlertDialog(
          title: const Text('命名这个目录'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '显示名称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
    if (labelName == null) return;

    var sub = '';
    try {
      final detected = await _saf.detectRimeSubdir(root);
      if (detected == null) {
        _setStatus('该目录里没有找到 Rime 配置，仍然添加以便手动指定', error: true);
      } else {
        sub = detected;
      }
    } catch (error) {
      _setStatus('读取目录失败：$error', error: true);
      return;
    }

    final label = labelName.isEmpty ? root.label : labelName;
    final safUri = sub.isEmpty ? root.uri : '${root.uri}|$sub';
    final updated = _settings.copyWith(
      safDirs: [
        ..._settings.safDirs.where((item) => item['uri'] != safUri),
        {'uri': safUri, 'label': label, 'root': root.uri, 'sub': sub},
      ],
    );
    saveSettings(updated);
    setState(() => _settings = updated);
    _refreshProfiles();
    _setStatus('已添加目录 $label');
  }

  Future<void> _removeSafDir(Map<String, dynamic> item) async {
    if (_busy) return;
    final uri = item['uri'] as String? ?? '';
    final label = item['label'] as String? ?? uri;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除 SAF 目录'),
        content: Text('从列表移除「$label」？\n只取消授权，不会删除任何文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final rootUri = item['root'] as String? ?? '';
    if (rootUri.isNotEmpty) {
      try {
        await _saf.releasePermission(rootUri);
      } catch (_) {
        // 释放授权失败不影响本地记录清理
      }
    }
    final updated = _settings.copyWith(
      safDirs: _settings.safDirs.where((e) => e['uri'] != uri).toList(),
    );
    saveSettings(updated);
    setState(() => _settings = updated);
    _refreshProfiles();
    _setStatus('已移除 $label');
  }

  Future<void> _removeProfile(Profile profile) async {
    if (_busy) return;
    final manual = _settings.customDirs.contains(profile.path);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除设备'),
        content: Text(
          '从列表移除「${profile.label}」？\n'
          '${profile.path}\n\n'
          '只会取消识别，不会删除任何 Rime 文件。'
          '${manual ? '需要时可用「+」再次添加。' : '删除后不会再被自动识别，需要时点「+」手动添加。'}',
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
    if (confirmed != true) return;

    final updated = manual
        ? _settings.copyWith(
            customDirs: _settings.customDirs
                .where((dir) => dir != profile.path)
                .toList(),
            customNames: Map<String, String>.of(_settings.customNames)
              ..remove(profile.path),
          )
        : _settings.copyWith(
            hiddenDirs: [..._settings.hiddenDirs, profile.path],
          );
    saveSettings(updated);
    _known.remove(profile.identity);
    setState(() {
      _settings = updated;
      _selected.remove(profile.identity);
      _profiles = _profiles.where((item) => item.path != profile.path).toList();
    });
    _refreshProfiles();
    _refreshBackups();
    _setStatus('已删除设备 ${profile.label}');
  }

  /// 异步读取 SAF 目录的版本号并刷新界面（SAF 只能异步访问）。
  Future<void> _refreshSafVersions(List<Profile> safProfiles) async {
    if (safProfiles.isEmpty) return;
    var changed = false;
    for (final profile in safProfiles) {
      final uri = profile.safUri;
      if (uri == null || uri.isEmpty) continue;
      // 一次性清掉历史写入失败留下的「N.cheese-tiger-version」残留。
      if (_safCleaned.add(uri)) {
        final removed = await cleanStaleSafMarkers(_saf, uri, log: _logLine);
        if (removed > 0) {
          _logLine('  已清理 $removed 个残留版本标记');
          _safVersions.remove(uri);
        }
      }
      try {
        final version = await readSafLocalVersion(_saf, uri);
        if (_safVersions[uri] != version) {
          _safVersions[uri] = version;
          changed = true;
        }
      } catch (_) {
        // 授权失效或目录不可读时保持「版本未知」，不打断界面。
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _refreshBackups() {
    final backups = <String, List<BackupInfo>>{};
    for (final profile in _profiles) {
      final remote = _androidProfiles[profile.path];
      backups[profile.path] = remote == null
          ? rime.listBackups(profile.path)
          : (remote['backups'] as List)
              .map((item) => BackupInfo(
                  stamp: item['stamp'] as String,
                  version: item['version'] as String,
                  previousVersion: item['previous'] as String,
                  overwritten: item['overwritten'] as int,
                  created: item['created'] as int,
                  deleted: item['deleted'] as int))
              .toList();
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
        final current = _profileVersion(profile);
        return current.isNotEmpty && current != release.version;
      });
      _logLine('远端最新：v${release.version}（${release.assetName}）'
          '${outdated ? '（可更新）' : '（最新）'}');
      _logLine('包类型：${release.isDelta ? '增量包' : '完整包'}');
      _releaseCache = release;
      _releaseCacheAt = DateTime.now();
      _releaseCacheRepo = _settings.repo.trim();
      _setStatus('检查完成');
    } on AlreadyLatest catch (latest) {
      // 全部设备已最新：没有下载任何包，直接结束。
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('全部设备已是最新 v${latest.version}');
      _refreshProfiles();
      _refreshBackups();
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
      final version = _remoteVersion.isEmpty ? '远端最新版本' : 'v$_remoteVersion';
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
        // SAF 目录没有文件系统路径，必须走版本缓存，否则永远被当成「版本未知」
        // 而白白下载几百 MB 完整包。
        installedVersions: _profiles.map(_profileVersion).toList(),
        profilePaths: _profiles.map((p) => p.path).toList(),
        log: _logLine,
        progress: (percent) {
          if (mounted) setState(() => _progress = percent / 100);
        },
        release: cached,
      );
      _logLine('目标版本：v${package.version}（${package.assetName}）');
      _logLine('准备更新 ${targets.length} 个用户目录'
          '（${dryRun ? '预演' : '正式'}）');

      final picked =
          _profiles.where((p) => targets.contains(p.identity)).toList();
      final failed = <String>[];
      for (var index = 0; index < picked.length; index++) {
        final profile = picked[index];
        _logLine('');
        _logLine('[${profile.label}] ${profile.path}');
        final base = 55 + index * 45 ~/ picked.length;
        final span = 45 ~/ picked.length;

        // 已经在本版本上的设备直接跳过：避免每次点更新都对所有设备
        // 重新遍历文件并重复部署（重启输入法）。
        if (_profileVersion(profile) == package.version) {
          _logLine('  已是最新 v${package.version}，跳过');
          continue;
        }

        // 单个设备失败不应中断整批：记录后继续下一个。
        try {
        // SAF 目录（如元书）没有文件系统路径，走 SAF 专用安装流程。
        if (profile.isSaf) {
          final domain = profile.safUri!.split('/tree/').first;
          final ok = await _saf.hasPermission(profile.safUri!) ||
              await _saf.hasPermission(domain);
          if (!ok) {
            _logLine('✗ 该 SAF 目录的访问授权已失效，请移除后重新添加：${profile.label}');
            _setStatus('SAF 授权失效，请重新添加 ${profile.label}', error: true);
            continue;
          }
          final result = await applyZipToSaf(
            client: _saf,
            rootUri: profile.safUri!,
            zipPath: package.zipPath,
            version: package.version,
            snapshot: _settings.snapshot && !dryRun,
            dryRun: dryRun,
            log: _logLine,
          );
          _logLine('  SAF：${dryRun ? '将' : '已'}写入 ${result.copied} 个文件，'
              '跳过 ${result.skipped} 个');
          if (result.backupStamp.isNotEmpty) {
            _logLine('  已创建 SAF 备份 ${result.backupStamp}');
          }
          if (!dryRun) {
            _logLine('  注意：SAF 目录无法自动部署，请在元书内重新加载方案');
          }
          continue;
        }

        final stats = await withProfileDirectory(
            profile,
            (local) => applyZip(
                  zipPath: package.zipPath,
                  target: local.path,
                  version: package.version,
                  dryRun: dryRun,
                  snapshot: _settings.snapshot,
                  log: _logLine,
                  onFile: (done, total) {
                    if (!mounted) return;
                    setState(() {
                      _progress =
                          (base + (total > 0 ? span * done ~/ total : span)) /
                              100;
                    });
                  },
                ),
            readOnly: dryRun);
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }

        if (_settings.deploy && !dryRun) {
          await deployProfile(profile,
              restart: _settings.restart, log: _logLine);
        }
        } catch (error) {
          _logLine('✗ ${profile.label} 失败：$error');
          failed.add(profile.label);
        }
      }

      // 更新成功后只保留当前版本用到的包，避免每次发版都多留一份
      // （完整包单个可达几百 MB）。
      if (!dryRun) {
        final keep = <String>{
          package.assetName,
          '${package.assetName}.sha256',
          'MODEL.json',
        };
        final freed = pruneCache(resolveCacheDir(_settings), keep: keep);
        if (freed > 0) {
          _logLine('  已清理旧缓存 '
              '${(freed / 1024 / 1024).toStringAsFixed(1)} MB');
        }
      }

      if (!mounted) return;
      setState(() => _progress = 1);
      if (failed.isEmpty) {
        _setStatus(dryRun ? '预演完成' : '更新完成');
      } else {
        final stage = dryRun ? '预演' : '更新';
        _setStatus('$stage部分失败：${failed.join('、')}', error: true);
      }
      _refreshProfiles();
      _refreshBackups();
    } on AlreadyLatest catch (latest) {
      // 全部设备已最新：没有下载任何包，直接结束。
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('全部设备已是最新 v${latest.version}');
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
      await withProfileDirectory(
          profile,
          (local) =>
              rollback(target: local.path, stamp: backup.stamp, log: _logLine));
      if (_settings.deploy) {
        await deployProfile(profile, restart: _settings.restart, log: _logLine);
      }
      setState(() => _progress = 1);
      _setStatus('回滚完成');
      _refreshProfiles();
      _refreshBackups();
    } on AlreadyLatest catch (latest) {
      // 全部设备已最新：没有下载任何包，直接结束。
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('全部设备已是最新 v${latest.version}');
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

        final stats = await withProfileDirectory(
            profile,
            (local) => applyZip(
                  zipPath: options.path,
                  target: local.path,
                  version: options.version,
                  dryRun: false,
                  snapshot: _settings.snapshot,
                  log: _logLine,
                  onFile: (done, total) {
                    if (!mounted) return;
                    setState(() {
                      _progress =
                          (base + (total > 0 ? span * done ~/ total : span)) /
                              100;
                    });
                  },
                ));
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }
        if (_settings.deploy) {
          await deployProfile(
            profile,
            restart: _settings.restart,
            log: _logLine,
          );
        }
      }
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('安装完成');
      _refreshProfiles();
      _refreshBackups();
    } on AlreadyLatest catch (latest) {
      // 全部设备已最新：没有下载任何包，直接结束。
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('全部设备已是最新 v${latest.version}');
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
          final stats = await withProfileDirectory(profile, (local) {
            final backup = backupUserData(
              local.path,
              label: profile.label,
              log: _logLine,
            );
            cleanScheme(local.path, log: _logLine);
            final stats = applyZip(
              zipPath: options.path,
              target: local.path,
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
            return stats;
          });
          if (_settings.deploy) {
            await deployProfile(
              profile,
              restart: _settings.restart,
              log: _logLine,
            );
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

  Future<void> _clearProfile(Profile profile) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空 Rime 目录'),
        content: Text(
          '将删除「${profile.label}」目录下的全部内容：\n'
          '${profile.path}\n\n'
          '⚠️ 这包括个人数据（词库、自造词、调频、开关记忆），'
          '且不备份、不可恢复。\n\n'
          '删除后需要重新安装方案才能使用该设备。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = '正在清空…';
      _statusError = false;
    });
    _logLine('');
    _logLine('[${profile.label}] ${profile.path}');
    try {
      final removed = await withProfileDirectory(
        profile,
        (local) async =>
            rime.clearRimeDir(local.path, log: _logLine),
      );
      setState(() => _progress = 1);
      _setStatus('已清空 ${profile.label}（$removed 项）');
      _refreshProfiles();
      _refreshBackups();
    } on AlreadyLatest catch (latest) {
      // 全部设备已最新：没有下载任何包，直接结束。
      if (!mounted) return;
      setState(() => _progress = 1);
      _setStatus('全部设备已是最新 v${latest.version}');
      _refreshProfiles();
      _refreshBackups();
    } catch (error) {
      _logLine('✗ $error');
      _setStatus('$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

    setState(() => _busy = true);
    try {
      var removed = 0;
      for (final profile in _profiles) {
        removed += await withProfileDirectory(
            profile, (local) => rime.clearBackups(local.path));
      }
      _refreshProfiles();
      _refreshBackups();
      _setStatus('已清理 $removed 份备份');
    } catch (error) {
      _setStatus('清理备份失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

        final stats = await withProfileDirectory(
            profile,
            (local) => applyZip(
                  zipPath: cachePath,
                  target: local.path,
                  version: options.version,
                  dryRun: false,
                  snapshot: _settings.snapshot,
                  log: _logLine,
                  onFile: (done, total) {
                    if (!mounted) return;
                    setState(() {
                      _progress =
                          (base + (total > 0 ? span * done ~/ total : span)) /
                              100;
                    });
                  },
                ));
        if (stats.backupStamp != null) {
          _logLine('  已创建备份 ${stats.backupStamp}');
        }
        if (_settings.deploy) {
          await deployProfile(
            profile,
            restart: _settings.restart,
            log: _logLine,
          );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 960 || constraints.maxHeight < 680;
          if (compact) {
            return Column(
              children: [
                Expanded(
                  child: _buildAnimatedPage(constraints.maxWidth, theme,
                      compact: true),
                ),
                HomeNavBar(
                  items: _navItems,
                  index: _tab,
                  onChanged: _switchTab,
                ),
              ],
            );
          }
          return Row(
            children: [
              _buildSidebar(theme),
              Expanded(
                child: _buildAnimatedPage(constraints.maxWidth, theme,
                    compact: false),
              ),
            ],
          );
        }),
      ),
    );
  }

  List<HomeNavItem> get _navItems => const [
        HomeNavItem(icon: Icons.bolt_rounded, label: '更新器'),
        HomeNavItem(icon: Icons.cloud_sync_outlined, label: '同步'),
        HomeNavItem(icon: Icons.widgets_outlined, label: '更多'),
        HomeNavItem(icon: Icons.settings_outlined, label: '设置'),
      ];

  void _switchTab(int index) {
    if (index == _tab) return;
    setState(() {
      _prevTab = _tab;
      _tab = index;
    });
  }

  /// 切页动画：按切换方向横向滑入/滑出，并叠加淡入淡出。
  Widget _buildAnimatedPage(
      double width, ThemeData theme, {required bool compact}) {
    final direction = _tab >= _prevTab ? 1.0 : -1.0;
    final currentKey = ValueKey('page-$_tab');
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // 只保留当前页：旧页立刻退场，不留残影。
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [
            if (currentChild != null) currentChild,
          ],
        ),
        transitionBuilder: (child, animation) {
          // 新页从切换方向整屏滑入；旧页不再绘制。
          final begin = Offset(direction, 0);
          final position = Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ));
          return SlideTransition(position: position, child: child);
        },
        child: KeyedSubtree(
          key: currentKey,
          child: _buildPage(width, theme, compact: compact),
        ),
      ),
    );
  }

  /// 三个内容页共用的页面容器。
  Widget _buildPage(double width, ThemeData theme, {required bool compact}) {
    switch (_tab) {
      case 1:
        return _SyncPage(
          settings: _settings,
          profiles: _profiles,
          compact: compact,
          sub: _syncSub,
          onSubChanged: (value) => setState(() => _syncSub = value),
        );
      case 2:
        return _buildMorePage(theme, compact: compact);
      case 3:
        return _buildSettingsPage(theme, compact: compact);
      default:
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 24,
            compact ? 16 : 20,
            compact ? 16 : 24,
            compact ? 0 : 20,
          ),
          child: compact ? _buildCompactBody(theme) : _buildDesktopBody(theme),
        );
    }
  }

  Widget _buildSettingsPage(ThemeData theme, {required bool compact}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 16 : 24, compact ? 16 : 20, compact ? 16 : 24, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.settings_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('设置', style: theme.textTheme.titleMedium),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: SettingsDialog(
                  settings: _settings,
                  embedded: true,
                  onSaved: (updated) {
                    saveSettings(updated);
                    setState(() => _settings = updated);
                    _setStatus('设置已保存');
                    _refreshProfiles();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMorePage(ThemeData theme, {required bool compact}) {
    Widget tile(IconData icon, String title, String subtitle, VoidCallback? onTap) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: Icon(icon, size: 20),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _busy ? null : onTap,
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
          compact ? 16 : 24, compact ? 16 : 20, compact ? 16 : 24, 8),
      children: [
        Text('更多', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('装包、换方案与设备访问',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 14),
        tile(Icons.cloud_download_outlined, 'GitHub 方案',
            '从任意 GitHub 仓库的 Release 安装', _installFromGithub),
        tile(Icons.inventory_2_outlined, '从本地 zip 安装',
            '选择本机方案包，按同一套规则覆盖', _installLocalZip),
        tile(Icons.swap_horiz_rounded, '换方案',
            '备份个人数据后整体替换为另一套方案', _switchScheme),
        if (Platform.isAndroid)
          tile(Icons.admin_panel_settings_outlined, 'Android 权限与 Shizuku',
              '公共目录授权、受限目录访问状态', _openAndroidAccess),
        const SizedBox(height: 16),
        SizedBox(height: 320, child: _buildBackups(theme)),
      ],
    );
  }

  Widget _buildSidebar(ThemeData theme) {
    Widget action(IconData icon, String label, VoidCallback? onTap,
        {bool selected = false}) {
      return Padding(
        key: ValueKey('sidebar-$label'),
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: ListTile(
            dense: true,
            minLeadingWidth: 18,
            horizontalTitleGap: 10,
            leading: Icon(icon,
                size: 18, color: selected ? theme.colorScheme.primary : null),
            title: Text(label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? theme.colorScheme.primary : null,
                )),
            onTap: _busy || selected ? null : onTap,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
    }

    return Container(
      width: 180,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border:
            Border(right: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 24, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            _buildLogo(theme, size: 32),
            const SizedBox(width: 10),
            const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Rime',
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.6)),
                  Text('UPDATER',
                      style: TextStyle(fontSize: 9, letterSpacing: 2)),
                ]),
          ]),
          const SizedBox(height: 32),
          action(Icons.space_dashboard_outlined, '更新器', () => _switchTab(0),
              selected: _tab == 0),
          action(Icons.widgets_outlined, '更多', () => _switchTab(2),
              selected: _tab == 2),
          const SizedBox(height: 24),
          Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 10),
              child: Text('方案管理', style: theme.textTheme.labelSmall)),
          action(
              Icons.cloud_download_outlined, 'GitHub 方案', _installFromGithub),
          action(Icons.inventory_2_outlined, '从本地 zip 安装', _installLocalZip),
          action(Icons.swap_horiz_rounded, '换方案', _switchScheme),
          const SizedBox(height: 24),
          Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 10),
              child: Text('个人数据', style: theme.textTheme.labelSmall)),
          action(Icons.cloud_sync_outlined, '云同步', () {
            setState(() => _syncSub = 0);
            _switchTab(1);
          }, selected: _tab == 1 && _syncSub == 0),
          action(Icons.folder_open_outlined, '同步库', () {
            setState(() => _syncSub = 1);
            _switchTab(1);
          }, selected: _tab == 1 && _syncSub == 1),
          const Spacer(),
          const Divider(),
          const SizedBox(height: 8),
          action(Icons.settings_outlined, '设置', () => _switchTab(3),
              selected: _tab == 3),
          const SizedBox(height: 10),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('你的输入，保持新鲜。',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10))),
        ],
      ),
    );
  }

  Widget _buildDesktopBody(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(theme),
        const SizedBox(height: 20),
        _buildHero(theme),
        const SizedBox(height: 20),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 3, child: _buildDevices(theme)),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: _buildLog(theme)),
          ]),
        ),
      ],
    );
  }

  Widget _buildCompactBody(ThemeData theme) {
    final deviceHeight = math.min(360.0, 84.0 * _profiles.length + 68.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _buildHeader(theme, compact: true),
      const SizedBox(height: 16),
      Expanded(
          child: SingleChildScrollView(
              child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHero(theme, compact: true),
          const SizedBox(height: 12),
          _buildMainButtonRow(),
          const SizedBox(height: 16),
          SizedBox(
              height: math.max(150, deviceHeight), child: _buildDevices(theme)),
          const SizedBox(height: 16),
          SizedBox(height: 260, child: _buildLog(theme)),
        ],
      ))),
    ]);
  }

  Widget _buildMainButtonRow() {
    final style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size.fromHeight(48)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
              child: OutlinedButton.icon(
            style: style,
            onPressed: _busy ? null : _check,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('检查更新'),
          )),
          const SizedBox(width: 10),
          Expanded(
              child: OutlinedButton.icon(
            style: style,
            onPressed: _busy ? null : () => _runUpdate(dryRun: true),
            icon: const Icon(Icons.play_circle_outline, size: 18),
            label: const Text('仅预演'),
          )),
        ]),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: style,
          onPressed: _busy ? null : () => _runUpdate(dryRun: false),
          icon: const Icon(Icons.arrow_upward_rounded, size: 18),
          label: const Text('一键更新'),
        ),
      ],
    );
  }

  Widget _buildLogo(ThemeData theme, {double size = 36}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(
        'R',
        style: TextStyle(
          fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
          color: theme.colorScheme.onPrimary,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, {bool compact = false}) {
    return Row(children: [
      if (compact) ...[_buildLogo(theme, size: 32), const SizedBox(width: 10)],
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Rime 更新器', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('管理方案，让每台设备同步向前。', style: theme.textTheme.bodySmall),
      ])),
      if (compact)
        // 设置已经有底部导航入口，这里不再重复放图标。
        const SizedBox.shrink()
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.outlineVariant)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_busy ? Icons.sync : Icons.check_circle_outline,
                size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(_busy ? '任务进行中' : '本地工作区', style: theme.textTheme.bodySmall),
          ]),
        ),
    ]);
  }

  int _countOutdated() {
    if (_remoteVersion.isEmpty) return 0;
    return _profiles.where((profile) {
      final current = _profileVersion(profile);
      return current.isNotEmpty && current != _remoteVersion;
    }).length;
  }

  Widget _buildStat(
    ThemeData theme,
    String label,
    String value, {
    bool highlight = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.0,
            letterSpacing: -0.4,
            color: highlight
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 5),
        Text(label, style: theme.textTheme.labelMedium),
      ],
    );
  }

  Widget _buildHero(ThemeData theme, {bool compact = false}) {
    final checked = _remoteVersion.isNotEmpty;
    final outdated = _countOutdated();
    final backups =
        _backups.values.fold<int>(0, (sum, list) => sum + list.length);
    return Container(
      padding: EdgeInsets.all(compact ? 18 : 22),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.system_update_alt_rounded,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('方案更新', style: theme.textTheme.titleMedium),
          const Spacer(),
          Text(checked ? (_remoteDelta ? '增量更新' : '完整包') : '等待检查',
              style: theme.textTheme.bodySmall),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(checked ? 'v$_remoteVersion' : '准备好，迎接下一次更新',
                    style: TextStyle(
                        fontSize: compact ? 21 : 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.8,
                        color: theme.colorScheme.onSurface,
                        fontFamily: checked ? 'Menlo' : null,
                        fontFamilyFallback: checked
                            ? const ['Consolas', 'monospace', 'Courier New']
                            : null)),
                const SizedBox(height: 8),
                Text(checked ? _remoteAsset : '先检查版本，再预演文件变更，安心更新。',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
              ])),
          if (!compact) ...[
            const SizedBox(width: 24),
            _buildStat(theme, '设备', '${_profiles.length}'),
            const SizedBox(width: 24),
            _buildStat(theme, '可更新', checked ? '$outdated' : '—',
                highlight: outdated > 0),
            const SizedBox(width: 24),
            _buildStat(theme, '备份', '$backups'),
          ],
        ]),
        const SizedBox(height: 18),
        if (!compact) ...[
          Row(children: [
            FilledButton.icon(
                onPressed: _busy ? null : () => _runUpdate(dryRun: false),
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                label: const Text('一键更新')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
                onPressed: _busy ? null : _check,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('检查更新')),
            const SizedBox(width: 8),
            TextButton.icon(
                onPressed: _busy ? null : () => _runUpdate(dryRun: true),
                icon: const Icon(Icons.play_circle_outline, size: 16),
                label: const Text('仅预演')),
          ]),
          const SizedBox(height: 18),
        ],
        const Divider(),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.code_rounded,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
              child: Text(_settings.repo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontSize: 10.5, fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New']))),
          const SizedBox(width: 8),
          Flexible(
              child: Text(_status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: _statusError ? theme.colorScheme.error : null))),
        ]),
        if (_busy) ...[const SizedBox(height: 12), _buildProgress(theme)],
      ]),
    );
  }

  Widget _buildDevices(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(
              children: [
                Text('设备', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('DEVICES', style: theme.textTheme.labelMedium),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${_profiles.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_settings.customDirs.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    '手动 ${_settings.customDirs.length}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
                const Spacer(),
                if (Platform.isAndroid) ...[
                  _buildShizukuBadge(theme),
                  IconButton(
                      tooltip: 'Android 权限与 Shizuku',
                      onPressed: _busy ? null : _openAndroidAccess,
                      icon: const Icon(Icons.admin_panel_settings_outlined,
                          size: 18),
                      visualDensity: VisualDensity.compact),
                ],
                IconButton(
                    tooltip: '重新识别目录',
                    onPressed: _busy
                        ? null
                        : () {
                            _refreshShizukuState();
                            _refreshProfiles();
                            _refreshBackups();
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    visualDensity: VisualDensity.compact),
                IconButton(
                  tooltip: '添加 Rime 目录',
                  onPressed: _busy ? null : _addDirectory,
                  icon: const Icon(Icons.add, size: 18),
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _profiles.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        Platform.isAndroid
                            ? '没有识别到 Rime 用户目录。点盾牌连接 Shizuku，或点「+」添加公共目录。'
                            : '没有识别到 Rime 用户目录，点右上角「+」手动添加',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: _profiles.length,
                    itemBuilder: (context, index) =>
                        _buildDeviceRow(theme, _profiles[index]),
                  ),
          ),
        ],
      ),
    );
  }

  void _toggleProfile(Profile profile) {
    setState(() {
      final id = profile.identity;
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Widget _buildDeviceRow(ThemeData theme, Profile profile) {
    final current = _profileVersion(profile);
    final selected = _selected.contains(profile.identity);
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: .07)
            : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: _busy ? null : () => _toggleProfile(profile),
          child: Semantics(
            label: profile.label,
            checked: selected,
            enabled: !_busy,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
              child: Row(
                children: [
                  _buildSelectBox(theme, selected),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                profile.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.1,
                                ),
                              ),
                            ),
                            if (_settings.customDirs
                                .contains(profile.path)) ...[
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: _busy
                                    ? null
                                    : () => _renameProfile(profile),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 13,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _buildStatusChip(theme, current),
                              Text(current.isEmpty ? '版本未知' : 'v$current',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'], fontSize: 10.5)),
                            ]),
                        const SizedBox(height: 4),
                        Text(
                          profile.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    enabled: !_busy,
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.more_vert,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onSelected: (value) {
                      if (value == 'rename') {
                        _renameProfile(profile);
                      } else if (value == 'clear') {
                        _clearProfile(profile);
                      } else if (value == 'removeSaf') {
                        final item = _settings.safDirs.firstWhere(
                          (e) => e['uri'] == profile.safUri,
                          orElse: () => <String, dynamic>{},
                        );
                        if (item.isNotEmpty) _removeSafDir(item);
                      } else if (value == 'remove') {
                        _removeProfile(profile);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                          value: 'rename', child: Text('重命名设备')),
                      if (!profile.isSaf)
                        const PopupMenuItem(
                            value: 'clear', child: Text('清空 Rime 目录')),
                      const PopupMenuDivider(),
                      if (profile.isSaf)
                        const PopupMenuItem(
                            value: 'removeSaf', child: Text('移除 SAF 目录'))
                      else
                        const PopupMenuItem(
                            value: 'remove', child: Text('删除设备')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShizukuBadge(ThemeData theme) {
    final (label, color) = _shizukuBadge(theme);
    final narrow = MediaQuery.of(context).size.width < 640;
    // 窄屏也要能看出连接状态，用短文案；宽屏显示完整句子。
    final short = label.replaceFirst('Shizuku', '').trim();
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: _busy ? null : _openAndroidAccess,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, size: 7, color: color),
            const SizedBox(width: 5),
            Text(
                narrow ? short : label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildSelectBox(ThemeData theme, bool selected) {
    return ExcludeSemantics(
        child: Icon(
      selected
          ? Icons.check_box_rounded
          : Icons.check_box_outline_blank_rounded,
      size: 21,
      color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
    ));
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
      color = theme.brightness == Brightness.dark
          ? AppColors.successDark
          : AppColors.success;
    } else {
      label = '可更新';
      color = theme.colorScheme.primary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              height: 1.2,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(ThemeData theme) {
    return LinearProgressIndicator(
      value: _progress,
      minHeight: 4,
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
    );
  }

  List<InlineSpan> _logSpans() {
    const latest = '（最新）';
    const updatable = '（可更新）';
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
            color: line.endsWith(latest)
                ? AppColors.consoleGreen
                : AppColors.consoleAccent,
            fontWeight: FontWeight.w600,
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: line,
          style: line.startsWith('✗')
              ? const TextStyle(color: AppColors.consoleRed)
              : null,
        ));
      }
      if (i != _log.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return spans;
  }

  Widget _buildLog(ThemeData theme) {
    final consoleColor = theme.brightness == Brightness.dark
        ? AppColors.consoleBgDark
        : AppColors.consoleBg;
    return Container(
      decoration: BoxDecoration(
        color: consoleColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.consoleAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'CONSOLE',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.6,
                    color: AppColors.consoleMuted,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '运行日志',
                  style: TextStyle(fontSize: 11, color: AppColors.consoleMuted),
                ),
                const Spacer(),
                Text(
                  _log.isEmpty ? 'IDLE' : '${_log.length} LINES',
                  style: const TextStyle(
                    fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
                    fontSize: 10,
                    letterSpacing: .6,
                    color: AppColors.consoleMuted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: consoleColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: _log.isEmpty
                  ? const Center(
                      child: Text(
                        '等待操作\n\n检查版本、预演与更新的过程\n都会记录在这里。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: AppColors.consoleMuted,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: _logScroll,
                      child: SelectableText.rich(
                        TextSpan(children: _logSpans()),
                        style: const TextStyle(
                          fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
                          fontSize: 12,
                          height: 1.6,
                          color: AppColors.consoleText,
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
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                const SizedBox(width: 4),
                Icon(
                  Icons.history_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${profile.label} · ${backup.stamp}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$from → $to',
                        style: TextStyle(
                          fontFamily: 'Menlo', fontFamilyFallback: ['Consolas', 'monospace', 'Courier New'],
                          fontSize: 10.5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _rollback(profile, backup),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: const Text('回滚'),
                ),
              ],
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
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
            child: Row(
              children: [
                Text('BACKUPS', style: theme.textTheme.labelMedium),
                const SizedBox(width: 8),
                Text('备份与回滚', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (rows.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _clearBackups,
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                    child: const Text('清理备份'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '还没有备份。勾选“更新前完整快照”后执行一次更新即可生成。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    children: rows,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 同步页：把「云同步」与「同步库」放进同一页，用分段控件切换。
class _SyncPage extends StatelessWidget {
  const _SyncPage({
    required this.settings,
    required this.profiles,
    required this.compact,
    required this.sub,
    required this.onSubChanged,
  });

  final Settings settings;
  final List<Profile> profiles;
  final bool compact;
  final int sub;
  final ValueChanged<int> onSubChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 24,
        compact ? 16 : 20,
        compact ? 16 : 24,
        8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.cloud_sync_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('同步', style: theme.textTheme.titleMedium),
            const Spacer(),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('云同步')),
                ButtonSegment(value: 1, label: Text('同步库')),
              ],
              selected: {sub},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              onSelectionChanged: (value) => onSubChanged(value.first),
            ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: sub == 0
                    ? SyncDialog(
                        embedded: true,
                        settings: settings,
                        profiles: profiles,
                      )
                    : SyncLibraryDialog(
                        embedded: true,
                        settings: settings,
                        profiles: profiles,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
