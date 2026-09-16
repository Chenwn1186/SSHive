import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/server_config.dart';
import '../models/tunnel_config.dart';
import '../services/app_state.dart';
import '../services/log_bus.dart';
import '../services/ssh_command_parser.dart';
import 'server_edit_page.dart';

/// 粘贴一条 ssh 命令（如 `ssh -L 8080:localhost:80 -p 2222 user@example.com`），
/// 自动解析并生成服务器 + 端口转发隧道配置。
class ImportSshPage extends StatefulWidget {
  const ImportSshPage({super.key});

  @override
  State<ImportSshPage> createState() => _ImportSshPageState();
}

class _ImportSshPageState extends State<ImportSshPage> {
  final _controller = TextEditingController();

  ParsedSshCommand? _parsed;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse(String text) {
    final t = text.trim();
    if (t.isEmpty) {
      setState(() {
        _parsed = null;
        _error = null;
      });
      return;
    }
    try {
      final r = parseSshCommand(t);
      setState(() {
        _parsed = r;
        _error = null;
      });
    } on SshCommandFormatException catch (e) {
      setState(() {
        _parsed = null;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _parsed = null;
        _error = '解析失败: $e';
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text == null || data!.text!.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('剪贴板没有文本')));
      return;
    }
    _controller.text = data.text!;
    _parse(data.text!);
  }

  Future<void> _confirmImport() async {
    final parsed = _parsed;
    if (parsed == null || parsed.host == null) return;

    final app = AppState.instance;
    final server = ServerConfig(
      name: parsed.username != null
          ? '${parsed.username}@${parsed.host}'
          : parsed.host!,
      host: parsed.host!,
      port: parsed.port,
      username: parsed.username ?? '',
      authType: 'password',
      password: '',
      keepaliveSeconds: 30,
      autoConnect: false,
      autoReconnect: true,
      socksPort: parsed.socksPort ?? 0,
    );
    await app.addServer(server);

    for (final t in parsed.tunnels) {
      await app.addTunnel(TunnelConfig(
        serverId: server.id,
        name: '${t.remoteHost}:${t.remotePort}',
        localPort: t.localPort,
        remoteHost: t.remoteHost,
        remotePort: t.remotePort,
        autoStart: true,
        openOnStart: false,
      ));
    }

    LogBus.instance.info(
      'Import',
      '已从 ssh 命令导入服务器 ${server.host}:${server.port}'
      '，${parsed.tunnels.length} 条隧道'
      '${parsed.socksPort != null ? '，SOCKS5:${parsed.socksPort}' : ''}',
    );

    if (!mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    nav.pop();
    // 引导用户去填密码
    await nav.push(MaterialPageRoute(
      builder: (_) => ServerEditPage(server: server),
    ));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('配置已导入，请填写密码后连接')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parsed = _parsed;

    return Scaffold(
      appBar: AppBar(title: const Text('从 ssh 命令导入')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _controller,
                  maxLines: 4,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    hintText:
                        'ssh -L 8080:localhost:80 -L 8443:localhost:443 '
                        '-p 2222 user@example.com',
                    hintStyle: const TextStyle(fontSize: 12),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: '清空',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _parse('');
                      },
                    ),
                  ),
                  onChanged: _parse,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('粘贴剪贴板'),
                  ),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  )
                else if (parsed != null)
                  _ImportPreview(parsed: parsed),
                const SizedBox(height: 8),
                Text(
                  '支持: 多个 -L 转发、-D SOCKS5、-p 端口、user@host。\n'
                  '导入后会创建服务器和隧道，并引导你填写密码。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: parsed == null || parsed.host == null
                    ? null
                    : _confirmImport,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  parsed == null
                      ? '等待解析…'
                      : '确认导入（${parsed.tunnels.length} 条隧道'
                          '${parsed.socksPort != null ? ' + SOCKS5' : ''}）',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.parsed});

  final ParsedSshCommand parsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(
              parsed.username != null
                  ? '${parsed.username}@${parsed.host}'
                  : parsed.host!,
            ),
            subtitle: Text('端口 ${parsed.port}'
                '${parsed.socksPort != null ? ' · SOCKS5:${parsed.socksPort}' : ''}'),
            trailing: const Icon(Icons.check_circle, color: Colors.green),
          ),
        ),
        const SizedBox(height: 8),
        for (final t in parsed.tunnels)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.hub_outlined, size: 20),
              title: Text('${t.localPort} → ${t.remoteHost}:${t.remotePort}'),
              subtitle: Text('访问地址 http://127.0.0.1:${t.localPort}'),
              trailing: const Icon(Icons.check_circle, size: 18,
                  color: Colors.green),
            ),
          ),
        if (parsed.warnings.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in parsed.warnings)
                  Text(
                    '⚠ $w',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
