import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/server_config.dart';
import '../models/tunnel_config.dart';
import 'keep_alive_task.dart';
import 'log_bus.dart';
import 'secure_store.dart';
import 'ssh_session.dart';
import 'tunnel_runtime.dart';

/// 全局应用状态：配置 CRUD + 连接编排。
class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  final SecureStore _store = SecureStore.instance;

  List<ServerConfig> servers = [];
  List<TunnelConfig> tunnels = [];
  bool backgroundKeepAlive = false;
  bool loaded = false;

  final Map<String, SshSession> _sessions = {};
  final Map<String, TunnelRuntime> _runtimes = {};

  // ---------------------------------------------------------------------
  // 加载与持久化
  // ---------------------------------------------------------------------

  Future<void> load() async {
    servers = await _store.loadServers();
    tunnels = await _store.loadTunnels();
    backgroundKeepAlive = await _store.loadBackgroundKeepAlive();
    loaded = true;
    notifyListeners();
  }

  Future<void> _persistServers() => _store.saveServers(servers);
  Future<void> _persistTunnels() => _store.saveTunnels(tunnels);

  // ---------------------------------------------------------------------
  // 服务器 CRUD
  // ---------------------------------------------------------------------

  Future<void> addServer(ServerConfig server) async {
    servers.add(server);
    await _persistServers();
    notifyListeners();
  }

  Future<void> updateServer(ServerConfig server) async {
    final i = servers.indexWhere((s) => s.id == server.id);
    if (i < 0) return;
    // 配置变更后，旧连接不再可信：断开并丢弃旧会话（下次连接用新配置）
    await disconnectServer(server.id);
    _sessions.remove(server.id)?.dispose();
    servers[i] = server;
    await _persistServers();
    notifyListeners();
  }

  Future<void> deleteServer(String serverId) async {
    await disconnectServer(serverId);
    // 清理该服务器的隧道
    final removed = tunnels.where((t) => t.serverId == serverId).toList();
    for (final t in removed) {
      _runtimes[t.id]?.dispose();
      _runtimes.remove(t.id);
    }
    tunnels.removeWhere((t) => t.serverId == serverId);
    servers.removeWhere((s) => s.id == serverId);
    _sessions.remove(serverId)?.dispose();
    await _persistServers();
    await _persistTunnels();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // 隧道 CRUD
  // ---------------------------------------------------------------------

  Future<void> addTunnel(TunnelConfig tunnel) async {
    tunnels.add(tunnel);
    await _persistTunnels();
    notifyListeners();
  }

  Future<void> updateTunnel(TunnelConfig tunnel) async {
    final i = tunnels.indexWhere((t) => t.id == tunnel.id);
    if (i < 0) return;
    final rt = _runtimes[tunnel.id];
    if (rt != null) {
      await rt.stop();
      rt.dispose();
      _runtimes.remove(tunnel.id);
    }
    tunnels[i] = tunnel;
    await _persistTunnels();
    notifyListeners();
  }

  Future<void> deleteTunnel(String tunnelId) async {
    final rt = _runtimes.remove(tunnelId);
    if (rt != null) {
      await rt.stop();
      rt.dispose();
    }
    tunnels.removeWhere((t) => t.id == tunnelId);
    await _persistTunnels();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // 连接编排
  // ---------------------------------------------------------------------

  SshSession? sessionOf(String serverId) => _sessions[serverId];

  TunnelRuntime? runtimeOf(String tunnelId) => _runtimes[tunnelId];

  Future<void> connectServer(String serverId) async {
    final server = servers.firstWhere((s) => s.id == serverId);
    var session = _sessions[serverId];
    if (session == null) {
      session = SshSession(server);
      _sessions[serverId] = session;
      session.addListener(() => _onSessionChanged(serverId));
    }
    await session.connect();
    // 连接过程中可能记录了主机密钥指纹，持久化
    await _persistServers();
  }

  Future<void> disconnectServer(String serverId) async {
    await _stopTunnelsOf(serverId);
    await _sessions[serverId]?.disconnect();
  }

  Future<void> _onSessionChanged(String serverId) async {
    final session = _sessions[serverId];
    if (session == null) return;
    if (session.isConnected) {
      // 重连成功：恢复自动启动的隧道
      for (final t in tunnels.where(
        (t) => t.serverId == serverId && t.autoStart,
      )) {
        _runtimes[t.id]?.dispose();
        _runtimes.remove(t.id);
        await startTunnel(t.id);
      }
    } else if (session.status != SshStatus.connecting) {
      await _stopTunnelsOf(serverId);
    }
    notifyListeners();
  }

  Future<void> _stopTunnelsOf(String serverId) async {
    for (final t in tunnels.where((t) => t.serverId == serverId)) {
      final rt = _runtimes[t.id];
      if (rt != null) await rt.stop();
    }
  }

  Future<void> startTunnel(String tunnelId) async {
    final tunnel = tunnels.firstWhere((t) => t.id == tunnelId);
    final session = _sessions[tunnel.serverId];
    if (session == null || !session.isConnected) {
      LogBus.instance
          .warn('Tunnel', '${tunnel.name}: 请先连接服务器 ${tunnel.serverId}');
      return;
    }
    var rt = _runtimes[tunnelId];
    if (rt == null) {
      rt = TunnelRuntime(tunnel, session);
      _runtimes[tunnelId] = rt;
    }
    await rt.start();
    notifyListeners();
  }

  Future<void> stopTunnel(String tunnelId) async {
    await _runtimes[tunnelId]?.stop();
    notifyListeners();
  }

  /// 应用启动后：自动连接标记了 autoConnect 的服务器。
  Future<void> applyAutoConnect() async {
    for (final s in servers.where((s) => s.autoConnect)) {
      await connectServer(s.id);
    }
  }

  // ---------------------------------------------------------------------
  // 后台保活（前台服务）
  // ---------------------------------------------------------------------

  Future<void> setBackgroundKeepAlive(bool on) async {
    // 前台服务是 Android 专属能力（Windows/桌面端无此概念）
    if (!Platform.isAndroid) {
      backgroundKeepAlive = false;
      await _store.saveBackgroundKeepAlive(false);
      notifyListeners();
      return;
    }
    backgroundKeepAlive = on;
    await _store.saveBackgroundKeepAlive(on);
    if (on) {
      await FlutterForegroundTask.requestNotificationPermission();
      await FlutterForegroundTask.startService(
        notificationTitle: 'SSH Agent',
        notificationText: 'SSH 隧道保活中',
        callback: keepAliveTask,
      );
      LogBus.instance.info('Service', '前台保活服务已启动');
    } else {
      await FlutterForegroundTask.stopService();
      LogBus.instance.info('Service', '前台保活服务已停止');
    }
    notifyListeners();
  }

  /// 应用启动时恢复保活服务（若上次开启过）。
  Future<void> restoreBackgroundKeepAlive() async {
    if (backgroundKeepAlive) {
      await setBackgroundKeepAlive(true);
    }
  }
}
