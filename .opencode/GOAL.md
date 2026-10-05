# Goal
- GoalID: 11ee50dd-9b9f-416c-af97-c64a51a51b04
- Status: active
- Created: 2026-10-05T20:30:00+08:00
- Updated: 2026-10-05T20:30:00+08:00
- Previous: .opencode/GOAL_achieved_2026-09-24.md（P0 全達標已歸檔；P0-A 圖書館區依使用者決定移除）

## Objective
手機獨立播放 + 改版整合收尾：手機不依賴電腦可播（直連/同步/轉播三路），
v2.15.34～v2.15.40 改版累積的審計問題清零，版號以 git tag 為準。

## Stopping condition
1. P0 全部實作並通過 Verification；
2. `dart analyze lib` 0 issues；
3. 本地 build + CLI smoke 通過，tag 推送後 CI 綠燈。

## Must read first
- lib/services/player_controller.dart（play/playStream/_playStreamDirect/completed handler）
- lib/services/youtube_service.dart（resolveStreamDirect）
- lib/services/sync_server.dart + sync_client.dart（區網同步）
- lib/services/cover_cache.dart（key 格式）

## Verification
```bash
dart analyze lib                     # 必須 0 issues
flutter build windows --release --dart-define=APP_VERSION=<ver>-dev
python C:\Users\CPXru\AppData\Local\Temp\opencode\cli_smoke.py   # status/podcast exit 0
flutter test test/sync_lan_test.dart test/stream_direct_test.dart
```

## P0（本 goal）
- [x] P0-1 手機直連串流（Spotube 同款）：resolveStreamDirect + playStream 手機分支
- [x] P0-2 桌面管線失敗 → 直連 fallback
- [x] P0-3 隊尾 autoplay 優先（loop 只管單曲重播）
- [x] P0-4 死開關接線：autoDownloadUpdate→背景下載、debugMode→LogManager.debug、
      enableRetroactiveLyrics→播放時預取歌詞（+設定頁開關）
- [x] P0-5 ISRC：parser 防禦性讀取 + CoverCache.key 小寫統一
- [x] P0-6 小修包：歌單卡可點、手機 Stats、USB/同步鈕按平台互斥、導覽文案
- [x] P0-7 播放旗標：playFile 補 _currentIsPodcast=false；CLI help/CI study 同步等
- [ ] P0-8 經電腦轉播（手機直連 403 時的保底）：手機經區網吃電腦轉碼管線
  - [x] 代碼完成：SyncServer `/relay-stream?q=` 複用 StreamServer.serveRelay 管線；
    config.lastSyncHost（SyncPage 連線時記住）；_playStreamDirect 二段式（直連→轉播）
- [ ] P0-9 實機驗證：手機 Wi-Fi/4G 下三路播放 + 回報
- [x] P0-10 手機獨立下載（Spotube 式）：YoutubeService.downloadDirect
  （直鏈 HTTP 存檔 m4a/webm，無 yt-dlp/ffmpeg）+ 詳情頁手機分支 +
  本地判重認 m4a/webm（三處）；宿舍網 E2E 驗到 manifest 通、
  媒體 403（環境擋，清網下應過）

## P1（下一個 goal 候選）
- Spotify mutation（like/加入清單，需抓 persisted hash）
- fetchAlbum/fetchArtist 詳情頁、liked 一鍵整批下載、scrobble→Spotify

## P2
- 藝人追蹤/新專輯推播 UI、多帳號、搜尋結果分頁/進階過濾

## Progress log
- [2026-10-05] 開新 goal（舊 achieved 歸檔為 GOAL_achieved_2026-09-24.md）；
  P0-1～P0-8 已實作：直連串流/桌面fallback/隊尾autoplay/死開關接線/ISRC/
  小修包/播放旗標/經電腦轉播；`dart analyze lib` 0 issues；
  sync_lan（+轉播路由測試）與 stream_direct 全過；
- [2026-10-05] v2.15.41 發版：本地 build ✓、CLI smoke（status/podcast exit 0）✓、
  analyze 0 issues ✓，main + tag 已推，CI 跑 Release + npm 中。
- [2026-10-05] v2.15.42 發版（手機獨立下載）：同上全綠，main + tag 已推。
- [2026-10-05] v2.15.43 發版（手機導引無限重現修復 + localIndex 認 m4a）：
  同上全綠，main + tag 已推。
- [2026-10-05] v2.15.44 候選（用戶決議落地）：全站統一 MP3（kAudioExts 共用判重、
  同步下載後刪同目錄 m4a/webm）、loop 隊尾優先回歸、_openPlaylist 重複碼合併、
  整理無 m3u8 拒絕、手機 in-app APK 更新（CI universal 包 + versionCode、
  open_filex 安裝、FileProvider/權限）。
