import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rime_updater/ui/swipe_action_row.dart';

void main() {
  testWidgets('向左滑动露出删除，点删除才执行', (tester) async {
    var tappedChild = 0;
    var deleted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SwipeActionRow(
                onAction: () async => deleted += 1,
                child: InkWell(
                  onTap: () => tappedChild += 1,
                  child: const SizedBox(height: 60, child: Text('设备 A')),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 未滑动时删除按钮在内容下面，点行内容走的是选择逻辑。
    await tester.tap(find.text('设备 A'));
    expect(tappedChild, 1);
    expect(deleted, 0);

    // 向左滑开。
    await tester.drag(find.text('设备 A'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);

    // 滑开后点行内容只是收起，不会触发选择。
    await tester.tap(find.text('设备 A'));
    await tester.pumpAndSettle();
    expect(tappedChild, 1);
    expect(deleted, 0);

    // 再滑开并点删除。
    await tester.drag(find.text('设备 A'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('滑动不足一半会收回', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SwipeActionRow(
                onAction: () async {},
                child: const SizedBox(height: 60, child: Text('设备 B')),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.drag(find.text('设备 B'), const Offset(-10, 0));
    await tester.pumpAndSettle();
    // 收起后行内容仍在原位：删除按钮被内容遮住，点「设备 B」仍然可命中。
    await tester.tap(find.text('设备 B'));
    expect(tester.takeException(), isNull);
  });
}
