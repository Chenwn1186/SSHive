import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/server_config.dart';
import '../services/app_state.dart';
import '../services/log_bus.dart';
import '../services/ssh_session.dart';

/// 服务器新增/编辑页。
class ServerEditPage extends StatefulWidget {
  const ServerEditPage({super.key, this.server});

  final ServerConfig? server;

  @override
  State<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends State<ServerEditPage> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late final TextEditingController _keepalive;
  late final TextEditingController _socksPort;

  late String _authType;
  late bool _autoConnect;
  late bool _autoReconnect;
  bool _obscurePassword = true;
  bool _testing = false;

  bool get _isEdit => widget.server != null;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _name = TextEditingController(text: s?.name ?? '');
    _host = TextEditingController(text: s?.host ?? '');
    _port = TextEditingController(text: (s?.port ?? 22).toString());
    _username = TextEditingController(text: s?.username ?? '');
    _password = TextEditingController(text: s?.password ?? '');
    _privateKey = TextEditingController(text: s?.privateKey ?? '');
    _passphrase = TextEditingController(text: s?.passphrase ?? '');
    _keepalive = TextEditingController(text: (s?.keepaliveSeconds ?? 30).toString());
    _socksPort = TextEditingController(text: (s?.socksPort ?? 0).toString());
    _authType = s?.authType ?? 'password';
    _autoConnect = s?.autoConnect ?? false;
    _autoReconnect = s?.autoReconnect ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    _keepalive.dispose();
    _socksPort.dispose();
    super.dispose();
  }

  ServerConfig _buildConfig() {
    final s = widget.server;
    return ServerConfig(
      id: s?.id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text) ?? 22,
      username: _username.text.trim(),
      authType: _authType,
      password: _authType == 'password' ? _password.text : null,
      privateKey: _authType == 'key' ? _privateKey.text : null,
      passphrase: _authType == 'key' ? _passphrase.text : null,
      keepaliveSeconds: int.tryParse(_keepalive.text) ?? 30,
      autoConnect: _autoConnect,
      autoReconnect: _autoReconnect,
      hostFingerprint: s?.hostFingerprint,
      socksPort: int.tryParse(_socksPort.text) ?? 0,
    );
  }

  String? _validate() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text);
    final username = _username.text.trim();
    if (host.isEmpty) return '请填写主机地址';
    if (port == null || port <= 0 || port > 65535) return '端口无效';
    if (username.isEmpty) return '请填写用户名';
    if (_authType == 'password' && _password.text.isEmpty) {
      return '请填写密码';
    }
    if (_authType == 'key' && _privateKey.text.trim().isEmpty) {
      return '请粘贴私钥内容（PEM 格式）';
    }
    final keepalive = int.tryParse(_keepalive.text);
    if (keepalive == null || keepalive < 0) return 'keepalive 间隔无效';
    final socks = int.tryParse(_socksPort.text);
    if (socks == null || socks < 0 || socks > 65535) return 'SOCKS5 端口无效';
    return null;
  }

  Future<void> _testConnection() async {
    final err = _validate();
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() => _testing = true);
    final server = _buildConfig();
    final session = SshSession(server);
    try {
      await session.connect();
      if (!mounted) return;
      if (session.isConnected) {
        _snack('连接成功！主机指纹: ${session.hostFingerprint}');
        await session.disconnect();
      } else {
        _snack('连接失败: ${session.error}');
      }
    } catch (e) {
      if (mounted) _snack('连接失败: $e');
    } finally {
      session.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      _snack(err);
      return;
    }
    final app = AppState.instance;
    final server = _buildConfig();
    if (_isEdit) {
      await app.updateServer(server);
    } else {
      await app.addServer(server);
    }
    LogBus.instance.info('Config', '已保存服务器 ${server.name}');
    if (mounted) Navigator.of(context).pop();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑服务器' : '添加服务器'),
        actions: [
          TextButton(
            onPressed: _testing ? null : _testConnection,
            child: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('测试连接'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                hintText: '如: 我的 NAS',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: '主机地址 *',
                hintText: 'IP 或域名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '端口 *',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: '用户名 *',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'password',
                  label: Text('密码登录'),
                  icon: Icon(Icons.password),
                ),
                ButtonSegment(
                  value: 'key',
                  label: Text('私钥登录'),
                  icon: Icon(Icons.key),
                ),
              ],
              selected: {_authType},
              onSelectionChanged: (v) => setState(() => _authType = v.first),
            ),
            const SizedBox(height: 12),
            if (_authType == 'password')
              TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: '密码 *',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              )
            else ...[
              TextFormField(
                controller: _privateKey,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '私钥（PEM）*',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密钥口令（可选）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _keepalive,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'keepalive 秒（0=关）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _socksPort,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'SOCKS5 端口（0=关）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('应用启动后自动连接'),
              value: _autoConnect,
              onChanged: (v) => setState(() => _autoConnect = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('断线自动重连'),
              subtitle: const Text('2s/5s/10s/30s 退避重试'),
              value: _autoReconnect,
              onChanged: (v) => setState(() => _autoReconnect = v),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(_isEdit ? '保存修改' : '添加服务器'),
            ),
          ],
        ),
      ),
    );
  }
}
