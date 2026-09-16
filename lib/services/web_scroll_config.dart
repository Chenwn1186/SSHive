import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 全局共享的 WebView2 环境（仅 Windows，main() 中初始化）。
///
/// 关键作用：WebView2 Runtime 120+ 默认启用 HTTPS 升级（HttpsUpgrades），
/// 会把 http://127.0.0.1:端口 自动升级为 https 访问，而 SSH 隧道转发的是
/// 纯 http 服务，收到 TLS 握手后立即断开 → 页面加载失败
/// （WebErrorStatus=CONNECTION_ABORTED，"connection was stopped"）。
/// 通过 AdditionalBrowserArguments 传入 `--disable-features=HttpsUpgrades`
/// 关闭该升级；参考 MicrosoftEdge/WebView2Feedback#4104。
/// 未指定 userDataFolder → 沿用 WebView2 默认（exe 同级目录下的
/// "应用名.WebView2"，如 sshagent.exe.WebView2），Cookie 持久化位置不变。
WebViewEnvironment? gWebViewEnvironment;

/// 是否启用滚轮增量校准（仅 Windows 的 WebView2 有此缺陷；
/// Android/iOS 为拖拽滚动，该设置不含此问题）。
bool get webScrollCalibrationEnabled =>
    defaultTargetPlatform == TargetPlatform.windows;
