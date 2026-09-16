import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_state.dart';
import '../services/log_bus.dart';
import '../services/web_desktop_mode.dart';
import '../services/web_scroll_config.dart';
import '../services/web_scroll_settings.dart';
import '../services/web_session_manager.dart';

/// 网页管理界面（HomePage 的"网页"Tab 内容）。
///
/// 多标签浏览器：所有页面常驻 IndexedStack（切 Tab 不销毁），
/// 仅手动销毁或应用退出才结束页面；cookie 持久保存。
class WebTabsTab extends StatelessWidget {
  const WebTabsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WebSessionManager.instance,
      builder: (context, _) {
        final manager = WebSessionManager.instance;
        if (manager.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tab_outlined,
                    size: 56, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text(
                  '没有打开的网页\n从隧道点"打开"，或点 + 新建标签',
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
            _TabStrip(manager: manager),
            Expanded(
              child: IndexedStack(
                index: manager.activeIndex,
                children: [
                  for (final s in manager.sessions) _WebPageView(session: s),
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
// 顶部标签栏
// ---------------------------------------------------------------------------

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.manager});

  final WebSessionManager manager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 单行合并：左侧标签区（可滚动）+ 右侧控制栏（最长 1/3 宽，可左右滚动）
    return Container(
      height: 42,
      color: theme.colorScheme.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          return Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  itemCount: manager.sessions.length + 1,
                  itemBuilder: (context, i) {
                    if (i == manager.sessions.length) {
                      return Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: IconButton.filledTonal(
                          tooltip: '新建标签',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add, size: 18),
                          onPressed: () => showNewTabDialog(context),
                        ),
                      );
                    }
                    return _TabChip(
                      session: manager.sessions[i],
                      active: i == manager.activeIndex,
                      onTap: () => manager.activate(i),
                      onClose: () => showCloseTabDialog(context, i),
                    );
                  },
                ),
              ),
              // 分隔线
              Container(
                width: 1,
                color: theme.dividerColor.withValues(alpha: 0.35),
                margin: const EdgeInsets.symmetric(vertical: 7),
              ),
              // 控制栏：宽度=内容自然宽，上限为总宽的 1/3
              // （内容超出上限时内部左右滚动，不挤压标签区）
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW / 3),
                child: _ControlBar(manager: manager),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.session,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final WebSession session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: active
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 150,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 2),
              child: Row(
                children: [
                  if (session.loading)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  else
                    const Icon(Icons.public, size: 13),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      session.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: active
                            ? theme.colorScheme.onPrimaryContainer
                            : null,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '销毁标签',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 网页控制栏（作用于当前标签）：左侧显示当前网页标题，右侧为控制按钮。
class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.manager});

  final WebSessionManager manager;

  Future<void> _openInBrowser(BuildContext context) async {
    final s = manager.active;
    if (s == null) return;
    var uri = s.url;
    final current = await s.currentUrl();
    if (current != null) uri = current;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = manager.active;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '后退',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back, size: 17),
            onPressed: active == null
                ? null
                : () async {
                    final c = active.controller;
                    if (c == null) return;
                    if (await c.canGoBack()) await c.goBack();
                  },
          ),
          IconButton(
            tooltip: '前进',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_forward, size: 17),
            onPressed: active == null
                ? null
                : () async {
                    final c = active.controller;
                    if (c == null) return;
                    if (await c.canGoForward()) await c.goForward();
                  },
          ),
          IconButton(
            tooltip: '刷新',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 17),
            onPressed: active == null ? null : () => active.reload(),
          ),
          IconButton(
            tooltip: '用系统浏览器打开',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.open_in_browser, size: 17),
            onPressed: active == null ? null : () => _openInBrowser(context),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            iconSize: 17,
            onSelected: (v) async {
            if (v == 'close_all') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('关闭全部标签'),
                  content: Text(
                      '将销毁 ${manager.sessions.length} 个页面（Cookie 保留）。'),
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
              if (ok == true) await manager.closeAll();
            } else if (v == 'clear_cookies') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('清除全部 Cookie'),
                  content: const Text('所有网站的登录状态将被清除。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('清除'),
                    ),
                  ],
                ),
              );
              if (ok == true) await manager.clearCookies();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'close_all', child: Text('关闭全部标签')),
            PopupMenuItem(value: 'clear_cookies', child: Text('清除全部 Cookie')),
          ],
        ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 单个网页视图
// ---------------------------------------------------------------------------

class _WebPageView extends StatelessWidget {
  const _WebPageView({required this.session});

  final WebSession session;

  @override
  Widget build(BuildContext context) {
    // 注意：此处不要用 ValueKey 变化 / 监听去"重建" InAppWebView——
    // 在共享 gWebViewEnvironment 下重建会损坏 WebView2 环境，
    // 导致 http://127.0.0.1:端口 加载报 CONNECTION_ABORTED。
    // 滚动幅度在创建时读取，改设置后新打开/重开的标签生效。
    final multiplier = WebScrollSettings.instance.multiplier;
    // 桌面版网页模式（仅 Android）：桌面 UA + 强制桌面视口，
    // 让手机上的网页按电脑布局渲染（设置变化对新标签生效）
    final desktop = Platform.isAndroid && WebDesktopMode.instance.enabled;
    return Stack(
      children: [
        InAppWebView(
          webViewEnvironment: gWebViewEnvironment,
          // 注意：不传 initialUrlRequest——加载统一由 attach 后的
          // WebSession._load()（controller.loadUrl）执行。之前传
          // initialUrlRequest 时会与 _load 形成双重导航竞态
          // （0.7.0-beta.3 下表现为初始化导航 about:blank 报
          // CONNECTION_ABORTED、目标导航丢失，页面停在空白）。
          initialUserScripts: desktop
              ? UnmodifiableListView([
                  UserScript(
                    source: WebDesktopMode.instance.viewportJs,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    forMainFrameOnly: true,
                  ),
                ])
              : null,
          initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                supportZoom: true,
                // 仅 Windows 校准滚轮增量，可调幅度（见 web_scroll_settings.dart）
                scrollMultiplier:
                    webScrollCalibrationEnabled ? multiplier : null,
                // 仅 Android 桌面模式：桌面 UA + 宽视口
                userAgent: desktop ? WebDesktopMode.kDesktopUserAgent : null,
                useWideViewPort: desktop ? true : null,
                loadWithOverviewMode: desktop ? true : null,
              ),
          onWebViewCreated: (controller) {
            session.attach(controller);
            LogBus.instance
                .info('Web', 'WebView 创建: 初始目标=${session.url}');
          },
          onLoadStart: (controller, url) {
            LogBus.instance.debug('Web', '开始加载: $url');
          },
          onTitleChanged: (controller, title) {
            if (title != null && title.isNotEmpty) {
              session.title = title;
              session.onChanged();
            }
          },
          onProgressChanged: (controller, progress) {
            final loading = progress < 100;
            if (loading != session.loading) {
              session.loading = loading;
              session.onChanged();
            }
          },
          onLoadStop: (controller, url) {
            LogBus.instance.debug('Web', '加载完成: $url');
            // 桌面模式实测诊断：读取页面真实 UA 与视口宽度
            if (desktop) {
              controller
                  .evaluateJavascript(
                    source:
                        '(function(){var m=document.querySelector("meta[name=viewport]");return JSON.stringify({ua:navigator.userAgent,innerWidth:window.innerWidth,innerHeight:window.innerHeight,clientWidth:document.documentElement.clientWidth,viewportMeta:m?m.content:null,dpr:window.devicePixelRatio});})()',
                  )
                  .then((v) => LogBus.instance
                      .debug('Web', '桌面模式实测: $v'))
                  .catchError((e) => LogBus.instance
                      .debug('Web', '桌面模式实测失败: $e'));
            }
            // 页面加载完成：清除错误横幅、更新标题
            session.onPageFinished();
          },
          onReceivedError: (controller, request, error) {
            if (error.type != WebResourceErrorType.CANCELLED &&
                request.isForMainFrame == true) {
              session.onLoadError(error.description);
              LogBus.instance.error('Web',
                  '加载失败: ${request.url} | ${error.type} | ${error.description}');
            }
          },
          shouldOverrideUrlLoading: (controller, action) async {
            LogBus.instance.debug('Web', '请求导航: ${action.request.url}');
            // 非主框架或同站导航放行；跨站导航也放行（站内跳转）
            return NavigationActionPolicy.ALLOW;
          },
        ),
        if (session.loading) const LinearProgressIndicator(minHeight: 2),
        if (session.error != null)
          Positioned(
            top: 6,
            left: 12,
            right: 12,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 18,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.error!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        // 关闭横幅后必须通知重建，否则横幅永远关不掉
                        session.error = null;
                        session.onChanged();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
  }
}

// ---------------------------------------------------------------------------
// 新建标签对话框
// ---------------------------------------------------------------------------

Future<void> showNewTabDialog(BuildContext context) async {
  final controller = TextEditingController(text: 'http://127.0.0.1:');
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final app = AppState.instance;
      final runningTunnels = app.tunnels
          .where((t) => app.runtimeOf(t.id)?.isRunning ?? false)
          .toList();
      return AlertDialog(
        title: const Text('新建网页标签'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '网址',
                  hintText: 'http://127.0.0.1:8080',
                  border: OutlineInputBorder(),
                ),
              ),
              if (runningTunnels.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('运行中的隧道',
                    style: Theme.of(ctx).textTheme.labelMedium),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in runningTunnels)
                      ActionChip(
                        label: Text(
                            '${t.name.isEmpty ? t.summary : t.name}\n'
                            '127.0.0.1:${t.localPort}',
                            style: const TextStyle(fontSize: 11)),
                        onPressed: () =>
                            Navigator.pop(ctx, 'http://127.0.0.1:${t.localPort}'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('打开'),
          ),
        ],
      );
    },
  );
  if (result == null || result.isEmpty) return;
  var uri = Uri.tryParse(result);
  if (uri == null || !uri.hasScheme) {
    uri = Uri.tryParse('http://$result');
  }
  if (uri == null || uri.host.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('网址无效')));
    }
    return;
  }
  WebSessionManager.instance.open(url: uri, title: uri.host);
  // 确保停留在"网页"Tab（若从其他 Tab 触发）
  WebSessionManager.instance.requestTab(2);
}

// ---------------------------------------------------------------------------
// 销毁标签对话框
// ---------------------------------------------------------------------------

Future<void> showCloseTabDialog(BuildContext context, int index) async {
  final manager = WebSessionManager.instance;
  final session = manager.sessions[index];
  var clearCookies = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('销毁标签页'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${session.displayTitle}"\n'
                '页面将被销毁；Cookie 会保留，重新打开仍是登录状态。'),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('同时清除全部 Cookie（所有网站）'),
              value: clearCookies,
              onChanged: (v) => setState(() => clearCookies = v ?? false),
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
            child: const Text('销毁'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) {
    await manager.close(index, clearAllCookies: clearCookies);
  }
}
