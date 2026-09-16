import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/styles/all.dart';

import '../services/font_config.dart';

/// 远程文本/代码文件查看器（只读，无 Scaffold，可嵌入标签页）。
///
/// 基于 re_editor：虚拟化渲染（大文件流畅滚动）、语法高亮
/// （re_highlight，100+ 语言）、行号、深浅色主题跟随系统。
///
/// 注意：父级应通过 [key] 区分不同文件/同一文件的不同版本
/// （如刷新后重建），本组件在 State 内自持 [CodeLineEditingController]。
class RemoteTextView extends StatefulWidget {
  const RemoteTextView({
    super.key,
    required this.name,
    required this.content,
    this.fontPref = ViewerFontPref.mono,
  });

  final String name;
  final String content;
  final ViewerFontPref fontPref;

  @override
  State<RemoteTextView> createState() => _RemoteTextViewState();
}

class _RemoteTextViewState extends State<RemoteTextView> {
  late final CodeLineEditingController _controller;

  int get _lineCount => '\n'.allMatches(widget.content).length + 1;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController.fromText(widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 按文件扩展名匹配 re_highlight 语言名。
  static String? _langFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower == 'dockerfile') return 'dockerfile';
    if (lower == 'makefile') return 'makefile';
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = lower.substring(dot + 1);
    const map = <String, String>{
      'dart': 'dart',
      'py': 'python',
      'js': 'javascript',
      'mjs': 'javascript',
      'jsx': 'javascript',
      'ts': 'typescript',
      'tsx': 'typescript',
      'go': 'go',
      'java': 'java',
      'c': 'c',
      'h': 'c',
      'cpp': 'cpp',
      'hpp': 'cpp',
      'cc': 'cpp',
      'cxx': 'cpp',
      'rs': 'rust',
      'rb': 'ruby',
      'php': 'php',
      'sh': 'bash',
      'bash': 'bash',
      'zsh': 'bash',
      'yaml': 'yaml',
      'yml': 'yaml',
      'json': 'json',
      'xml': 'xml',
      'html': 'xml',
      'htm': 'xml',
      'vue': 'xml',
      'svg': 'xml',
      'css': 'css',
      'scss': 'scss',
      'less': 'less',
      'md': 'markdown',
      'sql': 'sql',
      'toml': 'ini',
      'ini': 'ini',
      'conf': 'ini',
      'cfg': 'ini',
      'properties': 'properties',
      'env': 'properties',
      'txt': 'plaintext',
      'log': 'plaintext',
      'kt': 'kotlin',
      'kts': 'kotlin',
      'swift': 'swift',
      'lua': 'lua',
      'pl': 'perl',
      'ps1': 'powershell',
      'proto': 'protobuf',
      'gradle': 'groovy',
      'groovy': 'groovy',
      'graphql': 'graphql',
    };
    return map[ext];
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lang = _langFor(widget.name);
    final mode = lang == null ? null : builtinAllLanguages[lang];
    final highlight =
        (lang != null && mode != null)
            ? CodeHighlightTheme(
                languages: {
                  lang: CodeHighlightThemeMode(mode: mode),
                },
                theme: dark
                    ? builtinAllThemes['atom-one-dark']!
                    : builtinAllThemes['atom-one-light']!,
              )
            : null;
    final fonts = viewerFonts(widget.fontPref);

    return Stack(
      children: [
        Positioned.fill(
          child: CodeEditor(
            controller: _controller,
            readOnly: true,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            style: CodeEditorStyle(
              fontSize: 13,
              fontFamily: fonts.fontFamily,
              fontFamilyFallback: fonts.fallback,
              codeTheme: highlight,
            ),
            indicatorBuilder: (context, editingController, chunkController,
                    notifier) =>
                Row(
              children: [
                DefaultCodeLineNumber(
                  controller: editingController,
                  notifier: notifier,
                ),
                DefaultCodeChunkIndicator(
                  width: 20,
                  controller: chunkController,
                  notifier: notifier,
                ),
              ],
            ),
          ),
        ),
        // 右下角行数角标（替代原 AppBar 标题栏的位置）
        Positioned(
          right: 8,
          bottom: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$_lineCount 行',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ),
      ],
    );
  }
}
