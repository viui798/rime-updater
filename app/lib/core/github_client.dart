import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'settings_store.dart';

class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

String sha256File(String path) {
  final file = File(path);
  if (!file.existsSync()) return '';
  final digest = sha256.convert(file.readAsBytesSync());
  return digest.toString();
}

class GithubClient {
  GithubClient({
    required this.settings,
    required this.log,
  });

  final Settings settings;
  final void Function(String line) log;
  HttpClient? _client;

  String get repo {
    final value = settings.repo.trim();
    return value.isEmpty ? 'viui798/viui-tiger-sentense' : value;
  }

  String get token {
    if (settings.token.trim().isNotEmpty) return settings.token.trim();
    return Platform.environment['GITHUB_TOKEN'] ??
        Platform.environment['GH_TOKEN'] ??
        '';
  }

  HttpClient get client {
    if (_client != null) return _client!;
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..userAgent = 'CheeseTigerUpdater/1.0';
    final proxy = settings.proxy.trim();
    if (proxy.isNotEmpty) {
      final uri = Uri.tryParse(proxy);
      if (uri != null && uri.host.isNotEmpty) {
        final port = uri.hasPort ? uri.port : 1080;
        httpClient.findProxy = (target) => 'PROXY ${uri.host}:$port';
      }
    }
    _client = httpClient;
    return httpClient;
  }

  Map<String, String> get _baseHeaders => {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'CheeseTigerUpdater/1.0',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Future<ReleaseInfo> fetchLatest() async {
    final uri = Uri.https('api.github.com', '/repos/$repo/releases/latest');
    final request = await client.getUrl(uri);
    _baseHeaders.forEach(request.headers.set);

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      String detail = 'HTTP ${response.statusCode}';
      try {
        final data = jsonDecode(body);
        if (data is Map && data['message'] is String) {
          detail = data['message'] as String;
        }
      } catch (_) {
        // 保留 HTTP 状态
      }
      throw UpdateException(
        '无法访问 GitHub Release：$detail\n'
        '若为 API 限流，可在设置里填写 token，或检查网络与代理',
      );
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw UpdateException('Release 返回内容不是合法 JSON');
    }

    final version = (decoded['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
    final assets = <Asset>[];
    for (final item in (decoded['assets'] as List? ?? const [])) {
      final map = item as Map<String, dynamic>;
      assets.add(
        Asset(
          name: map['name'] as String? ?? '',
          url: map['browser_download_url'] as String? ?? '',
          size: (map['size'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    if (assets.isEmpty) throw UpdateException('Release 里没有可用资产');

    Asset? delta;
    Asset? full;
    for (final asset in assets) {
      if (asset.name.endsWith('-update.zip')) {
        delta ??= asset;
      } else if (asset.name.endsWith('.zip') &&
          !asset.name.contains('-update')) {
        full ??= asset;
      }
    }
    final chosen = delta ?? full;
    if (chosen == null) throw UpdateException('Release 里没有可用的 zip 资产');

    return ReleaseInfo(
      version: version,
      assets: assets,
      assetName: chosen.name,
      isDelta: chosen == delta,
      assetSize: chosen.size,
    );
  }

  Future<void> downloadTo(
    String url,
    String destPath, {
    String expectedSha = '',
    void Function(int percent)? onPercent,
  }) async {
    final dir = Directory(p.dirname(destPath))..createSync(recursive: true);
    if (!dir.existsSync()) throw UpdateException('无法创建缓存目录：${dir.path}');

    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Accept', 'application/octet-stream');
    request.headers.set('User-Agent', 'CheeseTigerUpdater/1.0');
    if (token.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $token');
    }

    final response = await request.close();
    if (response.statusCode != 200) {
      throw UpdateException('下载失败：HTTP ${response.statusCode}');
    }

    final partFile = File('$destPath.part');
    final sink = partFile.openWrite();
    final total = response.contentLength;
    var received = 0;
    var lastPercent = -5;

    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0 && onPercent != null) {
        final percent = received * 100 ~/ total;
        if (percent >= lastPercent + 5) {
          lastPercent = percent;
          log('  下载 $percent%');
          onPercent(percent);
        }
      }
    }
    await sink.close();

    if (expectedSha.isNotEmpty) {
      final actual = sha256File(partFile.path);
      if (actual.toLowerCase() != expectedSha.toLowerCase()) {
        partFile.deleteSync();
        log('  ✗ SHA256 不匹配：期望 $expectedSha，实际 $actual');
        throw UpdateException('安装包 SHA256 校验失败');
      }
      log('  ✓ SHA256 校验通过');
    }

    final target = File(destPath);
    if (target.existsSync()) target.deleteSync();
    partFile.renameSync(destPath);
  }

  Future<String> readExpectedSha(String assetName, ReleaseInfo release) async {
    final sidecar = '$assetName.sha256';
    if (!release.assets.any((asset) => asset.name == sidecar)) return '';

    final path = p.join(_cacheDir, sidecar);
    final file = File(path);
    if (!file.existsSync()) {
      final url = release.assets.firstWhere((a) => a.name == sidecar).url;
      await downloadTo(url, path);
    }
    final tokens = file.readAsStringSync().trim().split(RegExp(r'\s+'));
    return tokens.isEmpty ? '' : tokens.first.toLowerCase();
  }

  String get _cacheDir => resolveCacheDir(settings);

  String get cacheDir => _cacheDir;

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
