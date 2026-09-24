/// xterm.js 终端宿主页：把离线 xterm.js 资产拼成一个自包含 HTML，
/// 并提供 JS ↔ Dart 双向桥。
///
/// 设计要点（与旧的 kterm 方案相比）：
/// - **字节流直通**：SSH 的原始字节经 base64 送到 JS，由 xterm.js 自己的
///   流式 UTF-8 解码器处理。这修掉了旧实现 `utf8.decoder`（严格模式）
///   遇到坏字节会丢掉整块输出的问题，中文/GBK 混排也不会整段消失。
/// - **能力来自 xterm.js 6.0.0**：DEC mode 2026（同步输出，TUI 不撕裂）、
///   DECSCUSR、IRM、宽字符 unicode11、reflow、OSC 8 超链接等。
/// - **PTY 尺寸由真实像素反推**：xterm.js 的 fit 插件按容器尺寸算出
///   cols/rows，通过 sshiveResize 回传，彻底避免"远端 80×24、本地 120×40"。
/// - **粘贴走 xterm.js 的 paste()**：bracketed paste 模式的状态在 JS 侧，
///   由它决定是否包 `ESC[200~`，比在 Dart 侧猜要准确。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 终端外观与行为配置（Dart → JS）。
class XtermPageConfig {
  const XtermPageConfig({
    required this.theme,
    this.fontSize = 13,
    this.lineHeight = 1.2,
    this.scrollback = 10000,
    this.cursorBlink = true,
    this.scrollSensitivity = 1,
    this.padding = 8,
    // WebGL 渲染器默认关闭：先保证"一定能看到内容"（DOM 渲染器最稳）。
    // WebView2 走离屏捕获 + 自定义合成时，GPU 路径出问题会表现为整块黑屏，
    // 排查期默认关掉；确认链路正常后可在调用处传 webgl: true 再评估性能。
    this.webgl = false,
  });

  final Map<String, dynamic> theme;
  final double fontSize;
  final double lineHeight;
  final int scrollback;
  final bool cursorBlink;
  final double scrollSensitivity;
  final double padding;
  final bool webgl;

  /// 等宽字体 + 中文回退：Windows 上 `monospace` 不是真实字族，
  /// 必须显式给 Consolas/Cascadia 这类等宽字体，中文再回退到雅黑。
  static const String fontFamily =
      'Consolas, "Cascadia Mono", "Cascadia Code", "Courier New", '
      '"Microsoft YaHei Mono", "Microsoft YaHei", monospace';

  Map<String, dynamic> toJson() => {
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'scrollback': scrollback,
        'cursorBlink': cursorBlink,
        'scrollSensitivity': scrollSensitivity,
        'webgl': webgl,
        'theme': theme,
      };
}

/// 由 Flutter 主题推导 xterm.js 配色（背景/前景/光标/选区 + 16 色 ANSI）。
Map<String, dynamic> xtermThemeFrom(ThemeData theme, Brightness brightness) {
  String hex(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  final scheme = theme.colorScheme;
  final dark = brightness == Brightness.dark;

  // ANSI 调色板沿用仓库 Markdown 查看器同源的 GitHub 配色，保证与全局观感一致
  final ansi = dark
      ? const {
          'black': '#484f58',
          'red': '#ff7b72',
          'green': '#3fb950',
          'yellow': '#d29922',
          'blue': '#58a6ff',
          'magenta': '#bc8cff',
          'cyan': '#39c5cf',
          'white': '#b1bac4',
          'brightBlack': '#6e7681',
          'brightRed': '#ffa198',
          'brightGreen': '#56d364',
          'brightYellow': '#e3b341',
          'brightBlue': '#79c0ff',
          'brightMagenta': '#d2a8ff',
          'brightCyan': '#56d4dd',
          'brightWhite': '#f0f6fc',
        }
      : const {
          'black': '#24292f',
          'red': '#cf222e',
          'green': '#116329',
          'yellow': '#4d2d00',
          'blue': '#0969da',
          'magenta': '#8250df',
          'cyan': '#1b7c83',
          'white': '#6e7781',
          'brightBlack': '#57606a',
          'brightRed': '#a40e26',
          'brightGreen': '#1a7f37',
          'brightYellow': '#633c01',
          'brightBlue': '#218bff',
          'brightMagenta': '#a475f9',
          'brightCyan': '#3192aa',
          'brightWhite': '#8c959f',
        };

  return {
    'background': hex(scheme.surface),
    'foreground': hex(scheme.onSurface),
    'cursor': hex(scheme.primary),
    'cursorAccent': hex(scheme.surface),
    'selectionBackground': hex(scheme.primary.withValues(alpha: 0.30)),
    ...ansi,
  };
}

/// 宿主页构建与资产缓存。
class XtermPage {
  XtermPage._();

  static const String _assetDir = 'assets/xterm';

  static String? _coreJs;
  static String? _css;
  static String? _fitJs;
  static String? _webglJs;
  static String? _unicode11Js;
  static String? _webLinksJs;
  static Future<void>? _loading;

  /// 只读一次资产（约 790KB），多终端共享。
  static Future<void> ensureLoaded() {
    return _loading ??= () async {
      Future<String> load(String name) =>
          rootBundle.loadString('$_assetDir/$name');
      _css = await load('xterm.css');
      _coreJs = await load('xterm.js');
      _fitJs = await load('addon-fit.js');
      _webglJs = await load('addon-webgl.js');
      _unicode11Js = await load('addon-unicode11.js');
      _webLinksJs = await load('addon-web-links.js');
    }();
  }

  /// 生成自包含的终端页面。
  static Future<String> buildHtml(XtermPageConfig config) async {
    await ensureLoaded();
    final cfgJson = jsonEncode(config.toJson())
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026')
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
    final background = config.theme['background'] as String? ?? '#000000';
    return _template
        .replaceFirst('__CSS__', _css!)
        .replaceFirst('__JS__', _coreJs!)
        .replaceFirst('__FIT__', _fitJs!)
        .replaceFirst('__WEBGL__', _webglJs!)
        .replaceFirst('__UNICODE11__', _unicode11Js!)
        .replaceFirst('__WEBLINKS__', _webLinksJs!)
        .replaceFirst('__BG__', background)
        // __PAD__ 在 CSS 里出现多次，必须用 replaceAll
        .replaceAll('__PAD__', config.padding.toStringAsFixed(1))
        .replaceFirst('__CFG__', cfgJson);
  }

  /// 供 Dart 调用的 JS 入口名（与模板里的 window.__sshive 对应）。
  static const String jsRoot = 'window.__sshive';

  /// 模板为 raw 字符串：$ 与反斜杠都按字面处理，JS 里不要用模板字符串。
  static const String _template = r'''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>terminal</title>
<style>__CSS__</style>
<style>
  html, body { margin:0; padding:0; height:100%; overflow:hidden; background:__BG__; }
  #t { position:absolute; inset:0; padding:__PAD__px 6px 6px __PAD__px; box-sizing:border-box; }
  .xterm-viewport { background:transparent !important; }
  .xterm-viewport::-webkit-scrollbar { width:9px; }
  .xterm-viewport::-webkit-scrollbar-track { background:transparent; }
  .xterm-viewport::-webkit-scrollbar-thumb { background:rgba(140,140,140,.45); border-radius:5px; }
  .xterm-viewport::-webkit-scrollbar-thumb:hover { background:rgba(160,160,160,.65); }
</style>
</head>
<body>
<div id="t"></div>
<script>__JS__</script>
<script>__FIT__</script>
<script>__WEBGL__</script>
<script>__UNICODE11__</script>
<script>__WEBLINKS__</script>
<script>
(function () {
  'use strict';
  var CFG = __CFG__;

  // ---- 桥：优先直投 Flutter；桥还没注入时排队重试 ----
  // 注意：callHandler(name, a, b, ...) 在 Dart 侧收到的 args 是 [a, b, ...]，
  // 所以这里用可变参数展开，而不是把数组当作单个参数传。
  var queue = [];
  function callBridge(name, args) {
    var api = window.flutter_inappwebview;
    if (api && typeof api.callHandler === 'function') {
      try { api.callHandler.apply(api, [name].concat(args)); return true; }
      catch (e) { return false; }
    }
    return false;
  }
  function send() {
    var name = arguments[0];
    var args = Array.prototype.slice.call(arguments, 1);
    if (!callBridge(name, args)) { queue.push([name, args]); }
  }
  function flushQueue() {
    if (!queue.length) { return; }
    var rest = [];
    for (var i = 0; i < queue.length; i++) {
      if (!callBridge(queue[i][0], queue[i][1])) { rest.push(queue[i]); }
    }
    queue = rest;
    if (queue.length) { setTimeout(flushQueue, 120); }
  }

  // 任何未捕获的 JS 错误都上报，避免"黑屏但无日志"
  window.addEventListener('error', function (e) {
    send('sshiveError', 'JS 错误: ' + (e && e.message ? e.message : e));
  });
  window.addEventListener('unhandledrejection', function (e) {
    send('sshiveError', 'Promise 拒绝: ' + (e && e.reason ? e.reason : e));
  });

  // ---- 字节/文本编解码（Dart 侧统一用 base64 过桥）----
  function b64ToBytes(b64) {
    var bin = atob(b64), n = bin.length, out = new Uint8Array(n);
    for (var i = 0; i < n; i++) { out[i] = bin.charCodeAt(i); }
    return out;
  }
  function b64ToText(b64) {
    try { return new TextDecoder('utf-8').decode(b64ToBytes(b64)); }
    catch (e) { return atob(b64); }
  }

  function ctor(ns, name) {
    if (!window[ns]) { return null; }
    var m = window[ns];
    return (typeof m === 'function') ? m : (m && m[name]);
  }

  var term = null, fit = null, container = null;

  try {
    term = new Terminal({
      allowProposedApi: true,
      convertEol: false,
      cursorBlink: !!CFG.cursorBlink,
      cursorStyle: 'block',
      fontFamily: CFG.fontFamily,
      fontSize: CFG.fontSize,
      lineHeight: CFG.lineHeight,
      letterSpacing: 0,
      scrollback: CFG.scrollback,
      scrollSensitivity: CFG.scrollSensitivity,
      smoothScrollDuration: 0,
      theme: CFG.theme,
      macOptionIsMeta: false,
      rightClickSelectsWord: false,
      logLevel: 'off'
    });

    var Fit = ctor('FitAddon', 'FitAddon');
    if (Fit) { fit = new Fit(); term.loadAddon(fit); }

    var U11 = ctor('Unicode11Addon', 'Unicode11Addon');
    if (U11) {
      try {
        term.loadAddon(new U11());
        term.unicode.activeVersion = '11';
      } catch (e) { /* 退化到默认宽度表 */ }
    }

    var Links = ctor('WebLinksAddon', 'WebLinksAddon');
    if (Links) {
      try {
        term.loadAddon(new Links(function (ev, uri) {
          send('sshiveOpenUrl', uri);
        }));
      } catch (e) { /* 无超链接支持时忽略 */ }
    }

    if (CFG.webgl) {
      try {
        var GLR = ctor('WebglAddon', 'WebglAddon');
        if (GLR) {
          var gl = new GLR();
          if (gl.onContextLoss) {
            gl.onContextLoss(function () { try { gl.dispose(); } catch (e) {} });
          }
          term.loadAddon(gl);
        }
      } catch (e) { /* WebGL 不可用时退回 DOM 渲染器 */ }
    }

    container = document.getElementById('t');
    term.open(container);
    if (fit) { try { fit.fit(); } catch (e) {} }
  } catch (err) {
    send('sshiveError', 'xterm 初始化失败: ' + (err && err.message ? err.message : err));
  }

  if (term) {
    term.onData(function (data) { send('sshiveInput', data); });
    term.onTitleChange(function (title) {
      document.title = title || 'terminal';
      send('sshiveTitle', title || '');
    });
    term.onBell(function () { send('sshiveBell', ''); });
    term.onResize(function (size) {
      send('sshiveResize', size.cols, size.rows);
      send('sshiveDiag', 'resize -> ' + size.cols + 'x' + size.rows);
    });
    term.onSelectionChange(function () {
      var sel = term.getSelection();
      if (sel) { send('sshiveSelection', sel); }
    });

    // Ctrl+Shift+C：把 xterm 选区交给 Flutter 写系统剪贴板
    // （xterm 自己把 Ctrl+C 当 SIGINT，所以只接管 Shift 组合）
    if (term.attachCustomKeyEventHandler) {
      term.attachCustomKeyEventHandler(function (ev) {
        if (ev.type === 'keydown' && ev.ctrlKey && ev.shiftKey &&
            (ev.key === 'C' || ev.key === 'c')) {
          var sel = term.getSelection();
          if (sel) { send('sshiveCopy', sel); return false; }
        }
        return true;
      });
    }
    document.addEventListener('copy', function () {
      var sel = term.getSelection();
      if (sel) { send('sshiveCopy', sel); }
    });

    // 容器尺寸变化 → fit()（fit 会触发 onResize → Dart 侧转发 PTY resize）
    var scheduled = false;
    function refit() {
      if (scheduled) { return; }
      scheduled = true;
      requestAnimationFrame(function () {
        scheduled = false;
        if (fit) { try { fit.fit(); } catch (e) {} }
      });
    }
    if (window.ResizeObserver) { new ResizeObserver(refit).observe(container); }
    window.addEventListener('resize', refit);
    // 首帧布局可能还没稳定，补两次
    setTimeout(refit, 30);
    setTimeout(refit, 250);
    // 字体没加载完时测到的字符尺寸可能是 0 → fit 算不出行列（表现为整块空白）。
    // 字体就绪后再 fit 一次，并对异常行列做退避重试（最多 5 次）。
    if (document.fonts && document.fonts.ready && document.fonts.ready.then) {
      document.fonts.ready.then(function () { setTimeout(refit, 0); });
    }
    var fitRetry = 0;
    function ensureFit() {
      if (!fit || !term) { return; }
      if (term.cols > 2 && term.rows > 1) { return; }
      if (fitRetry++ > 5) {
        send('sshiveDiag', 'ensureFit 放弃：cols=' + term.cols + ' rows=' + term.rows);
        return;
      }
      try { fit.fit(); } catch (e) {}
      setTimeout(ensureFit, 100 * fitRetry);
    }
    setTimeout(ensureFit, 60);
  }

  var rxBytes = 0;
  var rxChunks = 0;

  // 所有入口都返回状态字符串（"ok..." / "err:<原因>"），Dart 侧会把返回值写进日志。
  // 这样"脚本到底有没有执行、执行时报了什么错"不再靠猜——原来的空 catch 正是
  // 我们排查黑屏时最大的信息黑洞。
  function errText(e) { return 'err:' + (e && e.message ? e.message : ('' + e)); }

  // ---- Dart → JS 的数据通道：WebView2 原生 web message ----
  // 为什么要绕开 evaluateJavascript：实测 Dart 侧发起的脚本执行看不到页面主世界的
  // 全局对象（window.__sshive 未定义），于是所有 Dart→JS 调用都静默失效。
  // window.chrome.webview 的 message 事件由 WebView2 直接投递到文档，不经过脚本执行。
  function doWrite(b64) {
    if (!term) { send('sshiveDiag', 'write 到达但 term 为空'); return 'err:term-null'; }
    try {
      var bytes = b64ToBytes(b64);
      rxBytes += bytes.length;
      rxChunks++;
      term.write(bytes);
      var info = 'ok chunk=' + rxChunks + ' bytes=' + bytes.length + ' total=' + rxBytes;
      // 结构化确认：Dart 侧据此判断"数据是否真的进了 xterm.js"
      send('sshiveAck', rxChunks, bytes.length, rxBytes);
      if (rxChunks <= 3 || (rxChunks % 50) === 0) {
        send('sshiveDiag', 'rx ' + info + ' cols=' + term.cols + ' rows=' + term.rows);
      }
      return info;
    } catch (e) {
      send('sshiveError', 'write 失败: ' + errText(e));
      return errText(e);
    }
  }

  function doCommand(cmd) {
    if (cmd === 'ping') { send('sshiveDiag', 'pong ' + diagJson()); return; }
    if (cmd === 'diag') { send('sshiveDiag', diagJson()); return; }
    if (cmd === 'focus') { requestNativeFocus(); if (term) { try { term.focus(); } catch (e) {} } return; }
    if (cmd === 'blur') { if (term && typeof term.blur === 'function') { try { term.blur(); } catch (e) {} } return; }
    if (!term && cmd !== 'fit') { send('sshiveError', '命令 ' + cmd + ' 到达但 term 为空'); return; }
    try {
      if (cmd === 'fit') { if (fit) { fit.fit(); } }
      else if (cmd === 'clear') { term.clear(); }
      else if (cmd === 'reset') { term.reset(); }
      else if (cmd === 'scrollBottom') { term.scrollToBottom(); }
      else { send('sshiveError', '未知命令: ' + cmd); }
    } catch (e) {
      send('sshiveError', '命令 ' + cmd + ' 失败: ' + errText(e));
    }
  }

  // 让原生侧把键盘焦点交回本 WebView（插件保留名 __focus → MoveFocus）。
  // 只调 term.focus() 不够：Flutter 侧按钮会把 Win32 焦点拿走，
  // 页面里的 DOM 焦点无法把窗口焦点要回来。
  function requestNativeFocus() {
    try {
      var api = window.flutter_inappwebview;
      if (api && typeof api.callHandler === 'function') {
        var p = api.callHandler('__focus');
        // Windows 的原生侧会执行 MoveFocus；其他平台没有这个保留名，
        // 这里吞掉 Promise 拒绝，避免产生无意义的错误日志。
        if (p && typeof p.catch === 'function') { p.catch(function () {}); }
        return true;
      }
    } catch (e) {}
    return false;
  }

  function applyEnvelope(raw) {
    // 兼容两种投递形态：Windows(WebView2) 原生消息给的是字符串，
    // 其他平台经 evaluateJavascript 调用时给的是对象字面量。
    var m;
    if (raw !== null && typeof raw === 'object') {
      m = raw;
    } else {
      try { m = JSON.parse(String(raw)); }
      catch (e) { send('sshiveError', 'message 解析失败: ' + errText(e)); return; }
    }
    if (!m || !m.t) { send('sshiveError', 'message 缺少类型字段'); return; }
    if (m.t === 'd') { doWrite(m.v); return; }
    if (m.t === 'p') {
      if (term) { try { term.paste(b64ToText(m.v)); } catch (e) { send('sshiveError', 'paste 失败: ' + errText(e)); } }
      return;
    }
    if (m.t === 'c') { doCommand(m.v); return; }
    send('sshiveError', '未知 envelope 类型: ' + m.t);
  }

  var hasWebMessage = !!(window.chrome && window.chrome.webview &&
    window.chrome.webview.addEventListener);
  if (hasWebMessage) {
    // Windows（WebView2）：插件已改为原生 PostWebMessageAsJson 投递
    window.chrome.webview.addEventListener('message', function (ev) {
      applyEnvelope(ev.data);
    });
  }
  // 其余平台（Android/iOS/macOS）：插件用 window.postMessage 派发 message 事件，
  // 同时 Dart 侧在这些平台走 evaluateJavascript 直接调 applyEnvelope，两条都接住。
  window.addEventListener('message', function (ev) {
    applyEnvelope(ev.data);
  });

  function diagJson() {
    var c = document.getElementById('t');
    var out = {};
    try {
      out.vis = document.visibilityState;
      out.ready = document.readyState;
      out.inner = window.innerWidth + 'x' + window.innerHeight;
      out.container = c ? (c.clientWidth + 'x' + c.clientHeight) : 'no-container';
      out.cols = term ? term.cols : -1;
      out.rows = term ? term.rows : -1;
      out.hasElement = !!(term && term.element);
      out.dpr = window.devicePixelRatio;
      out.rxChunks = rxChunks;
      out.rxBytes = rxBytes;
      out.core = (typeof Terminal !== 'undefined') ? 'ok' : 'missing';
      out.hasSshive = (typeof window.__sshive !== 'undefined');
      out.webMessage = hasWebMessage ? 'ok' : 'missing';
      out.renderer = (term && term._core && term._core._renderService &&
        term._core._renderService._renderer) ?
        (term._core._renderService._renderer.constructor.name || 'unknown') : 'unknown';
    } catch (e) {
      out.err = '' + e;
    }
    return JSON.stringify(out);
  }

  window.__sshive = {
    /// Dart→JS 的统一入口：Windows 走原生 web message，其他平台走
    /// evaluateJavascript 直接调用（Android 的 JS 执行能力正常）。
    applyEnvelope: function (raw) {
      try { applyEnvelope(raw); return 'ok'; } catch (e) { return errText(e); }
    },
    writeB64: function (b64) { return doWrite(b64); },
    pasteB64: function (b64) {
      if (!term) { return 'err:term-null'; }
      try { term.paste(b64ToText(b64)); return 'ok'; } catch (e) { return errText(e); }
    },
    sendText: function (text) {
      if (!term) { return 'err:term-null'; }
      try {
        if (typeof term.input === 'function') { term.input(text, true); }
        else { term.paste(text); }
        return 'ok';
      } catch (e) { return errText(e); }
    },
    focus: function () { requestNativeFocus(); if (!term) { return 'err:term-null'; } try { term.focus(); return 'ok'; } catch (e) { return errText(e); } },
    fit: function () { if (!fit) { return 'err:no-fit-addon'; } try { fit.fit(); return 'ok:' + term.cols + 'x' + term.rows; } catch (e) { return errText(e); } },
    clear: function () { if (!term) { return 'err:term-null'; } try { term.clear(); return 'ok'; } catch (e) { return errText(e); } },
    reset: function () { if (!term) { return 'err:term-null'; } try { term.reset(); return 'ok'; } catch (e) { return errText(e); } },
    scrollToBottom: function () { if (!term) { return 'err:term-null'; } try { term.scrollToBottom(); return 'ok'; } catch (e) { return errText(e); } },
    scrollLines: function (n) { if (!term) { return 'err:term-null'; } try { term.scrollLines(n); return 'ok'; } catch (e) { return errText(e); } },
    selection: function () { return term ? term.getSelection() : ''; },
    ping: function (tag) { return 'ok ' + JSON.stringify({ tag: String(tag == null ? '' : tag) }) + ' ' + diagJson(); },
    diag: function () { return diagJson(); },
    mark: function (tag) {
      // 诊断用：Dart 侧可写一行标记，便于在日志里对齐时序
      send('sshiveLog', String(tag));
      return 'ok';
    }
  };

  flushQueue();
  setTimeout(flushQueue, 60);
  setTimeout(flushQueue, 400);
  // 初始化快照（能一眼看出容器是否 0 尺寸、cols/rows 是否算出来、web message 通道在不在）
  send('sshiveDiag', diagJson());
  setTimeout(function () { send('sshiveDiag', 'T+400ms ' + diagJson()); }, 400);
  send('sshiveDiag', 'web message 通道: ' + (hasWebMessage ? 'ok' : 'missing'));
  // 通知 Dart：页面与 window.__sshive 已就绪。
  // 注意：此刻 document.readyState 仍是 'loading'（脚本在 body 末尾），而 WebView2
  // 在导航未完成时执行脚本不可靠，所以真正的"可以喂数据"信号是下面的 load 事件。
  send('sshiveReady', 1);

  // 文档 load 完成后才允许 Dart 开始推送（Dart 侧另有超时兜底，避免卡死）
  function signalLoaded() { send('sshiveLoaded', 1); }
  if (document.readyState === 'complete') {
    setTimeout(signalLoaded, 0);
  } else {
    window.addEventListener('load', function () { setTimeout(signalLoaded, 0); });
  }
})();
</script>
</body>
</html>
''';
}
