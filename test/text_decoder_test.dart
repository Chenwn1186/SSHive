import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sshive/services/text_decoder.dart';

void main() {
  group('decodeTextBytes', () {
    test('UTF-8 中文正常解码', () {
      final bytes = utf8.encode('你好，世界！Hello 世界');
      expect(decodeTextBytes(Uint8List.fromList(bytes)), '你好，世界！Hello 世界');
    });

    test('GBK 中文解码（国内服务器常见编码）', () {
      final bytes = gbk.encode('这是一个GBK编码的中文文件');
      expect(decodeTextBytes(Uint8List.fromList(bytes)), '这是一个GBK编码的中文文件');
    });

    test('UTF-8 BOM 解码', () {
      final withBom = [0xEF, 0xBB, 0xBF, ...utf8.encode('带BOM的中文')];
      expect(decodeTextBytes(Uint8List.fromList(withBom)), '带BOM的中文');
    });

    test('UTF-16 LE BOM 解码', () {
      final text = 'UTF16 中文测试';
      final units = text.codeUnits;
      final bytes = <int>[0xFF, 0xFE];
      for (final u in units) {
        bytes.add(u & 0xFF);
        bytes.add((u >> 8) & 0xFF);
      }
      expect(decodeTextBytes(Uint8List.fromList(bytes)), text);
    });

    test('混合 ASCII 与中文 UTF-8', () {
      final bytes = utf8.encode('config = "中文路径" # 注释');
      expect(decodeTextBytes(Uint8List.fromList(bytes)), 'config = "中文路径" # 注释');
    });

    test('二进制数据不崩溃（宽容兜底）', () {
      final bytes = [0x00, 0x01, 0xFF, 0xFE, 0x80, 0x81, 0x00, 0x41];
      final result = decodeTextBytes(Uint8List.fromList(bytes));
      // 不抛异常，返回字符串即可
      expect(result, isA<String>());
    });

    test('空字节串', () {
      expect(decodeTextBytes(Uint8List(0)), '');
    });
  });
}
