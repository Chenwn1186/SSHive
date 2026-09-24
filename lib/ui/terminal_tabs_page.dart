import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/app_state.dart';
import '../services/log_bus.dart';
import '../services/terminal_manager.dart';
import '../services/web_scroll_config.dart';
import '../services/web_scroll_settings.dart';
import '../services/xterm_page.dart';

/// 把键盘焦点交回当前活动终端。
///
/// 终端页里任何 Flutter 侧交互（工具栏按钮、按键栏、标签切换、对话框关闭）之后
/// 都要调用它：Flutter 的点击会把 Win32 焦点拿回自己的窗口，而终端要能继续接收
/// 键盘输入，就必须由原生侧把焦点交还 WebView2（见 focusTerminal 的说明）。
/// 用 post-frame 是为了让按钮/对话框自身的焦点处理先跑完。
void _refocusActiveTerminal() {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    TerminalManager.instance.active?.focusTerminal();
  });
}

/// 终端管理界面（HomePage 的"终端"Tab 内容）。
///
/// 多终端标签管理 + **xterm.js**（WebView 承载）+ 底部按键快捷栏。
/// 模拟器（转义序列/回看缓冲/宽字符/IME/粘贴协议）在 xterm.js 里，
/// Dart 侧只搬运字节并转发事件，详见 lib/services/xterm_page.dart。
class TerminalTabsTab extends StatelessWidget {
  const TerminalTabsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TerminalManager.instance,
      builder: (context, _) {
        final manager = TerminalManager.instance;
        if (manager.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal_outlined,
                    size: 56, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text(
                  '没有打开的终端\n从文件管理器"在此打开终端"，或点右下角新建',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            _TerminalTabStrip(manager: manager),
            Expanded(
              child: IndexedStack(
                index: manager.activeIndex,
                children: [
                  for (var i = 0; i < manager.sessions.length; i++)
                    _TerminalViewWrapper(
                      session: manager.sessions[i],
                      isActive: i == manager.activeIndex,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 标签条（第一栏）
// ---------------------------------------------------------------------------

class _TerminalTabStrip extends StatelessWidget {
  const _TerminalTabStrip({required this.manager});

  final TerminalManager manager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Focus 包裹：标签条按钮不参与焦点，避免点标签后终端失去键盘输入
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: Container(
        height: 42,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                itemCount: manager.sessions.length + 1,
                itemBuilder: (context, i) {
                  if (i == manager.sessions.length) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: IconButton.filledTonal(
                        tooltip: '新建终端',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add, size: 18),
                        onPressed: () async {
                          await showNewTerminalDialog(context);
                          _refocusActiveTerminal();
                        },
                      ),
                    );
                  }
                  final s = manager.sessions[i];
                  return Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Material(
                      color: i == manager.activeIndex
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          manager.activate(i);
                          _refocusActiveTerminal();
                        },
                        child: SizedBox(
                          width: 150,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10, right: 2),
                            child: Row(
                              children: [
                                Icon(
                                  s.connected
                                      ? Icons.terminal
                                      : Icons.link_off,
                                  size: 13,
                                  color: s.connected
                                      ? Colors.green
                                      : theme.colorScheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: i == manager.activeIndex
                                          ? theme.colorScheme
                                              .onPrimaryContainer
                                          : null,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '关闭终端',
                                  visualDensity: VisualDensity.compact,
                                iconSize: 16,
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    _confirmClose(context, manager, i),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _confirmClose(
      BuildContext context, TerminalManager manager, int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭终端'),
        content: Text('确定关闭"${manager.sessions[index].title}"？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (ok == true) await manager.close(index);
    _refocusActiveTerminal();
  }
}

// ---------------------------------------------------------------------------
// 终端视图 + 按键栏
// ---------------------------------------------------------------------------

class _TerminalViewWrapper extends StatefulWidget {
  const _TerminalViewWrapper({
    required this.session,
    required this.isActive,
  });

  final TerminalSession session;
  final bool isActive;

  @override
  State<_TerminalViewWrapper> createState() => _TerminalViewWrapperState();
}

class _TerminalViewWrapperState extends State<_TerminalViewWrapper> {
  bool _showKeys = true;

  @override
  void didUpdateWidget(covariant _TerminalViewWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 标签被激活时：让 xterm.js 重新适配尺寸并请求键盘焦点
    if (widget.isActive && !oldWidget.isActive) {
      widget.session.refitTerminal();
      widget.session.focusTerminal();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // 整个 Column（含按键栏）都监听 session：connect 完成后
    // connected 状态变化会触发按键栏重建，否则按钮会停在灰色禁用态
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        children: [
          // 控制栏：标题/状态 + 操作按钮
          // Focus 包裹：这些按钮一律不参与焦点（避免点击后把键盘焦点从终端拿走）
          Focus(
            canRequestFocus: false,
            descendantsAreFocusable: false,
            child: Container(
              height: 36,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      session.connected
                          ? session.title
                          : '${session.title}（已断开${session.error != null ? ': ${session.error}' : ''}）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '清屏 (Ctrl+L)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    onPressed: () {
                      session.sendSequence('\x0c');
                      _refocusActiveTerminal();
                    },
                  ),
                  IconButton(
                    tooltip: '复制选中内容 (Ctrl+Shift+C)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: const Icon(Icons.copy_all_outlined),
                    onPressed: () async {
                      await session.copySelection();
                      _refocusActiveTerminal();
                    },
                  ),
                  IconButton(
                    tooltip: '粘贴 (Ctrl+V)',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: const Icon(Icons.content_paste),
                    onPressed: () async {
                      await session.pasteFromClipboard();
                      _refocusActiveTerminal();
                    },
                  ),
                  IconButton(
                    tooltip: _showKeys ? '隐藏按键栏' : '显示按键栏',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    icon: Icon(
                      _showKeys ? Icons.keyboard_hide_outlined : Icons.keyboard,
                    ),
                    onPressed: () {
                      setState(() => _showKeys = !_showKeys);
                      _refocusActiveTerminal();
                    },
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    iconSize: 17,
                    onSelected: (v) async {
                      if (v == 'close_all') {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('关闭全部终端'),
                            content: Text(
                                '将关闭 ${TerminalManager.instance.sessions.length} 个终端。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('全部关闭'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await TerminalManager.instance.closeAll();
                        }
                        _refocusActiveTerminal();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                          value: 'close_all', child: Text('关闭全部终端')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 终端渲染区（xterm.js / WebView2 托管）
          Expanded(child: _TerminalWebView(session: session)),
          // 底部按键快捷栏（手机输入法不便的补偿）
          if (_showKeys) _KeyBar(onAfter: _refocusActiveTerminal),
        ],
      ),
    );
  }
}

/// xterm.js 终端宿主：一个会话一个 WebView。
///
/// 注意：这里**不能**因为主题变化等去重建 InAppWebView —— 在共享
/// gWebViewEnvironment 下重建会损坏 WebView2 环境（参见 web_tabs_page.dart
/// 的同类注释），页面内的主题由 xterm.js 侧承担。
class _TerminalWebView extends StatefulWidget {
  const _TerminalWebView({required this.session});

  final TerminalSession session;

  @override
  State<_TerminalWebView> createState() => _TerminalWebViewState();
}

class _TerminalWebViewState extends State<_TerminalWebView> {
  bool _pageError = false;

  Future<void> _loadPage(InAppWebViewController controller) async {
    // await 之前取主题，避免 use_build_context_synchronously
    final theme = Theme.of(context);
    final html = await XtermPage.buildHtml(
      XtermPageConfig(theme: xtermThemeFrom(theme, theme.brightness)),
    );
    if (!mounted) return;
    await controller.loadData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf8',
      baseUrl: WebUri('about:blank'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            webViewEnvironment: gWebViewEnvironment,
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              // JS → Dart 桥（输入/尺寸/标题/复制）依赖它
              javaScriptBridgeEnabled: true,
              transparentBackground: false,
              // 滚轮：终端用**独立的终端倍率**（与网页分开配置，改设置即时生效）
              scrollMultiplier: webScrollCalibrationEnabled
                  ? WebScrollSettings.instance.terminalMultiplier
                  : null,
            ),
            onWebViewCreated: (controller) {
              // 先注册桥（handler 必须在页面脚本调用前就位），再加载页面
              widget.session.attachWeb(controller);
              _loadPage(controller);
            },
            onConsoleMessage: (controller, consoleMessage) {
              // 页面里的 JS 异常会以 console message 形式回来（Windows 上
              // CDP 抛错也只走这里），不接住就会表现为"静默失败"
              LogBus.instance.debug(
                'Terminal',
                'console[${consoleMessage.messageLevel}] ${consoleMessage.message}',
              );
            },
            onReceivedError: (controller, request, error) {
              if (error.type != WebResourceErrorType.CANCELLED &&
                  request.isForMainFrame == true &&
                  mounted) {
                setState(() => _pageError = true);
              }
            },
            shouldOverrideUrlLoading: (controller, action) async {
              // 终端页面自身不应发生导航；真出现就放行（例如 about:blank）
              return NavigationActionPolicy.ALLOW;
            },
          ),
        ),
        if (_pageError)
          Positioned(
            left: 12,
            bottom: 12,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '终端页面加载失败',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onErrorContainer,
                      ),
                ),
              ),
            ),
          ),
        if (!widget.session.connected)
          Positioned(
            left: 12,
            bottom: 12,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '连接已断开',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 常用按键快捷栏。
class _KeyBar extends StatelessWidget {
  const _KeyBar({this.onAfter});

  /// 按键发送之后的回调（用于把键盘焦点交回终端）
  final VoidCallback? onAfter;

  @override
  Widget build(BuildContext context) {
    final active = TerminalManager.instance.active;
    // Focus 包裹：按键栏按钮不参与焦点，点完焦点仍归终端
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: Container(
        height: 42,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          children: [
            for (final k in _keys)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _KeyButton(
                  label: k.label,
                  onPressed: active == null || !active.connected
                      ? null
                      : () {
                          active.sendSequence(k.seq);
                          onAfter?.call();
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 11),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Text(label),
    );
  }
}

class _KeyDef {
  const _KeyDef(this.label, this.seq);
  final String label;
  final String seq;
}

const _keys = [
  _KeyDef('Ctrl+C', '\x03'),
  _KeyDef('Ctrl+D', '\x04'),
  _KeyDef('Tab', '\t'),
  _KeyDef('Esc', '\x1b'),
  _KeyDef('←', '\x1b[D'),
  _KeyDef('↓', '\x1b[B'),
  _KeyDef('↑', '\x1b[A'),
  _KeyDef('→', '\x1b[C'),
  _KeyDef('Ctrl+L 清屏', '\x0c'),
  _KeyDef('Ctrl+A', '\x01'),
  _KeyDef('Ctrl+E', '\x05'),
  _KeyDef('Ctrl+Z', '\x1a'),
  _KeyDef('Ctrl+R', '\x12'),
];

// ---------------------------------------------------------------------------
// 新建终端对话框
// ---------------------------------------------------------------------------

/// 选择一台已连接的服务器并新建终端。
Future<void> showNewTerminalDialog(BuildContext context) async {
  final app = AppState.instance;
  final connected = app.servers
      .where((s) => (app.sessionOf(s.id)?.isConnected ?? false))
      .toList();
  if (connected.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请先连接一台服务器')));
    }
    return;
  }
  final server = await showDialog(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择服务器'),
      children: [
        for (final s in connected)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, s),
            child: Row(
              children: [
                const Icon(Icons.dns_outlined, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${s.name.isEmpty ? s.host : s.name}\n'
                    '${s.username}@${s.host}:${s.port}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
  if (server == null) return;
  await TerminalManager.instance.open(serverId: server.id);
  TerminalManager.instance.requestTab(3);
  _refocusActiveTerminal();
}
