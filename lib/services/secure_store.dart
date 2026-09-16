import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/server_config.dart';
import '../models/tunnel_config.dart';
import 'log_bus.dart';

/// 配置持久化：全部数据加密存放于系统安全存储
/// （Android 上为 Keystore 加密的 EncryptedSharedPreferences）。
class SecureStore {
  SecureStore._();

  static final SecureStore instance = SecureStore._();

  static const _serversKey = 'sshagent_servers';
  static const _tunnelsKey = 'sshagent_tunnels';
  static const _keepAliveKey = 'sshagent_keepalive';
  static const _fontPrefKey = 'sshagent_viewer_font';
  static const _webScrollMultiplierKey = 'sshagent_web_scroll_multiplier';
  static const _webDesktopModeKey = 'sshagent_web_desktop_mode';
  static const _webDesktopWidthKey = 'sshagent_web_desktop_width';
  static const _viewerScrollKey = 'sshagent_viewer_scroll_factor';
  static const _downloadDirKey = 'sshagent_download_dir';
  static const _webSessionsKey = 'sshagent_web_sessions';

  // flutter_secure_storage 11.x：Android 端默认即 Keystore 加密
  static const _storage = FlutterSecureStorage();

  Future<List<ServerConfig>> loadServers() async {
    try {
      final raw = await _storage.read(key: _serversKey);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List)
          .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (e) {
      LogBus.instance.error('Store', '读取服务器配置失败: $e');
      return [];
    }
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    await _storage.write(
      key: _serversKey,
      value: jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
  }

  Future<List<TunnelConfig>> loadTunnels() async {
    try {
      final raw = await _storage.read(key: _tunnelsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List)
          .map((e) => TunnelConfig.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (e) {
      LogBus.instance.error('Store', '读取隧道配置失败: $e');
      return [];
    }
  }

  Future<void> saveTunnels(List<TunnelConfig> tunnels) async {
    await _storage.write(
      key: _tunnelsKey,
      value: jsonEncode(tunnels.map((t) => t.toJson()).toList()),
    );
  }

  Future<bool> loadBackgroundKeepAlive() async {
    try {
      return (await _storage.read(key: _keepAliveKey)) == '1';
    } catch (e) {
      LogBus.instance.error('Store', '读取保活设置失败: $e');
      return false;
    }
  }

  Future<void> saveBackgroundKeepAlive(bool on) async {
    await _storage.write(key: _keepAliveKey, value: on ? '1' : '0');
  }

  Future<String?> loadViewerFontPref() async {
    try {
      return await _storage.read(key: _fontPrefKey);
    } catch (e) {
      LogBus.instance.error('Store', '读取字体设置失败: $e');
      return null;
    }
  }

  Future<void> saveViewerFontPref(String key) async {
    await _storage.write(key: _fontPrefKey, value: key);
  }

  // ---------------------------------------------------------------------
  // 网页滚动幅度（Windows WebView2，scrollMultiplier）
  // ---------------------------------------------------------------------

  Future<int?> loadWebScrollMultiplier() async {
    try {
      final raw = await _storage.read(key: _webScrollMultiplierKey);
      if (raw == null || raw.isEmpty) return null;
      return int.tryParse(raw);
    } catch (e) {
      LogBus.instance.error('Store', '读取网页滚动设置失败: $e');
      return null;
    }
  }

  Future<void> saveWebScrollMultiplier(int v) async {
    await _storage.write(key: _webScrollMultiplierKey, value: '$v');
  }

  // ---------------------------------------------------------------------
  // 桌面版网页模式（Android）
  // ---------------------------------------------------------------------

  Future<bool?> loadWebDesktopMode() async {
    try {
      final raw = await _storage.read(key: _webDesktopModeKey);
      if (raw == null || raw.isEmpty) return null;
      return raw == '1';
    } catch (e) {
      LogBus.instance.error('Store', '读取桌面版网页设置失败: $e');
      return null;
    }
  }

  Future<void> saveWebDesktopMode(bool on) async {
    await _storage.write(key: _webDesktopModeKey, value: on ? '1' : '0');
  }

  Future<int?> loadWebDesktopWidth() async {
    try {
      final raw = await _storage.read(key: _webDesktopWidthKey);
      if (raw == null || raw.isEmpty) return null;
      return int.tryParse(raw);
    } catch (e) {
      LogBus.instance.error('Store', '读取网页渲染宽度设置失败: $e');
      return null;
    }
  }

  Future<void> saveWebDesktopWidth(int w) async {
    await _storage.write(key: _webDesktopWidthKey, value: '$w');
  }

  // ---------------------------------------------------------------------
  // 文本预览滚轮倍率 + 下载目录
  // ---------------------------------------------------------------------

  Future<double?> loadViewerScrollFactor() async {
    try {
      final raw = await _storage.read(key: _viewerScrollKey);
      if (raw == null || raw.isEmpty) return null;
      return double.tryParse(raw);
    } catch (e) {
      LogBus.instance.error('Store', '读取文本滚动倍率失败: $e');
      return null;
    }
  }

  Future<void> saveViewerScrollFactor(double v) async {
    await _storage.write(key: _viewerScrollKey, value: '$v');
  }

  Future<String?> loadDownloadDir() async {
    try {
      return await _storage.read(key: _downloadDirKey);
    } catch (e) {
      LogBus.instance.error('Store', '读取下载目录失败: $e');
      return null;
    }
  }

  Future<void> saveDownloadDir(String dir) async {
    await _storage.write(key: _downloadDirKey, value: dir);
  }

  // ---------------------------------------------------------------------
  // 网页会话持久化（退出 app 后还原上次打开的标签）
  // ---------------------------------------------------------------------

  Future<Map<String, dynamic>?> loadWebSessions() async {
    try {
      final raw = await _storage.read(key: _webSessionsKey);
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) return data;
      return null;
    } catch (e) {
      LogBus.instance.error('Store', '读取网页会话失败: $e');
      return null;
    }
  }

  Future<void> saveWebSessions(Map<String, dynamic> data) async {
    await _storage.write(key: _webSessionsKey, value: jsonEncode(data));
  }
}
