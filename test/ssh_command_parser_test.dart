import 'package:flutter_test/flutter_test.dart';

import 'package:sshagent/services/ssh_command_parser.dart';

void main() {
  group('parseSshCommand', () {
    test('解析多 -L + -p + user@host', () {
      final r = parseSshCommand(
        'ssh -L 8080:localhost:80 -L 8443:localhost:443 '
        '-p 2222 user@example.com',
      );
      expect(r.username, 'user');
      expect(r.host, 'example.com');
      expect(r.port, 2222);
      expect(r.tunnels, hasLength(2));
      expect(r.tunnels[0].localPort, 8080);
      expect(r.tunnels[0].remoteHost, 'localhost');
      expect(r.tunnels[0].remotePort, 80);
      expect(r.tunnels[1].localPort, 8443);
      expect(r.tunnels[1].remoteHost, 'localhost');
      expect(r.tunnels[1].remotePort, 443);
      expect(r.socksPort, isNull);
    });

    test('短格式 -L localPort:remotePort 默认 localhost', () {
      final r = parseSshCommand('ssh -L 8080:80 user@example.com');
      expect(r.tunnels.single.localPort, 8080);
      expect(r.tunnels.single.remoteHost, 'localhost');
      expect(r.tunnels.single.remotePort, 80);
    });

    test('bind 地址形式 -L 0.0.0.0:8080:example.com:80', () {
      final r = parseSshCommand('ssh -L 0.0.0.0:8080:example.com:80 user@h');
      expect(r.tunnels.single.localPort, 8080);
      expect(r.tunnels.single.remoteHost, 'example.com');
      expect(r.tunnels.single.remotePort, 80);
    });

    test('-D 解析为 socks 端口', () {
      final r = parseSshCommand('ssh -D 1080 -N user@example.com');
      expect(r.socksPort, 1080);
    });

    test('紧贴形式 -L8080:host:80', () {
      final r = parseSshCommand('ssh -L8080:127.0.0.1:80 user@h');
      expect(r.tunnels.single.localPort, 8080);
      expect(r.tunnels.single.remoteHost, '127.0.0.1');
    });

    test('-o Port=2222 与默认 22', () {
      final r = parseSshCommand('ssh -o Port=2222 user@h');
      expect(r.port, 2222);
      expect(parseSshCommand('ssh user@h').port, 22);
    });

    test('host:port 目标地址', () {
      final r = parseSshCommand('ssh user@example.com:2200');
      expect(r.port, 2200);
      expect(r.host, 'example.com');
    });

    test('引号包裹的 -L 参数', () {
      final r = parseSshCommand(r'ssh "-L 8080:localhost:80" user@h');
      expect(r.tunnels.single.localPort, 8080);
    });

    test('无用户名', () {
      final r = parseSshCommand('ssh -p 22 example.com');
      expect(r.username, isNull);
      expect(r.host, 'example.com');
    });

    test('忽略 -i 并给出警告', () {
      final r = parseSshCommand('ssh -i ~/.ssh/id_rsa user@h');
      expect(r.warnings, isNotEmpty);
      expect(r.warnings.first, contains('-i'));
    });

    test('忽略布尔开关 -N -f -v', () {
      final r = parseSshCommand('ssh -N -f -v -L 1:2 user@h');
      expect(r.tunnels.single.localPort, 1);
    });

    test('IPv6 方括号 bind', () {
      final r = parseSshCommand('ssh -L [::1]:8080:localhost:80 user@h');
      expect(r.tunnels.single.localPort, 8080);
      expect(r.tunnels.single.remoteHost, 'localhost');
    });

    test('多行/前导空格容错', () {
      final r = parseSshCommand('  \n  ssh  -p 22  user@h\n');
      expect(r.host, 'h');
    });

    test('空命令抛异常', () {
      expect(() => parseSshCommand(''), throwsA(isA<SshCommandFormatException>()));
      expect(() => parseSshCommand('ssh -N -f'), throwsA(isA<SshCommandFormatException>()));
    });

    test('-L 参数错误抛异常', () {
      expect(() => parseSshCommand('ssh -L abc user@h'),
          throwsA(isA<SshCommandFormatException>()));
    });

    test('无用户名且无 -p 时 host 默认 22', () {
      final r = parseSshCommand('ssh myserver.com');
      expect(r.username, isNull);
      expect(r.host, 'myserver.com');
      expect(r.port, 22);
    });
  });
}
