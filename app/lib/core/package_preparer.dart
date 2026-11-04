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

Future<PreparedPackage> preparePackage({
  required Settings settings,
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

    if (isDelta && zipRequiresFull(cachePath)) {
      log('  增量包要求完整包，改用完整 zip');
      final full = info.assets
          .where((asset) =>
              asset.name.endsWith('.zip') && !asset.name.contains('-update'))
          .toList();
      if (full.isEmpty) throw UpdateException('该版本没有完整包，无法更新');
      assetName = full.first.name;
      isDelta = false;
      expectedSha = await client.readExpectedSha(assetName, info);
      cachePath = p.join(client.cacheDir, assetName);

      final cached = File(cachePath);
      final valid = cached.existsSync() &&
          (expectedSha.isNotEmpty
              ? sha256File(cachePath).toLowerCase() ==
                  expectedSha.toLowerCase()
              : full.first.size > 0 &&
                  cached.lengthSync() == full.first.size);
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
