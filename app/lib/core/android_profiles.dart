import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models.dart';

const _channel = MethodChannel('com.viui798.rime_updater/platform');

bool needsShizuku(String path) =>
    Platform.isAndroid && path.startsWith('/storage/emulated/0/Android/data/');

Future<Map<String, dynamic>> shizukuStatus() async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('shizukuStatus') ?? {});
Future<bool> requestShizuku() async =>
    await _channel.invokeMethod<bool>('shizukuRequest') ?? false;
Future<List<Map<String, dynamic>>> discoverAndroidProfiles() async {
  final text = await _channel.invokeMethod<String>('shizukuDiscover') ?? '[]';
  return (jsonDecode(text) as List).cast<Map<String, dynamic>>();
}

/// Hashes are streamed so large language models do not need to fit in memory.
Future<Map<String, String>> directoryDigests(String root) async {
  final result = <String, String>{};
  await for (final entry
      in Directory(root).list(recursive: true, followLinks: false)) {
    if (entry is Link) throw FileSystemException('不支持符号链接', entry.path);
    if (entry is! File) continue;
    result[p.relative(entry.path, from: root).replaceAll('\\', '/')] =
        (await sha256.bind(entry.openRead()).first).toString();
  }
  return result;
}

Map<String, dynamic> directoryChanges(
    Map<String, String> before, Map<String, String> after) {
  final changed = {...before.keys, ...after.keys}
      .where((key) => before[key] != after[key])
      .toList()
    ..sort();
  return {
    'expected': {for (final key in changed) key: before[key]},
    'writes': changed.where(after.containsKey).toList(),
  };
}

/// All existing installers work on an isolated local tree. Commit only changed
/// files, with remote SHA256 checks and recovery copies handled by the service.
Future<T> withProfileDirectory<T>(
  Profile profile,
  FutureOr<T> Function(Profile local) action, {
  bool readOnly = false,
}) async {
  if (!needsShizuku(profile.path)) return await action(profile);
  final root = await _channel
      .invokeMethod<String>('shizukuStage', {'root': profile.path});
  if (root == null) throw const FileSystemException('未能读取 Shizuku 用户目录');
  final staged = Directory(root);
  final bundle = File('$root.zip');
  try {
    final before = readOnly ? <String, String>{} : await directoryDigests(root);
    final local = Profile(label: profile.label, path: root, kind: profile.kind);
    final value = await action(local);
    if (!readOnly) {
      final plan = directoryChanges(before, await directoryDigests(root));
      final expected = plan['expected'] as Map;
      if (expected.isNotEmpty) {
        final encoder = ZipFileEncoder();
        encoder.create(bundle.path);
        try {
          final data = utf8.encode(jsonEncode(plan));
          encoder.addArchiveFile(
              ArchiveFile('__manifest__.json', data.length, data));
          for (final rel in plan['writes'] as List<String>) {
            await encoder.addFile(File(p.join(root, rel)), rel);
          }
        } finally {
          encoder.close();
        }
        await _channel.invokeMethod<String>(
            'shizukuCommit', {'root': profile.path, 'bundle': bundle.path});
      }
    }
    return value;
  } finally {
    if (staged.existsSync()) staged.deleteSync(recursive: true);
    if (bundle.existsSync()) bundle.deleteSync();
  }
}
