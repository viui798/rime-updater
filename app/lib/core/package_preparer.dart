import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'github_client.dart';
import 'zip_installer.dart';

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

/// 基座校验：任一目标目录的已装版本与增量基座不一致（或未知）返回 true。
/// 增量包只覆盖 from->to 的差异，套在别的底子上会缺文件导致打不出字
/// （2026-11-05 事故），宁重勿缺。
bool deltaBaseMismatch(String zipPath, List<String> installedVersions) {
  final base = deltaBaseVersion(zipPath);
  if (base.isEmpty) return false;
  final norm = base.startsWith('v') ? base.substring(1) : base;
  return installedVersions.any((v) {
    final local = (v.startsWith('v') ? v.substring(1) : v).trim();
    return local.isEmpty || local != norm.trim();
  });
}

/// 丢弃增量包，改用完整 zip（复用既有缓存/下载与哈希校验逻辑）。
Future<PreparedPackage> _fallbackFull({
  required ReleaseInfo info,
  required GithubClient client,
  required void Function(String line) log,
  required void Function(int percent) progress,
}) async {
  log('  增量包不可用，改用完整 zip');
  final full = info.assets
      .where((asset) =>
          asset.name.endsWith('.zip') && !asset.name.contains('-update'))
      .toList();
  if (full.isEmpty) throw UpdateException('该版本没有完整包，无法更新');
  final assetName = full.first.name;
  var expectedSha = await client.readExpectedSha(assetName, info);
  var cachePath = p.join(client.cacheDir, assetName);

  final cached = File(cachePath);
  final valid = cached.existsSync() &&
      (expectedSha.isNotEmpty
          ? sha256File(cachePath).toLowerCase() == expectedSha.toLowerCase()
          : full.first.size > 0 && cached.lengthSync() == full.first.size);
  if (valid) {
    log('复用缓存 $cachePath');
  } else {
    log('下载 $assetName ...');
    await client.downloadTo(
      full.first.url,
      cachePath,
      expectedSha: expectedSha,
      onPercent: progress,
    );
  }
  return PreparedPackage(
    zipPath: cachePath,
    expectedSha: expectedSha,
    version: info.version,
    assetName: assetName,
    isDelta: false,
  );
}

Future<PreparedPackage> preparePackage({
  required Settings settings,
  required List<String> installedVersions,
  required void Function(String line) log,
  required void Function(int percent) progress,
  ReleaseInfo? release,
}) async {
  final client = GithubClient(settings: settings, log: log);
  try {
    final info = release ?? await client.fetchLatest();
    log('远端最新：v${info.version}（${info.assetName}）');

    var assetName = info.assetName;
    var isDelta = info.isDelta;
    var expectedSha = await client.readExpectedSha(assetName, info);
    var cachePath = p.join(client.cacheDir, assetName);

    bool cachedValid() {
      final file = File(cachePath);
      if (!file.existsSync()) return false;
      if (expectedSha.isNotEmpty) {
        return sha256File(cachePath).toLowerCase() ==
            expectedSha.toLowerCase();
      }
      return info.assetSize > 0 &&
          file.lengthSync() == info.assetSize;
    }

    if (cachedValid()) {
      log('复用缓存 $cachePath');
    } else {
      log('下载 $assetName ...');
      final asset = info.chosenAsset;
      if (asset == null) throw UpdateException('Release 缺少资产：$assetName');
      await client.downloadTo(
        asset.url,
        cachePath,
        expectedSha: expectedSha,
        onPercent: progress,
      );
    }

    if (isDelta && deltaBaseMismatch(cachePath, installedVersions)) {
      log('  增量包基座与已装版本不一致');
      return await _fallbackFull(info: info, client: client, log: log,
          progress: progress);
    }
    if (isDelta && zipRequiresFull(cachePath)) {
      log('  增量包要求完整包，改用完整 zip');
      return await _fallbackFull(info: info, client: client, log: log,
          progress: progress);
    }

    progress(55);
    return PreparedPackage(
      zipPath: cachePath,
      expectedSha: expectedSha,
      version: info.version,
      assetName: assetName,
      isDelta: isDelta,
    );
  } finally {
    client.close();
  }
}
