import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'log_bus.dart';
import 'secure_store.dart';
import 'web_scroll_settings.dart';

/// 一个网页会话（一个标签页）。
///
/// 生命周期规则：只有用户手动销毁或应用进程退出才结束；
/// 切换标签、返回主页均保活（页面状态/滚动位置/登录态/cookie 全部保留）。
///
/// WebView 引擎由 flutter_inappwebview 提供（跨平台：
/// Android / Windows(WebView2) / macOS / Linux）。
class WebSession {
  WebSession({
    required this.url,
    this.title,
    this.tunnelId,
    required this.onChanged,
  });

  /// 状态变化通知（由管理器注入）
  final VoidCallback onChanged;

  /// 初始地址（如 http://127.0.0.1:8080）
  final Uri url;

  /// 标题：初始为隧道名/自定义名，页面加载完成后更新为网页真实标题
  String? title;

  /// 关联的隧道 id（可选）
  final String? tunnelId;

  /// 控制器由 UI 层 InAppWebView 创建后挂载
  InAppWebViewController? controller;

  bool loading = true;
  String? error;

  String get displayTitle =>
      (title != null && title!.isNotEmpty) ? title! : url.toString();

  void attach(InAppWebViewController c) {
    controller = c;
    _load();
  }

  Future<void> _load() async {
    final c = controller;
    if (c == null) return;
    try {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
    } catch (e) {
      error = '加载失败: $e';
      loading = false;
      onChanged();
    }
  }

  /// 页面事件回调（由 UI 层 InAppWebView 转发过来）。
  void onPageStarted() {
    loading = true;
    error = null;
    onChanged();
  }

  Future<void> onPageFinished() async {
    loading = false;
    error = null;
    final c = controller;
    if (c != null) {
      try {
        title = await c.getTitle() ?? title;
      } catch (_) {}
    }
    onChanged();
  }

  void onLoadError(String description) {
    error = description.isEmpty ? '加载失败' : description;
    loading = false;
    onChanged();
  }

  /// 刷新当前页。
  Future<void> reload() async {
    try {
      await controller?.reload();
    } catch (_) {}
  }

  /// 获取当前实际 URL。
  Future<Uri?> currentUrl() async {
    try {
      final u = await controller?.getUrl();
      return u == null ? null : Uri.parse(u.toString());
    } catch (_) {
      return null;
    }
  }
}

/// 网页会话管理器：负责标签的打开、切换、销毁（全部保活）。
class WebSessionManager extends ChangeNotifier {
  WebSessionManager._();

  static final WebSessionManager instance = WebSessionManager._();

  final List<WebSession> _sessions = [];
  int _activeIndex = -1;
  int? _requestTab;

  List<WebSession> get sessions => List.unmodifiable(_sessions);
  int get activeIndex => _activeIndex;
  bool get isEmpty => _sessions.isEmpty;

  WebSession? get active =>
      (_activeIndex >= 0 && _activeIndex < _sessions.length)
          ? _sessions[_activeIndex]
          : null;

  /// 把所有已打开网页标签的滚轮倍率热更新为新值（改设置后立即生效；
  /// 终端另有独立倍率，互不影响）。
  Future<void> applyScrollMultiplier(int value) async {
    for (final s in _sessions) {
      await applyScrollMultiplierTo(s.controller, value);
    }
  }

  /// 请求主页切换到指定 tab（HomePage 监听并消费）。
  void requestTab(int index) {
    _requestTab = index;
    notifyListeners();
  }

  int? takeRequestTab() {
    final v = _requestTab;
    _requestTab = null;
    return v;
  }

  /// 新建标签并激活。
  WebSession open({required Uri url, String? title, String? tunnelId}) {
    final session = WebSession(
      url: url,
      title: title,
      tunnelId: tunnelId,
      onChanged: notifyListeners,
    );
    _sessions.add(session);
    _activeIndex = _sessions.length - 1;
    LogBus.instance.info('Web', '打开标签 $url'
        '${title != null ? '（$title）' : ''}');
    notifyListeners();
    persist();
    return session;
  }

  /// 切换到指定标签（不销毁任何页面）。
  void activate(int index) {
    if (index < 0 || index >= _sessions.length || index == _activeIndex) {
      return;
    }
    _activeIndex = index;
    notifyListeners();
  }

  /// 手动销毁标签。cookie 默认保留（重新打开仍是登录状态）；
  /// [clearAllCookies] 为 true 时同时清除全部站点 cookie。
  Future<void> close(int index, {bool clearAllCookies = false}) async {
    if (index < 0 || index >= _sessions.length) return;
    final s = _sessions.removeAt(index);
    if (_activeIndex >= _sessions.length) _activeIndex = _sessions.length - 1;
    LogBus.instance.info('Web', '销毁标签 ${s.url}');
    if (clearAllCookies) {
      await clearCookies();
    }
    notifyListeners();
    persist();
  }

  /// 关闭全部标签（页面全部销毁，cookie 保留）。
  Future<void> closeAll() async {
    if (_sessions.isEmpty) return;
    LogBus.instance.info('Web', '关闭全部标签（${_sessions.length} 个）');
    _sessions.clear();
    _activeIndex = -1;
    notifyListeners();
    persist();
  }

  /// 清除全部站点 Cookie（所有 WebView 共享存储）。
  Future<void> clearCookies() async {
    try {
      await CookieManager.instance().deleteAllCookies();
      LogBus.instance.info('Web', '已清除全部 Cookie');
    } catch (e) {
      LogBus.instance.error('Web', '清除 Cookie 失败: $e');
    }
  }

  // ---------------------------------------------------------------------
  // 会话持久化：退出 app 后还原上次打开的网页
  // ---------------------------------------------------------------------

  /// 将当前打开的标签列表写入加密存储（异步，不阻塞调用方）。
  void persist() {
    final data = <String, dynamic>{
      'activeIndex': _activeIndex,
      'sessions': [
        for (final s in _sessions)
          {
            'url': s.url.toString(),
            'title': s.title,
            'tunnelId': s.tunnelId,
          },
      ],
    };
    SecureStore.instance.saveWebSessions(data);
  }

  /// 应用启动时还原上次打开的标签（页面重新加载，Cookie 保留登录态）。
  Future<void> restore() async {
    final data = await SecureStore.instance.loadWebSessions();
    if (data == null) return;
    final sessions = data['sessions'];
    if (sessions is! List || sessions.isEmpty) return;
    for (final raw in sessions) {
      if (raw is! Map<String, dynamic>) continue;
      final url = Uri.tryParse((raw['url'] as String?) ?? '');
      if (url == null || url.host.isEmpty) continue;
      open(
        url: url,
        title: raw['title'] as String?,
        tunnelId: raw['tunnelId'] as String?,
      );
    }
    final activeIndex = (data['activeIndex'] as num?)?.toInt() ?? -1;
    if (activeIndex >= 0 && activeIndex < _sessions.length) {
      _activeIndex = activeIndex;
    }
    notifyListeners();
    LogBus.instance.info('Web', '已还原 ${_sessions.length} 个网页标签');
  }
}
