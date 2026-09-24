import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 日志级别。顺序即严重度（trace < debug < info < warn < error），
/// 过滤时用 `level.index >= minLevel.index` 判断。
enum LogLevel { trace, debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry(this.time, this.level, this.tag, this.message);

  String get levelName => switch (level) {
        LogLevel.trace => 'TRACE',
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };

  /// 单行格式化（毫秒精度，便于对齐跨语言调用的时序）
  String format() => '${formatTime(time)} [$levelName] $tag $message';

  static String two(int v) => v.toString().padLeft(2, '0');

  static String formatTime(DateTime t) =>
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}';
}

/// 全局环形日志总线，UI 直接监听。
///
/// 设计要点（2026-09-18 为排查 Dart↔JS 链路升级）：
/// - 增加 [LogLevel.trace]：高频诊断（每批写入、每次 JS 调用返回值）默认不记录，
///   打开 [verbose] 后才进环形缓冲，避免刷屏同时不丢信息。
/// - **合并刷新**：高频日志不再每条都 notifyListeners，避免日志页拖慢主线程。
/// - 环形缓冲放大到 4000 条，并保留"被丢弃的 trace 条数"提示。
/// - [exportText] / [environmentHeader]：一键导出可粘贴、可存档的完整上下文。
class LogBus extends ChangeNotifier {
  static final LogBus instance = LogBus._();

  final List<LogEntry> _entries = [];
  static const int maxEntries = 4000;

  /// 打开后记录 [LogLevel.trace] 级日志（诊断模式）
  bool verbose = false;

  /// 因 verbose 关闭而未记录的 trace 条数（提示"还有更细的日志"）
  int droppedTrace = 0;

  Timer? _notifyTimer;
  bool _dirty = false;

  LogBus._();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 出现过的标签（按首次出现顺序），供 UI 过滤
  List<String> get tags {
    final seen = <String>{};
    for (final e in _entries) {
      seen.add(e.tag);
    }
    return seen.toList();
  }

  void _add(LogLevel level, String tag, String message) {
    if (level == LogLevel.trace && !verbose) {
      droppedTrace++;
      return;
    }
    _entries.add(LogEntry(DateTime.now(), level, tag, message));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _notifySoon();
  }

  /// 合并刷新：120ms 内的多条日志只触发一次 UI 重建
  void _notifySoon() {
    _dirty = true;
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      if (!_dirty) return;
      _dirty = false;
      notifyListeners();
    });
  }

  void trace(String tag, String message) => _add(LogLevel.trace, tag, message);
  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);
  void info(String tag, String message) => _add(LogLevel.info, tag, message);
  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);
  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  /// 打开/关闭诊断模式（关闭时清零丢弃计数）
  void setVerbose(bool on) {
    verbose = on;
    if (!on) droppedTrace = 0;
    _add(LogLevel.info, 'Log', on ? '诊断模式已开启（记录 TRACE 级日志）' : '诊断模式已关闭');
  }

  /// 运行环境头部信息：贴日志给人排查时最需要的上下文
  String environmentHeader() {
    final b = StringBuffer();
    b.writeln('=== SSHive 诊断日志 ===');
    b.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    b.writeln('平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    b.writeln('Dart: ${Platform.version}');
    b.writeln('verbose: $verbose  丢弃的 trace: $droppedTrace  条目数: ${_entries.length}');
    if (Platform.isWindows) {
      final hosting = Platform.environment['SSHIVE_WEBVIEW_HOSTING'];
      b.writeln('WebView2 宿主模式: '
          '${hosting == 'default' ? '插件默认(Visual)' : 'Window-to-Visual(强制)'}'
          '${hosting == null ? '' : ' [SSHIVE_WEBVIEW_HOSTING=$hosting]'}');
    }
    b.writeln('--- 日志 ---');
    return b.toString();
  }

  /// 导出为可粘贴文本（可按级别/标签过滤）
  String exportText({
    LogLevel minLevel = LogLevel.trace,
    String? tag,
    bool withHeader = true,
  }) {
    final sb = StringBuffer();
    if (withHeader) sb.write(environmentHeader());
    for (final e in _entries) {
      if (e.level.index < minLevel.index) continue;
      if (tag != null && e.tag != tag) continue;
      sb.writeln(e.format());
    }
    return sb.toString();
  }

  void clear() {
    _entries.clear();
    droppedTrace = 0;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _dirty = false;
    notifyListeners();
  }
}
