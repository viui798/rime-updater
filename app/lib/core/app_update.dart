import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_version.dart';

/// 更新器自身所在的仓库（与「方案仓库」无关）。
const String appUpdateRepo = 'viui798/rime-updater';

const MethodChannel _platformChannel =
    MethodChannel('com.viui798.rime_updater/platform');

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

String get _currentPlatform {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  return Platform.operatingSystem;
}

/// 逐段比较版本号：`1.2.10` > `1.2.9`。
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('.')
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

class AppAsset {
  const AppAsset({required this.name, required this.url, required this.size});

  final String name;
  final String url;
  final int size;

  factory AppAsset.fromJson(Map<String, dynamic> json) => AppAsset(
        name: (json['name'] ?? '') as String,
        url: (json['browser_download_url'] ?? '') as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.assets,
  });

  final String version;
  final String tag;
  final String pageUrl;
  final String notes;
  final List<AppAsset> assets;

  bool get isNewer => compareVersions(version, appVersion) > 0;

  /// 按平台挑一个合适的安装包。
  ///
  /// [abis] 仅在 Android 上使用（`Build.SUPPORTED_ABIS` 顺序即优先级）；
  /// [platform] 默认取当前平台，测试时可显式指定。
  AppAsset? pickAsset({List<String> abis = const [], String? platform}) {
    bool has(String name, List<String> keys) =>
        keys.every((k) => name.toLowerCase().contains(k));

    final os = platform ?? _currentPlatform;
    if (os == 'macos') {
      return assets.where((a) => a.name.toLowerCase().endsWith('.dmg')).firstOrNull;
    }
    if (os == 'windows') {
      final setup = assets
          .where((a) =>
              a.name.toLowerCase().endsWith('.exe') && has(a.name, ['setup']))
          .firstOrNull;
      if (setup != null) return setup;
      return assets
          .where((a) => a.name.toLowerCase().endsWith('.zip'))
          .firstOrNull;
    }
    if (os == 'android') {
      final apks =
          assets.where((a) => a.name.toLowerCase().endsWith('.apk')).toList();
      if (apks.isEmpty) return null;
      // 先按设备 ABI 精确匹配，再退回不限架构的通用包。
      for (final abi in abis) {
        final token = switch (abi) {
          'arm64-v8a' => 'arm64',
          'armeabi-v7a' => 'armeabi',
          'x86_64' => 'x86_64',
          'x86' => 'x86',
          _ => abi,
        };
        final hit = apks
            .where((a) => a.name.toLowerCase().contains(token.toLowerCase()))
            .firstOrNull;
        if (hit != null) return hit;
      }
      final universal = apks
          .where((a) => !RegExp(r'arm64|armeabi|x86', caseSensitive: false)
              .hasMatch(a.name))
          .firstOrNull;
      return universal ?? apks.first;
    }
    return null;
  }
}

/// 检查 / 下载 / 启动安装：更新器自身的升级。
class AppUpdateService {
  AppUpdateService({
    required this.cacheDir,
    this.proxy = '',
    this.token = '',
  });

  final String cacheDir;
  final String proxy;
  final String token;

  HttpClient? _client;

  HttpClient get client {
    if (_client != null) return _client!;
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'RimeUpdater/$appVersion';
    final trimmed = proxy.trim();
    if (trimmed.isNotEmpty) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.host.isNotEmpty) {
        final port = uri.hasPort ? uri.port : 1080;
        httpClient.findProxy = (target) => 'PROXY ${uri.host}:$port';
      }
    }
    _client = httpClient;
    return httpClient;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// 读取当前平台的 ABI 列表，非 Android 返回空。
  Future<List<String>> supportedAbis() async {
    if (!Platform.isAndroid) return const [];
    try {
      final result = await _platformChannel.invokeMethod<List<Object?>>(
        'supportedAbis',
      );
      return (result ?? const []).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  Future<AppRelease> fetchLatest() async {
    final uri = Uri.https('api.github.com', '/repos/$appUpdateRepo/releases/latest');
    final request = await client.getUrl(uri);
    request.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('User-Agent', 'RimeUpdater/$appVersion');
    if (token.trim().isNotEmpty) {
      request.headers.set('Authorization', 'Bearer ${token.trim()}');
    }

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      String detail = 'HTTP ${response.statusCode}';
      try {
        final json = jsonDecode(body);
        if (json is Map && json['message'] != null) {
          detail = '${json['message']}';
        }
      } catch (_) {}
      throw HttpException('读取更新信息失败（$detail）', uri: uri);
    }

    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('更新信息格式不正确');
    }
    final tag = (json['tag_name'] ?? '') as String;
    return AppRelease(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      tag: tag,
      pageUrl: (json['html_url'] ?? '') as String,
      notes: (json['body'] ?? '') as String,
      assets: (json['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AppAsset.fromJson)
          .where((a) => a.name.isNotEmpty && a.url.isNotEmpty)
          .toList(),
    );
  }

  /// 下载到缓存目录，返回落地文件。已存在同尺寸文件时直接复用。
  Future<File> download(
    AppAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final target = File(p.join(dir.path, 'app-update', asset.name));
    if (await target.exists() && await target.length() == asset.size) {
      onProgress?.call(asset.size, asset.size);
      return target;
    }
    await target.parent.create(recursive: true);

    final uri = Uri.parse(asset.url);
    final request = await client.getUrl(uri);
    request.headers.set('User-Agent', 'RimeUpdater/$appVersion');
    request.followRedirects = true;
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('下载失败（HTTP ${response.statusCode}）', uri: uri);
    }

    final total = response.contentLength > 0 ? response.contentLength : asset.size;
    final temp = File('${target.path}.part');
    final sink = temp.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
    return target;
  }

  /// 交给系统安装：各平台只做「打开安装包」，不静默替换自身。
  Future<void> launchInstaller(File file) async {
    if (Platform.isMacOS) {
      await Process.run('open', [file.path]);
      return;
    }
    if (Platform.isWindows) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isAndroid) {
      final ok = await _platformChannel.invokeMethod<bool>('installApk', {
        'path': file.path,
      });
      if (ok != true) {
        throw const FileSystemException('系统没有接受安装请求');
      }
      return;
    }
    throw UnsupportedError('当前平台不支持自动安装，请手动打开下载的文件');
  }
}
