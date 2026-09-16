/// 端口转发隧道配置：本地端口 -> 远程主机:远程端口（经由 SSH 连接）。
class TunnelConfig {
  String id;
  String serverId;

  /// 隧道名称（如 "SD WebUI"）
  String name;

  /// 手机本地监听端口（浏览器访问 http://127.0.0.1:localPort）
  int localPort;

  /// 远程目标主机（相对 SSH 服务器而言，通常为 127.0.0.1）
  String remoteHost;

  /// 远程目标端口
  int remotePort;

  /// 服务器连接成功后自动启动该隧道
  bool autoStart;

  /// 隧道启动后自动打开 WebUI（可选）
  bool openOnStart;

  TunnelConfig({
    String? id,
    this.serverId = '',
    this.name = '',
    this.localPort = 8080,
    this.remoteHost = '127.0.0.1',
    this.remotePort = 8080,
    this.autoStart = true,
    this.openOnStart = true,
  }) : id = id ?? _newId();

  static String _newId() =>
      'tun_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 100000}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'name': name,
        'localPort': localPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'autoStart': autoStart,
        'openOnStart': openOnStart,
      };

  factory TunnelConfig.fromJson(Map<String, dynamic> json) => TunnelConfig(
        id: json['id'] as String?,
        serverId: (json['serverId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        localPort: (json['localPort'] as num?)?.toInt() ?? 8080,
        remoteHost: (json['remoteHost'] as String?) ?? '127.0.0.1',
        remotePort: (json['remotePort'] as num?)?.toInt() ?? 8080,
        autoStart: (json['autoStart'] as bool?) ?? true,
        openOnStart: (json['openOnStart'] as bool?) ?? true,
      );

  TunnelConfig copy() => TunnelConfig.fromJson(toJson());

  String get summary => '127.0.0.1:$localPort → $remoteHost:$remotePort';
}
