import 'package:flutter/foundation.dart';

/// 文件浏览器 Tab 的跨页面通信。
///
/// 服务器卡片上的"文件"按钮 → 请求主页切换到"文件"Tab 并选中该服务器；
/// 文件页内部切换选中服务器时也通过本控制器广播（供主页隐藏/显示 FAB 等）。
class FileBrowserController extends ChangeNotifier {
  FileBrowserController._();

  static final FileBrowserController instance = FileBrowserController._();

  /// 当前选中的服务器（由文件页维护）。
  String? _serverId;

  String? get serverId => _serverId;

  int? _pendingTab;
  String? _pendingServerId;

  /// 主页消费"请切到文件 Tab"请求。
  int? takeRequestTab() {
    final v = _pendingTab;
    _pendingTab = null;
    return v;
  }

  /// 文件页消费"请选中该服务器"请求。
  String? takePendingServerId() {
    final v = _pendingServerId;
    _pendingServerId = null;
    return v;
  }

  /// 文件页内部切换选中服务器（保持已打开的文件标签，标签按服务器归属）。
  void selectServer(String? id) {
    if (_serverId == id) return;
    _serverId = id;
    notifyListeners();
  }

  /// 外部请求：打开文件页并选中该服务器。
  void requestOpen(String serverId) {
    _pendingServerId = serverId;
    _pendingTab = 4; // "文件" Tab 在主页 TabBar 中的索引
    notifyListeners();
  }
}
