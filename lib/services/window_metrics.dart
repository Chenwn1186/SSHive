import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'log_bus.dart';

/// 窗口尺寸 / 系统 Insets 诊断（Android 小窗、分屏、多窗口、桌面窗口缩放）。
///
/// 背景：小米平板上把应用开成"小窗"时出现过"页面组件消失、只剩右下角 FAB"的现象。
/// 这类现象通常不是白屏，而是**窗口/Insets 极端值把布局压成 0 尺寸**：
/// Scaffold 高度趋近 0 时 AppBar 与 body 都会被压没，而未裁剪的 FAB 仍会绘制。
///
/// 这里做两件事：
/// 1. [logIfChanged]：窗口关键数值变化时写一条日志（去抖，只记变化）；
/// 2. [logDegenerate]：body 高度/宽度过小时写 WARN，并把完整数值带上。
class WindowMetrics {
  WindowMetrics._();

  /// 上次记录的指纹（避免每帧刷屏）
  static String? _lastSignature;

  /// body 小于这个高度就认为布局被压扁（AppBar 48 + 一点余量）
  static const double degenerateHeight = 80;

  static String _insets(EdgeInsets e) =>
      '(${e.left.toStringAsFixed(1)},${e.top.toStringAsFixed(1)},'
      '${e.right.toStringAsFixed(1)},${e.bottom.toStringAsFixed(1)})';

  /// 一行描述当前窗口状态
  static String describe(MediaQueryData mq) => 'size=${mq.size.width.toStringAsFixed(1)}x'
      '${mq.size.height.toStringAsFixed(1)} '
      'dpr=${mq.devicePixelRatio.toStringAsFixed(2)} '
      'padding=${_insets(mq.padding)} '
      'viewPadding=${_insets(mq.viewPadding)} '
      'viewInsets=${_insets(mq.viewInsets)} '
      'textScaler=${mq.textScaler.scale(10) / 10} '
      'orientation=${mq.orientation.name}';

  /// 窗口关键值变化时才记录（内存级去抖；同值重复调用不会写日志）
  static void logIfChanged(MediaQueryData mq, {String source = 'window'}) {
    final sig = '${mq.size}|${mq.padding}|${mq.viewPadding}|${mq.viewInsets}'
        '|${mq.devicePixelRatio}|${mq.orientation}';
    if (sig == _lastSignature) return;
    final first = _lastSignature == null;
    _lastSignature = sig;
    final line = '$source ${describe(mq)}';
    if (first) {
      LogBus.instance.info('Window', line);
    } else {
      LogBus.instance.info('Window', '变化 → $line');
    }
  }

  /// body 约束过小 → 明确报警（这就是"组件消失"的机械原因）
  static void logDegenerate({
    required BoxConstraints constraints,
    required MediaQueryData mq,
    String source = 'body',
  }) {
    final h = constraints.maxHeight;
    final w = constraints.maxWidth;
    if (h.isFinite && h >= degenerateHeight && w >= 120) return;
    final sig = 'degen|$h|$w|${mq.padding}';
    if (sig == _lastSignature) return;
    _lastSignature = sig;
    LogBus.instance.warn(
      'Window',
      '$source 可用空间过小：maxWidth=${w.toStringAsFixed(1)} '
      'maxHeight=${h.toStringAsFixed(1)}（阈值 ${degenerateHeight.toInt()}）'
      '；${describe(mq)}',
    );
  }

  /// 夹住系统 Insets：小窗/多窗口下 OEM 可能上报远超窗口的 padding，
  /// 直接交给 SafeArea 会把内容压成 0。这里限制到对应边长的 35%。
  static MediaQueryData clampInsets(MediaQueryData mq, {double ratio = 0.35}) {
    EdgeInsets clamp(EdgeInsets e) => EdgeInsets.only(
          left: math.min(e.left, mq.size.width * ratio),
          right: math.min(e.right, mq.size.width * ratio),
          bottom: math.min(e.bottom, mq.size.height * ratio),
          top: math.min(e.top, mq.size.height * ratio),
        );
    return mq.copyWith(
      padding: clamp(mq.padding),
      viewPadding: clamp(mq.viewPadding),
    );
  }
}
