import 'dart:io';

import 'package:chinese_font_library/chinese_font_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:re_editor/re_editor.dart';

import 'services/app_state.dart';
import 'services/log_bus.dart';
import 'services/secure_store.dart';
import 'services/web_scroll_config.dart';
import 'services/web_scroll_settings.dart';
import 'services/web_desktop_mode.dart';
import 'services/web_session_manager.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 前台保活服务初始化（仅 Android 支持；桌面平台跳过）
  if (Platform.isAndroid) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ssh_agent_keepalive',
        channelName: 'SSH 隧道保活',
        channelDescription: '保持 SSH 隧道在后台持续运行',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowAutoRestart: true,
      ),
    );
    FlutterForegroundTask.initCommunicationPort();
  }

  // WebView2 全局环境（仅 Windows）：禁用 HTTP→HTTPS 自动升级。
  // 详见 web_scroll_config.dart 中的 gWebViewEnvironment 注释。
  if (Platform.isWindows) {
    try {
      gWebViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          additionalBrowserArguments: '--disable-features=HttpsUpgrades',
        ),
      );
      LogBus.instance
          .info('WebView', 'WebView2 环境已就绪（禁用 HttpsUpgrades）');
    } catch (e) {
      LogBus.instance.error('WebView', '创建 WebView2 环境失败: $e');
    }
  }

  await AppState.instance.load();
  // 网页滚动幅度设置（Windows WebView2；在 WebView 创建前加载）
  await WebScrollSettings.instance.load();
  // 桌面版网页模式（Android；在 WebView 创建前加载）
  await WebDesktopMode.instance.load();
  // 文本预览滚轮倍率（re_editor 全局倍率，立即对所有编辑器生效）
  final scrollFactor = await SecureStore.instance.loadViewerScrollFactor();
  if (scrollFactor != null && scrollFactor > 0 && scrollFactor <= 8) {
    CodeWheelScale.factor = scrollFactor;
  }
  // 还原上次打开的网页标签（页面重新加载，Cookie 保留登录态）
  await WebSessionManager.instance.restore();
  // 后台保活：若上次开启则恢复前台服务（内部有 Android 守卫）
  await AppState.instance.restoreBackgroundKeepAlive();
  // 自动连接标记了 autoConnect 的服务器（内部也会自动启动 autoStart 隧道）
  await AppState.instance.applyAutoConnect();

  runApp(const SshiveApp());
}

class SshiveApp extends StatelessWidget {
  const SshiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSHive',
      debugShowCheckedModeBanner: false,
      // 全局安全区适配：Android 15+ 强制 edge-to-edge，内容会延伸到
      // 系统导航栏/状态栏之下，这里统一为页面内容避开系统导航栏
      // （顶部状态栏由 AppBar 自行处理，因此只避让底部与左右）。
      builder: (context, child) => SafeArea(
        top: false,
        bottom: true,
        left: true,
        right: true,
        child: child ?? const SizedBox.shrink(),
      ),
      // chinese_font_library：全局中文字体优化
      // （中文回退链 + wght 可变字重，各字重原生渲染）
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
        useMaterial3: true,
      ).useSystemChineseFont(Brightness.light),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ).useSystemChineseFont(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}
