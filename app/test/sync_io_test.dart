import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rime_updater/core/sync_service.dart';
import 'package:rime_updater/core/webdav_client.dart';
import 'package:rime_updater/models.dart';

/// 内存版 WebDAV：MKCOL / PUT / GET / DELETE。
class _FakeDav {
  _FakeDav(this.server, this.files);

  final HttpServer server;
  final Map<String, List<int>> files;

  int get port => server.port;

  static Future<_FakeDav> start() async {
    final files = <String, List<int>>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.pathSegments.join('/');
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
    return _FakeDav(server, files);
  }
}

void main() {
  test('上传、删除与下载同步库文件', () async {
    final rime = Directory.systemTemp.createTempSync('rime-sync-');
    final target = Directory.systemTemp.createTempSync('rime-sync-target-');
    final state = Directory.systemTemp.createTempSync('rime-sync-state-');
    final backups = Directory.systemTemp.createTempSync('rime-sync-backup-');
    final dav = await _FakeDav.start();
    addTearDown(() {
      rime.deleteSync(recursive: true);
      target.deleteSync(recursive: true);
      state.deleteSync(recursive: true);
      backups.deleteSync(recursive: true);
      dav.server.close(force: true);
    });

    // 本机源目录：个人数据 + 方案文件
    File(p.join(rime.path, 'user.yaml')).writeAsStringSync('user');
    File(p.join(rime.path, 'tiger.custom.yaml')).writeAsStringSync('custom');
    File(p.join(rime.path, '自学习-记忆.txt')).writeAsStringSync('learn');
    File(p.join(rime.path, 'default.yaml')).writeAsStringSync('scheme');
    File(p.join(rime.path, 'lily.userdb/data.mdb'))
      ..createSync(recursive: true)
      ..writeAsStringSync('db');

    // 目标设备：已有旧数据，用于验证覆盖与备份
    File(p.join(target.path, 'user.yaml')).writeAsStringSync('old');

    final client = WebDavClient(
      baseUrl: 'http://127.0.0.1:${dav.port}/',
      user: 'me',
      password: 'secret',
    );
    const profile = Profile(label: '鼠须管', path: '', kind: 'squirrel');

    final logs = <String>[];
    final count = await pushFiles(
      client: client,
      profile: Profile(label: profile.label, path: rime.path, kind: 'squirrel'),
      deviceName: '本机',
      log: logs.add,
      stateDir: state.path,
    );
    expect(count, 4, reason: logs.join('\n'));

    final keys = dav.files.keys.toList();
    expect(keys, contains('CheeseTigerSync/squirrel/files/user.yaml'));
    expect(
      keys,
      contains('CheeseTigerSync/squirrel/files/lily.userdb/data.mdb'),
    );
    // 中文文件名按段编码后仍能正确落库
    expect(keys, contains('CheeseTigerSync/squirrel/files/自学习-记忆.txt'));
    expect(keys.any((key) => key.endsWith('default.yaml')), isFalse);

    final library = await fetchLibrary(client, syncKey(profile));
    expect(library.files.length, 4);
    expect(library.devices.single.name, '本机');

    final removed = await deleteCloudFiles(
      client: client,
      profile: profile,
      paths: ['tiger.custom.yaml'],
      log: logs.add,
    );
    expect(removed, 1);
    final after = await fetchLibrary(client, syncKey(profile));
    expect(after.files.length, 3);
    expect(
      after.files.any((file) => file.path == 'tiger.custom.yaml'),
      isFalse,
    );

    final pulled = await pullLibrary(
      client: client,
      profile: Profile(label: '小企鹅', path: target.path, kind: 'squirrel'),
      log: logs.add,
      backupRoot: backups.path,
    );
    expect(pulled, 3);
    expect(File(p.join(target.path, 'user.yaml')).readAsStringSync(), 'user');
    expect(
      File(p.join(target.path, '自学习-记忆.txt')).readAsStringSync(),
      'learn',
    );
    expect(
      File(p.join(target.path, 'lily.userdb/data.mdb')).readAsStringSync(),
      'db',
    );
    // 覆盖前的本机数据已备份
    expect(backups.listSync(), isNotEmpty);

    // 直接编辑云端文件，清单里的来源与内容都会更新
    await writeCloudFile(
      client: client,
      profile: profile,
      deviceName: '云端编辑',
      rel: 'user.yaml',
      text: 'edited',
      stateDir: state.path,
    );
    expect(await readCloudFile(client, profile, 'user.yaml'), 'edited');
    final edited = await fetchLibrary(client, syncKey(profile));
    final entry =
        edited.files.firstWhere((file) => file.path == 'user.yaml');
    expect(entry.byName, '云端编辑');
    // 本机文件没有被云端编辑影响
    expect(File(p.join(target.path, 'user.yaml')).readAsStringSync(), 'user');

    client.close();
  });
}
