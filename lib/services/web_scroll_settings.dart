import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'log_bus.dart';
import 'secure_store.dart';

/// 滚轮倍率设置（Windows WebView2）——**网页与终端各自独立**。
///
/// 语义：`1` = 标准（一个滚轮格滚一格的量），范围 1~4；0/负数视为 1。
///
/// 为什么要分开：同一个宿主事件在两个消费方那里含义不同——
/// - 网页（Chromium）：把格数换算成像素并做平滑滚动，观感接近原生浏览器；
/// - 终端（xterm.js）：换算成「行」累积进回看缓冲，同样格数看起来更快。
/// 所以两者各留一个倍率，互不干扰。
///
/// 历史量纲迁移：早期版本取值区间是 20~400（量纲错误时代的"直接乘像素"），
/// 持久化值 ≥ [_legacyScaleMin] 一律判为旧值并回退默认。
class WebScrollSettings extends ChangeNotifier {
  WebScrollSettings._();

  static final WebScrollSettings instance = WebScrollSettings._();

  /// 倍率范围：1 = 标准，最大 4 倍
  static const int kMinMultiplier = 1;
  static const int kMaxMultiplier = 4;

  /// 网页默认 1（= 原生浏览器手感）
  static const int kDefaultWebMultiplier = 1;

  /// 终端默认 2：实测 1 偏慢，2 接近常见终端"一格几行"的手感
  static const int kDefaultTerminalMultiplier = 2;

  /// 旧量纲（20~400）的下界
  static const int _legacyScaleMin = 8;

  int _webMultiplier = kDefaultWebMultiplier;
  int _terminalMultiplier = kDefaultTerminalMultiplier;

  /// 网页（含 Markdown 预览）滚轮倍率
  int get webMultiplier => _webMultiplier;

  /// 终端回看缓冲的滚轮倍率
  int get terminalMultiplier => _terminalMultiplier;

  /// 兼容旧调用点：等同 [webMultiplier]
  int get multiplier => _webMultiplier;

  Future<void> load() async {
    _webMultiplier = await _loadOne(
      await SecureStore.instance.loadWebScrollMultiplier(),
      kDefaultWebMultiplier,
      terminal: false,
    );
    _terminalMultiplier = await _loadOne(
      await SecureStore.instance.loadTerminalScrollMultiplier(),
      kDefaultTerminalMultiplier,
      terminal: true,
    );
    notifyListeners();
  }

  Future<int> _loadOne(
    int? v,
    int fallback, {
    required bool terminal,
  }) async {
    if (v == null) return fallback;
    if (v >= kMinMultiplier && v <= kMaxMultiplier) return v;
    final label = terminal ? '终端' : '网页';
    if (v >= _legacyScaleMin) {
      LogBus.instance
          .info('WebView', '$label 滚轮倍率迁移：旧值 $v（旧量纲）→ $fallback');
    } else {
      LogBus.instance.info('WebView', '$label 滚轮倍率越界($v) → $fallback');
    }
    if (terminal) {
      await SecureStore.instance.saveTerminalScrollMultiplier(fallback);
    } else {
      await SecureStore.instance.saveWebScrollMultiplier(fallback);
    }
    return fallback;
  }

  /// 设置网页倍率（持久化；对已打开的网页视图逐一生效）
  Future<void> setWebMultiplier(int v) async {
    final clamped = v.clamp(kMinMultiplier, kMaxMultiplier);
    if (clamped == _webMultiplier) return;
    _webMultiplier = clamped;
    notifyListeners();
    await SecureStore.instance.saveWebScrollMultiplier(clamped);
    LogBus.instance.info('WebView', '网页滚轮倍率 → $clamped');
  }

  /// 设置终端倍率（持久化；对已打开的终端视图逐一生效）
  Future<void> setTerminalMultiplier(int v) async {
    final clamped = v.clamp(kMinMultiplier, kMaxMultiplier);
    if (clamped == _terminalMultiplier) return;
    _terminalMultiplier = clamped;
    notifyListeners();
    await SecureStore.instance.saveTerminalScrollMultiplier(clamped);
    LogBus.instance.info('WebView', '终端滚轮倍率 → $clamped');
  }

  /// 兼容旧调用点
  Future<void> setMultiplier(int v) => setWebMultiplier(v);
}

/// 把倍率热更新到**单个** WebView（每视图通道，见插件 fork 新增的
/// `WindowsInAppWebViewController.setScrollMultiplier`）。
///
/// 用 dynamic 调用是为了不让 app 直接依赖平台实现包（传递依赖直接 import 会触发
/// depend_on_referenced_packages）。失败只记日志、不影响功能——下次创建视图时
/// 仍会带上正确的倍率。
Future<void> applyScrollMultiplierTo(
  InAppWebViewController? controller,
  int value,
) async {
  if (controller == null || !Platform.isWindows) return;
  try {
    await (controller.platform as dynamic).setScrollMultiplier(value);
  } catch (e) {
    LogBus.instance.debug('WebView', '每视图滚轮倍率热更新失败: $e');
  }
}
