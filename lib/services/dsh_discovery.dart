import 'dart:async';
import 'dart:io';

import '../models/tunnel_config.dart';
import 'app_state.dart';
import 'log_bus.dart';

/// 服务器上的 deepseek harness（dsh-web）访问地址。
///
/// 地址从服务器 journald 日志中提取（最后一条带 token 的地址），
/// 再尝试映射为经本地隧道访问的地址。
class DshEndpoint {
  DshEndpoint({
    required this.serverId,
    required this.serverName,
    required this.rawUrl,
  });

  final String serverId;
  final String serverName;

  /// 服务器日志中取到的原始地址（自带 token 参数）
  final Uri rawUrl;

  /// 经本地隧道映射后的可用地址（尚无隧道时为 null）
  String? localUrl;

  /// 复用的/新建的隧道本地端口
  int? localPort;

  /// 匹配/新建的隧道 id（用于确认隧道确实在跑）
  String? tunnelId;

  /// 本地隧道是否已就绪（仅表示地址可拼出来，不代表隧道正在监听，
  /// 真正可用性由 [DshDiscovery.ensureLocalUrl] 保证）
  bool get tunnelReady => localUrl != null;

  /// 服务器上 dsh-web 的监听端口
  int get port => rawUrl.hasPort
      ? rawUrl.port
      : (rawUrl.scheme == 'https' ? 443 : 80);
}

/// 自动发现 dsh-web（DeepSeek Harness Web）最新访问地址。
///
/// 依赖服务器上以 user 服务方式运行的 `dsh-web`（journalctl --user -u dsh-web）。
class DshDiscovery {
  DshDiscovery._();

  /// 从 journald 日志中取最后一条带 token 的 http 地址。
  static const String journalCommand =
      "journalctl --user -u dsh-web --no-pager 2>/dev/null | "
      "grep -oE 'http://[^ ]*token=[A-Za-z0-9_-]+' | tail -1";

  /// dsh-web 是否正在运行。
  ///
  /// journal 里永远留着**上一次**启动的地址，服务停了也照样能 grep 到，
  /// 不检查就会把一个连不上的地址交给调用方。`systemctl --user` 依赖
  /// XDG_RUNTIME_DIR，而 app 发起的是非交互 SSH（没有这个变量，会直接
  /// 报 "Failed to connect to bus"），所以这里按 uid 现补。
  static const String activeCommand =
      'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user is-active dsh-web';

  /// 在指定服务器上查询 dsh-web 地址；查不到返回 null（不抛异常）。
  static Future<DshEndpoint?> fetch(
    String serverId,
    String serverName,
  ) async {
    final session = AppState.instance.sessionOf(serverId);
    if (session == null || !session.isConnected) return null;
    try {
      final active = (await session.runCommand(activeCommand)).trim();
      if (active != 'active') {
        LogBus.instance.warn(
          'DSH',
          '$serverName: dsh-web 未运行（当前状态「$active」），'
          '日志里的地址是上次启动留下的，不可用',
        );
        return null;
      }
      final out = await session.runCommand(journalCommand);
      final url = extractUrl(out);
      if (url == null) {
        LogBus.instance.debug('DSH', '$serverName: 日志中未找到 dsh-web 地址');
        return null;
      }
      final ep = DshEndpoint(
        serverId: serverId,
        serverName: serverName,
        rawUrl: url,
      );
      matchExistingTunnel(ep);
      LogBus.instance.info(
        'DSH',
        '$serverName: 发现 dsh-web 地址 ${url.host}:${url.port}'
        '${ep.tunnelReady ? '（隧道就绪 127.0.0.1:${ep.localPort}）' : ''}',
      );
      return ep;
    } catch (e) {
      LogBus.instance.warn('DSH', '$serverName: 获取 dsh-web 地址失败: $e');
      return null;
    }
  }

  /// 从命令输出中解析出带 token 的地址（取最后一条，即最新启动的实例）。
  static Uri? extractUrl(String output) {
    final matches =
        RegExp(r'http://\S*token=[A-Za-z0-9_-]+').allMatches(output);
    if (matches.isEmpty) return null;
    return Uri.tryParse(matches.last.group(0)!);
  }

  /// 若已有端口匹配的隧道，直接映射为本机地址（无需新建）。
  ///
  /// 只认目标为回环地址的隧道：dsh-web 只监听服务器的 127.0.0.1，
  /// 目标写成服务器内网 IP（如 172.18.168.30）的隧道必然连不上。
  static void matchExistingTunnel(DshEndpoint ep) {
    for (final t in AppState.instance.tunnels.where((t) =>
        t.serverId == ep.serverId &&
        t.remotePort == ep.port &&
        isLoopbackHost(t.remoteHost))) {
      ep.tunnelId = t.id;
      ep.localPort = t.localPort;
      ep.localUrl = buildLocalUrl(ep.rawUrl, t.localPort);
      return;
    }
  }

  /// 主机名是否为回环地址。
  static bool isLoopbackHost(String host) {
    final h = host.trim().toLowerCase();
    return h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '[::1]';
  }

  /// 构造本机访问地址（保留原 path 与 query，token 不丢）。
  static String buildLocalUrl(Uri raw, int localPort) {
    final scheme = raw.scheme.isEmpty ? 'http' : raw.scheme;
    final path = raw.path.isEmpty ? '/' : raw.path;
    final query = raw.hasQuery ? '?${raw.query}' : '';
    return '$scheme://127.0.0.1:$localPort$path$query';
  }

  /// 确保该地址可在本机访问：复用已有隧道（没在跑就先启动），
  /// 否则按需新建并启动一条；隧道没有真正监听时抛异常，
  /// 而不是把一个打不开的地址返回给调用方。
  static Future<String> ensureLocalUrl(DshEndpoint ep) async {
    final app = AppState.instance;
    var tunnelId = ep.tunnelId;
    var localPort = ep.localPort;

    if (tunnelId == null || localPort == null) {
      final port = await _pickFreeLocalPort(ep.port);
      if (port == null) {
        throw StateError(
            '${ep.port} 起始的 60 个本地端口均已占用，无法建立隧道');
      }
      final tunnel = TunnelConfig(
        serverId: ep.serverId,
        name: 'dsh-web (${ep.serverName})',
        localPort: port,
        remoteHost: '127.0.0.1',
        remotePort: ep.port,
        autoStart: true,
        openOnStart: false,
      );
      await app.addTunnel(tunnel);
      tunnelId = tunnel.id;
      localPort = port;
      ep.tunnelId = tunnelId;
      ep.localPort = localPort;
      LogBus.instance.info(
        'DSH',
        '已为 dsh-web 建立隧道 127.0.0.1:$localPort → 127.0.0.1:${ep.port}',
      );
    }

    // SSH 断开时隧道会被整体停掉（AppState._stopTunnelsOf），
    // 但配置仍然存在——不启动就直接开地址，页面只会卡在加载中。
    if (!(app.runtimeOf(tunnelId)?.isRunning ?? false)) {
      await app.startTunnel(tunnelId);
      LogBus.instance.info('DSH', '隧道 127.0.0.1:$localPort 未运行，已尝试启动');
    }
    await _waitListening(localPort);
    if (!await _isListening(localPort)) {
      throw StateError(
          '隧道 127.0.0.1:$localPort 未监听（服务器未连接或启动失败）');
    }

    ep.localUrl = buildLocalUrl(ep.rawUrl, localPort);
    return ep.localUrl!;
  }

  /// 选一个空闲的本地端口（从首选端口向后探测）；全都占用返回 null。
  static Future<int?> _pickFreeLocalPort(int preferred) async {
    for (var p = preferred; p < preferred + 60 && p < 65535; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {
        // 端口被占用，继续探测下一个
      }
    }
    return null;
  }

  /// 等待本地端口开始监听（最多约 4 秒）。
  static Future<void> _waitListening(int port) async {
    for (var i = 0; i < 20; i++) {
      if (await _isListening(port)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static Future<bool> _isListening(int port) async {
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 300),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
