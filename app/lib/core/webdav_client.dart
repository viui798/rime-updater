import 'dart:convert';
import 'dart:io';

class WebDavException implements Exception {
  WebDavException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 极简 WebDAV 客户端：只需要建目录、上传、下载文本与文件。
class WebDavClient {
  WebDavClient({
    required String baseUrl,
    required String user,
    required String password,
  }) : base = Uri.parse(
          baseUrl.endsWith('/') ? baseUrl : '$baseUrl/',
        ) {
    final credentials = base64Encode(utf8.encode('$user:$password'));
    _auth = 'Basic $credentials';
  }

  final Uri base;
  late final String _auth;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  Uri _uri(String relative) {
    // 逐段编码，保证中文 / 空格文件名也能正确请求
    final encoded = relative
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return base.resolve(encoded);
  }

  Map<String, String> get _headers => {
        'Authorization': _auth,
        'User-Agent': 'CheeseTigerUpdater/1.0',
      };

  Future<void> ensureDirectory(String relative) async {
    var path = '';
    for (final segment in relative.split('/').where((s) => s.isNotEmpty)) {
      path = path.isEmpty ? segment : '$path/$segment';
      final request = await _client.openUrl('MKCOL', _uri(path));
      _headers.forEach(request.headers.set);
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      await response.drain<void>();
      // 201 创建成功，405 已存在，都可能出现
      if (response.statusCode >= 400 && response.statusCode != 405) {
        throw WebDavException(
          '无法创建云目录（HTTP ${response.statusCode}），请检查地址与账号',
        );
      }
    }
  }

  Future<void> putFile(String relative, File file) async {
    final request = await _client.openUrl('PUT', _uri(relative));
    _headers.forEach(request.headers.set);
    request.headers.contentLength = file.lengthSync();
    await request.addStream(file.openRead());
    final response = await request.close().timeout(
          const Duration(seconds: 120),
        );
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('上传失败（HTTP ${response.statusCode}）');
    }
  }

  Future<void> putText(String relative, String text) async {
    final request = await _client.openUrl('PUT', _uri(relative));
    _headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(text);
    request.headers.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('上传清单失败（HTTP ${response.statusCode}）');
    }
  }

  /// 返回 null 表示文件不存在（404）。
  Future<String?> getText(String relative) async {
    final request = await _client.getUrl(_uri(relative));
    _headers.forEach(request.headers.set);
    final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw WebDavException('读取云端失败（HTTP ${response.statusCode}）');
    }
    return body;
  }

  Future<bool> getToFile(String relative, File dest) async {
    final request = await _client.getUrl(_uri(relative));
    _headers.forEach(request.headers.set);
    final response = await request.close().timeout(
          const Duration(seconds: 120),
        );
    if (response.statusCode == 404) {
      await response.drain<void>();
      return false;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw WebDavException('下载失败（HTTP ${response.statusCode}）');
    }
    dest.parent.createSync(recursive: true);
    final sink = dest.openWrite();
    await response.pipe(sink);
    return true;
  }

  /// 删除云端文件；本来就不存在时返回 false。
  Future<bool> deleteFile(String relative) async {
    final request = await _client.openUrl('DELETE', _uri(relative));
    _headers.forEach(request.headers.set);
    final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
    await response.drain<void>();
    if (response.statusCode == 404) return false;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebDavException('删除失败（HTTP ${response.statusCode}）');
    }
    return true;
  }

  void close() {
    _client.close(force: true);
  }
}
