import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_client.dart';
import 'zip_installer.dart';

/// 所有目标设备都已在远端最新版本，无需下载任何包。
class AlreadyLatest implements Exception {
  const AlreadyLatest(this.version);
  final String version;

  @override
  String toString() => '已是最新 v$version';
}

class PreparedPackage {
  const PreparedPackage({
    required this.zipPath,
    required this.expectedSha,
    required this.version,
    required this.assetName,
    required this.isDelta,
  });

  final String zipPath;
  final String expectedSha;
  final String version;
  final String assetName;
  final bool isDelta;
}

/// 更新阶梯（2026-11-05）：
///   1. 基座匹配的增量包（追新）；
///   2. 无模型版（落后几版但设备模型与本版 sha256 一致——保留设备模型）；
///   3. 完整包（模型缺失/变更/底子未知，宁重勿缺）。
/// 模型指纹来自 Release 的 MODEL.json 资产（1KB），设备侧流式哈希比对。
Future<PreparedPackage> preparePackage({
  required Settings settings,
  required List<String> installedVersions,
  required List<String> profilePaths,
  bool seedUnknown = false,
  required void Function(String line) log,
  required void Function(int percent) progress,
  ReleaseInfo? release,
}) async {
  final client = GithubClient(settings: settings, log: log);
  try {
    final info = release ?? await client.fetchLatest();
    log('远端最新：v${info.version}（${info.assetName}）');

    // 所有目标设备都已在最新版本：不必下载任何包（完整包可能有几百 MB）。
    final norm = info.version.startsWith('v')
        ? info.version.substring(1)
        : info.version;
    final allCurrent = installedVersions.isNotEmpty &&
        installedVersions.every((v) {
          final local = (v.startsWith('v') ? v.substring(1) : v).trim();
          return local.isNotEmpty && local == norm;
        });
    if (allCurrent) {
      log('  所有目标设备都已是 v$norm，跳过下载');
      throw AlreadyLatest(norm);
    }

    final releaseModelSha = await _fetchModelSha(info, client, log, progress);
    final modelOk =
        await deviceModelMatches(profilePaths, releaseModelSha ?? '', log);

    final deltaAsset = info.assets
        .where((asset) => asset.name.endsWith('-update.zip'))
        .toList();
    final nomodelAsset = info.assets
        .where((asset) => asset.name.endsWith('-nomodel.zip'))
        .toList();
    final fullAsset = info.assets
        .where((asset) =>
            asset.name.endsWith('.zip') &&
            !asset.name.contains('-update') &&
            !asset.name.contains('-nomodel'))
        .toList();

    progress(5);

    // 1) 增量包：基座匹配 + 模型没变才用
    if (deltaAsset.isNotEmpty) {
      final delta =
          await _downloadAsset(deltaAsset.first, info, client, log, progress,
              isDelta: true);
      if (!deltaBaseUsable(delta.zipPath, installedVersions,
          seedUnknown: seedUnknown)) {
        final base = normalizeVersion(deltaBaseVersion(delta.zipPath));
        log('  增量包基座 ${base.isEmpty ? '未知' : 'v$base'} 与本批设备不一致'
            '${seedUnknown ? '（无法从现有设备铺底）' : ''}');
        return await _pickHeavy(modelOk, nomodelAsset, fullAsset, info, client,
            log, progress);
      }
      if (!modelOk) {
        log('  设备模型与本版不一致，增量包不适用（避免代码与旧模型错配）');
        return await _pickHeavy(
            false, nomodelAsset, fullAsset, info, client, log, progress);
      }
      if (zipRequiresFull(delta.zipPath)) {
        log('  增量包要求完整包（模型有变更）');
        return await _downloadAsset(fullAsset.first, info, client, log,
            progress,
            isDelta: false);
      }
      return delta;
    }

    // 2) 无增量包：模型一致 → 无模型版；否则完整包
    return await _pickHeavy(
        modelOk, nomodelAsset, fullAsset, info, client, log, progress);
  } finally {
    client.close();
  }
}

Future<PreparedPackage> _pickHeavy(
    bool modelOk,
    List<Asset> nomodelAsset,
    List<Asset> fullAsset,
    ReleaseInfo info,
    GithubClient client,
    void Function(String line) log,
    void Function(int percent) progress) async {
  if (modelOk && nomodelAsset.isNotEmpty) {
    log('  设备模型与本版一致，使用无模型版更新');
    return await _downloadAsset(nomodelAsset.first, info, client, log, progress,
        isDelta: false);
  }
  if (fullAsset.isEmpty) throw UpdateException('该版本没有完整包，无法更新');
  return await _downloadAsset(fullAsset.first, info, client, log, progress,
      isDelta: false);
}

/// 下载 Release 里的 MODEL.json（1KB 模型指纹），失败返回 null。
Future<String?> _fetchModelSha(ReleaseInfo info, GithubClient client,
    void Function(String line) log, void Function(int percent) progress) async {
  final assets =
      info.assets.where((asset) => asset.name == 'MODEL.json').toList();
  if (assets.isEmpty) return null;
  final cachePath = p.join(client.cacheDir, 'MODEL.json');
  try {
    await client.downloadTo(assets.first.url, cachePath);
    final data = jsonDecode(File(cachePath).readAsStringSync());
    if (data is Map) return data['sha256']?.toString();
    return null;
  } catch (error) {
    log('  MODEL.json 读取失败（$error），按模型不一致处理');
    return null;
  }
}

/// 下载单个资产（含 .sha256 校验与缓存复用），返回 PreparedPackage。
Future<PreparedPackage> _downloadAsset(
    Asset asset, ReleaseInfo info, GithubClient client,
    void Function(String line) log, void Function(int percent) progress,
    {required bool isDelta}) async {
  var expectedSha = await client.readExpectedSha(asset.name, info);
  var cachePath = p.join(client.cacheDir, asset.name);

  final cached = File(cachePath);
  final valid = cached.existsSync() &&
      (expectedSha.isNotEmpty
          ? sha256File(cachePath).toLowerCase() == expectedSha.toLowerCase()
          : asset.size > 0 && cached.lengthSync() == asset.size);
  if (valid) {
    log('复用缓存 $cachePath');
  } else {
    log('下载 ${asset.name} ...');
    await client.downloadTo(
      asset.url,
      cachePath,
      expectedSha: expectedSha,
      onPercent: progress,
    );
  }
  return PreparedPackage(
    zipPath: cachePath,
    expectedSha: expectedSha,
    version: info.version,
    assetName: asset.name,
    isDelta: isDelta,
  );
}
