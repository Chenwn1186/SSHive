/// 服务器连接配置。
///
/// 注意：password / privateKey / passphrase 属于敏感信息，
/// 整个对象会被序列化后存入 flutter_secure_storage（Android Keystore 加密）。
class ServerConfig {
  String id;
  String name;
  String host;
  int port;
  String username;

  /// 'password' = 密码登录；'key' = 私钥登录
  String authType;

  String? password;
  String? privateKey;
  String? passphrase;

  /// keepalive 间隔（秒），0 表示关闭
  int keepaliveSeconds;

  /// 应用启动后自动连接
  bool autoConnect;

  /// 断开后自动重连
  bool autoReconnect;

  /// 主机密钥指纹（TOFU，首次连接记录，格式 "SHA256:xxx"）
  String? hostFingerprint;

  /// SOCKS5 动态转发端口（0 = 关闭）
  int socksPort;

  ServerConfig({
    String? id,
    this.name = '',
    this.host = '',
    this.port = 22,
    this.username = '',
    this.authType = 'password',
    this.password,
    this.privateKey,
    this.passphrase,
    this.keepaliveSeconds = 30,
    this.autoConnect = false,
    this.autoReconnect = true,
    this.hostFingerprint,
    this.socksPort = 0,
  })  : id = id ?? _newId();

  static String _newId() =>
      'srv_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 100000}';

  bool get useKey => authType == 'key';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType,
        'password': password,
        'privateKey': privateKey,
        'passphrase': passphrase,
        'keepaliveSeconds': keepaliveSeconds,
        'autoConnect': autoConnect,
        'autoReconnect': autoReconnect,
        'hostFingerprint': hostFingerprint,
        'socksPort': socksPort,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
        id: json['id'] as String?,
        name: (json['name'] as String?) ?? '',
        host: (json['host'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: (json['username'] as String?) ?? '',
        authType: (json['authType'] as String?) ?? 'password',
        password: json['password'] as String?,
        privateKey: json['privateKey'] as String?,
        passphrase: json['passphrase'] as String?,
        keepaliveSeconds: (json['keepaliveSeconds'] as num?)?.toInt() ?? 30,
        autoConnect: (json['autoConnect'] as bool?) ?? false,
        autoReconnect: (json['autoReconnect'] as bool?) ?? true,
        hostFingerprint: json['hostFingerprint'] as String?,
        socksPort: (json['socksPort'] as num?)?.toInt() ?? 0,
      );

  ServerConfig copy() => ServerConfig.fromJson(toJson());
}
