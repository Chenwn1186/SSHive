#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

// NOTE: keep this file ASCII-only. The runner project is built with
// warnings-as-errors, and MSVC (code page 936 on this machine) reports C4819 -
// which then becomes a hard error - for UTF-8 source files without a BOM.
// Non-ASCII notes belong in the Dart sources or design/research/*.md instead.

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // SSHive: force WebView2 into "Window to Visual" hosting mode.
  //
  // Why: flutter_inappwebview_windows embeds WebView2 through Visual
  // (composition) hosting - in_app_webview_manager.cpp calls
  // createInAppWebViewEnv(hwnd, /*willBeSurface=*/true, ...). Per Microsoft's
  // "Windowed vs. Visual hosting" documentation, visual hosting means the host
  // app receives spatial input (mouse/touch/pen) and must forward it to
  // WebView2. The plugin therefore scales Flutter's wheel delta by a
  // user-tunable multiplier and synthesizes WHEEL_DELTA events in sendScroll()
  // (in_app_webview.cpp) with mismatched units, which makes wheel scrolling
  // feel unpredictable; keyboard/IME focus problems live on the same path.
  //
  // "Window to Visual" hosting lets the OS deliver input to WebView2 directly
  // while content is still output to a Visual, so the existing texture capture
  // path keeps working. It must be set before any WebView2 initialization.
  //
  // Escape hatch: launch with SSHIVE_WEBVIEW_HOSTING=default to keep the
  // plugin's default hosting mode (the wheel multiplier setting becomes
  // effective again) for A/B comparison.
  {
    wchar_t raw[64] = {};
    const DWORD len =
        ::GetEnvironmentVariableW(L"SSHIVE_WEBVIEW_HOSTING", raw, 64);
    // len == 0 means "not set"; len >= 64 means the value was too long and got
    // truncated - both are treated as "not set".
    const std::wstring override_value =
        (len > 0 && len < 64) ? std::wstring(raw, len) : std::wstring();
    if (override_value != L"default") {
      ::SetEnvironmentVariableW(
          L"COREWEBVIEW2_FORCED_HOSTING_MODE",
          L"COREWEBVIEW2_HOSTING_MODE_WINDOW_TO_VISUAL");
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SSHive", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
