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
    // 备份与回滚已移到「更多」页，主页不再显示
    expect(find.text('备份与回滚'), findsNothing);
    // 启动时不自动请求 GitHub，日志区应保持「等待操作」状态
    expect(find.textContaining('等待操作'), findsOneWidget);
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
    // 底部导航：选中项显示文字，其余只有图标
    expect(find.text('更新器'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-nav-同步')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-nav-设置')), findsOneWidget);
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
        await tester.tap(find.byKey(const ValueKey('home-nav-更多')));
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

  testWidgets('设备菜单提供重命名与清空目录，清空有风险确认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    final menus = find.byTooltip('更多操作');
    if (menus.evaluate().isEmpty) {
      // 当前机器没有识别到任何 Rime 目录，跳过（CI 常见）。
      return;
    }
    await tester.tap(menus.first);
    await tester.pumpAndSettle();

    expect(find.text('重命名设备'), findsOneWidget);
    expect(find.text('清空 Rime 目录'), findsOneWidget);
    expect(find.text('删除设备'), findsOneWidget);

    // 清空必须二次确认，且明确写出不可恢复
    await tester.tap(find.text('清空 Rime 目录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不可恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置作为独立页面，可展开高级设置并看到缓存入口', (tester) async {
    // 用窄屏尺寸，走底部导航布局
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('home-nav-设置')));
    await tester.pumpAndSettle();

    expect(find.text('更新后自动部署'), findsOneWidget);
    expect(find.text('更新前完整快照'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('方案仓库'), findsOneWidget);
    expect(find.text('GitHub Token（可选）'), findsOneWidget);
    expect(find.text('下载缓存目录'), findsOneWidget);
    expect(find.text('清理缓存'), findsOneWidget);
    expect(find.text('保存设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部导航可在更新器 / 同步 / 更多 / 设置之间切换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    // 默认在更新器页
    expect(find.text('一键更新'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-同步')));
    await tester.pumpAndSettle();
    expect(find.text('云同步'), findsWidgets);
    expect(find.text('同步库'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('home-nav-更多')));
    await tester.pumpAndSettle();
    expect(find.text('GitHub 方案'), findsOneWidget);
    expect(find.text('换方案'), findsOneWidget);
    // 备份与回滚搬家到「更多」
    expect(find.text('备份与回滚'), findsOneWidget);
    // 更新器页的内容已经切走
    expect(find.text('一键更新'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('home-nav-设置')));
    await tester.pumpAndSettle();
    expect(find.text('更新后自动部署'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-更新器')));
    await tester.pumpAndSettle();
    expect(find.text('一键更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面侧栏的「同步库」直接落在同步库子页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    // 先看云同步：有 WebDAV 地址输入框
    await tester.tap(find.byKey(const ValueKey('sidebar-云同步')));
    await tester.pumpAndSettle();
    expect(find.text('WebDAV 地址'), findsOneWidget);

    // 点侧栏「同步库」应直接切到同步库子页，不再显示云同步表单
    await tester.tap(find.byKey(const ValueKey('sidebar-同步库')));
    await tester.pumpAndSettle();
    expect(find.text('WebDAV 地址'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换标签时胶囊真的在滑动（而不是瞬移）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    final pill = find.byKey(const ValueKey('home-nav-pill'));
    final startX = tester.getCenter(pill).dx;

    await tester.tap(find.byKey(const ValueKey('home-nav-更多')));
    await tester.pump(); // 提交状态变化，动画从起点开始
    // 动画进行中：位置应当在起点与终点之间
    await tester.pump(const Duration(milliseconds: 90));
    final midX = tester.getCenter(pill).dx;
    expect(midX, greaterThan(startX));

    // 动画结束后到达新位置并停住
    await tester.pumpAndSettle();
    final endX = tester.getCenter(pill).dx;
    expect(endX, greaterThan(midX));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换页面是整屏横向推入，而不是瞬间替换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();
    expect(find.text('一键更新'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-nav-更多')));
    await tester.pump(); // 过渡开始，新页此时还在屏幕右侧

    final newPage = find.byKey(const ValueKey('page-2'));
    expect(newPage, findsOneWidget);
    // 旧页立刻退场，过渡中不得残留（避免「残影」观感）
    expect(find.text('一键更新'), findsNothing);
    expect(find.byKey(const ValueKey('page-0')), findsNothing);
    final startDx = tester.getTopLeft(newPage).dx;
    // 整屏推入：起始位置应当接近屏幕右缘，而不是已经就位
    expect(startDx, greaterThan(300));

    // 过渡中途仍在移动
    await tester.pump(const Duration(milliseconds: 120));
    final midDx = tester.getTopLeft(newPage).dx;
    expect(midDx, lessThan(startDx));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(newPage).dx, closeTo(0, 1));
    // 过渡结束后旧页移除
    expect(find.text('一键更新'), findsNothing);
    expect(find.text('GitHub 方案'), findsOneWidget);
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
