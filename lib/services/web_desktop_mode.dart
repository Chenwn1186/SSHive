import 'package:flutter/foundation.dart';

import 'log_bus.dart';
import 'secure_store.dart';

/// 手机端"桌面版网页"模式（仅 Android 生效）。
///
/// 两个手段让网页按电脑布局渲染：
/// 1. [kDesktopUserAgent]：替换手机 UA（含 "Mobile" 关键字），
///    网站据此返回桌面版页面；
/// 2. [viewportJs]：在文档解析前注入可调宽度视口（[viewportWidth]，
///    默认 1280），确保即使站点依赖 viewport meta 也按桌面宽度布局；
///    宽度可由用户在设置里自由调节（800~2560）。
///
/// 注意：设置变化仅对**新打开/重开**的网页标签生效（WebView 在创建时
/// 应用这些参数）；Windows 端本就是桌面布局，此模式不参与。
class WebDesktopMode extends ChangeNotifier {
  WebDesktopMode._();

  static final WebDesktopMode instance = WebDesktopMode._();

  static const String kDesktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static const int kMinViewportWidth = 300;
  static const int kMaxViewportWidth = 2560;
  static const int kDefaultViewportWidth = 1280;

  /// 视口宽度模板：__W__ 会被替换为实际宽度（详见 [viewportJs]）。
  static const String _viewportJsTemplate = r'''
(function() {
  var VP = 'width=__W__, initial-scale=1';
  function setMeta() {
    try {
      var metas = document.querySelectorAll('meta[name="viewport"]');
      if (metas.length > 0) {
        for (var i = 0; i < metas.length; i++) metas[i].setAttribute('content', VP);
      } else {
        var m = document.createElement('meta');
        m.setAttribute('name', 'viewport');
        m.setAttribute('content', VP);
        var h = document.head || document.documentElement;
        if (h) h.appendChild(m);
      }
    } catch (e) {}
  }
  function setStyle() {
    try {
      if (document.querySelector('#__ssh_desktop_force')) return;
      var s = document.createElement('style');
      s.id = '__ssh_desktop_force';
      s.textContent = 'html,body{min-width:__W__px !important;}';
      var h = document.head || document.documentElement;
      if (h) h.appendChild(s);
    } catch (e) {}
  }
  setMeta();
  setStyle();
  var n = 0;
  var t = setInterval(function() {
    n++;
    if (document.head) { setMeta(); setStyle(); }
    if (n >= 40) clearInterval(t);
  }, 25);
})();
''';

  bool _enabled = true;
  bool get enabled => _enabled;

  int _viewportWidth = kDefaultViewportWidth;
  int get viewportWidth => _viewportWidth;

  /// 注入脚本（按当前视口宽度生成）。
  String get viewportJs =>
      _viewportJsTemplate.replaceAll('__W__', '$_viewportWidth');

  Future<void> load() async {
    try {
      final raw = await SecureStore.instance.loadWebDesktopMode();
      if (raw != null) _enabled = raw;
      final w = await SecureStore.instance.loadWebDesktopWidth();
      if (w != null && w >= kMinViewportWidth && w <= kMaxViewportWidth) {
        _viewportWidth = w;
      }
    } catch (e) {
      LogBus.instance.error('Web', '加载桌面版网页设置失败: $e');
    }
  }

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    notifyListeners();
    await SecureStore.instance.saveWebDesktopMode(v);
  }

  /// 设置视口渲染宽度（新打开/重开的网页标签生效）。
  Future<void> setViewportWidth(int w) async {
    final clamped = w.clamp(kMinViewportWidth, kMaxViewportWidth);
    if (clamped == _viewportWidth) return;
    _viewportWidth = clamped;
    notifyListeners();
    await SecureStore.instance.saveWebDesktopWidth(clamped);
  }
}