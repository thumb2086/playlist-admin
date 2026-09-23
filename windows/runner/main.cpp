#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>  // SetCurrentProcessExplicitAppUserModelID
#pragma comment(lib, "shell32.lib")

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins. 只在成功時配對 CoUninitialize；失敗直接結束（WinRT SMTC 需要 COM）。
  const HRESULT comHr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(comHr)) {
    return EXIT_FAILURE;
  }

  // SMTC 卡片的應用程式名稱：無 AUMID 的 Win32 app 從非安裝路徑執行時
  // Windows 顯示「未知的應用程式」。給固定 AUMID 統一顯示 playlist-admin。
  ::SetCurrentProcessExplicitAppUserModelID(L"thumb2086.playlist-admin");

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"playlist-admin", origin, size)) {
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
