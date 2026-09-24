import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/web_scroll_config.dart';
import '../services/web_scroll_settings.dart';

/// 远程 Markdown 渲染视图（无 Scaffold，可嵌入标签页）。
///
/// 基于 flutter_inappwebview（跨平台，Windows 走 WebView2）+ markdown-it
/// （GFM/表格/任务列表）+ KaTeX（$$ / \\( \\) 公式，可选行内 $ 公式）+
/// highlight.js（代码高亮）。所有引擎资源内嵌本地 assets，离线可用；
/// 链接点击转交系统浏览器。
class RemoteMarkdownView extends StatefulWidget {
  const RemoteMarkdownView({
    super.key,
    required this.name,
    required this.content,
  });

  final String name;
  final String content;

  @override
  State<RemoteMarkdownView> createState() => _RemoteMarkdownViewState();
}

class _RemoteMarkdownViewState extends State<RemoteMarkdownView> {
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _error;

  /// 模板资源缓存（只读一次 asset）
  static Future<String>? _templateCache;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final html = await _buildHtml(
        widget.content,
        dark: Theme.of(context).brightness == Brightness.dark,
      );
      if (!mounted) return;
      final c = _controller;
      if (c == null) return; // WebView 尚未创建，创建后会自动加载
      await c.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf8',
        baseUrl: WebUri('about:blank'),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '渲染失败: $e';
      });
    }
  }

  /// 读取并拼接 HTML（引擎资源缓存于静态字段）。
  static Future<String> _template({required bool dark}) async {
    var cached = _templateCache;
    if (cached == null) {
      cached = () async {
        Future<String> load(String name) =>
            rootBundle.loadString('assets/md_viewer/$name');
        final jsMarkdownIt = await load('markdown-it.min.js');
        final jsKatex = await load('katex.min.js');
        final jsTexmath = await load('texmath.js');
        final jsHighlight = await load('highlight.min.js');
        final cssKatex = await load('katex.min.css');
        final cssLight = await load('github.min.css');
        final cssDark = await load('github-dark.min.css');
        return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>$cssKatex</style>
<style>$cssLight</style>
<style>$cssDark</style>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; padding:16px 16px 48px; font-family: -apple-system, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif; font-size:16px; line-height:1.7; word-wrap:break-word; }
  #md { max-width: 860px; margin: 0 auto; }
  pre { padding:12px 14px; border-radius:8px; overflow-x:auto; font-size:13.5px; line-height:1.5; }
  code { font-family: "Cascadia Code", Consolas, "Courier New", monospace; }
  p code, li code, td code { background:rgba(128,128,128,.14); padding:1px 5px; border-radius:4px; font-size:.88em; }
  img { max-width:100%; height:auto; }
  table { border-collapse:collapse; margin:12px 0; }
  th, td { border:1px solid rgba(128,128,128,.4); padding:6px 12px; }
  blockquote { margin:12px 0; padding:2px 14px; border-left:4px solid rgba(128,128,128,.45); color:inherit; opacity:.85; }
  h1,h2,h3,h4 { margin:1.2em 0 .5em; line-height:1.3; }
  h1 { border-bottom:1px solid rgba(128,128,128,.3); padding-bottom:.3em; }
  hr { border:none; border-top:1px solid rgba(128,128,128,.3); }
  a { color:#0969da; }
  @media (prefers-color-scheme: dark) {
    a { color:#58a6ff; }
    body { background:#0d1117; }
  }
  .katex-display { overflow-x:auto; overflow-y:hidden; padding:4px 0; }
  eq { display:inline-block; }
  eqn { display:block; text-align:center; margin:8px 0; overflow-x:auto; overflow-y:hidden; }
  td eq { display:inline-block; }
</style>
</head>
<body>
<div id="md"></div>
<script>$jsMarkdownIt</script>
<script>$jsHighlight</script>
<script>$jsKatex</script>
<script>$jsTexmath</script>
<script>
const SRC = __SRC__;
const md = window.markdownit({ html:false, linkify:true, typographer:true, highlight:function(str, lang){
  if (lang && window.hljs && hljs.getLanguage(lang)) {
    try { return '<pre class="hljs"><code>' + hljs.highlight(str, {language:lang, ignoreIllegals:true}).value + '</code></pre>'; } catch(e) {}
  }
  return '<pre class="hljs"><code>' + md.utils.escapeHtml(str) + '</code></pre>';
}});
// 解析器级公式解析（markdown-it-texmath）：单美元行内 / 双美元块级
// 在 token 层识别，表格/列表/引用内的公式同样可靠渲染——
// 替代原先渲染后 DOM 扫描（auto-render）导致的表格内公式失效问题。
md.use(window.texmath, {
  engine: window.katex,
  delimiters: 'dollars',
  katexOptions: { throwOnError:false, strict:false }
});
const root = document.getElementById('md');
root.innerHTML = md.render(SRC);
</script>
</body>
</html>
''';
      }();
      _templateCache = cached;
    }
    return cached;
  }

  static Future<String> _buildHtml(
    String content, {
    required bool dark,
  }) async {
    final tpl = await _template(dark: dark);
    // 转义 md 原文为安全的 JS 字符串常量（防 </script> 截断与 HTML 注入）
    final src = jsonEncode(content)
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026')
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
    return tpl.replaceFirst('__SRC__', src);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            webViewEnvironment: gWebViewEnvironment,
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: false,
              // Windows：Markdown 预览按"网页"倍率（与终端分开配置）
              scrollMultiplier: webScrollCalibrationEnabled
                  ? WebScrollSettings.instance.webMultiplier
                  : null,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
              // 创建完成后加载 HTML
              _buildHtml(
                widget.content,
                dark: Theme.of(context).brightness == Brightness.dark,
              ).then((html) {
                if (!mounted) return;
                controller.loadData(
                  data: html,
                  mimeType: 'text/html',
                  encoding: 'utf8',
                  baseUrl: WebUri('about:blank'),
                );
              });
            },
            onProgressChanged: (controller, progress) {
              if (mounted) setState(() => _loading = progress < 100);
            },
            shouldOverrideUrlLoading: (controller, action) async {
              final url = action.request.url?.toString() ?? '';
              // 链接（http/https）转交系统浏览器，防止 WebView 内跳走
              if (url.startsWith('http://') || url.startsWith('https://')) {
                launchUrl(Uri.parse(url),
                    mode: LaunchMode.externalApplication);
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onReceivedError: (controller, request, error) {
              if (error.type != WebResourceErrorType.CANCELLED && mounted) {
                setState(() {
                  _loading = false;
                  _error = '渲染失败: ${error.description}';
                });
              }
            },
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 12),
                Text(_error!),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        // 右上角悬浮工具条（替代原 AppBar 操作入口）
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            elevation: 1,
            borderRadius: BorderRadius.circular(18),
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    try {
                      await _controller?.reload();
                    } catch (_) {}
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
