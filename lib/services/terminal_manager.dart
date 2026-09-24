import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dartssh2/dartssh2.dart' show SSHSession;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_state.dart';
import 'log_bus.dart';
import 'ssh_session.dart';
import 'web_scroll_settings.dart';

/// 一个终端会话：xterm.js（WebView 承载）+ SSH PTY 通道。
///
/// 与旧的 kterm 实现相比的职责划分：
/// - **模拟器在 JS 里**：转义序列解析、回看缓冲、宽字符、IME 组合、粘贴协议
///   全部由 xterm.js 负责，Dart 只负责搬字节与转发事件。
/// - **Dart 只做三件事**：把远端字节喂给 JS、把 JS 的输入写回 SSH、
///   把 JS 报上来的真实 cols/rows 同步给 PTY。
///
/// 排查约定（2026-09-18 排查黑屏后固化）：
/// - JS 侧所有入口都返回 `ok...` / `err:<原因>`，Dart 侧**一定把返回值写进日志**；
///   返回 null/空即表示脚本没有执行。
/// - 推送数据要等 `sshiveLoaded`（文档 load 完成）——WebView2 在导航未完成时
///   执行脚本不可靠，实测会导致"调用返回了但脚本没生效"。
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.serverId,
    String? title,
    this.startDir,
  }) : title = title ?? '终端 ${++_counter}';

  static int _counter = 0;

  final String serverId;

  /// 标题：默认"终端 N"，从目录打开时为目录名；远端设置标题时更新
  String title;

  /// 起始目录（与文件管理器联动，打开后自动 cd）
  final String? startDir;

  final DateTime createdAt = DateTime.now();

  // ---------------------------------------------------------------------
  // WebView 侧
  // ---------------------------------------------------------------------

  InAppWebViewController? _web;
  bool get webAttached => _web != null;

  /// 页面（含 window.__sshive）是否已就绪。就绪前只排队不发送，
  /// 避免在命令尚未定义时调用 evaluateJavascript 造成静默丢字节。
  bool _pageReady = false;

  /// 文档 load 是否已完成：WebView2 在导航未完成时执行脚本不可靠
  /// （实测第一批写入的 await 拖到 400ms 后才返回、脚本却没生效），
  /// 因此推送数据要等 `sshiveLoaded`；超时兜底见 [_loadedFallback]。
  bool _pageLoaded = false;
  Timer? _loadedFallback;

  /// 待发送给 xterm.js 的字节（远端输出），批量 flush 以降低过桥次数
  final List<int> _pendingBytes = <int>[];
  Timer? _flushTimer;
  bool _flushing = false;

  /// 单次过桥的字节上限（base64 后约 43KB 字符串）
  static const int _maxChunkBytes = 32 * 1024;

  /// 攒到这个量就立刻 flush，否则等 [_flushInterval]
  static const int _flushThresholdBytes = 8 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 8);

  /// 背压：待发送积压超过上限就暂停 SSH 流，回落后续读
  static const int _pauseBacklogBytes = 512 * 1024;
  static const int _resumeBacklogBytes = 64 * 1024;
  bool _paused = false;

  /// 诊断计数：已过桥的批次 / 是否已经打过"等待页面就绪"的日志
  int _sentChunks = 0;
  bool _gateLogged = false;

  /// JS 侧确认计数（由 sshiveAck 上报）。"Dart 投递成功"≠"JS 收到"，
  /// 两边分开记，出问题能一眼看出断在哪一段。
  int _jsAckChunks = 0;
  int _jsAckBytes = 0;
  Timer? _ackWatchdog;

  String _lastSelection = '';

  // ---------------------------------------------------------------------
  // SSH 侧
  // ---------------------------------------------------------------------

  SSHSession? _sshSession;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _connected = false;
  String? _error;

  bool get connected => _connected;
  String? get error => _error;

  /// 终端真实尺寸（由 xterm.js 的 fit 插件按像素反推后回传）。
  /// 建 PTY 时优先用它，避免"远端 80×24、本地 120×40"的错位。
  int _cols = 80;
  int _rows = 24;
  int get cols => _cols;
  int get rows => _rows;

  // ---------------------------------------------------------------------
  // WebView 接入与桥
  // ---------------------------------------------------------------------

  /// 由 UI 在 onWebViewCreated 里调用：注册 JS→Dart 回调并接上输出通道。
  void attachWeb(InAppWebViewController controller) {
    _web = controller;

    controller.addJavaScriptHandler(
      handlerName: 'sshiveInput',
      callback: (List<dynamic> args) => _onWebInput(_str(args, 0)),
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveReady',
      callback: (List<dynamic> args) {
        _pageReady = true;
        LogBus.instance.debug('Terminal', '$title: xterm.js 页面就绪（readyState=loading）');
        // 兜底：即便 load 事件没来（或页面结构变化），2 秒后也放行，避免卡死
        _loadedFallback ??= Timer(const Duration(seconds: 2), () {
          if (_pageLoaded) return;
          _pageLoaded = true;
          LogBus.instance
              .warn('Terminal', '$title: 未收到 load 信号，超时后强制开始推送');
          unawaited(_drain());
        });
        _scheduleRetry();
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveLoaded',
      callback: (List<dynamic> args) {
        _loadedFallback?.cancel();
        _loadedFallback = null;
        _pageLoaded = true;
        LogBus.instance.debug('Terminal', '$title: 文档 load 完成，开始推送');
        unawaited(_drain());
        unawaited(_selfTest());
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveResize',
      callback: (List<dynamic> args) => _onWebResize(args),
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveTitle',
      callback: (List<dynamic> args) => _onWebTitle(_str(args, 0)),
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveBell',
      callback: (List<dynamic> args) {
        unawaited(SystemSound.play(SystemSoundType.alert).catchError((_) {}));
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveCopy',
      callback: (List<dynamic> args) => _onWebCopy(_str(args, 0)),
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveSelection',
      callback: (List<dynamic> args) {
        _lastSelection = _str(args, 0);
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveOpenUrl',
      callback: (List<dynamic> args) async {
        final url = _str(args, 0);
        if (url.isNotEmpty) {
          try {
            await launchUrl(Uri.parse(url),
                mode: LaunchMode.externalApplication);
          } catch (e) {
            LogBus.instance.warn('Terminal', '$title: 打开链接失败 $url: $e');
          }
        }
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveError',
      callback: (List<dynamic> args) {
        final msg = _str(args, 0);
        _error = msg;
        LogBus.instance.error('Terminal', '$title: $msg');
        notifyListeners();
        return null;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'sshiveLog',
      callback: (List<dynamic> args) {
        LogBus.instance.debug('Terminal', '$title: ${_str(args, 0)}');
        return null;
      },
    );
    // 页面自检快照（容器/视口尺寸、cols/rows、收到的字节数、渲染器）
    controller.addJavaScriptHandler(
      handlerName: 'sshiveDiag',
      callback: (List<dynamic> args) {
        LogBus.instance.info('Terminal', '$title: [diag] ${_str(args, 0)}');
        return null;
      },
    );

    // JS 侧的结构化确认：数据真的进了 xterm.js 才算通
    controller.addJavaScriptHandler(
      handlerName: 'sshiveAck',
      callback: (List<dynamic> args) {
        _jsAckChunks = args.isNotEmpty ? (int.tryParse('${args[0]}') ?? 0) : 0;
        final bytes = args.length > 1 ? int.tryParse('${args[1]}') ?? 0 : 0;
        _jsAckBytes = args.length > 2 ? int.tryParse('${args[2]}') ?? 0 : 0;
        if (_jsAckChunks <= 3) {
          LogBus.instance.info(
            'Terminal',
            '$title: JS 已确认第 $_jsAckChunks 批（本批 $bytes 字节，累计 $_jsAckBytes）',
          );
        } else {
          LogBus.instance.trace('Terminal',
              '$title: JS 已确认第 $_jsAckChunks 批（累计 $_jsAckBytes 字节）');
        }
        if (_ackWatchdog != null) {
          _ackWatchdog!.cancel();
          _ackWatchdog = null;
        }
        return null;
      },
    );

    // WebView 建好时可能已经收到过 banner，补发积压（会被 _pageLoaded 拦下）
    unawaited(_drain());
  }

  static String _str(List<dynamic> args, int i) =>
      (i < args.length && args[i] != null) ? '${args[i]}' : '';

  /// Dart→JS 投递通道（**按平台分流**）：
  /// - Windows：WebView2 原生 web message（`PostWebMessageAsJson`）。
  ///   不用 `evaluateJavascript`：实测从 Dart 发起的脚本执行看不到页面主世界的
  ///   全局对象，所有调用都会静默失效（终端黑屏的根因）。
  /// - 其他平台（Android/iOS/macOS）：`evaluateJavascript` 是正常可用的，
  ///   直接调用页面暴露的 `window.__sshive.applyEnvelope`。
  Future<bool> _postEnvelope(Map<String, dynamic> env, {String label = 'msg'}) async {
    final web = _web;
    if (web == null) return false;
    final data = jsonEncode(env);
    try {
      if (Platform.isWindows) {
        await web.postWebMessage(
          message: WebMessage(data: data, type: WebMessageType.STRING),
          targetOrigin: WebUri('*'),
        );
      } else {
        // 用 jsonEncode 把整段 JSON 作为合法的 JS 字符串字面量传入
        await web.evaluateJavascript(
          source: 'window.__sshive && window.__sshive.applyEnvelope(${jsonEncode(data)})',
        );
      }
      LogBus.instance.trace('Terminal', '$title: → JS[$label] ${_short(data)}');
      return true;
    } catch (e) {
      LogBus.instance.warn('Terminal', '$title: → JS[$label] 投递失败: $e');
      return false;
    }
  }

  /// 端到端探针：让 JS 自己把状态推回来（走已验证可用的 JS→Dart 方向）。
  Future<void> _selfTest() async {
    await _postEnvelope({'t': 'c', 'v': 'ping'}, label: 'ping');
  }

  void _onWebInput(String data) {
    if (data.isEmpty) return;
    _writeToRemote(data);
  }

  void _onWebResize(List<dynamic> args) {
    final c = args.isNotEmpty ? int.tryParse('${args[0]}') : null;
    final r = args.length > 1 ? int.tryParse('${args[1]}') : null;
    if (c == null || r == null || c <= 0 || r <= 0) return;
    if (c == _cols && r == _rows) return;
    _cols = c;
    _rows = r;
    final s = _sshSession;
    if (s != null && _connected) {
      try {
        s.resizeTerminal(c, r);
      } catch (e) {
        LogBus.instance.warn('Terminal', '$title: PTY 尺寸同步失败: $e');
      }
    }
  }

  void _onWebTitle(String t) {
    if (t.isEmpty || t == title) return;
    title = t;
    notifyListeners();
  }

  void _onWebCopy(String text) {
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    LogBus.instance.debug('Terminal', '$title: 已复制 ${text.length} 字符');
  }

  // ---------------------------------------------------------------------
  // 远端 → xterm.js
  // ---------------------------------------------------------------------

  /// 把原始字节交给 xterm.js（由它做流式 UTF-8 解码，坏字节不再丢整块）。
  void _enqueue(List<int> bytes) {
    if (bytes.isEmpty) return;
    _pendingBytes.addAll(bytes);
    if (_pendingBytes.length >= _pauseBacklogBytes) {
      _pauseStreams();
    }
    if (_pendingBytes.length >= _flushThresholdBytes) {
      unawaited(_drain());
      return;
    }
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_flushing) return;
    if (!_pageReady || !_pageLoaded || _web == null) {
      // 页面/文档还没就绪：保持排队，稍后重试
      if (_pendingBytes.isNotEmpty && !_gateLogged) {
        _gateLogged = true;
        LogBus.instance.debug(
          'Terminal',
          '$title: 等待页面就绪（ready=$_pageReady loaded=$_pageLoaded），'
          '暂存 ${_pendingBytes.length} 字节',
        );
      }
      _scheduleRetry();
      return;
    }
    _gateLogged = false;
    _flushing = true;
    try {
      while (_pendingBytes.isNotEmpty) {
        final take = _pendingBytes.length > _maxChunkBytes
            ? _maxChunkBytes
            : _pendingBytes.length;
        final chunk = _pendingBytes.sublist(0, take);
        _pendingBytes.removeRange(0, take);
        final b64 = base64Encode(chunk);
        _sentChunks++;
        final ok = await _postEnvelope({'t': 'd', 'v': b64}, label: 'data');
        if (!ok) {
          // 投递失败（页面已销毁等）：放回队首稍后重试，避免数据丢失
          _pendingBytes.insertAll(0, chunk);
          _sentChunks--;
          _scheduleRetry();
          return;
        }
        if (_sentChunks <= 3 || _sentChunks % 50 == 0) {
          LogBus.instance.info(
            'Terminal',
            '$title: 已投递 xterm ${chunk.length} 字节（第 $_sentChunks 批），等待 JS 确认',
          );
        } else {
          LogBus.instance.trace(
            'Terminal',
            '$title: 已投递 xterm ${chunk.length} 字节（第 $_sentChunks 批）',
          );
        }
        // 看门狗：投递了但 3 秒内 JS 一次都没确认 → 通道有问题，直接给出结论
        _ackWatchdog ??= Timer(const Duration(seconds: 3), () {
          if (_sentChunks > 0 && _jsAckChunks == 0) {
            LogBus.instance.warn(
              'Terminal',
              '$title: 已投递 $_sentChunks 批但 JS 一次未确认'
              '（web message 通道可能不通，检查 [diag] 里的 webMessage 字段）',
            );
          }
        });
      }
    } finally {
      _flushing = false;
      if (_pendingBytes.length <= _resumeBacklogBytes) {
        _resumeStreams();
      }
    }
  }

  /// 页面积压时的重试：只在有待发数据且没有已排定的 flush 时挂一个定时器。
  void _scheduleRetry() {
    if (_pendingBytes.isEmpty) return;
    _flushTimer ??= Timer(const Duration(milliseconds: 120), () {
      _flushTimer = null;
      unawaited(_drain());
    });
  }

  void _pauseStreams() {
    if (_paused) return;
    _paused = true;
    _stdoutSub?.pause();
    _stderrSub?.pause();
  }

  void _resumeStreams() {
    if (!_paused) return;
    _paused = false;
    _stdoutSub?.resume();
    _stderrSub?.resume();
  }

  // ---------------------------------------------------------------------
  // 本地 → 远端
  // ---------------------------------------------------------------------

  void _writeToRemote(String data) {
    final s = _sshSession;
    if (s == null || !_connected) return;
    try {
      s.write(Uint8List.fromList(utf8.encode(data)));
    } catch (e) {
      LogBus.instance.warn('Terminal', '$title: 写入远端失败: $e');
    }
  }

  /// 发送控制序列（底部按键快捷栏用）。
  void sendSequence(String seq) => _writeToRemote(seq);

  /// 请求 xterm.js 取得键盘焦点。
  ///
  /// 两件事都要做：页面里 `term.focus()` 只是 DOM 焦点，而键盘事件能不能到页面
  /// 取决于 WebView2 的输入窗口有没有 Win32 焦点——插件里唯一的入口是那句
  /// `callHandler('__focus')`（我们打的补丁，原生侧执行 MoveFocus）。
  void focusTerminal() {
    unawaited(_postEnvelope({'t': 'c', 'v': 'focus'}, label: 'focus'));
  }

  /// 主动放弃终端焦点（离开终端页面时调用），避免在别的页面继续吃键盘输入。
  void blurTerminal() {
    unawaited(_postEnvelope({'t': 'c', 'v': 'blur'}, label: 'blur'));
  }

  /// 热更新本终端的滚轮倍率（终端与网页的倍率各自独立，
  /// 见 [WebScrollSettings]；每视图通道由插件 fork 提供）。
  Future<void> applyScrollMultiplier(int value) =>
      applyScrollMultiplierTo(_web, value);

  /// 让 xterm.js 重新适配容器尺寸（布局变化后调用）。
  void refitTerminal() {
    unawaited(_postEnvelope({'t': 'c', 'v': 'fit'}, label: 'fit'));
  }

  /// 从系统剪贴板粘贴：交给 xterm.js 的 paste()，由它按当前
  /// bracketed paste 模式决定是否包 ESC[200~。
  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final b64 = base64Encode(utf8.encode(text));
    await _postEnvelope({'t': 'p', 'v': b64}, label: 'paste');
  }

  /// 复制 xterm.js 的当前选区到系统剪贴板（选区文本由 JS 在
  /// onSelectionChange 时推上来，避免再向 JS 索取——那个方向已证明不可靠）。
  Future<void> copySelection() async {
    final text = _lastSelection;
    if (text.isEmpty) {
      LogBus.instance.debug('Terminal', '$title: 当前没有选中内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    LogBus.instance.debug('Terminal', '$title: 已复制 ${text.length} 字符');
  }

  static String _short(String s) =>
      s.length > 120 ? '${s.substring(0, 120)}…(${s.length})' : s;

  // ---------------------------------------------------------------------
  // 连接生命周期
  // ---------------------------------------------------------------------

  Future<void> connect(SshSession ssh) async {
    _error = null;
    try {
      // 用 xterm.js 已经报上来的真实尺寸建 PTY（拿不到时退回 80×24）
      final s = await ssh.shell(cols: _cols, rows: _rows);
      _sshSession = s;
      _connected = true;

      // 远端输出 → xterm.js（原始字节，不做 Dart 侧解码）
      _stdoutSub = s.stdout.cast<List<int>>().listen(
        _enqueue,
        onError: (Object e) {
          _error = '$e';
          notifyListeners();
        },
      );
      _stderrSub = s.stderr.cast<List<int>>().listen(
        _enqueue,
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

      notifyListeners();
      LogBus.instance.info(
        'Terminal',
        '$title: 已连接 ${ssh.server.name}（${_cols}x$_rows）',
      );

      // 防御：shell() 期间 WebView 可能已上报了更新的尺寸，再同步一次
      try {
        s.resizeTerminal(_cols, _rows);
      } catch (_) {}

      // 与文件管理器联动：打开后进入指定目录
      if (startDir != null && startDir!.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final dir = startDir!.replaceAll("'", r"'\''");
        _writeToRemote("cd '$dir'\r");
        LogBus.instance.info('Terminal', '$title: 已进入目录 $dir');
      }
    } catch (e) {
      _connected = false;
      _error = '$e';
      notifyListeners();
      LogBus.instance.error('Terminal', '$title: 连接失败: $e');
    }
  }

  Future<void> close() async {
    _connected = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    _loadedFallback?.cancel();
    _loadedFallback = null;
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

  @override
  void dispose() {
    _flushTimer?.cancel();
    _loadedFallback?.cancel();
    _ackWatchdog?.cancel();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _pendingBytes.clear();
    _web = null;
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

  /// 把所有已打开终端的滚轮倍率热更新为新值（改设置后立即生效）。
  Future<void> applyScrollMultiplier(int value) async {
    for (final s in _sessions) {
      await s.applyScrollMultiplier(value);
    }
  }
}
