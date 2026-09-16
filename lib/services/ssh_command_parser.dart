/// 解析 OpenSSH 风格的 ssh 命令行，自动提取服务器与端口转发配置。
///
/// 支持：
/// - `-L [bind:]localPort:remoteHost:remotePort`（可多个；短格式 localPort:remotePort）
/// - `-D port`（SOCKS5 动态转发）
/// - `-p port` / `-o Port=port`
/// - `user@host`（无用户名也可）
/// - 引号包裹的参数、IPv6 方括号、常见无关参数忽略（-N -f -C -v -i ...）
library;

/// 一条本地端口转发（来自 -L）。
class ParsedTunnel {
  ParsedTunnel({
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  });

  final int localPort;
  final String remoteHost;
  final int remotePort;
}

/// ssh 命令解析结果。
class ParsedSshCommand {
  ParsedSshCommand({
    this.username,
    this.host,
    this.port = 22,
    this.tunnels = const [],
    this.socksPort,
    this.warnings = const [],
  });

  final String? username;
  final String? host;
  final int port;
  final List<ParsedTunnel> tunnels;
  final int? socksPort;

  /// 非致命提示（如忽略了 -i / -R 等）。
  final List<String> warnings;
}

/// 解析失败时抛出，message 可直接展示给用户。
class SshCommandFormatException implements Exception {
  SshCommandFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 按空白分词，支持单/双引号包裹。
List<String> _tokenize(String input) {
  final tokens = <String>[];
  final buf = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  for (final ch in input.split('')) {
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if ((ch == ' ' || ch == '\t' || ch == '\n') && !inSingle && !inDouble) {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) tokens.add(buf.toString());
  return tokens;
}

/// 冒号切分（方括号内的冒号忽略，用于 IPv6）。
List<String> _splitColon(String s) {
  final parts = <String>[];
  final buf = StringBuffer();
  var inBracket = false;
  for (final ch in s.split('')) {
    if (ch == '[') {
      inBracket = true;
      buf.write(ch);
    } else if (ch == ']') {
      inBracket = false;
      buf.write(ch);
    } else if (ch == ':' && !inBracket) {
      parts.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  parts.add(buf.toString());
  return parts;
}

String _stripBrackets(String s) {
  var r = s.trim();
  if (r.length >= 2 && r.startsWith('[') && r.endsWith(']')) {
    r = r.substring(1, r.length - 1);
  }
  return r;
}

int _parsePort(String raw, String what) {
  final v = int.tryParse(raw.trim());
  if (v == null || v <= 0 || v > 65535) {
    throw SshCommandFormatException('$what 无效: "$raw"');
  }
  return v;
}

/// 解析一条 -L 规格。
ParsedTunnel _parseLocalForward(String spec) {
  final parts = _splitColon(spec).map((p) => p.trim()).toList();

  // 可能的形态：
  //   localPort:remotePort
  //   localPort:remoteHost:remotePort
  //   bind:localPort:remoteHost:remotePort
  // 先判断第一个是不是端口号（决定是否有 bind 地址）
  var idx = 0;
  var bind = '';
  if (int.tryParse(_stripBrackets(parts[0])) == null && parts.length > 2) {
    bind = _stripBrackets(parts[0]);
    idx = 1;
  }
  if (parts.length - idx < 2) {
    throw SshCommandFormatException('-L 参数无效: "$spec"（应为 本地端口:远程主机:远程端口）');
  }
  final localPort = _parsePort(parts[idx], '-L 本地端口');
  final remotePort = _parsePort(parts[parts.length - 1], '-L 远程端口');
  final remoteHost = parts.length - idx == 2
      ? 'localhost'
      : _stripBrackets(parts[idx + 1]);
  if (remoteHost.isEmpty) {
    throw SshCommandFormatException('-L 参数无效: "$spec"（远程主机为空）');
  }
  if (bind.isNotEmpty && bind != '0.0.0.0' && bind != '::') {
    // 我们只监听 127.0.0.1，bind 地址仅提示
  }
  return ParsedTunnel(
    localPort: localPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
  );
}

/// 需要携带值（下一 token 是值）的参数。
const _valueFlags = {
  'p', 'L', 'D', 'o', 'i', 'l', 'J', 'W', 'b', 'e', 'F', 'G', 'c', 'm', 's', 'w',
};

/// 解析整条 ssh 命令。失败抛 [SshCommandFormatException]。
ParsedSshCommand parseSshCommand(String input) {
  final tokens = _tokenize(input);
  final warnings = <String>[];

  // 去掉开头的 ssh/ssh.exe/路径/ssh 之类
  while (tokens.isNotEmpty) {
    final t = tokens.first;
    final base = t.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (base == 'ssh' || base == 'ssh.exe') {
      tokens.removeAt(0);
    } else {
      break;
    }
  }

  if (tokens.isEmpty) {
    throw SshCommandFormatException('命令为空');
  }

  String? username;
  String? host;
  var port = 22;
  int? socksPort;
  final tunnels = <ParsedTunnel>[];

  var i = 0;
  String? destination;
  while (i < tokens.length) {
    final t = tokens[i];
    if (t.startsWith('-') && t.length > 1) {
      final flag = t.substring(1);
      if (flag.startsWith('L') && flag.length > 1) {
        // -L8080:host:80 紧贴形式
        tunnels.add(_parseLocalForward(flag.substring(1)));
      } else if (flag.startsWith('D') && flag.length > 1) {
        socksPort = _parsePort(flag.substring(1), '-D 端口');
      } else if (flag.startsWith('p') && flag.length > 1) {
        port = _parsePort(flag.substring(1), '-p 端口');
      } else if (_valueFlags.contains(flag)) {
        final value = i + 1 < tokens.length ? tokens[i + 1] : null;
        if (value == null) {
          throw SshCommandFormatException('参数 -$flag 缺少值');
        }
        switch (flag) {
          case 'p':
            port = _parsePort(value, '-p 端口');
          case 'L':
            tunnels.add(_parseLocalForward(value));
          case 'D':
            socksPort = _parsePort(value, '-D 端口');
          case 'o':
            final eq = value.indexOf('=');
            if (eq > 0) {
              final key = value.substring(0, eq).trim();
              final v = value.substring(eq + 1).trim();
              if (key.toLowerCase() == 'port') {
                port = _parsePort(v, '-o Port');
              } else {
                warnings.add('已忽略选项 -o $key=$v');
              }
            }
          case 'i':
            warnings.add('已忽略私钥参数 -i $value（请在编辑页手动粘贴私钥）');
          default:
            warnings.add('已忽略参数 -$flag $value');
        }
        i++;
      } else {
        // 布尔开关，忽略（-N -f -C -v -4 -6 -A 等）
      }
    } else {
      // 非选项 token：第一个即目标地址
      destination ??= t;
    }
    i++;
  }

  if (destination == null || destination.isEmpty) {
    throw SshCommandFormatException('未找到 user@host 目标地址');
  }

  // 解析 user@host[:port]
  var rest = destination;
  final at = rest.lastIndexOf('@');
  if (at >= 0) {
    username = rest.substring(0, at);
    rest = rest.substring(at + 1);
    if (username.isEmpty) {
      throw SshCommandFormatException('目标地址无效: "$destination"');
    }
  }
  host = _stripBrackets(rest);
  // 兼容 host:port 形式（未用 -p 时）
  final colon = host.indexOf(':');
  if (colon > 0 && !host.contains('[')) {
    final hp = _parsePort(host.substring(colon + 1), '目标端口');
    if (port == 22) port = hp;
    host = host.substring(0, colon);
  }
  if (host.isEmpty) {
    throw SshCommandFormatException('目标地址无效: "$destination"');
  }

  return ParsedSshCommand(
    username: username,
    host: host,
    port: port,
    tunnels: tunnels,
    socksPort: socksPort,
    warnings: warnings,
  );
}
