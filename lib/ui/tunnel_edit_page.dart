import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tunnel_config.dart';
import '../services/app_state.dart';
import '../services/log_bus.dart';
import '../services/web_session_manager.dart';

/// 隧道新增/编辑页。
class TunnelEditPage extends StatefulWidget {
  const TunnelEditPage({super.key, this.tunnel});

  final TunnelConfig? tunnel;

  @override
  State<TunnelEditPage> createState() => _TunnelEditPageState();
}

class _TunnelEditPageState extends State<TunnelEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _localPort;
  late final TextEditingController _remoteHost;
  late final TextEditingController _remotePort;

  late String _serverId;
  late bool _autoStart;
  late bool _openOnStart;

  bool get _isEdit => widget.tunnel != null;

  @override
  void initState() {
    super.initState();
    final t = widget.tunnel;
    final app = AppState.instance;
    _name = TextEditingController(text: t?.name ?? '');
    _localPort = TextEditingController(text: (t?.localPort ?? 8080).toString());
    _remoteHost = TextEditingController(text: t?.remoteHost ?? '127.0.0.1');
    _remotePort = TextEditingController(text: (t?.remotePort ?? 8080).toString());
    _serverId = t?.serverId ??
        (app.servers.isNotEmpty ? app.servers.first.id : '');
    _autoStart = t?.autoStart ?? true;
    _openOnStart = t?.openOnStart ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _localPort.dispose();
    _remoteHost.dispose();
    _remotePort.dispose();
    super.dispose();
  }

  String? _validate() {
    final localPort = int.tryParse(_localPort.text);
    final remotePort = int.tryParse(_remotePort.text);
    if (_serverId.isEmpty) return '请先添加服务器';
    if (localPort == null || localPort <= 0 || localPort > 65535) {
      return '本地端口无效';
    }
    if (_remoteHost.text.trim().isEmpty) return '请填写远程主机';
    if (remotePort == null || remotePort <= 0 || remotePort > 65535) {
      return '远程端口无效';
    }
    return null;
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final app = AppState.instance;
    final t = widget.tunnel;
    final tunnel = TunnelConfig(
      id: t?.id,
      serverId: _serverId,
      name: _name.text.trim(),
      localPort: int.parse(_localPort.text),
      remoteHost: _remoteHost.text.trim(),
      remotePort: int.parse(_remotePort.text),
      autoStart: _autoStart,
      openOnStart: _openOnStart,
    );
    if (_isEdit) {
      await app.updateTunnel(tunnel);
    } else {
      await app.addTunnel(tunnel);
    }
    LogBus.instance.info('Config', '已保存隧道 ${tunnel.name}');

    // 服务器已连接且隧道配置为自动启动 → 立即启动，并可选打开 WebUI
    var shouldOpen = false;
    if (tunnel.autoStart) {
      await app.startTunnel(tunnel.id);
      final runtime = app.runtimeOf(tunnel.id);
      if (runtime != null && runtime.isRunning) {
        shouldOpen = tunnel.openOnStart;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (shouldOpen) {
      // 在网页管理界面打开（保活），并切到"网页"Tab
      WebSessionManager.instance.open(
        url: Uri.parse('http://127.0.0.1:${tunnel.localPort}'),
        title: tunnel.name.isEmpty ? tunnel.summary : tunnel.name,
        tunnelId: tunnel.id,
      );
      WebSessionManager.instance.requestTab(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑隧道' : '添加隧道')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _serverId,
            decoration: const InputDecoration(
              labelText: '所属服务器 *',
              border: OutlineInputBorder(),
            ),
            items: app.servers
                .map((s) => DropdownMenuItem(
                      value: s.id,
                      child: Text(
                        s.name.isEmpty ? s.host : s.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _serverId = v ?? ''),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称（可选）',
              hintText: '如: SD WebUI / Jupyter',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _localPort,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '本地端口 *',
                    hintText: '8080',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward),
              ),
              Expanded(
                child: TextFormField(
                  controller: _remotePort,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '远程端口 *',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _remoteHost,
            decoration: const InputDecoration(
              labelText: '远程主机 *',
              hintText: '通常是 127.0.0.1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '浏览器访问地址: http://127.0.0.1:${_localPort.text.isEmpty ? '端口' : _localPort.text}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('服务器连接后自动启动'),
            value: _autoStart,
            onChanged: (v) => setState(() => _autoStart = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启动后自动打开 WebUI'),
            value: _openOnStart,
            onChanged: (v) => setState(() => _openOnStart = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(_isEdit ? '保存修改' : '添加隧道'),
          ),
        ],
      ),
    );
  }
}
