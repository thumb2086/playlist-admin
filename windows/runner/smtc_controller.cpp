#include "smtc_controller.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <fstream>
#include <string>

#include <windows.h>

// --- C++/WinRT (SMTC via UWP MediaPlayer) --------------------------------
// Same route as Spotube's libwinmedia: a MediaPlayer instance registers its
// SystemMediaTransportControls with the system media session manager, so the
// media flyout shows up reliably (no GetForWindow interop quirks).

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Storage.Streams.h>

namespace winrt {
using namespace winrt::Windows::Media;
using namespace winrt::Windows::Media::Playback;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;
}

namespace {

std::string NowStamp() {
  using namespace std::chrono;
  const auto t = system_clock::to_time_t(system_clock::now());
  std::tm tm{};
  localtime_s(&tm, &t);
  char buf[32];
  snprintf(buf, sizeof(buf), "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
  return buf;
}

void SmtcLog(const std::string& msg) {
  try {
    size_t len = 0;
    char* local = nullptr;
    if (_dupenv_s(&local, &len, "LOCALAPPDATA") != 0 || local == nullptr) {
      return;
    }
    std::wstring path(local, local + len - 1);
    free(local);
    path += L"\\playlist-admin\\smtc_debug.txt";
    std::ofstream out(path, std::ios::app);
    if (out) {
      out << "[" << NowStamp() << "] " << msg << std::endl;
    }
  } catch (...) {
  }
}

}  // namespace

struct SmtcControllerImpl {
  winrt::MediaPlayer player = nullptr;
  winrt::SystemMediaTransportControls smtc = nullptr;
  winrt::event_token buttonToken{};
  winrt::event_token seekToken{};
  // Last seek position requested from the OS, posted to the UI thread.
  // atomic：SMTC 回呼執行緒寫、UI 執行緒（HandleSystemMediaButton）讀。
  std::atomic<int64_t> pendingSeekMs{0};
};

// Button codes posted from the SMTC event thread to the UI thread.
enum {
  kMediaButtonPlayPause = 1,
  kMediaButtonNext = 2,
  kMediaButtonPrevious = 3,
  kMediaButtonStop = 4,
  kMediaSeek = 5,
};

SmtcController::SmtcController(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_name_("playlist_admin/smtc"),
      impl_(std::make_unique<SmtcControllerImpl>()) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, channel_name_, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(std::bind(
      &SmtcController::HandleMethodCall, this, std::placeholders::_1,
      std::placeholders::_2));

  SmtcLog("SmtcController::init begin (MediaPlayer route)");
  try {
    impl_->player = winrt::MediaPlayer();
    impl_->player.AudioCategory(winrt::MediaPlayerAudioCategory::Media);
    impl_->smtc = impl_->player.SystemMediaTransportControls();
    SmtcLog("SmtcController: MediaPlayer + SMTC acquired");

    impl_->smtc.IsEnabled(true);
    impl_->smtc.IsPlayEnabled(true);
    impl_->smtc.IsPauseEnabled(true);
    impl_->smtc.IsNextEnabled(true);
    impl_->smtc.IsPreviousEnabled(true);
    impl_->smtc.IsStopEnabled(true);
    impl_->smtc.PlaybackStatus(winrt::MediaPlaybackStatus::Closed);

    // 預設展示資訊：Dart 第一次 push 之前，flyout 不可落到 Windows 的
    // fallback（曾顯示 exe 路徑 / GUID 字串）。Title 固定給 app 名。
    try {
      auto updater = impl_->smtc.DisplayUpdater();
      updater.Type(winrt::MediaPlaybackType::Music);
      updater.MusicProperties().Title(L"playlist-admin");
      updater.MusicProperties().Artist(L"");
      updater.MusicProperties().AlbumTitle(L"");
      updater.Thumbnail(nullptr);
      updater.Update();
      SmtcLog("SmtcController: default display metadata set");
    } catch (const winrt::hresult_error& e) {
      SmtcLog(std::string("SmtcController: default metadata FAILED: ") +
              winrt::to_string(e.message()));
    }

    // Button events arrive on the SMTC thread; marshal to the UI thread via
    // a WM_APP message so the Flutter channel is only touched on the platform
    // thread.
    // 診斷：每個按鈕事件都記，確認 shell → event → WM_APP → Dart 鏈路死在哪。
    impl_->buttonToken = impl_->smtc.ButtonPressed(
        [this](winrt::SystemMediaTransportControls const&,
               winrt::SystemMediaTransportControlsButtonPressedEventArgs const& args) {
          SmtcLog(std::string("ButtonPressed event: code=") +
                  std::to_string(static_cast<int>(args.Button())));
          int code = 0;
          switch (args.Button()) {
            case winrt::SystemMediaTransportControlsButton::Play:
            case winrt::SystemMediaTransportControlsButton::Pause:
              code = kMediaButtonPlayPause;
              break;
            case winrt::SystemMediaTransportControlsButton::Next:
              code = kMediaButtonNext;
              break;
            case winrt::SystemMediaTransportControlsButton::Previous:
              code = kMediaButtonPrevious;
              break;
            case winrt::SystemMediaTransportControlsButton::Stop:
              code = kMediaButtonStop;
              break;
            default:
              return;
          }
          ::PostMessageW(window_, WM_APP, code, 0);
        });

    // Timeline seek: when the user drags the progress bar in the media
    // flyout, the OS asks for a new playback position.
    impl_->seekToken = impl_->smtc.PlaybackPositionChangeRequested(
        [this](winrt::SystemMediaTransportControls const&,
               winrt::PlaybackPositionChangeRequestedEventArgs const& evt) {
          const auto requested = evt.RequestedPlaybackPosition();
          // TimeSpan is a chrono duration with 100ns ticks.
          impl_->pendingSeekMs =
              std::chrono::duration_cast<std::chrono::milliseconds>(requested)
                  .count();
          ::PostMessageW(window_, WM_APP, kMediaSeek, 0);
        });
    SmtcLog("SmtcController::init OK");
  } catch (const winrt::hresult_error& e) {
    SmtcLog(std::string("SmtcController::init FAILED: ") +
            winrt::to_string(e.message()));
  } catch (...) {
    SmtcLog("SmtcController::init FAILED: unknown");
  }
}

SmtcController::~SmtcController() {
  if (impl_->smtc) {
    try {
      impl_->smtc.ButtonPressed(impl_->buttonToken);
      impl_->smtc.PlaybackPositionChangeRequested(impl_->seekToken);
      impl_->smtc.IsEnabled(false);
    } catch (...) {
    }
  }
  if (impl_->player) {
    try {
      impl_->player.Close();
    } catch (...) {
    }
  }
}

void SmtcController::HandleSystemMediaButton(int buttonCode) {
  SmtcLog("WM_APP handled: code=" + std::to_string(buttonCode));
  if (buttonCode == kMediaSeek) {
    // Send seek position as a separate channel event with ms value.
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("positionMs")] =
        flutter::EncodableValue(impl_->pendingSeekMs);
    channel_->InvokeMethod(
        "onSeek",
        std::make_unique<flutter::EncodableValue>(payload));
    return;
  }
  SendButtonEvent([&]() -> std::string {
    switch (buttonCode) {
      case kMediaButtonPlayPause:
        return "play_pause";
      case kMediaButtonNext:
        return "next";
      case kMediaButtonPrevious:
        return "previous";
      case kMediaButtonStop:
        return "stop";
      default:
        return "";
    }
  }());
}

void SmtcController::SendButtonEvent(const std::string& event) {
  if (event.empty()) {
    return;
  }
  SmtcLog("channel onButton -> '" + event + "'");
  flutter::EncodableValue value(event);
  channel_->InvokeMethod("onButton", std::make_unique<flutter::EncodableValue>(value));
}

void SmtcController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "update") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args != nullptr) {
      ApplyUpdate(*args);
    }
    result->Success();
    return;
  }
  result->NotImplemented();
}

void SmtcController::ApplyUpdate(const flutter::EncodableMap& map) {
  try {
    if (!impl_->smtc) {
      SmtcLog("ApplyUpdate: smtc is null");
      return;
    }
    auto getStr = [&map](const char* key) -> std::wstring {
      auto it = map.find(flutter::EncodableValue(key));
      if (it == map.end()) {
        return std::wstring();
      }
      const auto* s = std::get_if<std::string>(&it->second);
      if (s == nullptr || s->empty()) {
        return std::wstring();
      }
      // Flutter sends UTF-8 bytes; decode to UTF-16 or SMTC shows mojibake.
      const int len = MultiByteToWideChar(CP_UTF8, 0, s->c_str(),
                                          static_cast<int>(s->size()),
                                          nullptr, 0);
      if (len <= 0) {
        return std::wstring();
      }
      std::wstring out(len, L'\0');
      MultiByteToWideChar(CP_UTF8, 0, s->c_str(),
                          static_cast<int>(s->size()), &out[0], len);
      return out;
    };
    auto getBool = [&map](const char* key, bool def) -> bool {
      auto it = map.find(flutter::EncodableValue(key));
      if (it == map.end()) {
        return def;
      }
      const auto* b = std::get_if<bool>(&it->second);
      return b != nullptr ? *b : def;
    };

    const std::wstring title = getStr("title");
    const std::wstring artist = getStr("artist");
    const std::wstring album = getStr("album");
    const std::wstring artworkUrl = getStr("artworkUrl");
    const bool playing = getBool("playing", false);

    // 診斷：記錄實際推入的 payload（GUID/亂碼來源定位用）。wstring → UTF-8。
    try {
      auto w2u8 = [](const std::wstring& w) -> std::string {
        if (w.empty()) return std::string();
        const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(),
                                          static_cast<int>(w.size()),
                                          nullptr, 0, nullptr, nullptr);
        if (n <= 0) return std::string();
        std::string out(n, '\0');
        WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                            &out[0], n, nullptr, nullptr);
        return out;
      };
      SmtcLog("ApplyUpdate title=[" + w2u8(title) + "] artist=[" +
              w2u8(artist) + "] art=[" + w2u8(artworkUrl) +
              "] playing=" + (playing ? "1" : "0"));
    } catch (...) {
    }

    // Timeline: positionMs/endTimeMs let the OS media flyout render a
    // progress bar with a draggable seek thumb.
    auto getInt = [&map](const char* key, int64_t def) -> int64_t {
      auto it = map.find(flutter::EncodableValue(key));
      if (it == map.end()) {
        return def;
      }
      const auto* d = std::get_if<int64_t>(&it->second);
      if (d != nullptr) {
        return *d;
      }
      const auto* i = std::get_if<int32_t>(&it->second);
      if (i != nullptr) {
        return static_cast<int64_t>(*i);
      }
      const auto* db = std::get_if<double>(&it->second);
      if (db != nullptr) {
        return static_cast<int64_t>(*db);
      }
      return def;
    };
    const int64_t positionMs = getInt("positionMs", 0);
    const int64_t endTimeMs = getInt("endTimeMs", 0);

    auto updater = impl_->smtc.DisplayUpdater();
    updater.Type(winrt::MediaPlaybackType::Music);
    // 全量寫入（含空字串）：換歌缺欄位時清空上一首殘留，否則 flyout 顯示舊資訊。
    updater.MusicProperties().Title(winrt::hstring(title));
    updater.MusicProperties().Artist(winrt::hstring(artist));
    updater.MusicProperties().AlbumTitle(winrt::hstring(album));
    if (!artworkUrl.empty()) {
      try {
        auto ref = winrt::RandomAccessStreamReference::CreateFromUri(
            winrt::Windows::Foundation::Uri(winrt::hstring(artworkUrl)));
        updater.Thumbnail(ref);
      } catch (const winrt::hresult_error& e) {
        SmtcLog(std::string("thumbnail FAILED: ") +
                winrt::to_string(e.message()));
      }
    } else {
      updater.Thumbnail(nullptr);
    }
    updater.Update();

    // Update timeline first, then playback status (order matters for the
    // flyout to render the progress bar). 無時長時推零 timeline 清掉舊進度條。
    try {
      auto timeline = winrt::SystemMediaTransportControlsTimelineProperties();
      timeline.StartTime(std::chrono::milliseconds(0));
      timeline.EndTime(std::chrono::milliseconds((std::max<int64_t>)(0, endTimeMs)));
      timeline.Position(std::chrono::milliseconds(
          (std::max<int64_t>)(0, (std::min<int64_t>)(positionMs, endTimeMs))));
      impl_->smtc.UpdateTimelineProperties(timeline);
    } catch (const winrt::hresult_error& e) {
      SmtcLog(std::string("timeline FAILED: ") +
              winrt::to_string(e.message()));
    }

    impl_->smtc.PlaybackStatus(
        playing ? winrt::MediaPlaybackStatus::Playing
                : winrt::MediaPlaybackStatus::Paused);
  } catch (const winrt::hresult_error& e) {
    SmtcLog(std::string("ApplyUpdate FAILED: ") + winrt::to_string(e.message()));
  } catch (...) {
    SmtcLog("ApplyUpdate FAILED: unknown");
  }
}
