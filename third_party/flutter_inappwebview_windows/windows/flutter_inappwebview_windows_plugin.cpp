#include "flutter_inappwebview_windows_plugin.h"

#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include "cookie_manager.h"
#include "headless_in_app_webview/headless_in_app_webview_manager.h"
#include "in_app_browser/in_app_browser_manager.h"
#include "in_app_webview/in_app_webview_manager.h"
#include "platform_util.h"
#include "webview_environment/webview_environment_manager.h"


#pragma comment(lib, "Shlwapi.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "rpcrt4.lib")  // UuidCreate - Minimum supported OS Win 2000
#pragma comment(lib, "WindowsApp.lib")

namespace flutter_inappwebview_plugin
{
  // static
  void FlutterInappwebviewWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar)
  {
    auto plugin = std::make_unique<FlutterInappwebviewWindowsPlugin>(registrar);

    // ssh_agent patch: 注册滚动倍率热更新静态通道（Dart 侧同名 MethodChannel 调用，
    // 对全部 WebView 即时生效，不重建 WebView）
    plugin->scrollChannel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), FlutterInappwebviewWindowsPlugin::SCROLL_CHANNEL_NAME,
      &flutter::StandardMethodCodec::GetInstance());
    plugin->scrollChannel_->SetMethodCallHandler(
      [plugin_raw = plugin.get()](const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
      {
        if (call.method_name() == "setMultiplier") {
          double v = 1;
          if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = args->find(flutter::EncodableValue("value"));
            if (it != args->end()) {
              if (const auto* num = std::get_if<double>(&it->second)) {
                v = *num;
              }
              else if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
                v = static_cast<double>(*i64);
              }
            }
          }
          if (plugin_raw->inAppWebViewManager) {
            plugin_raw->inAppWebViewManager->setScrollMultiplierAll(v);
          }
          result->Success();
        }
        else {
          result->NotImplemented();
        }
      });

    registrar->AddPlugin(std::move(plugin));
  }

  FlutterInappwebviewWindowsPlugin::FlutterInappwebviewWindowsPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar)
  {
    webViewEnvironmentManager = std::make_unique<WebViewEnvironmentManager>(this);
    inAppWebViewManager = std::make_unique<InAppWebViewManager>(this);
    inAppBrowserManager = std::make_unique<InAppBrowserManager>(this);
    headlessInAppWebViewManager = std::make_unique<HeadlessInAppWebViewManager>(this);
    cookieManager = std::make_unique<CookieManager>(this);
    platformUtil = std::make_unique<PlatformUtil>(this);

    window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
      {
        return HandleWindowProc(hWnd, message, wParam, lParam);
      });
  }

  FlutterInappwebviewWindowsPlugin::~FlutterInappwebviewWindowsPlugin()
  {
    if (registrar) {
      registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
    }
    webViewEnvironmentManager = nullptr;
    inAppWebViewManager = nullptr;
    inAppBrowserManager = nullptr;
    headlessInAppWebViewManager = nullptr;
    cookieManager = nullptr;
    platformUtil = nullptr;
  }


  std::optional<LRESULT> FlutterInappwebviewWindowsPlugin::HandleWindowProc(
    HWND hWnd,
    UINT message,
    WPARAM wParam,
    LPARAM lParam)
  {
    std::optional<LRESULT> result = std::nullopt;

    if (platformUtil) {
      result = platformUtil->HandleWindowProc(hWnd, message, wParam, lParam);
    }

    return result;
  }
}