import 'dart:io';

import 'package:flutter/material.dart';

import '../models/server_config.dart';
import '../models/tunnel_config.dart';
import '../services/app_state.dart';
import '../services/file_browser_controller.dart';
import '../services/log_bus.dart';
import '../services/ssh_session.dart';
import '../services/terminal_manager.dart';
import '../services/tunnel_runtime.dart';
import '../services/web_scroll_settings.dart';
import '../services/web_desktop_mode.dart';
import '../services/web_session_manager.dart';
import 'import_ssh_page.dart';
import 'remote_file_tabs_page.dart';
import 'server_edit_page.dart';
import 'terminal_tabs_page.dart';
import 'tunnel_edit_page.dart';
import 'web_tabs_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    // IndexedStack 不会像 TabBarView 那样自动监听 controller，
    // 必须手动监听并在 index 变化时重建，否则点击 Tab 内容不切换
    _tabController.addListener(_onTabIndexChanged);
    // 监听网页会话管理器的"请求切到网页 Tab"（如从隧道点"打开"）
    WebSessionManager.instance.addListener(_onWebSessionsChanged);
    // 监听终端管理器的"请求切到终端 Tab"（如从文件管理器打开终端）
    TerminalManager.instance.addListener(_onTerminalSessionsChanged);
    // 监听文件浏览器的"请求切到文件 Tab"（如服务器卡片点"文件"）
    FileBrowserController.instance.addListener(_onFileBrowserChanged);
  }

  void _onTabIndexChanged() {
    if (mounted) setState(() {});
  }

  void _onWebSessionsChanged() {
    final idx = WebSessionManager.instance.takeRequestTab();
    if (idx != null && idx != _tabController.index && mounted) {
      _tabController.animateTo(idx);
    }
  }

  void _onTerminalSessionsChanged() {
    final idx = TerminalManager.instance.takeRequestTab();
    if (idx != null && idx != _tabController.index && mounted) {
      _tabController.animateTo(idx);
    }
  }

  void _onFileBrowserChanged() {
    final idx = FileBrowserController.instance.takeRequestTab();
    if (idx != null && idx != _tabController.index && mounted) {
      _tabController.animateTo(idx);
    }
  }

  /// 网页滚动幅度设置（Windows）：滑杆自由调节，保存后网页标签即时重载生效。
  Future<void> _adjustWebScroll(BuildContext context) async {
    final settings = WebScrollSettings.instance;
    var current = settings.multiplier;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('网页滚动幅度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '一个滚轮格滚动的量：$current\n'
                '（标准浏览器 ≈120；越小越细腻）',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Slider(
                value: current.toDouble(),
                min: WebScrollSettings.kMinMultiplier.toDouble(),
                max: WebScrollSettings.kMaxMultiplier.toDouble(),
                divisions: 38,
                label: '$current',
                onChanged: (v) => setState(() => current = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await settings.setMultiplier(current);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已生效（当前网页立即使用新滚动幅度）'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  /// 网页渲染宽度设置（Android 桌面模式）：滑杆自由调节视口宽度，
  /// 保存后新打开/重开的网页标签按新宽度渲染。
  Future<void> _adjustWebViewportWidth(BuildContext context) async {
    final mode = WebDesktopMode.instance;
    var width = mode.viewportWidth;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('网页渲染宽度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '以 ${width}px 宽度渲染网页\n'
                '（越大越接近电脑效果，内容整体越小）',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Slider(
                value: width.toDouble(),
                min: WebDesktopMode.kMinViewportWidth.toDouble(),
                max: WebDesktopMode.kMaxViewportWidth.toDouble(),
                label: '$width',
                onChanged: (v) => setState(() => width = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await mode.setViewportWidth(width);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('已保存为 ${mode.viewportWidth}px；新打开或重开的网页标签生效'),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabIndexChanged);
    WebSessionManager.instance.removeListener(_onWebSessionsChanged);
    TerminalManager.instance.removeListener(_onTerminalSessionsChanged);
    FileBrowserController.instance.removeListener(_onFileBrowserChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // Tab 栏吸收进 AppBar 单行（标题行即标签行），压缩顶部空间
      appBar: AppBar(
        toolbarHeight: 48,
        titleSpacing: 0,
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          dividerColor: Colors.transparent,
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
          indicatorSize: TabBarIndicatorSize.label,
          indicatorWeight: 2,
          tabs: const [
            Tab(text: '服务器'),
            Tab(text: '隧道'),
            Tab(text: '网页'),
            Tab(text: '终端'),
            Tab(text: '文件'),
            Tab(text: '日志'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '从 ssh 命令导入配置',
            icon: const Icon(Icons.terminal),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ImportSshPage()),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '设置',
            onSelected: (value) async {
              if (value == 'keepalive') {
                await app.setBackgroundKeepAlive(!app.backgroundKeepAlive);
              } else if (value == 'clear_log') {
                LogBus.instance.clear();
              } else if (value == 'web_scroll') {
                await _adjustWebScroll(context);
              } else if (value == 'web_desktop') {
                final on = !WebDesktopMode.instance.enabled;
                await WebDesktopMode.instance.setEnabled(on);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text(on
                          ? '桌面版网页已开启（新打开/重开的标签生效）'
                          : '桌面版网页已关闭（新打开/重开的标签生效）'),
                      duration: const Duration(seconds: 2),
                    ));
                }
              } else if (value == 'web_desktop_width') {
                await _adjustWebViewportWidth(context);
              }
            },
            itemBuilder: (context) => [
              // 前台保活仅 Android 支持
              if (Platform.isAndroid)
                CheckedPopupMenuItem(
                  value: 'keepalive',
                  checked: app.backgroundKeepAlive,
                  child: const Text('后台保活（前台服务）'),
                ),
              // 桌面版网页仅 Android 生效
              if (Platform.isAndroid)
                CheckedPopupMenuItem(
                  value: 'web_desktop',
                  checked: WebDesktopMode.instance.enabled,
                  child: const Text('桌面版网页'),
                ),
              if (Platform.isAndroid)
                const PopupMenuItem(
                  value: 'web_desktop_width',
                  child: Text('网页渲染宽度…'),
                ),
              // 网页滚动幅度仅 Windows WebView2 有效
              if (Platform.isWindows)
                const PopupMenuItem(
                  value: 'web_scroll',
                  child: Text('网页滚动幅度…'),
                ),
              if (Platform.isAndroid) const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'clear_log',
                child: Text('清空日志'),
              ),
            ],
          ),
        ],
      ),
      // IndexedStack 保活：所有 Tab（含其中的 WebView/终端页面）常驻内存，
      // 切换不销毁，只有退出应用或用户手动销毁才结束页面
      body: IndexedStack(
        index: _tabController.index,
        children: const [
          _ServersTab(),
          _TunnelsTab(),
          WebTabsTab(),
          TerminalTabsTab(),
          RemoteFileTabsTab(),
          _LogsTab(),
        ],
      ),
      floatingActionButton: AnimatedBuilder(
        // 同时监听 tab 切换、网页会话和终端会话（有会话时隐藏 FAB 避免遮挡）
        animation: Listenable.merge([
          _tabController,
          WebSessionManager.instance,
          TerminalManager.instance,
        ]),
        builder: (context, _) {
          final index = _tabController.index;
          if (index == 0) {
            return FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ServerEditPage()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('添加服务器'),
            );
          }
          if (index == 1) {
            return FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TunnelEditPage()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('添加隧道'),
            );
          }
          if (index == 2) {
            // 有网页时隐藏 FAB（标签栏已有"+"按钮），避免遮挡网页内容
            if (!WebSessionManager.instance.isEmpty) {
              return const SizedBox.shrink();
            }
            return FloatingActionButton.extended(
              onPressed: () => showNewTabDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('新建网页标签'),
            );
          }
          if (index == 3) {
            // 有终端会话时隐藏 FAB（标签栏已有"+"按钮），避免遮挡终端内容
            if (!TerminalManager.instance.isEmpty) {
              return const SizedBox.shrink();
            }
            return FloatingActionButton.extended(
              onPressed: () => showNewTerminalDialog(context),
              icon: const Icon(Icons.terminal),
              label: const Text('新建终端'),
            );
          }
          if (index == 4) {
            // 文件页自带操作按钮，不需要 FAB
            return const SizedBox.shrink();
          }
          return FloatingActionButton.small(
            onPressed: () => LogBus.instance.clear(),
            tooltip: '清空日志',
            child: const Icon(Icons.delete_sweep),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 服务器 Tab
// ---------------------------------------------------------------------------

class _ServersTab extends StatelessWidget {
  const _ServersTab();

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (app.servers.isEmpty) {
          return _EmptyHint(
            icon: Icons.dns_outlined,
            text: '还没有服务器配置',
            actions: [
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ImportSshPage()),
                ),
                icon: const Icon(Icons.terminal),
                label: const Text('从 ssh 命令导入'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ServerEditPage()),
                ),
                icon: const Icon(Icons.add),
                label: const Text('手动添加服务器'),
              ),
            ],
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: app.servers.length,
          itemBuilder: (context, i) => _ServerCard(server: app.servers[i]),
        );
      },
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server});

  final ServerConfig server;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final session = app.sessionOf(server.id);
    final status = session?.status ?? SshStatus.disconnected;

    final (Color color, String label) = switch (status) {
      SshStatus.connected => (Colors.green, '已连接'),
      SshStatus.connecting => (Colors.orange, '连接中…'),
      SshStatus.error => (Colors.red, '连接失败'),
      SshStatus.disconnected => (Colors.grey, '未连接'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusDot(status: status, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name.isEmpty ? server.host : server.name,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${server.username}@${server.host}:${server.port}'
                        '${server.useKey ? ' · 密钥' : ' · 密码'}'
                        '${server.socksPort > 0 ? ' · SOCKS5:${server.socksPort}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ServerEditPage(server: server),
                      ));
                    } else if (v == 'delete') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除服务器'),
                          content: Text('确定删除"${server.name}"？\n相关隧道也会一并删除。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await app.deleteServer(server.id);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
            if ((status == SshStatus.error || status == SshStatus.connected) &&
                session != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Text(
                  status == SshStatus.error
                      ? '${session.error}'
                      : '主机指纹 ${session.hostFingerprint}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: status == SshStatus.error
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Text(label,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: color)),
                  const Spacer(),
                  if (status != SshStatus.disconnected) ...[
                    TextButton.icon(
                      // 切到"文件"Tab 并选中该服务器（无论是否已连接，
                      // 文件页内会提示连接状态）
                      onPressed: () =>
                          FileBrowserController.instance.requestOpen(server.id),
                      icon: const Icon(Icons.folder_outlined, size: 18),
                      label: const Text('文件'),
                    ),
                    const SizedBox(width: 4),
                  ],
                  FilledButton.tonal(
                    onPressed: () => status == SshStatus.connected ||
                            status == SshStatus.connecting
                        ? app.disconnectServer(server.id)
                        : app.connectServer(server.id),
                    child: Text(status == SshStatus.connected ||
                            status == SshStatus.connecting
                        ? '断开'
                        : '连接'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.color});

  final SshStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (status == SshStatus.connecting) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

// ---------------------------------------------------------------------------
// 隧道 Tab
// ---------------------------------------------------------------------------

class _TunnelsTab extends StatelessWidget {
  const _TunnelsTab();

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (app.tunnels.isEmpty) {
          return const _EmptyHint(
            icon: Icons.hub_outlined,
            text: '还没有隧道配置\n点击右下角"添加隧道"开始',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: app.tunnels.length,
          itemBuilder: (context, i) =>
              _TunnelCard(tunnel: app.tunnels[i]),
        );
      },
    );
  }
}

class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.tunnel});

  final TunnelConfig tunnel;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    final runtime = app.runtimeOf(tunnel.id);
    final status = runtime?.status ?? TunnelStatus.stopped;
    final server = app.servers
        .where((s) => s.id == tunnel.serverId)
        .firstOrNull;
    final running = runtime?.isRunning ?? false;

    final (Color color, String label) = switch (status) {
      TunnelStatus.running => (Colors.green, '运行中'),
      TunnelStatus.starting => (Colors.orange, '启动中…'),
      TunnelStatus.error => (Colors.red, '错误'),
      TunnelStatus.stopped => (Colors.grey, '已停止'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Switch(
                  value: running,
                  onChanged: (on) => on
                      ? app.startTunnel(tunnel.id)
                      : app.stopTunnel(tunnel.id),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tunnel.name.isEmpty ? tunnel.summary : tunnel.name,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        tunnel.summary,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        server != null
                            ? '服务器: ${server.name.isEmpty ? server.host : server.name}'
                            : '服务器: 已删除',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (status == TunnelStatus.error && runtime?.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${runtime!.error}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Row(
              children: [
                Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: color)),
                const Spacer(),
                TextButton(
                  onPressed: running
                      ? () {
                          // 在网页管理界面打开（保活），并切到"网页"Tab
                          WebSessionManager.instance.open(
                            url: Uri.parse(
                                'http://127.0.0.1:${tunnel.localPort}'),
                            title:
                                tunnel.name.isEmpty ? tunnel.summary : tunnel.name,
                            tunnelId: tunnel.id,
                          );
                          WebSessionManager.instance.requestTab(2);
                        }
                      : null,
                  child: const Text('打开'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => TunnelEditPage(tunnel: tunnel),
                      ));
                    } else if (v == 'delete') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除隧道'),
                          content: Text('确定删除"${tunnel.name}"？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await app.deleteTunnel(tunnel.id);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 日志 Tab
// ---------------------------------------------------------------------------

class _LogsTab extends StatelessWidget {
  const _LogsTab();

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LogBus.instance,
      builder: (context, _) {
        final entries = LogBus.instance.entries;
        if (entries.isEmpty) {
          return const _EmptyHint(
            icon: Icons.article_outlined,
            text: '暂无日志',
          );
        }
        // 保留最近 2000 条
        final from = entries.length > 2000 ? entries.length - 2000 : 0;
        final sb = StringBuffer();
        for (var i = from; i < entries.length; i++) {
          final e = entries[i];
          sb
            ..write(_formatTime(e.time))
            ..write(' [${e.levelName}] ')
            ..writeln('${e.tag} ${e.message}');
        }
        return SelectionArea(
          // 自由选择复制：移动端长按/双击弹出选择手柄，
          // 桌面端鼠标拖选；日志自动追加（随 LogBus 刷新）
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Text(
              sb.toString(),
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text, this.actions});

  final IconData icon;
  final String text;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          if (actions != null) ...[
            const SizedBox(height: 16),
            ...actions!,
          ],
        ],
      ),
    );
  }
}
