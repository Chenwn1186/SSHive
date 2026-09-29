package com.chenwnx.sshive

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新用的原生能力（零新增 pub 依赖）：
 * - getVersionName：读包管理器里的真实版本号（Dart 侧无法直接获取）
 * - installApk：把下载好的 APK 通过 FileProvider 交给系统安装器
 *
 * Dart 侧调用点见 lib/services/update_service.dart。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.chenwnx.sshive/update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVersionName" -> {
                        try {
                            @Suppress("DEPRECATION")
                            val info = packageManager.getPackageInfo(packageName, 0)
                            result.success(info.versionName ?: "")
                        } catch (e: Exception) {
                            result.error("VERSION_FAILED", e.message ?: e.toString(), null)
                        }
                    }

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("NOT_FOUND", "apk not found: $path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // authority 与 AndroidManifest 里的 ${applicationId}.fileprovider 一致
                            val uri: Uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri, "application/vnd.android.package-archive"
                                )
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // 常见原因：未授予"安装未知应用"权限
                            result.error("INSTALL_FAILED", e.message ?: e.toString(), null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
