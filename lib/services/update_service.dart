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
    this.windowsZipUrl,
    this.windowsZipBytes,
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

  /// Windows 绿色包（`*-windows-x64.zip`）的直链
  final String? windowsZipUrl;
  final int? windowsZipBytes;

  /// 发布页地址（不支持自动更新的平台打开发布页）
  final String? releaseUrl;

  /// 失败原因
  final String? error;

  /// 是否走了"绕过 api.github.com"的降级路径（仅用于日志/排查）
  final bool viaWebFallback;

  bool get hasApk => (apkUrl ?? '').isNotEmpty;
  bool get hasWindowsZip => (windowsZipUrl ?? '').isNotEmpty;

  /// 当前平台是否需要下载才能更新（Android：APK；Windows：绿色包）
  static bool get platformSupportsAutoUpdate =>
      Platform.isAndroid || Platform.isWindows;

  /// 当前平台该下载哪个资产；不支持的平台返回 null
  String? get downloadUrl {
    if (Platform.isAndroid) return hasApk ? apkUrl : null;
    if (Platform.isWindows) return hasWindowsZip ? windowsZipUrl : null;
    return null;
  }

  int? get downloadBytes {
    if (Platform.isAndroid) return apkBytes;
    if (Platform.isWindows) return windowsZipBytes;
    return null;
  }

  /// 下载文件的建议名（APK / zip）
  String get downloadFileName {
    if (Platform.isAndroid) return 'SSHive-${latestVersion ?? 'latest'}.apk';
    return 'SSHive-${latestVersion ?? 'latest'}-windows-x64.zip';
  }
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
  static const String fallbackVersion = '1.0.6';

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

  /// 诊断用环境变量：设置后用它冒充"当前版本"，便于在**没有更新可装**的情况下
  /// 实测下载与自更新流程（例如 Windows：`set SSHIVE_FAKE_VERSION=1.0.4` 后启动）。
  static const String fakeVersionEnv = 'SSHIVE_FAKE_VERSION';

  /// 当前应用版本（Android 取 versionName；其它平台用 [fallbackVersion]）
  static Future<String> currentVersion() async {
    final fake = Platform.environment[fakeVersionEnv]?.trim();
    if (fake != null && fake.isNotEmpty) {
      LogBus.instance.warn(
          'Update', '$fakeVersionEnv=$fake —— 按此版本比较（仅用于测试更新流程）');
      return fake;
    }
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

  /// 从 `releases/expanded_assets/<tag>` 片段里取出所有资产链接（绝对地址）。
  /// 片段形如 `<a href="/owner/repo/releases/download/v1.0.4/xxx.zip">…</a>`。
  static List<String> parseAssetUrlsFromAssetsHtml(String html) {
    final out = <String>[];
    for (final m in RegExp(r'href="([^"]+)"', caseSensitive: false)
        .allMatches(html)) {
      final href = m.group(1)!.trim();
      if (!href.contains('/releases/download/')) continue;
      if (href.startsWith('http://') || href.startsWith('https://')) {
        out.add(href);
      } else if (href.startsWith('/')) {
        out.add('https://github.com$href');
      } else {
        out.add('https://github.com/$href');
      }
    }
    return out;
  }

  /// 取出第一个 .apk 资产的绝对地址（Android）
  static String? parseApkUrlFromAssetsHtml(String html, {String repo = repo}) {
    for (final u in parseAssetUrlsFromAssetsHtml(html)) {
      if (u.toLowerCase().endsWith('.apk')) return u;
    }
    return null;
  }

  /// 取出 Windows 绿色包（`*-windows-x64.zip`，退化时取任意 .zip）的地址
  static String? parseWindowsZipUrlFromAssetsHtml(String html) {
    final urls = parseAssetUrlsFromAssetsHtml(html)
        .where((u) => u.toLowerCase().endsWith('.zip'))
        .toList();
    if (urls.isEmpty) return null;
    for (final u in urls) {
      if (u.toLowerCase().contains('windows')) return u;
    }
    return urls.first;
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
    String? zipUrl;
    int? zipBytes;
    for (final raw in (json['assets'] as List?) ?? const []) {
      final a = raw as Map;
      final name = '${a['name'] ?? ''}'.toLowerCase();
      final url = '${a['browser_download_url'] ?? ''}';
      final size = a['size'];
      if (apkUrl == null && name.endsWith('.apk')) {
        apkUrl = url;
        apkBytes = size is int ? size : null;
      } else if (zipUrl == null &&
          name.endsWith('.zip') &&
          (name.contains('windows') || !name.contains('macos'))) {
        zipUrl = url;
        zipBytes = size is int ? size : null;
      }
    }
    return _buildInfo(
      current: current,
      latest: latest,
      notes: (json['body'] as String?)?.trim(),
      apkUrl: apkUrl,
      apkBytes: apkBytes,
      windowsZipUrl: zipUrl,
      windowsZipBytes: zipBytes,
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
    String? zipUrl;
    try {
      final assetsHtml =
          await _httpGet('$repoUrl/releases/expanded_assets/$tag');
      apkUrl = parseApkUrlFromAssetsHtml(assetsHtml.body);
      zipUrl = parseWindowsZipUrlFromAssetsHtml(assetsHtml.body);
    } catch (e) {
      LogBus.instance.debug('Update', '读取资产列表失败: $e');
    }

    LogBus.instance.info('Update', '降级路径命中：$tag'
        '${apkUrl != null ? '，APK 已取到' : '（未取到 APK 链接）'}'
        '${zipUrl != null ? '，Windows 包已取到' : ''}');
    return _buildInfo(
      current: current,
      latest: latest,
      notes: null, // 降级路径不抓更新说明（正文是整页 HTML）
      apkUrl: apkUrl,
      apkBytes: null,
      windowsZipUrl: zipUrl,
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
    String? windowsZipUrl,
    int? windowsZipBytes,
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
      windowsZipUrl: windowsZipUrl,
      windowsZipBytes: windowsZipBytes,
      releaseUrl: releaseUrl,
      viaWebFallback: viaWebFallback,
    );
    final sizes = <String>[
      if (apkBytes != null) 'APK ${(apkBytes / 1048576).toStringAsFixed(1)}MB',
      if (windowsZipBytes != null)
        'Windows 包 ${(windowsZipBytes / 1048576).toStringAsFixed(1)}MB',
    ];
    LogBus.instance.info(
      'Update',
      '检查更新：当前 $current，最新 $latest → ${info.status.name}'
      '${viaWebFallback ? '（降级路径）' : ''}'
      '${sizes.isEmpty ? '' : '，${sizes.join('，')}'}',
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

  /// 下载当前平台的更新包到应用缓存目录（带重试：GitHub 资产 CDN 偶发连接重置）。
  /// Android 得到 APK；Windows 得到绿色包 zip。
  static Future<String> downloadUpdate(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = info.downloadUrl;
    if (url == null || url.isEmpty) {
      throw StateError(Platform.isWindows
          ? '该版本没有提供 Windows 包'
          : '该版本没有提供可下载的更新包');
    }
    final dir = await getTemporaryDirectory();
    final fileName = info.downloadFileName;
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    final expected = info.downloadBytes;

    Object? lastError;
    for (var attempt = 1; attempt <= _downloadAttempts; attempt++) {
      if (isCancelled?.call() ?? false) throw const _Cancelled();
      try {
        if (await file.exists()) await file.delete();
        await _downloadOnce(
            url, file, info, expected, onProgress, isCancelled);
        LogBus.instance.info(
          'Update',
          '更新包已下载：$fileName（第 $attempt 次尝试，'
          '${(await file.length() / 1048576).toStringAsFixed(1)}MB）',
        );
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

  /// 兼容旧调用（Android 下载 APK）
  static Future<String> downloadApk(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) =>
      downloadUpdate(info, onProgress: onProgress, isCancelled: isCancelled);

  static Future<void> _downloadOnce(
    String url,
    File file,
    UpdateInfo info,
    int? expectedBytes,
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
      final total = res.contentLength > 0 ? res.contentLength : expectedBytes;
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

  // ---------------------------------------------------------------------
  // Windows 自更新（绿色包：下载 zip → 解包 → 助手脚本覆盖安装目录并重启）
  // ---------------------------------------------------------------------

  /// 更新暂存根目录（`%LOCALAPPDATA%\SSHive\update`，退回系统临时目录）
  static Future<Directory> windowsUpdateRoot() async {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['TEMP'] ??
        Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}SSHive'
        '${Platform.pathSeparator}update');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 生成"等应用退出 → 镜像覆盖安装目录 → 重启 → 清理"的批处理脚本内容。
  ///
  /// **必须保持纯 ASCII**：cmd.exe 在这个环境下默认代码页是 936，脚本里写中文
  /// 会变乱码甚至让 `robocopy` 参数解析失败。
  @visibleForTesting
  static String buildWindowsApplyScript({
    required String stagedDir,
    required String installDir,
    required String exeName,
    required int pid,
    required String cleanupDir,
  }) {
    final b = StringBuffer()
      ..writeln('@echo off')
      ..writeln('setlocal enableextensions')
      ..writeln('rem Wait for the running SSHive to exit, then mirror the staged')
      ..writeln('rem release into the install directory and relaunch it.')
      ..writeln('set "SRC=$stagedDir"')
      ..writeln('set "DST=$installDir"')
      ..writeln('set "PID=$pid"')
      ..writeln('set /a tries=0')
      ..writeln(':wait')
      ..writeln('tasklist /FI "PID eq %PID%" 2>nul | findstr /C:"%PID%" >nul')
      ..writeln('if errorlevel 1 goto apply')
      ..writeln('set /a tries+=1')
      ..writeln('if %tries% GTR 180 goto apply')
      ..writeln('timeout /t 1 /nobreak >nul')
      ..writeln('goto wait')
      ..writeln(':apply')
      // /MIR 镜像；/XJ 排除 junction；保留 WebView2 运行时数据（登录态）与旧 zip
      ..writeln('robocopy "%SRC%" "%DST%" /MIR /XJ '
          '/XD EBWebView sshive.exe.WebView2 sshagent.exe.WebView2 '
          '/XF *.zip /R:3 /W:1 /NFL /NDL /NJH /NJS /NP')
      ..writeln('start "" "%DST%\\$exeName"')
      ..writeln('rd /s /q "$cleanupDir" 2>nul')
      ..writeln('endlocal');
    return b.toString();
  }

  /// 解包下载好的 Windows 绿色包，返回解包目录（内含新的 sshive.exe）。
  static Future<Directory> stageWindowsUpdate(
    String zipPath,
    UpdateInfo info,
  ) async {
    final root = await windowsUpdateRoot();
    final dest = Directory('${root.path}${Platform.pathSeparator}'
        'staged-${info.latestVersion ?? 'new'}');
    if (await dest.exists()) await dest.delete(recursive: true);
    await dest.create(recursive: true);

    // Win10 1803+ 自带 bsdtar，直接支持 zip；失败再退 PowerShell Expand-Archive
    final tar = File(
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
        '${Platform.pathSeparator}System32${Platform.pathSeparator}tar.exe');
    Object? lastError;
    if (await tar.exists()) {
      try {
        final r = await Process.run(
            tar.path, ['-xf', zipPath, '-C', dest.path]);
        if (r.exitCode != 0) {
          lastError = 'tar 退出码 ${r.exitCode}：${r.stderr}';
        }
      } catch (e) {
        lastError = e;
      }
    } else {
      lastError = '未找到 tar.exe';
    }

    if (!await File('${dest.path}${Platform.pathSeparator}sshive.exe')
        .exists()) {
      LogBus.instance.warn('Update', 'tar 解包不可用（$lastError），改用 Expand-Archive');
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Expand-Archive -LiteralPath "$zipPath" '
            '-DestinationPath "${dest.path}" -Force',
      ]);
      if (r.exitCode != 0) {
        throw StateError('解包失败：${r.stderr}');
      }
    }

    final exe = File('${dest.path}${Platform.pathSeparator}sshive.exe');
    if (!await exe.exists()) {
      throw StateError('解包后没有找到 sshive.exe，更新包结构不符合预期');
    }
    LogBus.instance.info('Update', 'Windows 更新已解包：${dest.path}');
    return dest;
  }

  /// 启动助手脚本完成覆盖与重启，然后**退出当前进程**。
  ///
  /// 覆盖自己正在使用的 exe/DLL 会被系统拒绝，所以必须交给外部脚本在进程退出后做。
  static Future<void> applyWindowsUpdate(
    Directory staged,
    UpdateInfo info,
  ) async {
    final installDir = File(Platform.resolvedExecutable).parent.path;
    final script = File('${staged.parent.path}${Platform.pathSeparator}'
        'apply_update.cmd');
    await script.writeAsString(
      buildWindowsApplyScript(
        stagedDir: staged.path,
        installDir: installDir,
        exeName: 'sshive.exe',
        pid: pid,
        cleanupDir: staged.path,
      ),
      flush: true,
    );
    LogBus.instance.info('Update',
        '启动更新助手：${script.path}（安装目录 $installDir）');
    await Process.start(
      'cmd.exe',
      ['/c', script.path],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    // 给助手一点时间挂上，再退出让出文件锁
    await Future<void>.delayed(const Duration(milliseconds: 600));
    LogBus.instance.info('Update', '应用退出以完成更新…');
    exit(0);
  }

  /// 启动时清理上一次更新留下的暂存目录（尽力而为，失败忽略）
  static Future<void> cleanupWindowsStaging() async {
    if (!Platform.isWindows) return;
    try {
      final root = await windowsUpdateRoot();
      if (!await root.exists()) return;
      await for (final e in root.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
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
