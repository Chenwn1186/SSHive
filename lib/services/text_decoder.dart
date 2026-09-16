import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 智能文本解码：按优先级尝试 UTF-8 / GBK / UTF-16（含 BOM 检测），
/// 彻底解决远程文件中文乱码问题。
///
/// 优先级：
/// 1. BOM 检测（UTF-8 / UTF-16 LE / UTF-16 BE）
/// 2. UTF-8 严格解码（通过则用它——绝大多数文件）
/// 3. GBK/GB18030（国内服务器常见编码）
/// 4. UTF-8 宽容解码兜底（不抛异常）
String decodeTextBytes(Uint8List bytes) {
  // 1) BOM 检测
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    // UTF-8 BOM
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    // UTF-16 LE BOM
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    // UTF-16 BE BOM
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }

  // 2) UTF-8 严格解码（能通过说明是合法 UTF-8）
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // 3) GBK（含 GB18030 兼容）
    try {
      return gbk.decode(bytes);
    } catch (_) {
      // 4) 兜底：宽容解码，绝不崩溃
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final len = bytes.length ~/ 2 * 2;
  final bd = ByteData.sublistView(bytes, 0, len);
  final units = Uint16List(len ~/ 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = littleEndian
        ? bd.getUint16(i * 2, Endian.little)
        : bd.getUint16(i * 2, Endian.big);
  }
  return String.fromCharCodes(units);
}
