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
  /// 夹住系统 Insets。
  ///
  /// 两道限制同时生效（取更小者）：
  /// 1. **绝对上限**（逻辑像素/≈dp）：top 48 / bottom 96 / left·right 48。
  ///    正常全屏下状态栏、手势条、刘海都在这个量级以内；
  /// 2. **比例上限**：[ratio] × 对应边长（默认 35%），防止窗口极小时被压成 0。
  ///
  /// 为什么需要绝对上限：小窗里 OEM 会把**全屏**的状态栏/小窗把手也算进 padding，
  /// 而 `AppBar` 会把 `padding.top` 垫在工具栏之上 —— 只按比例夹（35%）在矮窗口里
  /// 仍可能留下两三百像素的"垫高"，表现为"上半黑、下半才是页面"。
  static MediaQueryData clampInsets(
    MediaQueryData mq, {
    double ratio = 0.35,
    double maxTop = 48,
    double maxBottom = 96,
    double maxSide = 48,
  }) {
    EdgeInsets clamp(EdgeInsets e) => EdgeInsets.only(
          left: math.min(e.left, math.min(maxSide, mq.size.width * ratio)),
          right: math.min(e.right, math.min(maxSide, mq.size.width * ratio)),
          bottom: math.min(
              e.bottom, math.min(maxBottom, mq.size.height * ratio)),
          top: math.min(e.top, math.min(maxTop, mq.size.height * ratio)),
        );
    final padding = clamp(mq.padding);
    final viewPadding = clamp(mq.viewPadding);
    // 只在真的夹掉东西时记一条（这就是"上半黑"的直接证据）
    if (padding != mq.padding || viewPadding != mq.viewPadding) {
      LogBus.instance.info(
        'Window',
        'Insets 被夹取：padding ${_insets(mq.padding)} → ${_insets(padding)}；'
        'viewPadding ${_insets(mq.viewPadding)} → ${_insets(viewPadding)}',
      );
    }
    return mq.copyWith(padding: padding, viewPadding: viewPadding);
  }
}
