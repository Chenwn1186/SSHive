import 'package:flutter_test/flutter_test.dart';

import 'package:sshive/services/dsh_discovery.dart';

void main() {
  group('DshDiscovery.extractUrl', () {
    test('解析 journalctl 单行输出', () {
      final out = 'http://127.0.0.1:3080/?token=AbC-123_xyz';
      final url = DshDiscovery.extractUrl(out);
      expect(url, isNotNull);
      expect(url!.host, '127.0.0.1');
      expect(url.port, 3080);
      expect(url.queryParameters['token'], 'AbC-123_xyz');
    });

    test('多行时取最后一条（最新启动的实例）', () {
      final out = 'http://127.0.0.1:3080/?token=old_token\n'
          'http://10.0.0.5:3080/?token=new_token';
      final url = DshDiscovery.extractUrl(out);
      expect(url!.host, '10.0.0.5');
      expect(url.queryParameters['token'], 'new_token');
    });

    test('日志前后有其它内容也能提取', () {
      final out = 'Aug 31 12:00:00 host dsh-web[123]: listening on '
          'http://0.0.0.0:3080/?token=xyz789 more text after';
      final url = DshDiscovery.extractUrl(out);
      expect(url!.port, 3080);
      expect(url.queryParameters['token'], 'xyz789');
    });

    test('没有 token 的地址不会被误取', () {
      expect(DshDiscovery.extractUrl('http://127.0.0.1:3080/'), isNull);
      expect(DshDiscovery.extractUrl(''), isNull);
      expect(DshDiscovery.extractUrl('-- No entries --'), isNull);
    });
  });

  group('DshDiscovery.buildLocalUrl', () {
    test('保留 path 与 token，主机换成本地回环', () {
      final raw = Uri.parse('http://10.0.0.5:3080/ui/?token=abc');
      final local = DshDiscovery.buildLocalUrl(raw, 13080);
      expect(local, 'http://127.0.0.1:13080/ui/?token=abc');
    });

    test('无 path/query 时补默认路径', () {
      final raw = Uri.parse('http://10.0.0.5:3080');
      expect(DshDiscovery.buildLocalUrl(raw, 8080), 'http://127.0.0.1:8080/');
    });
  });
}
