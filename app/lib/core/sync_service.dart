import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'scheme_switcher.dart';
import 'settings_store.dart';
import 'webdav_client.dart';

const syncRoot = 'CheeseTigerSync';

String get syncAppDir => p.dirname(settingsFilePath);

String _statePath([String? stateDir]) =>
    p.join(stateDir ?? syncAppDir, 'sync-state.json');

String syncKey(Profile profile) {
  if (profile.kind == 'unknown') return _safe(profile.label);
  return profile.kind;
}

String _safe(String value) =>
    value.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_');

String defaultDeviceName() {
  final host = Platform.localHostname;
  return host.isEmpty ? '本机' : host;
}

Map<String, dynamic> _loadState([String? stateDir]) {
  final file = File(_statePath(stateDir));
  if (!file.existsSync()) return {};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, dynamic> ? decoded : {};
  } catch (_) {
    return {};
  }
}

void _saveState(Map<String, dynamic> state, [String? stateDir]) {
  final file = File(_statePath(stateDir));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(state));
}

String deviceId({String? stateDir}) {
  final state = _loadState(stateDir);
  final existing = state['device_id'] as String?;
  if (existing != null && existing.isNotEmpty) return existing;
  final id = 'dev-${DateTime.now().millisecondsSinceEpoch}';
  state['device_id'] = id;
  _saveState(state, stateDir);
  return id;
}

/// 上传过数据的设备，仅用于在界面上显示来源与时间。
class SyncDevice {
  const SyncDevice({required this.id, required this.name, required this.at});

  final String id;
  final String name;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'at': at.toUtc().toIso8601String(),
      };

  static SyncDevice? fromJson(dynamic value) {
    if (value is! Map) return null;
    final at = DateTime.tryParse(value['at']?.toString() ?? '');
    if (at == null) return null;
    return SyncDevice(
      id: value['id']?.toString() ?? '',
      name: value['name']?.toString() ?? '',
      at: at,
    );
  }
}

/// 同步库里的一个文件，记录是谁、什么时候上传的。
class SyncFile {
  const SyncFile({
    required this.path,
    required this.by,
    required this.byName,
    required this.at,
  });

  final String path;
  final String by;
  final String byName;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'path': path,
        'by': by,
        'by_name': byName,
        'at': at.toUtc().toIso8601String(),
      };

  static SyncFile? fromJson(dynamic value) {
    if (value is! Map) return null;
    final path = value['path']?.toString() ?? '';
    final at = DateTime.tryParse(value['at']?.toString() ?? '');
    if (path.isEmpty || at == null) return null;
    return SyncFile(
      path: path,
      by: value['by']?.toString() ?? '',
      byName: value['by_name']?.toString() ?? '',
      at: at,
    );
  }
}

class SyncLibrary {
  const SyncLibrary({required this.devices, required this.files});

  const SyncLibrary.empty()
      : devices = const [],
        files = const [];

  final List<SyncDevice> devices;
  final List<SyncFile> files;

  DateTime? get latestAt {
    DateTime? latest;
    for (final device in devices) {
      if (latest == null || device.at.isAfter(latest)) latest = device.at;
    }
    for (final file in files) {
      if (latest == null || file.at.isAfter(latest)) latest = file.at;
    }
    return latest;
  }
}

Future<SyncLibrary> fetchLibrary(WebDavClient client, String kind) async {
  final text = await client.getText('$syncRoot/$kind/manifest.json');
  if (text == null || text.trim().isEmpty) return const SyncLibrary.empty();
  try {
    final data = jsonDecode(text);
    if (data is! Map) return const SyncLibrary.empty();
    final devices = (data['devices'] as List? ?? const [])
        .map(SyncDevice.fromJson)
        .whereType<SyncDevice>()
        .toList();
    final files = (data['files'] as List? ?? const [])
        .map(SyncFile.fromJson)
        .whereType<SyncFile>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return SyncLibrary(devices: devices, files: files);
  } catch (_) {
    return const SyncLibrary.empty();
  }
}

Future<void> _writeLibrary(
  WebDavClient client,
  String kind,
  SyncLibrary library,
) async {
  await client.putText(
    '$syncRoot/$kind/manifest.json',
    const JsonEncoder.withIndent('  ').convert({
      'devices': library.devices.map((device) => device.toJson()).toList(),
      'files': library.files.map((file) => file.toJson()).toList(),
    }),
  );
}

/// 同步库文件树里的一项：文件夹、普通文件，或一个不可展开的 `*.userdb` 目录。
class LibraryEntry {
  LibraryEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.isUserDb,
    required this.fileCount,
    required this.at,
    required this.byName,
    List<String>? paths,
  }) : paths = paths ?? [];

  final String name;
  final String path;
  final bool isDir;
  final bool isUserDb;
  int fileCount;
  DateTime at;
  String byName;
  final List<String> paths;

  bool get isFolder => isDir;
}

/// 列出 `prefix` 这一层的内容；`*.userdb` 保持为一项，不展开内部数据库文件。
List<LibraryEntry> listEntries(List<SyncFile> files, String prefix) {
  final entries = <String, LibraryEntry>{};

  for (final file in files) {
    var rel = file.path;
    if (prefix.isNotEmpty) {
      if (!rel.startsWith('$prefix/')) continue;
      rel = rel.substring(prefix.length + 1);
    }
    if (rel.isEmpty) continue;

    final parts = rel.split('/');
    final name = parts.first;
    final fullPath = prefix.isEmpty ? name : '$prefix/$name';
    final isUserDb = name.endsWith('.userdb');

    final existing = entries[fullPath];
    if (parts.length == 1) {
      entries[fullPath] = LibraryEntry(
        name: name,
        path: fullPath,
        isDir: false,
        isUserDb: false,
        fileCount: 1,
        at: file.at,
        byName: file.byName,
      );
    } else if (isUserDb) {
      if (existing == null) {
        entries[fullPath] = LibraryEntry(
          name: name,
          path: fullPath,
          isDir: false,
          isUserDb: true,
          fileCount: 1,
          at: file.at,
          byName: file.byName,
          paths: [file.path],
        );
      } else {
        existing.fileCount++;
        existing.paths.add(file.path);
        if (file.at.isAfter(existing.at)) {
          existing.at = file.at;
          existing.byName = file.byName;
        }
      }
    } else if (existing == null) {
      entries[fullPath] = LibraryEntry(
        name: name,
        path: fullPath,
        isDir: true,
        isUserDb: false,
        fileCount: 1,
        at: file.at,
        byName: file.byName,
      );
    } else {
      existing.fileCount++;
      if (file.at.isAfter(existing.at)) {
        existing.at = file.at;
        existing.byName = file.byName;
      }
    }
  }

  return entries.values.toList()
    ..sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      if (a.isUserDb != b.isUserDb) return a.isUserDb ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}

Future<String?> readCloudFile(
  WebDavClient client,
  Profile profile,
  String rel,
) {
  return client.getText(_fileUrl(syncKey(profile), rel));
}

/// 直接编辑云端文本文件，并更新清单里的来源与时间。
Future<void> writeCloudFile({
  required WebDavClient client,
  required Profile profile,
  required String deviceName,
  required String rel,
  required String text,
  String? stateDir,
}) async {
  final kind = syncKey(profile);
  final path = _normalize(rel);
  if (_unsafe(path)) throw WebDavException('非法文件路径');

  await client.ensureDirectory('$syncRoot/$kind/files');
  final parent = p.posix.dirname(path);
  if (parent != '.' && parent.isNotEmpty) {
    await client.ensureDirectory('$syncRoot/$kind/files/$parent');
  }
  await client.putText(_fileUrl(kind, path), text);

  final id = deviceId(stateDir: stateDir);
  final name =
      deviceName.trim().isEmpty ? defaultDeviceName() : deviceName.trim();
  final library = await fetchLibrary(client, kind);
  final now = DateTime.now();
  final entries = {for (final file in library.files) file.path: file};
  entries[path] = SyncFile(path: path, by: id, byName: name, at: now);
  final devices = library.devices.where((device) => device.id != id).toList()
    ..add(SyncDevice(id: id, name: name, at: now));
  await _writeLibrary(
    client,
    kind,
    SyncLibrary(
      devices: devices,
      files: entries.values.toList()..sort((a, b) => a.path.compareTo(b.path)),
    ),
  );
}

String _normalize(String rel) => rel.replaceAll('\\', '/');

bool _unsafe(String rel) =>
    rel.isEmpty || rel.startsWith('/') || rel.split('/').any((p) => p == '..');

String _fileUrl(String kind, String rel) => '$syncRoot/$kind/files/$rel';

/// 把目录展开成具体文件，`*.userdb/` 这类目录也要逐个文件上传。
List<String> _expand(String target, String rel) {
  final full = p.join(target, rel);
  if (!FileSystemEntity.isDirectorySync(full)) return [rel];
  final files = <String>[];
  for (final entity in Directory(full).listSync(recursive: true)) {
    if (entity is! File) continue;
    files.add(p.relative(entity.path, from: target).replaceAll('\\', '/'));
  }
  return files;
}

/// 把文件放进云端同步库。`files` 为空时使用默认的个人数据集合。
/// 同名文件会被本次上传覆盖。返回实际上传的文件数。
Future<int> pushFiles({
  required WebDavClient client,
  required Profile profile,
  required String deviceName,
  required void Function(String line) log,
  List<String>? files,
  String? stateDir,
}) async {
  final kind = syncKey(profile);
  final id = deviceId(stateDir: stateDir);
  final name =
      deviceName.trim().isEmpty ? defaultDeviceName() : deviceName.trim();
  final targets = <String>[];
  for (final rel in (files ?? collectUserData(profile.path))
      .map(_normalize)
      .where((rel) => !_unsafe(rel))) {
    targets.addAll(_expand(profile.path, rel));
  }
  final unique = targets.toSet().toList();

  if (unique.isEmpty) {
    throw WebDavException('没有找到可同步的文件');
  }

  await client.ensureDirectory('$syncRoot/$kind/files');
  final dirs = <String>{};
  final uploaded = <String>[];
  for (final rel in unique) {
    final src = File(p.join(profile.path, rel));
    if (!src.existsSync()) {
      log('  跳过不存在的 $rel');
      continue;
    }
    final parent = p.posix.dirname(rel);
    if (parent != '.' && dirs.add(parent)) {
      await client.ensureDirectory('$syncRoot/$kind/files/$parent');
    }
    await client.putFile(_fileUrl(kind, rel), src);
    uploaded.add(rel);
    log('  已上传 $rel');
  }

  if (uploaded.isEmpty) {
    throw WebDavException('没有可上传的文件');
  }

  final library = await fetchLibrary(client, kind);
  final now = DateTime.now();
  final entries = {for (final file in library.files) file.path: file};
  for (final rel in uploaded) {
    entries[rel] = SyncFile(path: rel, by: id, byName: name, at: now);
  }
  final devices = library.devices.where((device) => device.id != id).toList()
    ..add(SyncDevice(id: id, name: name, at: now));
  await _writeLibrary(
    client,
    kind,
    SyncLibrary(
      devices: devices,
      files: entries.values.toList()..sort((a, b) => a.path.compareTo(b.path)),
    ),
  );
  log('  同步库已更新（${entries.length} 个文件）');
  return uploaded.length;
}

/// 从同步库删除文件；本机文件不受影响。`paths` 可以是一组（如整个 *.userdb 目录）。
/// 返回实际删掉的云端文件数。
Future<int> deleteCloudFiles({
  required WebDavClient client,
  required Profile profile,
  required List<String> paths,
  required void Function(String line) log,
}) async {
  final kind = syncKey(profile);
  final targets = paths.map(_normalize).toSet();
  var removed = 0;
  for (final rel in targets) {
    final ok = await client.deleteFile(_fileUrl(kind, rel));
    if (ok) {
      removed++;
      log('  已从云端删除 $rel');
    } else {
      log('  云端本来就没有 $rel');
    }
  }

  final library = await fetchLibrary(client, kind);
  final files =
      library.files.where((file) => !targets.contains(file.path)).toList();
  await _writeLibrary(
    client,
    kind,
    SyncLibrary(devices: library.devices, files: files),
  );
  return removed;
}

/// 把同步库里的全部文件下载到本地目录；覆盖前先备份本机个人数据。
Future<int> pullLibrary({
  required WebDavClient client,
  required Profile profile,
  required void Function(String line) log,
  String? backupRoot,
}) async {
  final kind = syncKey(profile);
  final library = await fetchLibrary(client, kind);
  if (library.files.isEmpty) {
    log('  云端同步库还是空的');
    return 0;
  }
  final latest = library.latestAt;
  log('  云端 ${library.files.length} 个文件'
      '${latest == null ? '' : '，最新 ${formatSyncTime(latest)}'}');

  // 覆盖前先备份本机个人数据
  backupUserData(
    profile.path,
    label: '${profile.label}-同步前',
    log: log,
    destinationRoot: backupRoot ?? p.join(syncAppDir, 'switch-backups'),
  );

  var done = 0;
  for (final file in library.files) {
    final rel = _normalize(file.path);
    if (_unsafe(rel)) continue;
    final dest = File(p.join(profile.path, rel));
    dest.parent.createSync(recursive: true);
    final ok = await client.getToFile(_fileUrl(kind, rel), dest);
    if (ok) {
      done++;
      log('  已下载 $rel');
    } else {
      log('  云端缺少 $rel，已跳过');
    }
  }

  log('  已同步 $done 个文件到本机');
  return done;
}

String formatSyncTime(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
