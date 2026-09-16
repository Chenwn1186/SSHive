import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/server_config.dart';
import 'log_bus.dart';

enum SshStatus { disconnected, connecting, connected, error }

/// 单个服务器的 SSH 连接会话。
///
/// 职责：建立/断开连接（密码、私钥或 keyboard-interactive 认证）、
/// 主机密钥 TOFU 校验、内置 keepalive、断线自动重连（退避重试）、
/// 可选的 SOCKS5 动态代理、对外提供端口转发通道 [forwardLocal]。
///
/// 注：dartssh2 2.x 的 keepalive 由 SSHClient 构造参数 keepAliveInterval
/// 内置管理（认证成功后自动启动），无需外部定时器。
class SshSession extends ChangeNotifier {
  SshSession(this.server);

  final ServerConfig server;

  SSHClient? _client;
  SSHDynamicForward? _socks;
  SftpClient? _sftp;
  SshStatus _status = SshStatus.disconnected;
  String? _error;
  String? _hostFingerprint;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _manualDisconnect = false;

  SshStatus get status => _status;
  bool get isConnected => _status == SshStatus.connected && _client != null;
  String? get error => _error;
  String? get hostFingerprint => _hostFingerprint;

  /// 手动发起连接（同时用于自动重连）。
  Future<void> connect() async {
    if (_status == SshStatus.connecting) return;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();

    _setStatus(SshStatus.connecting, null);
    try {
      final socket = await SSHSocket.connect(
        server.host,
        server.port,
        timeout: const Duration(seconds: 20),
      );
      final client = SSHClient(
        socket,
        username: server.username,
        // 密码认证
        onPasswordRequest: () => server.password,
        // keyboard-interactive 认证（部分服务器仅支持这种方式）
        onUserInfoRequest: (request) => List<String>.filled(
          request.prompts.length,
          server.password ?? '',
        ),
        // 服务器要求修改密码时提示（不支持交互式改密，直接跳过）
        onChangePasswordRequest: (prompt) {
          LogBus.instance.warn('SSH', '${server.name}: 服务器要求修改密码: $prompt');
          return null;
        },
        // 私钥认证（支持加密私钥）
        identities: server.useKey && (server.privateKey ?? '').isNotEmpty
            ? SSHKeyPair.fromPem(server.privateKey!, server.passphrase)
            : null,
        // 主机密钥 TOFU 校验
        onVerifyHostKey: _verifyHostKey,
        // 内置 keepalive（认证成功后自动开始）
        keepAliveInterval: server.keepaliveSeconds > 0
            ? Duration(seconds: server.keepaliveSeconds)
            : null,
        handshakeTimeout: const Duration(seconds: 20),
        authTimeout: const Duration(seconds: 30),
      );

      // 等待认证完成（失败会在此抛出异常）
      await client.authenticated;

      _client = client;
      _reconnectAttempt = 0;
      _setStatus(SshStatus.connected, null);
      LogBus.instance.info(
        'SSH',
        '${server.name}: 已连接 ${server.host}:${server.port}',
      );
      _startSocks();
      _watchConnection();
    } catch (e) {
      _client = null;
      _socks = null;
      LogBus.instance.error('SSH', '${server.name}: 连接失败: $e');
      _setStatus(SshStatus.error, '$e');
      _scheduleReconnect();
    }
  }

  /// 主机密钥校验：首次连接记录指纹（TOFU），之后比对，不匹配则拒绝。
  Future<bool> _verifyHostKey(String name, Uint8List fingerprint) async {
    final fp = utf8.decode(fingerprint);
    _hostFingerprint = fp;
    final stored = server.hostFingerprint;
    if (stored == null || stored.isEmpty) {
      server.hostFingerprint = fp;
      LogBus.instance.info(
        'SSH',
        '${server.name}: 首次连接，记录主机密钥 $name 指纹 $fp',
      );
      return true;
    }
    if (stored == fp) {
      LogBus.instance.debug(
        'SSH',
        '${server.name}: 主机密钥 $name 指纹校验通过 $fp',
      );
      return true;
    }
    LogBus.instance.error(
      'SSH',
      '${server.name}: 主机密钥指纹不匹配！\n'
      '已记录: $stored\n当前: $fp\n可能遭受中间人攻击，已拒绝连接',
    );
    return false;
  }

  /// 启动可选的 SOCKS5 动态代理（ssh -D 等效）。
  Future<void> _startSocks() async {
    if (server.socksPort <= 0) return;
    final c = _client;
    if (c == null) return;
    try {
      _socks = await c.forwardDynamic(bindPort: server.socksPort);
      LogBus.instance.info(
        'SSH',
        '${server.name}: SOCKS5 代理已启动 127.0.0.1:${server.socksPort}',
      );
    } catch (e) {
      _socks = null;
      LogBus.instance.error('SSH', '${server.name}: SOCKS5 代理启动失败: $e');
    }
  }

  /// 主动断开（不触发自动重连）。
  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    final c = _client;
    _client = null;
    final socks = _socks;
    _socks = null;
    _sftp = null;
    if (socks != null) {
      try {
        await socks.close();
      } catch (_) {}
    }
    if (c != null && !c.isClosed) {
      try {
        c.close();
        await c.done.timeout(const Duration(seconds: 5));
      } catch (e) {
        LogBus.instance.debug('SSH', '${server.name}: 断开时异常: $e');
      }
    }
    _setStatus(SshStatus.disconnected, null);
    LogBus.instance.info('SSH', '${server.name}: 已断开');
  }

  /// 建立本地端口转发通道（由 TunnelRuntime 调用）。
  Future<SSHForwardChannel> forwardLocal(String host, int port) async {
    final c = _client;
    if (c == null || c.isClosed) {
      throw StateError('SSH 未连接，无法建立转发通道');
    }
    return c.forwardLocal(host, port);
  }

  /// 获取 SFTP 客户端（懒创建）。断线/重连后自动重建，调用方应
  /// 在每次操作失败（SSH 断开）后重新获取。
  Future<SftpClient> sftp() async {
    final c = _client;
    if (c == null || c.isClosed) {
      throw StateError('SSH 未连接，无法建立 SFTP 会话');
    }
    var s = _sftp;
    if (s != null) return s;
    s = await c.sftp();
    _sftp = s;
    LogBus.instance.info('SSH', '${server.name}: SFTP 会话已建立');
    return s;
  }

  /// 建立 PTY 远程终端会话。
  Future<SSHSession> shell({
    int cols = 80,
    int rows = 24,
    int pixelWidth = 800,
    int pixelHeight = 600,
  }) async {
    final c = _client;
    if (c == null || c.isClosed) {
      throw StateError('SSH 未连接，无法打开终端');
    }
    return c.shell(
      pty: SSHPtyConfig(
        type: 'xterm-256color',
        width: cols,
        height: rows,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------

  /// 监听连接被动关闭（网络中断、服务器踢线等）。
  void _watchConnection() {
    final c = _client;
    if (c == null) return;
    unawaited(c.done.then((_) {
      _onConnectionLost(c, null);
    }, onError: (Object e) {
      _onConnectionLost(c, e);
    }));
  }

  void _onConnectionLost(SSHClient c, Object? error) {
    if (_client != c) return;
    _client = null;
    _socks = null;
    _sftp = null;
    LogBus.instance.warn(
      'SSH',
      '${server.name}: 连接${error == null ? '已断开' : '异常断开: $error'}',
    );
    _setStatus(SshStatus.disconnected, null);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || !server.autoReconnect) return;
    _reconnectTimer?.cancel();
    final delay = const [2, 5, 10, 30][min(_reconnectAttempt, 3)];
    _reconnectAttempt++;
    LogBus.instance.info(
      'SSH',
      '${server.name}: ${delay}s 后自动重连（第 $_reconnectAttempt 次）',
    );
    _reconnectTimer = Timer(Duration(seconds: delay), connect);
  }

  void _setStatus(SshStatus status, String? error) {
    _status = status;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _client = null;
    _socks = null;
    _sftp = null;
    super.dispose();
  }
}
