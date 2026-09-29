import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshive/services/update_service.dart';
import 'package:sshive/ui/home_page.dart';

void main() {
  group('版本比较', () {
    test('常见写法', () {
      expect(UpdateService.compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(UpdateService.compareVersions('1.0.0', '1.0.1'), lessThan(0));
      expect(UpdateService.compareVersions('1.0.0', '1.0.0'), 0);
      // 前缀 v / 后缀 +build 都要容忍
      expect(UpdateService.compareVersions('v1.2.0', '1.1.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.2.3+4', '1.2.3'), 0);
      // 段数不足按 0 补齐
      expect(UpdateService.compareVersions('1.3', '1.3.0'), 0);
      expect(UpdateService.compareVersions('2', '1.9.9'), greaterThan(0));
      // 非法内容不炸
      expect(UpdateService.compareVersions('abc', '0.0.0'), 0);
    });
  });

  group('检查更新菜单', () {
    testWidgets('点击后菜单项显示转圈圈，完成后弹出结果', (WidgetTester tester) async {
      final gate = Completer<UpdateInfo>();
      UpdateService.debugCheckOverride = () => gate.future;
      addTearDown(() => UpdateService.debugCheckOverride = null);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();

      // 打开右上角设置菜单
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('检查更新'), findsOneWidget);

      // 点击检查更新 → 菜单**不关闭**，菜单项变转圈圈
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(find.text('正在检查更新…'), findsOneWidget,
          reason: '检查期间菜单应保持打开并显示进度文案');
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // 检查完成 → 菜单关闭 + 弹结果对话框
      gate.complete(const UpdateInfo(
        status: UpdateStatus.upToDate,
        currentVersion: '1.0.0',
        latestVersion: '1.0.0',
      ));
      await tester.pumpAndSettle();
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.text('检查更新'), findsNothing,
          reason: '结果弹出时菜单应已关闭');
    });

    testWidgets('发现新版本时给出"下载并安装"入口', (WidgetTester tester) async {
      UpdateService.debugCheckOverride = () async => const UpdateInfo(
            status: UpdateStatus.available,
            currentVersion: '1.0.0',
            latestVersion: '9.9.9',
            notes: '测试更新说明',
            apkUrl: 'https://example.com/x.apk',
            apkBytes: 1024 * 1024,
            releaseUrl: 'https://example.com/release',
          );
      addTearDown(() => UpdateService.debugCheckOverride = null);

      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 v9.9.9'), findsOneWidget);
      expect(find.text('测试更新说明'), findsOneWidget);
      // 桌面/测试环境不是 Android，因此入口是"打开发布页"
      expect(find.text('打开发布页'), findsOneWidget);
    });
  });
}
