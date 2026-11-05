import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/app_version.dart';

/// 设置页里的「软件更新」区块：检查 GitHub Release、下载当前平台的安装包、交给系统安装。
///
/// 只做「检查 + 下载 + 打开安装器」，不静默替换正在运行的自身——那样在
/// macOS（App 包被占用）和 Windows（exe 被锁）上都会失败或留下半成品。
class AppUpdateCard extends StatefulWidget {
  const AppUpdateCard({
    super.key,
    required this.cacheDir,
    this.proxy = '',
    this.token = '',
  });

  final String cacheDir;
  final String proxy;
  final String token;

  @override
  State<AppUpdateCard> createState() => _AppUpdateCardState();
}

enum _Phase { idle, checking, ready, downloading, downloaded, error }

class _AppUpdateCardState extends State<AppUpdateCard> {
  AppUpdateService? _service;
  _Phase _phase = _Phase.idle;
  AppRelease? _release;
  AppAsset? _asset;
  File? _file;
  String _message = '';
  double _progress = 0;

  AppUpdateService get _svc => _service ??= AppUpdateService(
        cacheDir: widget.cacheDir,
        proxy: widget.proxy,
        token: widget.token,
      );

  @override
  void dispose() {
    _service?.close();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _message = '';
      _release = null;
      _asset = null;
      _file = null;
    });
    try {
      final release = await _svc.fetchLatest();
      final abis = await _svc.supportedAbis();
      final asset = release.pickAsset(abis: abis);
      if (!mounted) return;
      setState(() {
        _release = release;
        _asset = asset;
        _phase = _Phase.ready;
        // 「已最新」由描述行表达，这里只放需要额外说明的情况，避免重复。
        _message = release.isNewer && asset == null
            ? 'v${release.version} 没有适用于当前平台的文件，可在发布页手动下载。'
            : '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = _describe(error);
      });
    }
  }

  Future<void> _download() async {
    final asset = _asset;
    if (asset == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
      _message = '';
    });
    try {
      final file = await _svc.download(asset, onProgress: (received, total) {
        if (!mounted || total <= 0) return;
        final value = (received / total).clamp(0.0, 1.0);
        if ((value - _progress).abs() < 0.01 && value < 1) return;
        setState(() => _progress = value);
      });
      if (!mounted) return;
      setState(() {
        _file = file;
        _phase = _Phase.downloaded;
        _progress = 1;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = _describe(error);
      });
    }
  }

  Future<void> _install() async {
    final file = _file;
    if (file == null) return;
    try {
      await _svc.launchInstaller(file);
      if (!mounted) return;
      setState(() {
        _message = '已交给系统安装，按提示完成即可。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _message = '无法打开安装包：${_describe(error)}\n文件位置：${file.path}';
      });
    }
  }

  String _describe(Object error) {
    if (error is HttpException) return error.message;
    if (error is SocketException) return '网络不可用或代理设置不正确';
    return error.toString();
  }

  String get _sizeLabel {
    final asset = _asset;
    if (asset == null || asset.size <= 0) return '';
    final mb = asset.size / 1024 / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final release = _release;
    final busy = _phase == _Phase.checking || _phase == _Phase.downloading;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_alt_outlined,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Text('软件更新', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                'v$appVersion',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            release == null
                ? '检查更新器自身是否有新版本（与方案更新无关）。'
                : release.isNewer
                    ? '发现新版本 v${release.version}'
                        '${_sizeLabel.isEmpty ? '' : '（$_sizeLabel）'}'
                    : '当前 v$appVersion，已是最新版本。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: release != null && release.isNewer
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
          ),
          if (_phase == _Phase.downloading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '下载中 ${(_progress * 100).round()}%',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _phase == _Phase.error
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _check,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(_phase == _Phase.checking ? '检查中…' : '检查更新'),
              ),
              const SizedBox(width: 8),
              if (release != null &&
                  release.isNewer &&
                  _asset != null &&
                  _file == null)
                FilledButton.icon(
                  onPressed: busy ? null : _download,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(_phase == _Phase.downloading ? '下载中…' : '下载'),
                ),
              if (_file != null) ...[
                FilledButton.icon(
                  onPressed: busy ? null : _install,
                  icon: const Icon(Icons.install_desktop_outlined, size: 16),
                  label: const Text('安装'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _file = null;
                    _phase = _Phase.ready;
                    _message = '';
                  }),
                  child: const Text('稍后'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
