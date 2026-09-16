import 'package:flutter/material.dart';
import 'package:kterm/kterm.dart';

import '../services/app_state.dart';
import '../services/terminal_manager.dart';

/// 终端管理界面（HomePage 的"终端"Tab 内容）。
///
/// 多终端标签管理 + xterm 渲染 + 底部按键快捷栏（手机输入法不便的补偿）。
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
    return Container(
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
                      onPressed: () => showNewTerminalDialog(context),
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
                      onTap: () => manager.activate(i),
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
    // 终端标签被激活时抢占键盘焦点（键盘输入的前提）
    if (widget.isActive && !oldWidget.isActive) {
      widget.session.focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 整个 Column（含按键栏）都监听 session：connect 完成后
    // connected 状态变化会触发按键栏重建，否则按钮会停在灰色禁用态
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        children: [
          // 控制栏：标题/状态 + 操作按钮
          Container(
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
                  onPressed: () => session.sendSequence('\x0c'),
                ),
                IconButton(
                  tooltip: '粘贴',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: const Icon(Icons.content_paste),
                  onPressed: () => session.pasteFromClipboard(),
                ),
                IconButton(
                  tooltip: _showKeys ? '隐藏按键栏' : '显示按键栏',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: Icon(
                    _showKeys ? Icons.keyboard_hide_outlined : Icons.keyboard,
                  ),
                  onPressed: () => setState(() => _showKeys = !_showKeys),
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
          // 终端渲染区（kterm：完整 IME/软键盘/Kitty 协议支持）
          Expanded(
            child: Stack(
              children: [
                TerminalView(
                  session.terminal,
                  controller: session.controller,
                  focusNode: session.focusNode,
                  autofocus: widget.isActive,
                  cursorType: TerminalCursorType.block,
                  padding: const EdgeInsets.all(8),
                  textStyle: const TerminalStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.2,
                  ),
                  theme: dark
                      ? TerminalThemes.defaultTheme
                      : TerminalThemes.whiteOnBlack,
                  onTapUp: (details, offset) {
                    // 点击终端区域时请求焦点（IME/软键盘输入前提）
                    session.focusNode.requestFocus();
                  },
                ),
                if (!session.connected)
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: Material(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text(
                          '连接已断开',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 底部按键快捷栏（手机输入法不便的补偿）
          // 注意：不能写 const —— const 实例会被 Flutter 判为相同 widget
          // 而跳过 rebuild，按钮的启用状态会停留在首次构建的禁用态
          if (_showKeys) _KeyBar(),
        ],
      ),
    );
  }
}

/// 常用按键快捷栏。
class _KeyBar extends StatelessWidget {  const _KeyBar();

  @override
  Widget build(BuildContext context) {
    final active = TerminalManager.instance.active;
    return Container(
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
                    : () => active.sendSequence(k.seq),
              ),
            ),
        ],
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
}
