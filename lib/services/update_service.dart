import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'log_bus.dart';

/// 更新检查结果
enum UpdateStatus {
  /// 检查失败（网络/限流/解析等）
  failed,

  /// 已是最新
  upToDate,

  /// 有新版本
  available,
}

class UpdateInfo {
  const UpdateInfo({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.notes,
    this.apkUrl,
    this.apkBytes,
    this.releaseUrl,
    this.error,
  });

  final UpdateStatus status;
  final String currentVersion;
  final String? latestVersion;

  /// Release 说明（Markdown 原文，直接展示）
  final String? notes;

  /// 首个 .apk 资产的直链（Android 下载用）
  final String? apkUrl;
  final int? apkBytes;

  /// 发布页地址（非 Android 平台打开发布页）
  final String? releaseUrl;

  /// 失败原因
  final String? error;

  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;
}

/// 应用内更新：检查 GitHub Releases → 下载 APK → 拉起系统安装器。
///
/// 零新增依赖：
/// - 网络用 `dart:io HttpClient`（api.github.com 与资产都是 HTTPS；
///   network_security_config 只对 127.0.0.1 放行明文，不影响这里）；
/// - 版本号与"跳转安装"通过自建 MethodChannel 走 Android 原生
///   （`getVersionName` / `installApk`，见 MainActivity.kt）。
class UpdateService {
  UpdateService._();

  /// 发布仓库（与 git remote 一致）
  static const String repo = 'Chenwn1186/SSHive';

  static const String _apiLatest =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String _releasePage = 'https://github.com/$repo/releases/latest';

  static const Duration _timeout = Duration(seconds: 15);

  static const MethodChannel _channel =
      MethodChannel('com.chenwnx.sshive/update');

  /// 非 Android 平台（Windows）无法从包管理器取版本，用这个常量兜底。
  /// **需与 pubspec.yaml 的 version 保持一致。**
  static const String fallbackVersion = '1.0.1';

  /// 测试注入点：绕过网络返回固定结果
  @visibleForTesting
  static Future<UpdateInfo> Function()? debugCheckOverride;

  // ---------------------------------------------------------------------
  // 版本
  // ---------------------------------------------------------------------

  /// 当前应用版本（Android 取 versionName；其它平台用 [fallbackVersion]）
  static Future<String> currentVersion() async {
    try {
      final v = await _channel.invokeMethod<String>('getVersionName');
      if (v != null && v.trim().isNotEmpty) return v.trim();
    } on MissingPluginException {
      // 非 Android 平台：走兜底常量
    } catch (e) {
      LogBus.instance.debug('Update', '读取版本号失败: $e');
    }
    return fallbackVersion;
  }

  /// 语义化版本比较：返回 >0 表示 [a] 比 [b] 新。
  /// 容忍 `v1.2.3` / `1.2` / `1.2.3+4` 等写法，非数字段按 0 处理。
  static int compareVersions(String a, String b) {
    List<int> parse(String v) {
      var s = v.trim();
      if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
      s = s.split('+').first; // 去掉 +build
      final parts = s.split('.');
      final out = <int>[];
      for (final p in parts) {
        out.add(int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0);
      }
      while (out.length < 3) {
        out.add(0);
      }
      return out;
    }

    final x = parse(a);
    final y = parse(b);
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] > y[i] ? 1 : -1;
    }
    return 0;
  }

  // ---------------------------------------------------------------------
  // 检查更新
  // ---------------------------------------------------------------------

  static Future<UpdateInfo> check() async {
    final override = debugCheckOverride;
    if (override != null) return override();

    final current = await currentVersion();
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(Uri.parse(_apiLatest)).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'SSHive/$current');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(_timeout);
      final bodyText =
          await res.transform(utf8.decoder).join().timeout(_timeout);

      if (res.statusCode == 404) {
        // 仓库还没有发布任何 Release
        return UpdateInfo(
          status: UpdateStatus.upToDate,
          currentVersion: current,
          latestVersion: current,
          releaseUrl: _releasePage,
          error: '仓库暂无已发布的版本',
        );
      }
      if (res.statusCode != 200) {
        final hint = res.statusCode == 403
            ? '（GitHub API 限流，稍后再试）'
            : '';
        return UpdateInfo(
          status: UpdateStatus.failed,
          currentVersion: current,
          error: 'GitHub 返回 ${res.statusCode}$hint',
        );
      }

      final json = jsonDecode(bodyText) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final latest = tag.replaceFirst(RegExp(r'^[vV]'), '');
      if (latest.isEmpty) {
        return UpdateInfo(
          status: UpdateStatus.failed,
          currentVersion: current,
          error: '发布信息缺少 tag_name',
        );
      }

      String? apkUrl;
      int? apkBytes;
      for (final raw in (json['assets'] as List?) ?? const []) {
        final a = raw as Map;
        final name = '${a['name'] ?? ''}'.toLowerCase();
        if (name.endsWith('.apk')) {
          apkUrl = '${a['browser_download_url'] ?? ''}';
          final size = a['size'];
          apkBytes = size is int ? size : null;
          break;
        }
      }

      final newer = compareVersions(latest, current) > 0;
      final info = UpdateInfo(
        status: newer ? UpdateStatus.available : UpdateStatus.upToDate,
        currentVersion: current,
        latestVersion: latest,
        notes: (json['body'] as String?)?.trim(),
        apkUrl: apkUrl,
        apkBytes: apkBytes,
        releaseUrl: (json['html_url'] as String?) ?? _releasePage,
      );
      LogBus.instance.info(
        'Update',
        '检查更新：当前 $current，最新 $latest → ${info.status.name}'
        '${apkBytes != null ? '，APK ${(apkBytes / 1048576).toStringAsFixed(1)}MB' : ''}',
      );
      return info;
    } catch (e) {
      LogBus.instance.warn('Update', '检查更新失败: $e');
      return UpdateInfo(
        status: UpdateStatus.failed,
        currentVersion: current,
        error: '$e',
      );
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------
  // 下载与安装
  // ---------------------------------------------------------------------

  /// 下载 APK 到应用缓存目录，返回本地路径。
  ///
  /// [onProgress] 回调 (已下载字节, 总字节或 null)；[isCancelled] 返回 true 时中断。
  static Future<String> downloadApk(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = info.apkUrl;
    if (url == null || url.isEmpty) {
      throw StateError('该版本没有可下载的 APK');
    }
    final dir = await getTemporaryDirectory();
    final fileName = 'SSHive-${info.latestVersion ?? 'latest'}.apk';
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    if (await file.exists()) {
      await file.delete();
    }

    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader,
          'SSHive/${info.currentVersion}');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      final total = res.contentLength > 0 ? res.contentLength : info.apkBytes;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          if (isCancelled?.call() ?? false) {
            throw const _Cancelled();
          }
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      LogBus.instance
          .info('Update', 'APK 已下载：$fileName（${(received / 1048576).toStringAsFixed(1)}MB）');
      return file.path;
    } catch (e) {
      // 失败/取消都清掉半包，避免占空间或误安装
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 拉起系统安装器（Android）。非 Android 平台会抛 [MissingPluginException]。
  static Future<void> installApk(String path) async {
    LogBus.instance.info('Update', '拉起安装器：$path');
    await _channel.invokeMethod<bool>('installApk', {'path': path});
  }
}

/// 下载被用户取消
class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '已取消下载';
}

/// 供 UI 判断"是否用户主动取消"
bool isDownloadCancelled(Object e) => e is _Cancelled;
