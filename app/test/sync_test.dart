import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/core/sync_service.dart';
import 'package:rime_updater/models.dart';
import 'package:rime_updater/ui/sync_dialog.dart';
import 'package:rime_updater/ui/sync_library_dialog.dart';

void main() {
  test('同步库清单字段可序列化', () {
    final device = SyncDevice(
      id: 'dev-1',
      name: '家里的 Mac',
      at: DateTime.utc(2026, 11, 4, 8, 30),
    );
    final decoded = SyncDevice.fromJson(
      jsonDecode(jsonEncode(device.toJson())) as Map<String, dynamic>,
    );
    expect(decoded, isNotNull);
    expect(decoded!.name, '家里的 Mac');
    expect(decoded.at.toUtc(), DateTime.utc(2026, 11, 4, 8, 30));
    expect(SyncDevice.fromJson({'id': 'x'}), isNull);

    final file = SyncFile(
      path: 'user.yaml',
      by: 'dev-1',
      byName: '家里的 Mac',
      at: DateTime.utc(2026, 11, 4, 9, 0),
    );
    final parsed = SyncFile.fromJson(
      jsonDecode(jsonEncode(file.toJson())) as Map<String, dynamic>,
    );
    expect(parsed!.path, 'user.yaml');
    expect(parsed.byName, '家里的 Mac');
    expect(SyncFile.fromJson({'path': ''}), isNull);
  });

  test('设置保存云同步字段', () {
    const settings = Settings(
      syncUrl: 'https://dav.example.com/me/',
      syncUser: 'me',
      syncPassword: 'secret',
      deviceName: '办公电脑',
    );
    final decoded = Settings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.syncUrl, settings.syncUrl);
    expect(decoded.syncUser, 'me');
    expect(decoded.syncPassword, 'secret');
    expect(decoded.deviceName, '办公电脑');
  });

  test('同步目录按前端类型区分', () {
    const known = Profile(label: '鼠须管', path: '/tmp/rime', kind: 'squirrel');
    const manual =
        Profile(label: '我的 Rime', path: '/tmp/other', kind: 'unknown');
    expect(syncKey(known), 'squirrel');
    expect(syncKey(manual), '我的_Rime');
  });

  test('同步库按目录分组，*.userdb 保持整组', () {
    final at = DateTime.utc(2026, 11, 4, 9, 0);
    SyncFile file(String path) => SyncFile(
          path: path,
          by: 'dev-1',
          byName: '本机',
          at: at,
        );
    final files = [
      file('user.yaml'),
      file('lua/quote.txt'),
      file('lua/input_stats_1.lua'),
      file('lily.userdb/data.mdb'),
      file('lily.userdb/LOG'),
    ];

    final root = listEntries(files, '');
    expect(root.map((entry) => entry.name).toList(),
        ['lua', 'lily.userdb', 'user.yaml']);
    expect(root.first.isDir, isTrue);
    expect(root.first.fileCount, 2);
    expect(root[1].isUserDb, isTrue);
    expect(root[1].paths.length, 2);
    expect(root.last.isDir, isFalse);

    final lua = listEntries(files, 'lua');
    expect(lua.map((entry) => entry.name).toSet(),
        {'input_stats_1.lua', 'quote.txt'});
  });

  testWidgets('同步库弹窗是文件夹式列表', (tester) async {
    const profile = Profile(
      label: '鼠须管',
      path: '/tmp/rime',
      kind: 'squirrel',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SyncLibraryDialog(
            settings: Settings(),
            profiles: [profile],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('同步库'), findsOneWidget);
    expect(find.textContaining('还没有配置 WebDAV'), findsOneWidget);
    expect(find.byTooltip('上传本机文件'), findsOneWidget);
    expect(find.byTooltip('刷新同步库'), findsOneWidget);
  });

  testWidgets('云同步弹窗展示配置与文件管理入口', (tester) async {
    const profile = Profile(
      label: '鼠须管',
      path: '/tmp/rime',
      kind: 'squirrel',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SyncDialog(
            settings: Settings(),
            profiles: [profile],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('云同步（WebDAV）'), findsOneWidget);
    expect(find.text('WebDAV 地址'), findsOneWidget);
    expect(find.text('上传本机'), findsOneWidget);
    expect(find.text('添加文件'), findsOneWidget);
    expect(find.text('下载云端'), findsOneWidget);
    expect(find.text('鼠须管'), findsOneWidget);
    expect(find.text('未读取云端同步库'), findsOneWidget);
  });
}
