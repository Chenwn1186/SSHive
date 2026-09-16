part of re_editor;

const double _kScrollbarThickness = 8.0;

/// ssh_agent patch: 全局滚轮滚动倍率。
///
/// 文本/代码查看器（CodeEditor）的滚轮幅度默认由内部硬编码的
/// ClampingScrollPhysics 决定（不可配置）。此处暴露全局倍率，
/// 通过 [applyPhysicsToUserOffset] 生效——该方法只作用于"用户输入
/// 滚动偏移"（滚轮/触控板），不影响代码逻辑与程序化滚动。
class CodeWheelScale {
  static double factor = 1.0;
}

class _CodeScrollable extends StatelessWidget {

  final AxisDirection axisDirection;
  final ScrollController? controller;
  final ViewportBuilder viewportBuilder;
  final CodeScrollbarBuilder? scrollbarBuilder;

  const _CodeScrollable({
    required this.axisDirection,
    this.controller,
    required this.viewportBuilder,
    this.scrollbarBuilder
  });

  @override
  Widget build(BuildContext context) {
    return Scrollable(
      excludeFromSemantics: true,
      controller: controller,
      scrollBehavior: _ScrollBehavior(scrollbarBuilder),
      viewportBuilder: viewportBuilder,
      axisDirection: axisDirection,
      // ssh_agent patch: 使用自定义 physics（支持滚轮倍率），
      // 原实现硬编码 const ClampingScrollPhysics()
      physics: _ScrollPhysics(),
    );
  }

}

class _ScrollBehavior extends MaterialScrollBehavior {

  final _ScrollPhysics physics;
  final CodeScrollbarBuilder? scrollbarBuilder;

  _ScrollBehavior(this.scrollbarBuilder) : physics = _ScrollPhysics();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    final Widget? scrollbar = scrollbarBuilder?.call(context, child, details);
    if (scrollbar != null) {
      return scrollbar;
    }
    final ScrollbarOrientation? orientation;
    if (details.direction == AxisDirection.down) {
      orientation = ScrollbarOrientation.right;
    } else if (details.direction == AxisDirection.right) {
      orientation = ScrollbarOrientation.bottom;
    } else {
      orientation = null;
    }
    if (kIsAndroid || kIsIOS) {
      return Scrollbar(
        controller: details.controller,
        scrollbarOrientation: orientation,
        thumbVisibility: details.direction == AxisDirection.down,
        child: child,
      );
    }
    return _RawScrollbar(
      physics: physics,
      controller: details.controller ?? ScrollController(),
      scrollbarOrientation: orientation,
      thumbVisibility: details.direction == AxisDirection.down,
      child: child,
    );
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return physics;
  }

}

class _RawScrollbar extends RawScrollbar {

  final _ScrollPhysics physics;

  const _RawScrollbar({
    required this.physics,
    required Widget child,
    required ScrollController controller,
    ScrollbarOrientation? scrollbarOrientation,
    required bool thumbVisibility,
  }) : super(
    controller: controller,
    scrollbarOrientation: scrollbarOrientation,
    thumbVisibility: thumbVisibility,
    thickness: _kScrollbarThickness,
    radius: const Radius.circular(10),
    crossAxisMargin: 2,
    child: child,
  );

  @override
  RawScrollbarState<_RawScrollbar> createState() => _RawScrollbarState();

}

class _RawScrollbarState extends RawScrollbarState<_RawScrollbar> {

  Offset? downPosition;
  double? downOffset;

  @override
  void handleThumbPressStart(ui.Offset localPosition) {
    downPosition = localPosition;
    downOffset = widget.controller!.offset;
    super.handleThumbPressStart(localPosition);
  }

  @override
  void handleThumbPressUpdate(Offset localPosition) {
    if (getScrollbarDirection() == Axis.vertical) {
      widget.physics.setScrollPosition(downOffset! + scrollbarPainter.getTrackToScroll(localPosition.dy - downPosition!.dy));
    }
    super.handleThumbPressUpdate(localPosition);
  }

}

// ignore: must_be_immutable
class _ScrollPhysics extends ScrollPhysics {

  double? _position;

  void setScrollPosition(double position) {
    _position = position;
  }

  // ssh_agent patch: 滚轮/触控板滚动幅度倍率
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final m = CodeWheelScale.factor;
    if (m != 1.0) return offset * m;
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (_position == null) {
      return super.applyBoundaryConditions(position, value);
    }
    return value - _position!;
  }

}