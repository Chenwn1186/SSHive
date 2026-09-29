import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshive/services/window_metrics.dart';
import 'package:sshive/ui/home_page.dart';

/// "小窗下组件消失、只剩 FAB"的机械原因与回归防护。
///
/// 场景：OEM（小米小窗/分屏/多窗口）可能上报**超过窗口尺寸**的系统 Insets。
/// 此时 SafeArea 会把子树可用高度压成 0：AppBar 与 body 全被压没，
/// 而未裁剪的 FAB 仍会绘制 —— 表现就是"只剩右下角 FAB"。
/// 实测：未夹取时 HomePage 的 body 高度 = 0；夹取后 = 147（400x300 窗口）。
void main() {
  void useWindow(WidgetTester tester,
      {required Size size, required double bottomPadding}) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding(bottom: bottomPadding);
    addTearDown(() {
      tester.view.resetPadding();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('机制：未夹取的异常 Insets 会把可用高度压成 0', (tester) async {
    useWindow(tester, size: const Size(400, 300), bottomPadding: 320);

    double? availHeight;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => SafeArea(
          top: false,
          bottom: true,
          left: true,
          right: true,
          child: LayoutBuilder(builder: (context, c) {
            availHeight = c.maxHeight;
            return const SizedBox.shrink();
          }),
        ),
        home: const SizedBox.shrink(),
      ),
    );
    await tester.pump();

    expect(availHeight, 0,
        reason: 'padding(320) 大于窗口高度(300) 时 SafeArea 会把内容压成 0');
  });

  testWidgets('修复：夹取后 HomePage 的 body 仍有可用空间', (tester) async {
    // 小窗：500x700，但 OEM 上报的底部 padding(800) 超过窗口高度
    useWindow(tester, size: const Size(500, 700), bottomPadding: 800);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: WindowMetrics.clampInsets(mq),
            child: SafeArea(
              top: false,
              bottom: true,
              left: true,
              right: true,
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
        home: const HomePage(),
      ),
    );
    await tester.pump();

    final bodyHeight = tester.getSize(find.byType(IndexedStack).first).height;
    debugPrint('夹取后 HomePage body 高度 = $bodyHeight');
    expect(bodyHeight, greaterThan(0),
        reason: '夹取 Insets 后 body 不应被压成 0（否则页面组件会消失）');
  });

  testWidgets('clampInsets 只夹 Insets，不改窗口尺寸与键盘 Insets', (tester) async {
    const mq = MediaQueryData(
      size: Size(400, 300),
      padding: EdgeInsets.only(bottom: 320, left: 300, right: 4),
      viewInsets: EdgeInsets.only(bottom: 120),
      viewPadding: EdgeInsets.only(bottom: 320, left: 300, right: 4),
    );
    final clamped = WindowMetrics.clampInsets(mq);

    // 尺寸与键盘 Insets 保持原样（键盘避让逻辑不能被破坏）
    expect(clamped.size, mq.size);
    expect(clamped.viewInsets, mq.viewInsets);
    // 越界的边被夹到 35%
    expect(clamped.padding.bottom, lessThanOrEqualTo(300 * 0.35));
    expect(clamped.padding.left, lessThanOrEqualTo(400 * 0.35));
    // 未越界的边保持原值
    expect(clamped.padding.right, 4);
  });
}
