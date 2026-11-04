# playlist-admin 後續roadmap方案（Spotify 完整音樂庫 + 本地改版 + CLI→TUI）

> 對應你的三點需求：
> 1. Spotify 音樂庫完整可用（歌單 / Liked Songs / Albums / Podcasts …）
> 2. 本地音樂庫改版
> 3. CLI 升級為完整 TUI（opencode-cli 風格）
>
> 採分階段推進；每個階段都會打包 tag 可測，避免一次大爆發。
>
> ---
>
> ## 現況分析（為什麼現在覺得 Spotify 音樂庫「不能用」）
>
> - `library_page.dart` 的 `playlists` 只來自 `ConfigService.playlists`，
>   也就是 `cfg.urlNames`（使用者手動貼的 Spotify playlist URL）。
>   **官方 Spotify library（/me/playlists, /me/tracks saved, /me/albums, /me/shows）
>   從未被拉進來** → 用戶在 Spotify 收藏的歌單/歌/專輯/節目 app 看不到。
> - 本地庫：`_refresh` 只掃 `.m3u8` 檔案並比對 stem，沒有 `album/artist` metadata 面、沒有搜尋、UI 全部擠在同一 GridView。
> - CLI/TUI：已有 16+ TUI screen，但 args 解析是 ad-hoc (`if (cmd == 'x')`)，沒有 `--help`/completion/JSON 輸出，多命令組合時易混淆。
>
> ---
>
> ## Milestone 0 — 歌詞 Provider 層（已完成，v2.16.0）
>
> 歌詞服務改為 provider chain（`LyricsProvider` + `LyricsProviderRegistry`，LRCLib 首批）。
> 後續加 NetEase / Megalobiz 只需新-provider。
>
> ---
>
> ## Milestone 1 — Spotify 完整音樂庫（預計 2 週）
>
> ### 1.1 OAuth PKCE 雙路授權
> - 新增 `SpotifyPkceService`（無 secret，僅 browser redirect → code → access_token + refresh_token）
> - scope: `user-library-read user-library-modify playlist-read-private
>   playlist-read-collaborative user-follow-read user-top-read`
> - 儲存 access/refresh token 到 `cache/spotify_session.json`，auto-refresh on 401。
>
> ### 1.2 Library API wrapper（Spotify Web API, official, quota-safe）
> - `lib/services/spotify_library_service.dart`
>   - `fetchPlaylists()` / `fetchSavedTracks(offset, limit)` / `fetchSavedAlbums()` /
>     `fetchSavedShows()` / `fetchFollowedArtists()`
>   - 全部分頁（page_size 50），含 `Retry-After` 處理。
>
> ### 1.3 匯入 UI
> - LibraryPage 重排：`Playlists` / `Liked Songs` / `Albums` / `Podcasts` / `Artists` tabs
>   （保底「Spotify」badge，本機歌單另成「本機」區）
> - 每筆 item 提供：
>   - Spotify URL → 內建播放（`PlayerController.play(spotifyUri)`）
>   - 「匯入為本機歌單」按鈕：把曲目列表 materialize 成 m3u8（之後 offline 播放）
>   - 「加入下載佇列」→ existing pipeline `_stepDownload`.
>
> ### 1.4 快取
> - `data/spotify_library/` 快取 JSON + ETag；每 30 分鐘或手動 refresh。
>
> ### 交付
> - tag `v2.17.0`（Android + Windows release）。
>
> ---
>
> ## Milestone 2 — 本地音樂庫改版（預計 1.5 週）
>
> - 掃描 isolate 執行（`compute`）避免 UI 卡頓；metadata 請求走 Stream，每批 setState。
> - metadata 索引：`assets/tools/ffprobe` 提取的 `artist/album/title/genre/year/coverArt` 寫入 `library_index.json`（可 rebuild）。
> - UI：Tabs：全部 / 歌單 / 歌曲 / 專輯 / 藝人，每列有 virtual scroll + cover cache。
> - 搜尋 localized search over index。
> - Filter / sort（最近新增、A-Z、most-played from history）。
>
> ---
>
> ## Milestone 3 — CLI → full TUI（opencode-cli 風格）（預計 2 週）
>
> ### 3.1 命令樹 + ArgParser
> - 引入 `package:args`，重寫 `cli_main.dart` 為 subcommand tree：
>   `playlist-admin status|pipeline|podcast|lyrics|library|search|jam|serve|config|doctor|help`
> - 每個 subcommand 有 `--json`, `--quiet`, `--verbose`, `--config <path>`。
> - Man page auto-gen（`playlist-admin help [cmd]`）。
>
> ### 3.2 TUI v2（opencode 風格）
> - 像 opencode 的 TUI：頂部狀態列、左側 nav、中央 content、下方輸入列；
>   tabs: Fleet / Agent / Status / Library / Pipeline / Settings（復用現有 TuiScreen）。
> - Live log following, scrollback buffer, keyboard shortcuts (Tab, arrows, ⌘K, q).
> - 插入 command palette（Ctrl+P）映射到 commands。
>
> ### 3.3 REPL mode（可選）
> - `playlist-admin shell` 進入持久 session，history + autocompletion；模擬 opencode 但受限於本 app 的命令集。
>
> ### 3.4 JSON scripting
> - `playlist-admin ... --json` 輸出結構化結果，供腳本整合。
>
> ---
>
> ## Milestone 4 — Plugin System v2（後續）
>
> - Milestone 0 的 lyrics provider UI 化。
> - Audio source provider（YouTube 先行 → Spotify audio unsupported for third parties，注意 DRM；以 playback URL 取而代之）。
> - Provider 管理頁（enable / priority / install from directory）。
>
> ---
>
> ## 風險/注意
>
> 1. Spotify Web API 個人資料 endpoint quota：每次 refresh 都要全量分頁 → ETag + incremental since.
> 2. judicially: Spotify ToS 禁止 redistribution of audio; app 已用 yt-dlp 為 audio source → OK.
> 3. Windows-only 換本機測試（macOS/Linux 也支援 GUI，但測試主要在 Windows）。
> 4. CLI TUI 需要真實 TTY —— CI 無法 automated test，人工 smoke。
>
> ---
>
> ## 建議執行順序
>
> **先做 Milestone 1.1 + 1.2（OAuth + Library API）** 一周內拿到可登入 Spotify 並列出全部 playlists/albums/saved tracks；之後再 1.3 UI 視覺 polish。
>
> 要我.Signal 確認還是直接開始 Milestone 1？
