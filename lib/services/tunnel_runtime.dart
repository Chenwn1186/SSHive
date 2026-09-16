import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/tunnel_config.dart';
import 'log_bus.dart';
import 'ssh_session.dart';

enum TunnelStatus { stopped, starting, running, error }

/// 单个端口转发隧道的运行时。
///
/// 在手机本机 127.0.0.1:localPort 上监听 TCP，每个接入连接
/// 通过 SSH 通道 [SshSession.forwardLocal] 转发到远程 host:port。
class TunnelRuntime extends ChangeNotifier {
  TunnelRuntime(this.config, this.session) {
    _sessionListener = () => _onSessionChanged();
    session.addListener(_sessionListener);
  }

  final TunnelConfig config;
  final SshSession session;
  late final VoidCallback _sessionListener;

  TunnelStatus _status = TunnelStatus.stopped;
  String? _error;
  ServerSocket? _server;
  int _connections = 0;
  bool _disposed = false;

  TunnelStatus get status => _status;
  bool get isRunning => _status == TunnelStatus.running;
  String? get error => _error;
  int get connectionCount => _connections;

  Future<void> start() async {
    if (_disposed) return;
    if (_status == TunnelStatus.starting || _status == TunnelStatus.running) {
      return;
    }
    if (!session.isConnected) {
      _status = TunnelStatus.error;
      _error = '服务器未连接';
      notifyListeners();
      LogBus.instance.warn('Tunnel', '${config.name}: 服务器未连接，无法启动');
      return;
    }
    _status = TunnelStatus.starting;
    _error = null;
    notifyListeners();
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        config.localPort,
      );
      _server = server;
      _status = TunnelStatus.running;
      _connections = 0;
      notifyListeners();
      LogBus.instance.info(
        'Tunnel',
        '${config.name}: 监听 127.0.0.1:${config.localPort} '
            '→ ${config.remoteHost}:${config.remotePort}',
      );
      server.listen(_onClient, onError: (Object e) {
        LogBus.instance.error('Tunnel', '${config.name}: 监听异常: $e');
      });
    } catch (e) {
      _server = null;
      _status = TunnelStatus.error;
      _error = '$e';
      notifyListeners();
      LogBus.instance.error('Tunnel', '${config.name}: 启动失败: $e');
    }
  }

  Future<void> _onClient(Socket client) async {
    _connections++;
    notifyListeners();
    try {
      final forward = await session.forwardLocal(
        config.remoteHost,
        config.remotePort,
      );
      // 双向管道：本地 socket <-> SSH 转发通道
      // （SSHForwardChannel 的 stream 是 Stream<Uint8List>，
      //   sink 是 StreamSink<List<int>>，需要桥接类型）
      final bridge = StreamController<Uint8List>();
      client.pipe(bridge.sink);
      bridge.stream.listen(
        (data) => forward.sink.add(data),
        onDone: () => forward.close(),
        onError: (Object e) => forward.destroy(),
      );
      forward.stream.cast<List<int>>().pipe(client);
      // 任一端关闭则清理另一端
      client.done.then((_) => forward.close()).catchError((_) {});
      forward.done.then((_) => client.destroy()).catchError((_) {});
    } catch (e) {
      LogBus.instance.error(
        'Tunnel',
        '${config.name}: 转发通道建立失败: $e',
      );
      client.destroy();
    }
  }

  void _onSessionChanged() {
    // 底层 SSH 断开（非重连中）时，隧道随之停止
    if (_disposed) return;
    if (_status != TunnelStatus.stopped &&
        !session.isConnected &&
        session.status != SshStatus.connecting) {
      stop();
      LogBus.instance.info('Tunnel', '${config.name}: SSH 断开，隧道已停止');
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
    _status = TunnelStatus.stopped;
    _error = null;
    notifyListeners();
    LogBus.instance.info('Tunnel', '${config.name}: 已停止');
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_sessionListener);
    _server?.close();
    super.dispose();
  }
}
