# playlist-admin ↔ Spotube 功能補足計畫（v2.17+）

> 本計畫以 Spotube v6 beta 的功能矩陣為 đối照，對齊到本 app 的「Sync + Pipeline 工具」定位，
> 並 distinguishing ** lyrics provider/music source plugin**、**本機 GUI 播放器**、**移動端**、**桌面系統整合** 四大 axis。
>
> 先前已完成：Lyrics Provider 層（v2.16.0）、Spotify PKCE OAuth（v2.17.0-alpha.1）。
>
> ---
>
> ## §1 現況 inventory（本 app 已具備）
>
> - GUI (Flutter, Windows primarily)：Home, Search, Jam, Library, Pipeline, Stats, Settings, PlaylistDetail, AudioExtractor, Download, Lyrics, Sync
> - 音樂來源：YouTube via yt-dlp、Spotify metadata (GQL persisted)、RSS podcast pipeline
> - 播放：media_kit (Windows) / just_audio (mobile 已有 queue)
> - 同步：mobile sync server + desktop sync client
> - Pipeline：scrape/import/download/metadata/lyrics/LUFS/RAG, podcast transc ceiling
> - Jam relay：Cloudflare DO WebSocket
> - TUI：16+ screen 但 args ad-hoc
>
> ---
>
> ## §2 待補功能（Spotube parity）— phân級
>
> ### P0 (v2.17–v2.18, 6–8 weeks) — playback core & library sources
>
> | # | 項目 | 內容 | 依賴 |
> |---|---|---|---|
> | P0-1 | Spotify OAuth Library Sync | 已有 PKCE service，下一步 library API + 匯入 | v2.17.0-alpha.1 |
> | P0-2 | Spotify Library Tab (Playlists/Liked Songs/Albums/Podcasts) | 前端 tab + m3u8 materialize | P0-1 |
> | P0-3 | Playable stream resolver 抽象 | `AudioSourceProvider` (yt-dlp/YT Music/Tidal) | v2.16 plugin layer pattern |
> | P0-4 | 播放列 UX 完善 | queue、shuffle、repeat(one/all)、crossfade、normalization (LUFS 已有) | — |
> | P0-5 | Lyrics 時間同步頁 | 已有 lyrics_page，加 auto-scroll + sync-offset 調整 + 翻譯 ShowOnTop | — |
> | P0-6 | 全域 hotkey + system tray (desktop) | Win32 MPRFd + tray icon + mini-player window | media_kit Win32 |
> | P0-7 | Android background playback + notification | audio_service (just_audio) 已 partially; confirm service lifecycle | — |
>
> ### P1 (v2.18–v2.20, 6–10 weeks) — discover/search/streaming ecosystem
>
> | # | 項目 | 內容 |
> |---|---|---|
> | P1-1 | Browse/Home 面 | Spotify browseAll/hubs + featured/playlist cards（homepage feed） |
> | P1-2 | Search autocomplete + filter | typed query, results grouped, recent history |
> | P1-3 | Genre/ mood browse | api genre seeds, category rails |
> | P1-4 | Last.fm / ListenBrainz scrobbling | scrobble track, love/unlove; provider interface |
> | P1-5 | Liked songs bulk import | like → enqueue download |
> | P1-6 | Blacklist / filter preferences | exclude artists/keywords/regions |
> | P1-7 | Equalizer & audio settings | media_kit/exo eq, balance, ReplayGain |
> | P1-8 | Podcast browse + subscribe (Spotify show catalog search) | already search page; add subscribe button |
> | P1-9 | Android Auto / Apple CarPlay | Android Auto media browser; requires ExoPlayer ↔ CarAudio API |
> | P1-10 | Local stats & insights dashboard (extension) | stats_page 已有，加 top songs/artist/genre heatmap |
>
> ### P2 (v2.20+, long tail)
>
> | # | 項目 | 內容 |
> |---|---|---|
> | P2-1 | Plugin runtime (external) | Zipline-like sandboxed host not feasible in Flutter desktop without major rewiring; instead: **Dart package plugins compiled-in** via `PluginRegistry`（現有）+ config enable/disable |
> | P2-2 | Offline mode | download cache index, mark offline, no-network playback |
> | P2-3 | Smart playlists (dynamic/rule-based) | filter spec, auto-updating m3u8 |
> | P2-4 | Recent played history + resume | PlayerController already tracks current path; persist & resume UI |
> | P2-5 | Sleep timer / crossfade UI | injected in player bar |
> | P2-6 | Multi-device playback (Jam session v2) | extend existing Jam DO with presence, queue voting |
> | P2-7 | Web version (Spotify web player equivalent offline) | Flutter web compile + audio_web |
>
> ---
>
> ## §3 Audio source provider feasibility (important caveat)
>
> Spotube's "audio source plugin" lets a plugin return YouTube/Invidious/etc. streams. **Spotify's official track has no playable stream URL** (ToS: 3rd-party can't stream Spotify content). So playback here will remain YouTube-based + cached m3u8 + RSS podcasts. Web API only supplies metadata + library. Configure `AudioSourceProvider` with:
> - `YouTubeProvider` (existing yt-dlp/youtube-dl)
> - `InvidiousProvider` (fallback with direct url)
> - `LocalProvider` (for downloaded files)
> - `PodcastRssProvider` (RSS enclosures)
>
> This mirrors Spotube's split without DRM violation.
>
> ---
>
> ## §4 Plugin ecosystem compat strategy
>
> Spotube v6 is Kotlin/JS via Zipline — **not portable** to this Flutter app without rewriting host (~M sdk). Decision: **keep Dart interface plugins** (current `Plugin`/`LyricsProvider`), ship curated provider libraries as pub packages consumed at build time, documented API parity but no third-party distributed .smplug. Advantages: simpler delivery, less supply-chain risk; tradeoff: no "install random plugin from hub".
>
> ---
>
> ## §5 Suggested execution order
>
> 1. M1 (v2.17.0): Spotify PKCE login UI + library sync (P0-1/P0-2)
> 2. M2 (v2.18.0): searchable albums/liked + download enqueue (P0-4 + P0-6)
> 3. M3 (v2.19.0): audio source provider + desktop integrations
> 4. M4 (v2.20.0): P1 features + stats
>
> Each milestone ships a tagged release (already validated release pipeline).
>
> ---
>
> ## §6 养護/測試
>
> - Mock Spotify Web API in unit tests for `/me/playlists` and token refresh
> - Desktop GUI smoke (drag&drop install, tray controls), mobile (Android Auto minimal)
> - TUI `--json` smoke output stability (M3)
>
> ---
>
> ## §7 開放問題（請回答）
>
> 1. ** priorities**: 哪些 P1 項目是必要的（例如 scrobbling、Android Auto）？或全部 P0 先？
> 2. **account linkage**: 要求所有使用者自建 Spotify Developer app，還是本 app 用 centralized OAuth broker?
> 3. **release cadence**: 每 milestone 一次 tag（CI 已穩定 JDK17），或更細？
