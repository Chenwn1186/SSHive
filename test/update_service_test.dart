import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  group('降级路径（绕过 api.github.com）', () {
    test('从 releases 页面地址取 tag', () {
      expect(
        UpdateService.parseTagFromUrl(
            'https://github.com/Chenwn1186/SSHive/releases/tag/v1.0.3'),
        'v1.0.3',
      );
      expect(
        UpdateService.parseTagFromUrl('https://github.com/x/y/releases/tag/1.2.3?a=1'),
        '1.2.3',
      );
      expect(UpdateService.parseTagFromUrl('https://github.com/x/y/releases'),
          isNull);
      expect(UpdateService.parseTagFromUrl(null), isNull);
    });

    test('从 expanded_assets 片段取 APK 直链', () {
      const html = '<a href="/Chenwn1186/SSHive/releases/download/v1.0.3/'
          'SSHive-1.0.3-android-universal.apk">asset</a>';
      expect(
        UpdateService.parseApkUrlFromAssetsHtml(html),
        'https://github.com/Chenwn1186/SSHive/releases/download/v1.0.3/'
        'SSHive-1.0.3-android-universal.apk',
      );
      // 绝对地址的资产链接也接受；但非 /releases/download/ 的 href 会被忽略
      // （片段里还有发布页/校验和等无关链接，不能误抓）
      expect(
        UpdateService.parseApkUrlFromAssetsHtml(
            '<a href="https://github.com/o/r/releases/download/v1/a.apk">'),
        'https://github.com/o/r/releases/download/v1/a.apk',
      );
      expect(UpdateService.parseApkUrlFromAssetsHtml('<a href="https://x/y.apk">'),
          isNull);
      expect(UpdateService.parseApkUrlFromAssetsHtml('没有 apk'), isNull);
    });

    test('API 不可达时自动降级到 github.com 并拿到新版本', () async {
      UpdateService.debugHttpGetOverride =
          (String url, {bool noRedirect = false}) async {
        if (url.contains('api.github.com')) {
          throw const SocketException('blocked in CN');
        }
        if (url.endsWith('/releases/latest')) {
          return (
            body: '',
            location:
                'https://github.com/Chenwn1186/SSHive/releases/tag/v9.9.9',
            status: 302,
          );
        }
        if (url.contains('expanded_assets')) {
          return (
            body: '<a href="/Chenwn1186/SSHive/releases/download/v9.9.9/'
                'SSHive-9.9.9-android-universal.apk">a</a>',
            location: null,
            status: 200,
          );
        }
        return (body: '', location: null, status: 404);
      };
      addTearDown(() => UpdateService.debugHttpGetOverride = null);

      final info = await UpdateService.check();
      expect(info.status, UpdateStatus.available);
      expect(info.latestVersion, '9.9.9');
      expect(info.viaWebFallback, isTrue, reason: '应走降级路径');
      expect(info.hasApk, isTrue);
      expect(info.releaseUrl, contains('/releases/tag/v9.9.9'));
    });

    test('两条路径都失败时返回失败并带上原因', () async {
      UpdateService.debugHttpGetOverride =
          (String url, {bool noRedirect = false}) async {
        throw const SocketException('offline');
      };
      addTearDown(() => UpdateService.debugHttpGetOverride = null);

      final info = await UpdateService.check();
      expect(info.status, UpdateStatus.failed);
      expect(info.error, isNotNull);
      expect(info.error, contains('API'));
      expect(info.error, contains('网页'));
    });
  });

  group('Windows 更新', () {
    test('API 路径同时解析 APK 与 Windows 绿色包', () async {
      UpdateService.debugHttpGetOverride =
          (String url, {bool noRedirect = false}) async => (
                body: jsonEncode({
                  'tag_name': 'v9.9.9',
                  'body': '发行说明',
                  'html_url': 'https://github.com/Chenwn1186/SSHive/releases/tag/v9.9.9',
                  'assets': [
                    {
                      'name': 'SSHive-9.9.9-android-universal.apk',
                      'browser_download_url': 'https://example.com/a.apk',
                      'size': 1048576,
                    },
                    {
                      'name': 'SSHive-9.9.9-windows-x64.zip',
                      'browser_download_url': 'https://example.com/w.zip',
                      'size': 2097152,
                    },
                  ],
                }),
                location: null,
                status: 200,
              );
      addTearDown(() => UpdateService.debugHttpGetOverride = null);

      final info = await UpdateService.check();
      expect(info.hasApk, isTrue);
      expect(info.hasWindowsZip, isTrue);
      expect(info.windowsZipUrl, 'https://example.com/w.zip');
      expect(info.windowsZipBytes, 2097152);
      // 测试宿主是 Windows → 应选 zip 而不是 apk
      if (Platform.isWindows) {
        expect(info.downloadUrl, 'https://example.com/w.zip');
        expect(info.downloadFileName, endsWith('-windows-x64.zip'));
      } else {
        expect(info.downloadUrl, 'https://example.com/a.apk');
      }
    });

    test('降级路径也能取到 Windows 包', () {
      const html = '<a href="/Chenwn1186/SSHive/releases/download/v9.9.9/'
          'SSHive-9.9.9-android-universal.apk">apk</a>'
          '<a href="/Chenwn1186/SSHive/releases/download/v9.9.9/'
          'SSHive-9.9.9-windows-x64.zip">zip</a>';
      final urls = UpdateService.parseAssetUrlsFromAssetsHtml(html);
      expect(urls.length, 2);
      expect(UpdateService.parseApkUrlFromAssetsHtml(html), endsWith('.apk'));
      expect(UpdateService.parseWindowsZipUrlFromAssetsHtml(html),
          'https://github.com/Chenwn1186/SSHive/releases/download/v9.9.9/'
          'SSHive-9.9.9-windows-x64.zip');
      expect(UpdateService.parseWindowsZipUrlFromAssetsHtml('<a href="/x.apk">'),
          isNull);
    });

    test('更新助手脚本：等进程退出 → 镜像覆盖 → 重启 → 清理', () {
      final script = UpdateService.buildWindowsApplyScript(
        stagedDir: r'C:\Users\u\AppData\Local\SSHive\update\staged-9.9.9',
        installDir: r'D:\exe dire\SSHive',
        exeName: 'sshive.exe',
        pid: 4321,
        cleanupDir: r'C:\Users\u\AppData\Local\SSHive\update\staged-9.9.9',
      );

      expect(script, contains('set "PID=4321"'), reason: '要等旧进程退出');
      expect(script, contains('tasklist'));
      expect(script, contains('timeout /t 1'));
      expect(script, contains(r'robocopy "%SRC%" "%DST%"'));
      expect(script, contains('/MIR'), reason: '镜像覆盖，顺手清掉旧版本残留文件');
      expect(script, contains('/XJ'), reason: '不跟进 junction');
      expect(script, contains('sshive.exe.WebView2'),
          reason: '必须保留 WebView2 运行时数据（登录态）');
      expect(script, contains(r'start "" "%DST%\sshive.exe"'),
          reason: '覆盖完要重新拉起');
      expect(script, contains(r'rd /s /q'));
    });

    test('更新助手脚本必须是纯 ASCII', () {
      final script = UpdateService.buildWindowsApplyScript(
        stagedDir: r'C:\stage',
        installDir: r'D:\app',
        exeName: 'sshive.exe',
        pid: 1,
        cleanupDir: r'C:\stage',
      );
      // cmd.exe 默认代码页 936，脚本里出现非 ASCII 会乱码甚至让参数解析失败
      final bad = script.runes.where((r) => r > 127).toList();
      expect(bad, isEmpty,
          reason: '含非 ASCII 字符：${bad.map(String.fromCharCode).join()}');
    });
  });
}
