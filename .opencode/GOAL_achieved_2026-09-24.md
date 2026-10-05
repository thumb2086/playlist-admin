# Goal
- GoalID: 11ee50dd-9b9f-416c-af97-c64a51a51b04
- Status: achieved
- Created: 2026-09-24T13:10:00+08:00
- Updated: 2026-09-24T13:55:00+08:00

## Objective
看看 Spotify 跟 Spotube，我們需要什麼功能，都幫我計畫與實作。
（盤點兩者的核心功能 → 對照本專案現況產出缺口清單 → 分期計畫 → 依計畫實作。）

## Stopping condition
1. `## 功能盤點與分期計畫` 章節完成（Spotify/Spotube 功能清單 + 現況對照 + P0/P1/P2 分期，寫入本檔）；
2. 所有 P0 功能已實作，且通過全部驗證指令（見 Verification）；
3. P1/P2 明列於計畫章節作為後續待辦。
（未完成 P0 者不得標 achieved。）

## Must read first
- lib/services/spotify_gql_client.dart ✅（search/playlist/home/whatsNew/browseAll/libraryV3/likedSongs/getTrack）
- lib/services/spotify_session.dart ✅（sp_dc→TOTP→web-player token）
- lib/pages/spotube_page.dart ✅（一鍵補全下載器；掛在 download_page 內）
- lib/pages/library_page.dart ✅（純本機 m3u8 庫：加 URL/統計/USB 匯出）
- lib/pages/search_page.dart、lib/pages/home_page.dart ✅（本 session 已讀）
- 歌詞鏈路 ✅：lyrics_service（lrclib）/ lyrics_page（同步 LRC 高亮）/ lrc_parser / config(offsets, retroactive)
- app.dart sidebar ✅（home/search/jam/library/pipeline/stats/settings）

## Verification
```bash
dart analyze lib                     # 必須 0 issues
flutter build windows --release --dart-define=APP_VERSION=2.15.32
# CLI smoke（python subprocess 捕 exit code）：status exit 0 / podcast exit 0 且 [17/17]
```

## 功能盤點與分期計畫

### A. 現況盤點（本專案已具備）
| 來源 | 功能 | 狀態 |
|---|---|---|
| Spotify | sp_dc cookie → TOTP → web-player token（自動續期） | ✅ spotify_session |
| Spotify | 搜尋（全型/單曲）、歌單讀取（分頁）、個人首頁、whatsNew、browseAll | ✅ gql client |
| Spotify | 個人圖書館 API：libraryPlaylists / libraryAlbums / likedSongs | ⚠️ **API 現成但 0 使用者（死碼）** |
| Spotify | getTrack | ✅（未接 UI） |
| Spotify | Pipeline 單向同步（Spotify 清單 → 本機 m3u8 → 下載補齊） | ✅ 已在用 |
| Spotube | catalog 替代音訊播放（YouTube→本機/真串流） | ✅ 本 session 修好 |
| Spotube | 一鍵補全下載器（SpotubePage） | ✅ 掛在 download 頁 |
| Spotube | 同步歌詞（lrclib + LRC 高亮 LyricsPage） | ⚠️ **功能完整但 0 入口（LyricsPage 無任何呼叫）** |
| 通用 | 搜尋頁（本機+Spotify）、歌單詳情（播放/隨機/下載）、統計、一起聽、我的最愛、音軌抽取、USB 匯出 | ✅ |

### B. 缺口（Spotify/Spotube 有而我們沒有或斷線）
1. **個人圖書館不可見**：我的清單/喜歡的歌無法在 UI 看到、無法一鍵納入同步（API 齊備零接線）
2. **同步歌詞進不去**：LyricsPage 無入口、播放器無歌詞鈕（Spotube 的招牌）
3. **串流無音質選項**：固定 bestaudio（Spotube 有 low/med/high 選擇）
4. **無寫入操作**：不能 like / 加入 Spotify 清單（無 mutation hash，需研究）
5. **無專輯/藝人詳情頁**（gql 缺 fetchAlbum/fetchArtist hash）
6. **liked 一鍵整批下載**未接（liked → 補全流程）

### C. 分期
- **P0（本 goal 實作）**
  - **P0-A Spotify 個人圖書館進歌單庫**：library_page 新增「Spotify 我的清單 / 喜歡的歌」區（libraryPlaylists + likedSongs），卡片有「＋加入同步」（寫入 urlNames → 既有 Pipeline 立即可同步）與「查看」（開 PlaylistDetailPage）
  - **P0-B 串流音質設定**：config.streamQuality（auto/省流量/標準/高），settings 下拉；StreamServer yt-dlp `-f` selector 對應（auto=現行 ba/b）
  - **P0-C 歌詞入口**：播放詳情面板（本 session 做的 track detail sheet）加「歌詞」按鈕 → LyricsPage；補齊 player.no_lyrics 文案使用
- **P1**：Spotify mutation（like/加入清單，需抓 persisted hash）、fetchAlbum/fetchArtist 詳情頁、liked 一鍵下載整批、播放歷程回饋（scrobble→Spotify）
- **P2**：藝人追蹤/新專輯推播 UI、多帳號、搜尋結果分頁/進階過濾

## Progress log
- [2026-09-24T13:10] checkpoint 0：建立 goal（覆寫舊 achieved goal）；必讀檔案讀畢（spotify_gql_client / spotify_session / spotube_page / library_page / 歌詞鏈路 / sidebar）。
- [2026-09-24T13:25] checkpoint 1（CP1 盤點）✅：grep 證據 — likedSongs/libraryPlaylists/libraryAlbums 無呼叫者；LyricsPage 無入口；無 Spotify mutation；無 fetchAlbum/fetchArtist；串流無 quality 選項；SpotubePage 掛 download_page。
- [2026-09-24T13:25] checkpoint 2（CP2 計畫）✅：A/B/C 盤點與 P0/P1/P2 分期入檔。
- [2026-09-24T13:35] checkpoint 3（P0-A 實作）✅：真 token 打 GQL 實測 — libraryV3 帶 order='AUDIO_ITEM_CREATED_AT_DESC' 回 LibraryInvalidSortOrderIdError，**省略 order 即通**（items=10 真實樣本存 temp）；修正 gql client（libraryPlaylists/libraryAlbums 移除 order）；library_page 新增「Spotify 我的圖書館」區（喜歡的歌＋我的清單卡片、置頂排序、封面、查看→PlaylistDetailPage 分頁≤300、＋加入同步→urlNames 接既有 Pipeline）。
- [2026-09-24T13:45] checkpoint 4（P0-B 實作）✅：config.streamQuality（low/standard/high，預設 standard，json 讀寫齊）＋settings「串流音質」下拉＋StreamServer `_qualityFormat` selector 套用到串流與預取下載。
- [2026-09-24T13:45] checkpoint 5（P0-C 實作）✅：播放詳情面板 header 加「歌詞」鈕 → push LyricsPage(artist/track/album/durationSec)（同步 LRC 高亮頁終於有入口）。
- [2026-09-24T13:55] checkpoint 6（全套驗證）✅：`dart analyze lib` No issues found；`flutter build windows --release` ✓ 31.0s；CLI smoke status exit 0、podcast exit 0 且 [17/17] 完成。停止條件 1/2/3 全數達成 → achieved。
- [2026-09-24T14:xx] checkpoint 7（使用者回饋修正）：圖書館「有點少」→ libraryV3 分頁抓全（50/頁 loop）；「接收 Beta 更新」原是死開關 → 接通 releases 清單（開=含 prerelease，關=原 latest 行為）；水平列滾輪無效 → Listener 把滾輪 dy 轉送水平捲動。
- [2026-09-28] checkpoint 8（使用者決定：整個刪掉）：**移除 P0-A 圖書館區塊與 _loadSpotifyLibrary 全套**（理由：首頁已有 Spotify 內容，判定重複）。P0-B 串流音質、P0-C 歌詞入口、檢查更新鈕保留。移除後 `dart analyze lib` 0 issues、build ✓、CLI smoke exit 0×2。libraryV3「省略 order 即通」的發現保留於 gql client 註解供日後 P1 使用。

## 還剩什麼
- P1（下一個 goal）：Spotify mutation（like/加入清單，需抓 persisted hash）、fetchAlbum/fetchArtist 詳情頁、liked 一鍵整批下載、scrobble→Spotify。
- P2：藝人追蹤/新專輯推播 UI、多帳號、搜尋結果分頁/進階過濾。
- 未提交：檢查更新按鈕、串流音質設定、歌詞入口、Beta 開關修復（v2.15.33 候選）。
- 註：測試期間「＋加入同步」曾寫入一筆 urlNames（第15筆），可在歌單庫卡片 ✕ 移除。
