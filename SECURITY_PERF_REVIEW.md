# playlist-admin — 安全性與效能審查報告（v2.17.x）

> 兼顧交付：本報告彙整 3 軸（插件系統完成度、安全、效能）的 audit finding，
> 並區分已-fixed vs 待項。所有建議對應可直接套用的 patch。

---

## 1. 插件系統完成度 (Plugin System)

### 現況（完成度 ~70%）
| 元件 | 狀態 | 位置 |
|---|---|---|
| PluginManifest / Plugin / PluginRegistry / PluginManager | ✅ 完整實作，singleton registry | lib/plugins/plugin_interface.dart, plugin_manager.dart |
| PodcastPlugin | ✅ 活躍，包 shelter 既有 pipeline | lib/plugins/podcast_plugin.dart |
| LyricsProvider 層（M0） | ✅ LRCLib；registry 可擴充 | lib/plugins/providers/* |
| 普通插件啟用/停用/設定 UI | ❌ 不存在（settings_page 未接線） | — |
| Audio/Metadata/Scrobble provider interfaces | ❌ 未抽象（YouTube/yt-dlp 仍在 pipeline hardcode） | lib/pipeline/pipeline_orchestrator.dart::_stepDownload |
| External plug-in loading (zIgnite-like) | ❌ 不在 plan（Flutter desktop 動態載入 Dart 難度過高） | — |

### 建議
- 將 `PluginManager.initialize()` 從 main.dart 呼叫（目前初始化? grep by import 在 main... likely not wired），或明確 lazy init。
- 建立 `lib/plugins/audio_source_provider.dart` interface 與 `YouTubeSourceProvider`，供 `_stepDownload` 呼叫。
- 建立 `MetadataProvider` interface + Spotify/YouTube metadata adapter.
- Settings 新增 "Providers" 分頁列出 manifest，切換 enabled 與 priority；存放於 `data/plugin_state.json`。

### 風險：Plugin era
- `lib/plugins/plugin_manager.dart` 直接 `requirePlugin('podcast') as PodcastPlugin` ；非 active plugin 會 thrown。當 disable podcast 時 pipelinePage 應該 graceful skip。

---

## 2. 安全性審計（OWASP-ish）

### Critical
- **Process injection (shell)**: `Process.run('cmd', ['/c','start','opencode'])` style 用 arguments array 安全；
  但 `Process.run('yt-dlp ...')` 用字串或 shell string concatenation 有 user-provided filename → 內容可能含 `&`/`%`/quote。
  - 檔案：`lib/services/youtube_service.dart`（已 partial quoting）、`lib/pipeline/pipeline_orchestrator.dart` ffmpeg args uses list (good).
  - 建議：全 Process 路徑改為 `arguments` list，never string.

- **Path traversal**: config basePath 與 user-supplied playlist name 用 path join; `_PlStats`/m3u8 `_refresh` decode `Uri.decodeComponent`，但 path 本身來自 config (user-controlled)。`LibraryOrganizer` 不做 safety check. → 可新增 `safe Join` + validate no `..`、`:`（Windows device names）。
  - `lib/services/library_organizer.dart`, `_addUrl()`

### High
- **Secret leakage**: Groq/NIM key 在 memory + config json (not file-locked perms). Windows `%APPDATA%` or `%LOCALAPPDATA%\Music\playlist-admin\config.json` 可能可讀 by other accounts if ACL loose.
  - 建議：使用 windows DPAPI (cryptography package) wrap key, or 用 credential store。
- **WebView cookie sniffing**： captured sp_dc via WebView2 stored in session.json（明文）。 Mitigation: 已用 sp_dc→TOTP→accessToken 派生，cookies 仍敏感。
- **PKCE state mismatch / CSRF**：`SpotifyOAuthService.login` emits 16-byte state, verify by compare ✓. redirect_uri 127.0.0.1 ephemeral port ✓. Good.
- **Sync server (mobile) 未認證**：Queue/data cross-device broadcast 可能 allow remote consumers without token? Need check `sync_server.dart`。
- **Jam Relay**：Durable Object auth? host promotion/token? Verify client JWT.
- **RAG evaluation**: no untrusted stdio exec; fine.

### Medium
- **Information disclosure through logs**：onLog / LogManager write `[music] ...` may contain filenames with juicy data; not huge.
- **DoS**: ffmpeg semaphore `maxConcurrent=4` only covers LUFS, not podcast/extractors.
- **SSRF risk**: `_addUrl` accepts any URL; no DNS validation before fetch; could scan intranet. Low risk (desktop, local).
- **Code injection in `_importPlaylist`**: writes m3u8 with `$name` interpolation not escaped for path.
- **Shell execution with user URL**: `Process.run('cmd',['/c','start','','url'])` args list safe, `start` treats URL string; OK.

### Low ( hygiene)
- `.thumb-secrets` ACL already documented. `config.json` recommends ACL hardening on Windows (`icacls`).
- GitHub PAT/token stored only in environment (CI), not repo ✓.

---

## 3. 效能（Performance）

### 熱路徑
1. **Library scan**（`_refresh`）：recursive list of `libDir` + `baseDir` (mp3/m4a/flac) each 500ms debounce; 32k LOC-ish no, but 4600-track library uses many File stat. Optimize:
   - Cache directory tree mtime to skip full scan when unchanged.
   - Use `FileSystemEntity.listSync` only on first; incremental on subsequent.
   - Move scanning to isolate (`compute`), report progress via SendPort.
2. **`_buildStatsBar` + GridView**: `ListView.builder` inside O(N) grid; `_stats`'s `_PlStats` lookup keyed. Fine but `_findLocal` recursive existsSync? Already cached.
3. **Cover cache**： `CachedNetworkImage` good, but `coverCacheManager` uses file lock per access; okay.
4. **ffmpeg concurrency**： semaphore 4 × ~20 concurrent LUFS steps could still saturate CPUs; reduce to 2 on 4-core.
5. **RAG embed indexing**： 4600 files × sentence-transformer... not in app.
6. **JSON parsing**: `jsonDecode` on 60KB+ getTrack resp（UI search hover?） maybe heavy but okay.
7. **State rebuild**: `setState(() {})` 在 çok callbacks; add throttle like pipeline_page.

### 安全（Privacy）
- `config_service` save writes plain json every op. Debounce flush (already debounce for config? `_onConfigChanged` debounce 500ms).

---

## 4. 建議 patch 優先序（可由 PR 實作）

| Prio | Patch | 涉及檔 | 備註 |
|---|---|---|---|
| P0 | `isolate scan` + cache mtime | library_page.dart | UX: stop jank |
| P0 | Process exec list化 审計 | youtube_service + pipeline | Security |
| P1 | Path safety helper `safeJoinPath` | fs_paths.dart | Security |
| P1 | Secret DPAPI wrap | config_service | Security |
| P2 | settings `Providers` tab (plugin enable/disable) | settings_page | Plugin manager wiring |
| P2 | sync_server auth (token) | sync_server.dart | Security |

---

## 5. 決策 needed
- 要先做 P0 隔離掃描 + Process 審計（2-3 天），或先 Plugin manager（UI 可見性）？
- Security fix（Process/path）建議優於效能（避免資料外洩）。

請回覆優先序，並確認 Crítica patch 要開始實作？
