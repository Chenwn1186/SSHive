import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHSession;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show FocusNode;
import 'package:kterm/kterm.dart';

import 'app_state.dart';
import 'log_bus.dart';
import 'ssh_session.dart';
import 'term_debug.dart';

/// 一个终端会话：xterm 模拟器 + SSH PTY 通道。
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.serverId,
    String? title,
    this.startDir,
  }) : title = title ?? '终端 ${++_counter}';

  static int _counter = 0;

  final String serverId;

  /// 标题：默认"终端 N"，从目录打开时为目录名
  String title;

  /// 起始目录（与文件管理器联动，打开后自动 cd）
  final String? startDir;

  final DateTime createdAt = DateTime.now();

  late final Terminal terminal = Terminal(
    // 用户输入（键盘/IME/粘贴）→ SSH
    onOutput: (data) {
      TermDebug.log('onOutput', data.isEmpty
          ? '(empty)'
          : (data.length > 120 ? '${data.substring(0, 120)}…(${data.length})' : data));
      _send(data);
    },
    // 终端视图尺寸变化 → PTY resize
    onResize: (w, h, pw, ph) => _sshSession?.resizeTerminal(w, h, pw, ph),
  );

  late final TerminalController controller = TerminalController();

  /// 终端键盘焦点（物理键盘输入需要；点击/激活时请求焦点）
  late final FocusNode focusNode = _createFocusNode();

  FocusNode _createFocusNode() {
    final n = FocusNode();
    n.addListener(() {
      TermDebug.log('focus', 'hasFocus=${n.hasFocus} connected=$_connected');
    });
    return n;
  }

  SSHSession? _sshSession;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _connected = false;
  String? _error;

  bool get connected => _connected;
  String? get error => _error;

  void _send(String data) {
    TermDebug.log('send', data.isEmpty
        ? '(empty)'
        : (data.length > 80 ? '${data.substring(0, 80)}…(${data.length})' : data));
    final s = _sshSession;
    if (s != null && _connected) {
      s.write(Uint8List.fromList(utf8.encode(data)));
    } else {
      TermDebug.log('send', 'SKIPPED: session=${s != null} connected=$_connected');
    }
  }

  /// 发送控制序列（底部按键快捷栏用）。
  void sendSequence(String seq) => _send(seq);

  Future<void> connect(SshSession ssh) async {
    _error = null;
    try {
      final s = await ssh.shell(cols: 80, rows: 24);
      _sshSession = s;
      // 远端输出 → 终端。用增量 UTF-8 解码，防止多字节字符
      // 被 SSH 分包切断导致乱码
      _stdoutSub = s.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen(
            (text) => terminal.write(text),
            onError: (Object e) {
              _error = '$e';
              notifyListeners();
            },
          );
      _stderrSub = s.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen(
            (text) => terminal.write(text),
            onError: (Object e) {
              _error = '$e';
              notifyListeners();
            },
          );
      s.done.then((_) {
        _connected = false;
        LogBus.instance.info('Terminal', '$title: 连接已断开');
        notifyListeners();
      }).catchError((Object e) {
        _connected = false;
        _error = '$e';
        LogBus.instance.warn('Terminal', '$title: 连接异常: $e');
        notifyListeners();
      });

      _connected = true;
      notifyListeners();
      TermDebug.log('session', 'connected to ${ssh.server.name}');
      LogBus.instance.info('Terminal', '$title: 已连接 ${ssh.server.name}');

      // 与文件管理器联动：打开后进入指定目录
      if (startDir != null && startDir!.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        // 单引号包裹，路径内的单引号转义
        final dir = startDir!.replaceAll("'", r"'\''");
        s.write(Uint8List.fromList(utf8.encode("cd '$dir'\r")));
        LogBus.instance.info('Terminal', '$title: 已进入目录 $dir');
      }
    } catch (e) {
      _connected = false;
      _error = '$e';
      notifyListeners();
      TermDebug.log('session', 'connect FAILED: $e');
      LogBus.instance.error('Terminal', '$title: 连接失败: $e');
    }
  }

  Future<void> close() async {
    _connected = false;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    try {
      _sshSession?.close();
    } catch (_) {}
    _sshSession = null;
    notifyListeners();
  }

  /// 从系统剪贴板粘贴（走 bracketed paste 协议）。
  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    terminal.paste(text);
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    focusNode.dispose();
    super.dispose();
  }
}

/// 多终端会话管理器：多开、切换、销毁；SSH 断开时终端随之中断。
class TerminalManager extends ChangeNotifier {
  TerminalManager._();

  static final TerminalManager instance = TerminalManager._();

  final List<TerminalSession> _sessions = [];
  int _activeIndex = -1;
  int? _requestTab;

  List<TerminalSession> get sessions => List.unmodifiable(_sessions);
  int get activeIndex => _activeIndex;
  bool get isEmpty => _sessions.isEmpty;

  TerminalSession? get active =>
      (_activeIndex >= 0 && _activeIndex < _sessions.length)
          ? _sessions[_activeIndex]
          : null;

  /// 请求主页切换到"终端"Tab（文件管理器联动等）。
  void requestTab(int index) {
    _requestTab = index;
    notifyListeners();
  }

  int? takeRequestTab() {
    final v = _requestTab;
    _requestTab = null;
    return v;
  }

  /// 在指定服务器上打开新终端（[startDir] 可选：打开后自动 cd 到该目录）。
  /// 服务器未连接时返回 null。
  Future<TerminalSession?> open({
    required String serverId,
    String? startDir,
  }) async {
    final ssh = AppState.instance.sessionOf(serverId);
    if (ssh == null || !ssh.isConnected) {
      LogBus.instance.warn('Terminal', '服务器未连接，无法打开终端');
      return null;
    }
    final session = TerminalSession(serverId: serverId, startDir: startDir);
    _sessions.add(session);
    _activeIndex = _sessions.length - 1;
    notifyListeners();
    await session.connect(ssh);
    return session;
  }

  void activate(int index) {
    if (index < 0 || index >= _sessions.length || index == _activeIndex) {
      return;
    }
    _activeIndex = index;
    notifyListeners();
  }

  Future<void> close(int index) async {
    if (index < 0 || index >= _sessions.length) return;
    final s = _sessions.removeAt(index);
    LogBus.instance.info('Terminal', '关闭终端 ${s.title}');
    await s.close();
    if (_activeIndex >= _sessions.length) _activeIndex = _sessions.length - 1;
    s.dispose();
    notifyListeners();
  }

  Future<void> closeAll() async {
    LogBus.instance.info('Terminal', '关闭全部终端（${_sessions.length}）');
    for (final s in _sessions) {
      await s.close();
      s.dispose();
    }
    _sessions.clear();
    _activeIndex = -1;
    notifyListeners();
  }
}
