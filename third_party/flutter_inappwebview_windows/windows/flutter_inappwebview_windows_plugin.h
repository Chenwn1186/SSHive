#ifndef FLUTTER_PLUGIN_FLUTTER_INAPPWEBVIEW_PLUGIN_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_INAPPWEBVIEW_PLUGIN_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>

namespace flutter_inappwebview_plugin
{
  class WebViewEnvironmentManager;
  class InAppWebViewManager;
  class InAppBrowserManager;
  class HeadlessInAppWebViewManager;
  class CookieManager;
  class PlatformUtil;

  class FlutterInappwebviewWindowsPlugin : public flutter::Plugin {
  public:
    // ssh_agent patch: 静态通道名（Dart 侧 MethodChannel 同名调用）
    static inline const std::string SCROLL_CHANNEL_NAME = "com.chenwnx.sshagent/webview_scroll";

    flutter::PluginRegistrarWindows* registrar;
    std::unique_ptr<WebViewEnvironmentManager> webViewEnvironmentManager;
    std::unique_ptr<InAppWebViewManager> inAppWebViewManager;
    std::unique_ptr<InAppBrowserManager> inAppBrowserManager;
    std::unique_ptr<HeadlessInAppWebViewManager> headlessInAppWebViewManager;
    std::unique_ptr<CookieManager> cookieManager;
    std::unique_ptr<PlatformUtil> platformUtil;

    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

    FlutterInappwebviewWindowsPlugin(flutter::PluginRegistrarWindows* registrar);

    virtual ~FlutterInappwebviewWindowsPlugin();

    // Disallow copy and assign.
    FlutterInappwebviewWindowsPlugin(const FlutterInappwebviewWindowsPlugin&) = delete;
    FlutterInappwebviewWindowsPlugin& operator=(const FlutterInappwebviewWindowsPlugin&) = delete;
  private:
    // The ID of the WindowProc delegate registration.
    int window_proc_id = -1;
    // ssh_agent patch: 滚动倍率热更新的静态通道实例（保持存活）
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> scrollChannel_;
    std::optional<LRESULT> FlutterInappwebviewWindowsPlugin::HandleWindowProc(
      HWND hWnd,
      UINT message,
      WPARAM wParam,
      LPARAM lParam);
  };
}
#endif  // FLUTTER_PLUGIN_FLUTTER_INAPPWEBVIEW_PLUGIN_PLUGIN_H_
