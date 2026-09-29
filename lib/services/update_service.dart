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
    this.viaWebFallback = false,
  });

  final UpdateStatus status;
  final String currentVersion;
  final String? latestVersion;

  /// Release 说明（Markdown 原文，直接展示；降级路径下可能为空）
  final String? notes;

  /// 首个 .apk 资产的直链（Android 下载用）
  final String? apkUrl;
  final int? apkBytes;

  /// 发布页地址（非 Android 平台打开发布页）
  final String? releaseUrl;

  /// 失败原因
  final String? error;

  /// 是否走了"绕过 api.github.com"的降级路径（仅用于日志/排查）
  final bool viaWebFallback;

  bool get hasApk => apkUrl != null && apkUrl!.isNotEmpty;
}

/// 应用内更新：检查 GitHub Releases → 下载 APK → 拉起系统安装器。
///
/// 两条检查路径：
/// 1. **官方 API**（`api.github.com`，信息最全：带 tag、资产与更新说明）；
/// 2. **降级路径**（只用 `github.com`）：国内网络下 `api.github.com` 常不可达，
///    而 `github.com` 正常。做法是读 `releases/latest` 的 302 重定向拿到 tag，
///    再从 `releases/expanded_assets/<tag>` 这个轻量片段里取出 .apk 资产链接。
///
/// 零新增依赖：网络用 `dart:io HttpClient`；版本号与"跳转安装"走自建 MethodChannel
/// （`getVersionName` / `installApk`，见 MainActivity.kt）。
class UpdateService {
  UpdateService._();

  /// 发布仓库（与 git remote 一致）
  static const String repo = 'Chenwn1186/SSHive';
  static const String repoUrl = 'https://github.com/$repo';

  static const String _apiLatest =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String _latestPage = '$repoUrl/releases/latest';

  static const Duration _timeout = Duration(seconds: 15);
  static const int _downloadAttempts = 3;

  static const MethodChannel _channel =
      MethodChannel('com.chenwnx.sshive/update');

  /// 非 Android 平台（Windows）无法从包管理器取版本，用这个常量兜底。
  /// **需与 pubspec.yaml 的 version 保持一致。**
  static const String fallbackVersion = '1.0.3';

  /// 测试注入点：绕过网络返回固定结果
  @visibleForTesting
  static Future<UpdateInfo> Function()? debugCheckOverride;

  /// 测试注入点：替换整段 HTTP 文本获取（用于验证降级路径的解析）
  @visibleForTesting
  static Future<({String body, String? location, int status})> Function(
      String url, {bool noRedirect})? debugHttpGetOverride;

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
      final out = <int>[];
      for (final p in s.split('.')) {
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
  // 解析（纯函数，便于单测）
  // ---------------------------------------------------------------------

  /// 从 `https://github.com/<repo>/releases/tag/v1.2.3`（或任意含 `/tag/<x>` 的
  /// 地址）里取出 tag。取不到返回 null。
  static String? parseTagFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(url);
    if (m == null) return null;
    final tag = Uri.decodeComponent(m.group(1)!.trim());
    return tag.isEmpty ? null : tag;
  }

  /// 从 `releases/expanded_assets/<tag>` 片段里取出第一个 .apk 的绝对地址。
  static String? parseApkUrlFromAssetsHtml(String html, {String repo = repo}) {
    final m = RegExp(r'href="([^"]*?\.apk)"', caseSensitive: false)
        .firstMatch(html);
    if (m == null) return null;
    var href = m.group(1)!.trim();
    if (href.startsWith('http://') || href.startsWith('https://')) return href;
    if (href.startsWith('/')) return 'https://github.com$href';
    return 'https://github.com/$href';
  }

  // ---------------------------------------------------------------------
  // 检查更新
  // ---------------------------------------------------------------------

  static Future<UpdateInfo> check() async {
    final override = debugCheckOverride;
    if (override != null) return override();

    final current = await currentVersion();
    final errors = <String>[];

    // 1) 官方 API（带更新说明，信息最全）
    try {
      final info = await _checkViaApi(current);
      if (info != null) return info;
    } catch (e) {
      errors.add('API 不可用（$e）');
    }

    // 2) 降级：只依赖 github.com（国内网络下 API 常被墙）
    try {
      final info = await _checkViaWebFallback(current);
      if (info != null) return info;
      errors.add('网页路径未能解析出版本信息');
    } catch (e) {
      errors.add('网页路径失败（$e）');
    }

    LogBus.instance.warn('Update', '检查更新失败：${errors.join('；')}');
    return UpdateInfo(
      status: UpdateStatus.failed,
      currentVersion: current,
      error: errors.join('\n'),
    );
  }

  /// 官方 API 路径。返回 null 表示"拿到了响应但不能用"（交由降级路径处理）。
  static Future<UpdateInfo?> _checkViaApi(String current) async {
    final res = await _httpGet(_apiLatest,
        headers: {
          HttpHeaders.userAgentHeader: 'SSHive/$current',
          HttpHeaders.acceptHeader: 'application/vnd.github+json',
        });
    if (res.status == 404) {
      // 仓库还没有发布任何 Release：视为"已是最新"
      return UpdateInfo(
        status: UpdateStatus.upToDate,
        currentVersion: current,
        latestVersion: current,
        releaseUrl: '$repoUrl/releases',
        error: '仓库暂无已发布的版本',
      );
    }
    if (res.status != 200) {
      throw HttpException('GitHub API 返回 ${res.status}'
          '${res.status == 403 ? '（限流）' : ''}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String?)?.trim() ?? '';
    final latest = _normalize(tag);
    if (latest.isEmpty) throw const FormatException('API 缺少 tag_name');

    String? apkUrl;
    int? apkBytes;
    for (final raw in (json['assets'] as List?) ?? const []) {
      final a = raw as Map;
      if ('${a['name'] ?? ''}'.toLowerCase().endsWith('.apk')) {
        apkUrl = '${a['browser_download_url'] ?? ''}';
        final size = a['size'];
        apkBytes = size is int ? size : null;
        break;
      }
    }
    return _buildInfo(
      current: current,
      latest: latest,
      notes: (json['body'] as String?)?.trim(),
      apkUrl: apkUrl,
      apkBytes: apkBytes,
      releaseUrl: (json['html_url'] as String?) ?? '$repoUrl/releases/tag/$tag',
    );
  }

  /// 降级路径：只访问 github.com。
  /// 版本号来自 `releases/latest` 的 302 Location，资产来自 expanded_assets 片段。
  static Future<UpdateInfo?> _checkViaWebFallback(String current) async {
    // （a）取 tag：不跟随重定向，只读 Location
    final head = await _httpGet(_latestPage, noRedirect: true);
    var tag = parseTagFromUrl(head.location);
    if (tag == null || tag.isEmpty) {
      // 有些网络会直接跟随返回 200，则从正文里找 /releases/tag/<x>
      tag = parseTagFromUrl(RegExp(r'/releases/tag/[^"\s>]+')
          .firstMatch(head.body)
          ?.group(0));
    }
    if (tag == null || tag.isEmpty) {
      throw const FormatException('未能从 releases/latest 解析出版本号');
    }
    final latest = _normalize(tag);

    // （b）取该 tag 的资产列表（轻量片段，只有几 KB）
    String? apkUrl;
    try {
      final assetsHtml =
          await _httpGet('$repoUrl/releases/expanded_assets/$tag');
      apkUrl = parseApkUrlFromAssetsHtml(assetsHtml.body);
    } catch (e) {
      LogBus.instance.debug('Update', '读取资产列表失败: $e');
    }

    LogBus.instance.info('Update', '降级路径命中：$tag'
        '${apkUrl != null ? '，APK $apkUrl' : '（未取到 APK 链接）'}');
    return _buildInfo(
      current: current,
      latest: latest,
      notes: null, // 降级路径不抓更新说明（正文是整页 HTML）
      apkUrl: apkUrl,
      apkBytes: null,
      releaseUrl: '$repoUrl/releases/tag/$tag',
      viaWebFallback: true,
    );
  }

  static UpdateInfo _buildInfo({
    required String current,
    required String latest,
    String? notes,
    String? apkUrl,
    int? apkBytes,
    String? releaseUrl,
    bool viaWebFallback = false,
  }) {
    final newer = compareVersions(latest, current) > 0;
    final info = UpdateInfo(
      status: newer ? UpdateStatus.available : UpdateStatus.upToDate,
      currentVersion: current,
      latestVersion: latest,
      notes: notes,
      apkUrl: apkUrl,
      apkBytes: apkBytes,
      releaseUrl: releaseUrl,
      viaWebFallback: viaWebFallback,
    );
    LogBus.instance.info(
      'Update',
      '检查更新：当前 $current，最新 $latest → ${info.status.name}'
      '${viaWebFallback ? '（降级路径）' : ''}'
      '${apkBytes != null ? '，APK ${(apkBytes / 1048576).toStringAsFixed(1)}MB' : ''}',
    );
    return info;
  }

  static String _normalize(String tag) =>
      tag.trim().replaceFirst(RegExp(r'^[vV]'), '');

  // ---------------------------------------------------------------------
  // HTTP（可注入，便于单测降级解析）
  // ---------------------------------------------------------------------

  static Future<({String body, String? location, int status})> _httpGet(
    String url, {
    Map<String, String> headers = const {},
    bool noRedirect = false,
  }) async {
    final inject = debugHttpGetOverride;
    if (inject != null) return inject(url, noRedirect: noRedirect);

    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = headers[HttpHeaders.userAgentHeader] ?? 'SSHive';
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      headers.forEach((k, v) => req.headers.set(k, v));
      if (noRedirect) req.followRedirects = false;
      final res = await req.close().timeout(_timeout);
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      return (
        body: body,
        location: res.headers.value(HttpHeaders.locationHeader),
        status: res.statusCode,
      );
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------
  // 下载与安装
  // ---------------------------------------------------------------------

  /// 下载 APK 到应用缓存目录（带重试：GitHub 资产 CDN 偶发连接重置）。
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

    Object? lastError;
    for (var attempt = 1; attempt <= _downloadAttempts; attempt++) {
      if (isCancelled?.call() ?? false) throw const _Cancelled();
      try {
        if (await file.exists()) await file.delete();
        await _downloadOnce(url, file, info, onProgress, isCancelled);
        LogBus.instance.info('Update',
            'APK 已下载：$fileName（第 $attempt 次尝试，${(await file.length() / 1048576).toStringAsFixed(1)}MB）');
        return file.path;
      } catch (e) {
        lastError = e;
        if (isDownloadCancelled(e)) rethrow;
        LogBus.instance.warn('Update', '下载第 $attempt 次失败: $e');
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        if (attempt < _downloadAttempts) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    throw lastError ?? StateError('下载失败');
  }

  static Future<void> _downloadOnce(
    String url,
    File file,
    UpdateInfo info,
    void Function(int, int?)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = 'SSHive/${info.currentVersion}';
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${res.statusCode}',
            uri: Uri.parse(url));
      }
      final total = res.contentLength > 0 ? res.contentLength : info.apkBytes;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          if (isCancelled?.call() ?? false) throw const _Cancelled();
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      // 内容长度已知时校验完整性（避免半包被拿去安装）
      if (total != null && total > 0 && received != total) {
        throw HttpException('下载不完整：$received/$total');
      }
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
