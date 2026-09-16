import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry(this.time, this.level, this.tag, this.message);

  String get levelName => switch (level) {
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warn => 'WARN',
        LogLevel.error => 'ERROR',
      };
}

/// 全局环形日志总线，UI 直接监听。
class LogBus extends ChangeNotifier {
  static final LogBus instance = LogBus._();

  final List<LogEntry> _entries = [];
  static const int _maxEntries = 800;

  LogBus._();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void _add(LogLevel level, String tag, String message) {
    _entries.add(LogEntry(DateTime.now(), level, tag, message));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);
  void info(String tag, String message) => _add(LogLevel.info, tag, message);
  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);
  void error(String tag, String message) => _add(LogLevel.error, tag, message);

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
