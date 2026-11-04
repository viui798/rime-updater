import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/core/webdav_client.dart';

/// 用一个内存版 WebDAV 服务验证 MKCOL / PUT / GET 与 Basic Auth。
void main() {
  late HttpServer server;
  final files = <String, List<int>>{};
  final methods = <String>[];
  String? auth;

  setUp(() async {
    files.clear();
    methods.clear();
    auth = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.pathSegments.join('/');
      methods.add('${request.method} $path');
      auth = request.headers.value('authorization');
      try {
        switch (request.method) {
          case 'MKCOL':
            request.response.statusCode = 201;
            break;
          case 'PUT':
            files[path] = await request.fold<List<int>>(
              <int>[],
              (list, chunk) => list..addAll(chunk),
            );
            request.response.statusCode = 201;
            break;
          case 'GET':
            final body = files[path];
            if (body == null) {
              request.response.statusCode = 404;
            } else {
              request.response.statusCode = 200;
              request.response.add(body);
            }
            break;
          case 'DELETE':
            final existed = files.remove(path) != null;
            request.response.statusCode = existed ? 204 : 404;
            break;
          default:
            request.response.statusCode = 405;
        }
      } finally {
        await request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  WebDavClient client() => WebDavClient(
        baseUrl: 'http://127.0.0.1:${server.port}/',
        user: 'me',
        password: 'secret',
      );

  test('建目录、上传与读取清单', () async {
    final dav = client();
    await dav.ensureDirectory('CheeseTigerSync/squirrel');
    await dav.putText(
      'CheeseTigerSync/squirrel/manifest.json',
      jsonEncode({'devices': <Object>[]}),
    );
    final text = await dav.getText('CheeseTigerSync/squirrel/manifest.json');
    expect(text, contains('devices'));
    expect(
      await dav.getText('CheeseTigerSync/squirrel/missing.json'),
      isNull,
    );
    expect(methods, contains('MKCOL CheeseTigerSync'));
    expect(methods, contains('MKCOL CheeseTigerSync/squirrel'));
    expect(auth, startsWith('Basic '));
    dav.close();
  });

  test('中文文件名与删除', () async {
    final dav = client();
    await dav.putText('CheeseTigerSync/squirrel/files/自学习-记忆.txt', 'abc');
    expect(
      files['CheeseTigerSync/squirrel/files/自学习-记忆.txt'],
      isNotNull,
    );
    expect(
      await dav.getText('CheeseTigerSync/squirrel/files/自学习-记忆.txt'),
      'abc',
    );
    expect(
      await dav.deleteFile('CheeseTigerSync/squirrel/files/自学习-记忆.txt'),
      isTrue,
    );
    expect(
      await dav.getText('CheeseTigerSync/squirrel/files/自学习-记忆.txt'),
      isNull,
    );
    expect(
      await dav.deleteFile('CheeseTigerSync/squirrel/files/none.txt'),
      isFalse,
    );
    dav.close();
  });

  test('上传与下载 zip 文件', () async {
    final dir = Directory.systemTemp.createTempSync('webdav-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = File('${dir.path}/src.zip')..writeAsBytesSync([1, 2, 3]);
    final dst = File('${dir.path}/dst.zip');

    final dav = client();
    await dav.putFile('CheeseTigerSync/squirrel/dev-1.zip', src);
    expect(await dav.getToFile('CheeseTigerSync/squirrel/dev-1.zip', dst), isTrue);
    expect(dst.readAsBytesSync(), [1, 2, 3]);
    expect(
      await dav.getToFile('CheeseTigerSync/squirrel/none.zip', dst),
      isFalse,
    );
    dav.close();
  });
}
