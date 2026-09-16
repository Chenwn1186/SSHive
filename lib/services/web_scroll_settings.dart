import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'log_bus.dart';
import 'secure_store.dart';

/// 网页滚动幅度设置（Windows WebView2）。
///
/// [multiplier] 即传给 `InAppWebViewSettings.scrollMultiplier` 的值，
/// 等于 WebView2 合成滚轮事件的 offset（WHEEL_DELTA=120 为一个标准滚轮格）。
/// 值越大每次滚动越多。可自由调节并持久化；标准值 120 可能偏激进，
/// 默认给 80（略小于标准格，手感更细）。
class WebScrollSettings extends ChangeNotifier {
  WebScrollSettings._();

  static final WebScrollSettings instance = WebScrollSettings._();

  static const int kMinMultiplier = 20;
  static const int kMaxMultiplier = 400;
  static const int kStandardMultiplier = 120;
  static const int kDefaultMultiplier = 80;

  int _multiplier = kDefaultMultiplier;
  int get multiplier => _multiplier;

  /// 启动时从持久化存储加载（范围外回退默认）。
  Future<void> load() async {
    try {
      final v = await SecureStore.instance.loadWebScrollMultiplier();
      if (v != null && v >= kMinMultiplier && v <= kMaxMultiplier) {
        _multiplier = v;
        notifyListeners();
      }
    } catch (e) {
      LogBus.instance.error('WebView', '加载滚动幅度设置失败: $e');
    }
  }

  /// 设置新的滚动幅度并持久化。
  ///
  /// Windows 上会通过插件级静态通道（third_party/flutter_inappwebview_windows
  /// 补丁）热更新所有已存在 WebView 的倍率——立即生效、不重建页面。
  Future<void> setMultiplier(int v) async {
    final clamped = v.clamp(kMinMultiplier, kMaxMultiplier);
    if (clamped == _multiplier) return;
    _multiplier = clamped;
    notifyListeners();
    await SecureStore.instance.saveWebScrollMultiplier(clamped);
    if (Platform.isWindows) {
      try {
        await const MethodChannel('com.chenwnx.sshagent/webview_scroll')
            .invokeMethod('setMultiplier', {'value': clamped});
        LogBus.instance.info('WebView', '滚动幅度已热更新为 $clamped');
      } catch (e) {
        LogBus.instance.error('WebView', '滚动幅度热更新失败: $e');
      }
    }
  }
}
