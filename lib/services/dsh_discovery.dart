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

  /// 本地隧道是否已就绪（可直接在应用内打开）
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

  /// 在指定服务器上查询 dsh-web 地址；查不到返回 null（不抛异常）。
  static Future<DshEndpoint?> fetch(
    String serverId,
    String serverName,
  ) async {
    final session = AppState.instance.sessionOf(serverId);
    if (session == null || !session.isConnected) return null;
    try {
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
  static void matchExistingTunnel(DshEndpoint ep) {
    for (final t in AppState.instance.tunnels
        .where((t) => t.serverId == ep.serverId)) {
      if (t.remotePort == ep.port) {
        ep.localPort = t.localPort;
        ep.localUrl = buildLocalUrl(ep.rawUrl, t.localPort);
        return;
      }
    }
  }

  /// 构造本机访问地址（保留原 path 与 query，token 不丢）。
  static String buildLocalUrl(Uri raw, int localPort) {
    final scheme = raw.scheme.isEmpty ? 'http' : raw.scheme;
    final path = raw.path.isEmpty ? '/' : raw.path;
    final query = raw.hasQuery ? '?${raw.query}' : '';
    return '$scheme://127.0.0.1:$localPort$path$query';
  }

  /// 确保该地址可在本机访问：复用已有隧道，否则按需新建并启动一条。
  static Future<String> ensureLocalUrl(DshEndpoint ep) async {
    if (ep.localUrl != null) return ep.localUrl!;
    final app = AppState.instance;
    final localPort = await _pickFreeLocalPort(ep.port);
    final tunnel = TunnelConfig(
      serverId: ep.serverId,
      name: 'dsh-web (${ep.serverName})',
      localPort: localPort,
      remoteHost: '127.0.0.1',
      remotePort: ep.port,
      autoStart: true,
      openOnStart: false,
    );
    await app.addTunnel(tunnel);
    await app.startTunnel(tunnel.id);
    await _waitListening(localPort);
    ep.localPort = localPort;
    ep.localUrl = buildLocalUrl(ep.rawUrl, localPort);
    LogBus.instance.info(
      'DSH',
      '已为 dsh-web 建立隧道 127.0.0.1:$localPort → 127.0.0.1:${ep.port}',
    );
    return ep.localUrl!;
  }

  /// 选一个空闲的本地端口（从首选端口向后探测）。
  static Future<int> _pickFreeLocalPort(int preferred) async {
    for (var p = preferred; p < preferred + 60 && p < 65535; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {
        // 端口被占用，继续探测下一个
      }
    }
    return preferred;
  }

  /// 等待本地端口开始监听（最多约 4 秒）。
  static Future<void> _waitListening(int port) async {
    for (var i = 0; i < 20; i++) {
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        s.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }
}
