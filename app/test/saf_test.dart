import 'dart:typed_data';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rime_updater/core/saf_client.dart';
import 'package:archive/archive.dart';
import 'package:rime_updater/core/saf_installer.dart';
import 'package:rime_updater/core/zip_installer.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

/// 内存版 SAF 后端：把 URI 当成路径，模拟 DocumentFile 树。
class _FakeSaf extends SafUtilPlatform with MockPlatformInterfaceMixin {
  final Map<String, SafDocumentFile> dirs = {'content://root': _dir('content://root', '')};
  final Map<String, SafDocumentFile> files = {};

  static SafDocumentFile _dir(String uri, String name) =>
      SafDocumentFile(uri: uri, name: name, isDir: true, length: 0, lastModified: 0);

  static SafDocumentFile _file(String uri, String name, int len) =>
      SafDocumentFile(uri: uri, name: name, isDir: false, length: len, lastModified: 0);

  @override
  Future<List<SafDocumentFile>> list(String uri) async => [
        ...dirs.values.where((d) => d.uri == uri).expand((_) => <SafDocumentFile>[]),
        ..._children(uri, dirs: true),
        ..._children(uri, dirs: false),
      ];

  Iterable<SafDocumentFile> _children(String parent,
      {required bool dirs}) {
    final source = dirs == true ? this.dirs.values : files.values;
    return source.where((e) => _parentOf(e.uri) == parent);
  }

  String _parentOf(String uri) {
    final idx = uri.lastIndexOf('/');
    return idx <= 'content://'.length ? '' : uri.substring(0, idx);
  }

  @override
  Future<SafDocumentFile?> documentFileFromUri(String uri, bool? isDir) async =>
      dirs[uri] ?? files[uri];

  @override
  Future<SafDocumentFile> mkdirp(String uri, List<String> names) async {
    var current = uri;
    for (final name in names) {
      final childUri = '$current/$name';
      dirs.putIfAbsent(childUri, () => _dir(childUri, name));
      current = childUri;
    }
    return dirs[current]!;
  }

  @override
  Future<void> delete(String uri, bool isDir) async {
    dirs.remove(uri);
    files.remove(uri);
  }

  @override
  Future<bool> hasPersistedPermission(String uri,
          {bool checkRead = true, bool checkWrite = false}) async =>
      true;

  @override
  Future<void> releasePersistedPermission(String uri,
      {bool read = true, bool write = false}) async {}

  @override
  Future<SafDocumentFile?> pickDirectory({
    String? initialUri,
    bool? writePermission,
    bool? persistablePermission,
  }) async =>
      dirs['content://root'];
}

void main() {
  test('SAF 目录递归列出文件与相对路径', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    await fake.mkdirp('content://root', ['schemeA']);
    await fake.mkdirp('content://root/schemeA', ['lua']);
    fake.files['content://root/schemeA/default.yaml'] =
        _FakeSaf._file('content://root/schemeA/default.yaml', 'default.yaml', 3);
    fake.files['content://root/schemeA/lua/db.lua'] =
        _FakeSaf._file('content://root/schemeA/lua/db.lua', 'db.lua', 3);

    final client = SafClient();
    final entries = await client.walk('content://root');
    expect(entries.keys.toSet(),
        {'schemeA/default.yaml', 'schemeA/lua/db.lua'});
  });

  test('walk 跳过 build 目录', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    await fake.mkdirp('content://root', ['build']);
    fake.files['content://root/build/x.yaml'] =
        _FakeSaf._file('content://root/build/x.yaml', 'x.yaml', 1);
    fake.files['content://root/keep.yaml'] =
        _FakeSaf._file('content://root/keep.yaml', 'keep.yaml', 1);

    final client = SafClient();
    final entries =
        await client.walk('content://root', skipDirs: {'build'});
    expect(entries.keys, ['keep.yaml']);
  });

  _streamTests();
  _versionTests();
  _deltaTests();
  _dryRunTests();
  _staleMarkerTests();

  test('识别根目录或子目录中的 Rime 方案', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    final client = SafClient();

    // 根目录直接是 Rime 目录
    fake.files['content://root/default.yaml'] =
        _FakeSaf._file('content://root/default.yaml', 'default.yaml', 1);
    expect(await client.detectRimeSubdir(
        const SafRoot(uri: 'content://root', label: 't')), '');

    // 子目录里才是 Rime 目录（新 client，避免复用上一步的目录缓存）
    final fake2 = _FakeSaf();
    SafUtilPlatform.instance = fake2;
    await fake2.mkdirp('content://root', ['rime-ice']);
    fake2.files['content://root/rime-ice/luna.schema.yaml'] = _FakeSaf._file(
        'content://root/rime-ice/luna.schema.yaml', 'luna.schema.yaml', 1);
    final client2 = SafClient();
    expect(await client2.detectRimeSubdir(
        const SafRoot(uri: 'content://root', label: 't')), 'rime-ice');
  });
}

/// 记录流式写入的假实现，用来验证分块拼装是否正确。
class _FakeSafStream extends SafStreamPlatform with MockPlatformInterfaceMixin {
  final Map<String, List<int>> written = {};
  final Map<String, _Session> sessions = {};
  final Map<String, String> readable = {};
  int _seq = 0;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async =>
      Uint8List.fromList(utf8.encode(readable[uri] ?? ''));

  @override
  Future<SafNewFile> writeFileBytes(String treeUri, String fileName, String mime,
      Uint8List data, {bool? overwrite, bool? append}) async {
    final uri = '$treeUri/$fileName';
    written[uri] = data.toList();
    return SafNewFile(Uri.parse(uri), fileName);
  }

  @override
  Future<SafWriteStreamInfo> startWriteStream(String treeUri, String fileName,
      String mime, {bool? overwrite, bool? append}) async {
    final id = 's${_seq++}';
    sessions[id] = _Session('$treeUri/$fileName');
    return SafWriteStreamInfo(
        id, SafNewFile(Uri.parse('$treeUri/$fileName'), fileName));
  }

  @override
  Future<void> writeChunk(String session, Uint8List data) async {
    sessions[session]!.chunks.add(data);
  }

  @override
  Future<void> endWriteStream(String session) async {
    final s = sessions.remove(session)!;
    written[s.target] = [for (final c in s.chunks) ...c];
  }
}

class _Session {
  _Session(this.target);
  final String target;
  final List<Uint8List> chunks = [];
}

void _streamTests() {
  test('流式写入按分块拼装，内容完整', () async {
    final fake = _FakeSafStream();
    SafStreamPlatform.instance = fake;

    final client = SafClient();
    // 3.5 个分块的数据，验证边界处理
    final total = 1024 * 1024 * 3 + 512 * 1024;
    final source = Stream<List<int>>.fromIterable([
      List<int>.filled(total, 7),
    ]);
    await client.writeStream('content://root', 'big.bin',
        source: source, chunkSize: 1024 * 1024);

    final out = fake.written['content://root/big.bin'];
    expect(out, isNotNull);
    expect(out!.length, total);
    expect(out.first, 7);
    expect(out.last, 7);
  });
}

void _versionTests() {
  test('SAF 版本号优先读标记文件', () async {
    final fake = _FakeSaf();
    fake.files['content://root/.cheese-tiger-version'] = _FakeSaf._file(
        'content://root/.cheese-tiger-version', '.cheese-tiger-version', 7);
    SafUtilPlatform.instance = fake;
    final stream = _FakeSafStream()
      ..readable['content://root/.cheese-tiger-version'] = '0.3.23\n';
    SafStreamPlatform.instance = stream;
    final client = SafClient();
    expect(await readSafLocalVersion(client, 'content://root'), '0.3.23');
  });

  test('没有标记时退回 CHANGELOG', () async {
    final fake = _FakeSaf();
    fake.files['content://root/CHANGELOG.md'] = _FakeSaf._file(
        'content://root/CHANGELOG.md', 'CHANGELOG.md', 30);
    SafUtilPlatform.instance = fake;
    final stream = _FakeSafStream()
      ..readable['content://root/CHANGELOG.md'] = '## v0.3.22（2026-11-03）\n- x\n';
    SafStreamPlatform.instance = stream;
    final client = SafClient();
    expect(await readSafLocalVersion(client, 'content://root'), '0.3.22');
  });

  test('优先读取不带点的 SAF 标记（元书会拒绝点开头的文件）', () async {
    final fake = _FakeSaf();
    fake.files['content://root/$safMarkerFile'] = _FakeSaf._file(
        'content://root/$safMarkerFile', safMarkerFile, 6);
    SafUtilPlatform.instance = fake;
    final stream = _FakeSafStream()
      ..readable['content://root/$safMarkerFile'] = '0.3.26\n';
    SafStreamPlatform.instance = stream;
    final client = SafClient();
    expect(await readSafLocalVersion(client, 'content://root'), '0.3.26');
  });

  test('两处都没有时返回空', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    final client = SafClient();
    expect(await readSafLocalVersion(client, 'content://root'), '');
  });
}

/// 构造一个只含 DELTA.json 与一个 yaml 的增量包。
String _makeDeltaZip(Map<String, dynamic> delta) {
  final dir = Directory.systemTemp.createTempSync('saf-delta-');
  final archive = Archive();
  final deltaBytes = utf8.encode(jsonEncode(delta));
  archive.addFile(
      ArchiveFile('update/DELTA.json', deltaBytes.length, deltaBytes));
  final yaml = utf8.encode('x: 1\n');
  archive.addFile(ArchiveFile('update/default.yaml', yaml.length, yaml));
  final path = '${dir.path}/delta.zip';
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

void _deltaTests() {
  test('基座不符时 SAF 路径抛出 FullPackageRequired', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    // 已装 0.3.2
    fake.files['content://root/.cheese-tiger-version'] = _FakeSaf._file(
        'content://root/.cheese-tiger-version', '.cheese-tiger-version', 6);
    final stream = _FakeSafStream()
      ..readable['content://root/.cheese-tiger-version'] = '0.3.2\n';
    SafStreamPlatform.instance = stream;

    final zip = _makeDeltaZip({'from': 'v0.3.25'});
    final client = SafClient();
    expect(
      () => applyZipToSaf(
        client: client,
        rootUri: 'content://root',
        zipPath: zip,
        version: '0.3.26',
        snapshot: false,
        log: (_) {},
      ),
      throwsA(isA<FullPackageRequired>()),
    );
  });

  test('full_required 为真时要求完整包', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    SafStreamPlatform.instance = _FakeSafStream();
    final zip = _makeDeltaZip({'full_required': true});
    final client = SafClient();
    expect(
      () => applyZipToSaf(
        client: client,
        rootUri: 'content://root',
        zipPath: zip,
        version: '0.3.26',
        snapshot: false,
        log: (_) {},
      ),
      throwsA(isA<FullPackageRequired>()),
    );
  });
}

/// 构造一个普通的（非增量）安装包。
String _makePlainZip(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('saf-plain-');
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final path = '${dir.path}/plain.zip';
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

void _dryRunTests() {
  test('预演不写盘：新增文件只统计不落盘', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    final stream = _FakeSafStream();
    SafStreamPlatform.instance = stream;

    final zip = _makePlainZip({'default.yaml': 'x: 1\n'});
    final result = await applyZipToSaf(
      client: SafClient(),
      rootUri: 'content://root',
      zipPath: zip,
      version: '0.3.26',
      snapshot: true,
      dryRun: true,
      log: (_) {},
    );

    expect(result.copied, 1, reason: '应该统计出 1 个待写文件');
    expect(stream.written, isEmpty, reason: '预演不得写入任何文件');
    // 版本标记也不能写
    expect(stream.written.keys.where((k) => k.contains('cheese-tiger-version')),
        isEmpty);
  });

  test('正式更新会写入并写版本标记', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    final stream = _FakeSafStream();
    SafStreamPlatform.instance = stream;

    final zip = _makePlainZip({'default.yaml': 'x: 1\n'});
    final result = await applyZipToSaf(
      client: SafClient(),
      rootUri: 'content://root',
      zipPath: zip,
      version: '0.3.26',
      snapshot: false,
      log: (_) {},
    );

    expect(result.copied, 1);
    expect(stream.written, isNotEmpty);
    final marker = stream.written.entries
        .where((e) => e.key.contains('cheese-tiger-version'))
        .toList();
    expect(marker, isNotEmpty, reason: '应写入版本标记');
    expect(utf8.decode(marker.first.value).trim(), '0.3.26');
  });
}

void _staleMarkerTests() {
  test('只清理「数字.cheese-tiger-version」残留', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    SafStreamPlatform.instance = _FakeSafStream();
    for (final name in [
      '1.cheese-tiger-version',
      '2.cheese-tiger-version',
      '3.cheese-tiger-version',
    ]) {
      fake.files['content://root/$name'] =
          _FakeSaf._file('content://root/$name', name, 6);
    }
    // 这些都必须保留
    for (final name in [
      'cheese-tiger-version.txt',
      '.cheese-tiger-version',
      'tiger.schema.yaml',
      'user.yaml',
    ]) {
      fake.files['content://root/$name'] =
          _FakeSaf._file('content://root/$name', name, 6);
    }

    final client = SafClient();
    final removed = await cleanStaleSafMarkers(client, 'content://root');

    expect(removed, 3);
    final names = (await client.list('content://root')).map((e) => e.name).toSet();
    expect(names.contains('1.cheese-tiger-version'), isFalse);
    expect(names.contains('2.cheese-tiger-version'), isFalse);
    expect(names.contains('3.cheese-tiger-version'), isFalse);
    expect(names.contains('cheese-tiger-version.txt'), isTrue);
    expect(names.contains('.cheese-tiger-version'), isTrue);
    expect(names.contains('tiger.schema.yaml'), isTrue);
    expect(names.contains('user.yaml'), isTrue);
  });

  test('没有残留时返回 0', () async {
    final fake = _FakeSaf();
    SafUtilPlatform.instance = fake;
    SafStreamPlatform.instance = _FakeSafStream();
    fake.files['content://root/cheese-tiger-version.txt'] = _FakeSaf._file(
        'content://root/cheese-tiger-version.txt', 'cheese-tiger-version.txt', 6);
    final client = SafClient();
    expect(await cleanStaleSafMarkers(client, 'content://root'), 0);
  });
}
