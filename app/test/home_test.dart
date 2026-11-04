import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/main.dart';
import 'package:rime_updater/models.dart';
import 'package:rime_updater/ui/app_theme.dart';
import 'package:rime_updater/ui/local_zip_dialog.dart';
import 'package:rime_updater/ui/remote_scheme_dialog.dart';
import 'package:rime_updater/ui/switch_scheme_dialog.dart';

void main() {
  testWidgets('主页渲染标题、设备与操作按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: HomePage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rime 更新器'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('仅预演'), findsOneWidget);
    expect(find.text('一键更新'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    // 启动时不自动请求 GitHub，日志区应保持「等待操作」状态
    expect(find.textContaining('等待操作'), findsOneWidget);
    expect(find.text('备份与回滚'), findsOneWidget);
    expect(find.byTooltip('添加 Rime 目录'), findsOneWidget);
    expect(find.text('DEVICES'), findsOneWidget);
    expect(find.text('CONSOLE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机窄屏布局不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: HomePage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('云同步'), findsOneWidget);
    expect(find.text('同步库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 640),
    const Size(960, 600),
    const Size(1000, 540),
    const Size(1440, 900),
  ]) {
    testWidgets('新版布局在 $size、深色和放大文字下保持可操作', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.2)),
          child: child!,
        ),
        home: const HomePage(),
      ));
      await tester.pumpAndSettle();
      expect(find.text('一键更新'), findsOneWidget);
      expect(find.textContaining('等待操作'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (size.width < 960 || size.height < 680) {
        await tester.ensureVisible(find.text('备份与回滚'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.byTooltip('更多功能'), -200,
            scrollable: find.byType(Scrollable).first);
        await tester.tap(find.byTooltip('更多功能'));
        await tester.pumpAndSettle();
        expect(find.text('GitHub 方案'), findsOneWidget);
        expect(find.text('从本地 zip 安装'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } else {
        expect(find.text('方案管理'), findsOneWidget);
        await tester.tap(find.text('从本地 zip 安装'));
        await tester.pumpAndSettle();
        expect(find.text('开始安装'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('设置弹窗可以打开并展开高级设置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(home: HomePage()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('更新后自动部署'), findsOneWidget);
    expect(find.text('更新前完整快照'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('方案仓库'), findsOneWidget);
    expect(find.text('GitHub Token（可选）'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地 zip 安装弹窗可以打开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const LocalZipDialog(deviceCount: 2),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('从本地 zip 安装'), findsOneWidget);
    expect(find.text('压缩包路径'), findsOneWidget);
    expect(find.text('开始安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换方案弹窗可以打开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const SwitchSchemeDialog(deviceCount: 3),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('换方案'), findsOneWidget);
    expect(find.text('新方案压缩包'), findsOneWidget);
    expect(find.text('备份并切换'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GitHub 方案弹窗可以打开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const RemoteSchemeDialog(settings: Settings()),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('从 GitHub 安装方案'), findsOneWidget);
    expect(find.text('方案仓库'), findsOneWidget);
    expect(find.byTooltip('读取 Releases'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
