import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/core/app_update.dart';
import 'package:rime_updater/core/app_version.dart';

AppAsset _asset(String name) =>
    AppAsset(name: name, url: 'https://example.com/$name', size: 1024);

AppRelease _release(List<String> names, {String version = '0.11.0'}) =>
    AppRelease(
      version: version,
      tag: 'v$version',
      pageUrl: 'https://github.com/viui798/rime-updater/releases/tag/v$version',
      notes: '',
      assets: names.map(_asset).toList(),
    );

const _allAssets = [
  'RimeUpdater-v0.11.0-macos.dmg',
  'RimeUpdater-v0.11.0-Setup.exe',
  'RimeUpdater-v0.11.0-portable-x64.zip',
  'RimeUpdater-v0.11.0-android-arm64-v8a.apk',
  'RimeUpdater-v0.11.0-android-armeabi-v7a.apk',
  'RimeUpdater-v0.11.0-android-x86_64.apk',
];

void main() {
  group('版本比较', () {
    test('按段比较数字而不是字典序', () {
      expect(compareVersions('0.10.0', '0.9.9'), 1);
      expect(compareVersions('0.9.9', '0.10.0'), -1);
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2.10', '1.2.9'), 1);
    });

    test('新版才提示更新', () {
      expect(_release(['x.dmg'], version: '0.10.0').isNewer, isFalse);
      expect(_release(['x.dmg'], version: '0.9.9').isNewer, isFalse);
      expect(_release(['x.dmg'], version: '0.10.1').isNewer, isTrue);
      expect(_release(['x.dmg'], version: '0.11.0').isNewer, isTrue);
    });
  });

  group('按平台选安装包', () {
    test('macOS 选 DMG', () {
      final picked = _release(_allAssets).pickAsset(platform: 'macos');
      expect(picked?.name, endsWith('.dmg'));
    });

    test('Windows 优先 Setup.exe 而不是 zip', () {
      final picked = _release(_allAssets).pickAsset(platform: 'windows');
      expect(picked?.name, 'RimeUpdater-v0.11.0-Setup.exe');
    });

    test('Windows 没有安装包时退回 zip', () {
      final picked = _release([
        'RimeUpdater-v0.11.0-portable-x64.zip',
      ]).pickAsset(platform: 'windows');
      expect(picked?.name, endsWith('.zip'));
    });

    test('Android 按设备 ABI 选对应 APK', () {
      final arm64 = _release(_allAssets)
          .pickAsset(platform: 'android', abis: ['arm64-v8a']);
      expect(arm64?.name, contains('arm64'));

      final arm32 = _release(_allAssets)
          .pickAsset(platform: 'android', abis: ['armeabi-v7a']);
      expect(arm32?.name, contains('armeabi'));

      final x64 = _release(_allAssets)
          .pickAsset(platform: 'android', abis: ['x86_64']);
      expect(x64?.name, contains('x86_64'));
    });

    test('Android 没有匹配的 ABI 时退回通用包', () {
      final picked = _release([
        'RimeUpdater-v0.11.0-android.apk',
        'RimeUpdater-v0.11.0-android-arm64-v8a.apk',
      ]).pickAsset(platform: 'android', abis: ['mips']);
      expect(picked?.name, 'RimeUpdater-v0.11.0-android.apk');
    });

    test('没有可用资产时返回 null', () {
      expect(_release(['readme.txt']).pickAsset(platform: 'macos'), isNull);
    });
  });

  group('版本号与 pubspec 一致', () {
    test('appVersion / appBuild 不能和 pubspec 漂移', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue, reason: '测试需要在 app/ 目录下运行');
      final line = pubspec
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
      expect(line, isNotEmpty);
      final value = line.split(':').last.trim(); // 0.10.0+36
      final parts = value.split('+');
      expect(parts.first, appVersion,
          reason: 'lib/core/app_version.dart 的 appVersion 需要同步 pubspec');
      expect(int.parse(parts.last), appBuild,
          reason: 'lib/core/app_version.dart 的 appBuild 需要同步 pubspec');
    });
  });
}
