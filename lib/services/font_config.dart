/// 字体配置：中文字体优化 + 文本浏览器字体偏好。
///
/// 中文回退链直接复用 chinese_font_library 的 SystemChineseFont
/// （按平台自动包含 微软雅黑/PingFang SC/miui 等），保证终端、
/// 代码编辑器等非 TextStyle 场景的中文渲染与全局 UI 一致。
library;

import 'package:chinese_font_library/chinese_font_library.dart';

/// 中文字体回退链（来自 chinese_font_library，跨平台自动适配）。
final List<String> kCjkFallback = SystemChineseFont.fontFamilyFallback;

/// 文本浏览器（re_editor）的字体偏好。
enum ViewerFontPref {
  /// 跟随系统默认字体
  system('system'),

  /// 等宽字体（代码查看默认）
  mono('mono'),

  /// 无衬线字体
  sans('sans');

  const ViewerFontPref(this.key);
  final String key;

  static ViewerFontPref fromKey(String? key) => ViewerFontPref.values
      .firstWhere((p) => p.key == key, orElse: () => ViewerFontPref.mono);
}

/// 根据偏好返回字体系列配置（fontFamily + fontFamilyFallback）。
({String? fontFamily, List<String> fallback}) viewerFonts(
  ViewerFontPref pref,
) {
  switch (pref) {
    case ViewerFontPref.system:
      return (fontFamily: null, fallback: kCjkFallback);
    case ViewerFontPref.mono:
      return (fontFamily: 'monospace', fallback: kCjkFallback);
    case ViewerFontPref.sans:
      return (fontFamily: 'sans-serif', fallback: kCjkFallback);
  }
}
