import 'dart:io';

import 'log_bus.dart';

/// 终端输入调试日志：双通道（临时目录日志文件 + 应用内 LogBus）。
///
/// 用途：排查远程终端键盘/IME 输入链路（焦点 → TextInput 连接 →
/// 按键事件 → onInsert → onOutput → SSH 发送）。
/// 日志文件：Windows `%TEMP%\ssh_agent_term.log`；
/// Android `<应用缓存目录>/ssh_agent_term.log`。
class TermDebug {
  static File? _file;

  static File get _logFile {
    _file ??= File('${Directory.systemTemp.path}/ssh_agent_term.log');
    return _file!;
  }

  static void log(String tag, String msg) {
    final line = '[${DateTime.now().toIso8601String()}] [$tag] $msg';
    try {
      _logFile.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // 文件不可写时忽略（调试日志不应影响功能）
    }
    LogBus.instance.debug('TermDebug', line);
  }

  static void clear() {
    try {
      _logFile.writeAsStringSync('');
    } catch (_) {}
    LogBus.instance.debug('TermDebug', '--- 日志已清空 ---');
  }
}
