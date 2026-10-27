# GUI 前端評估與 TUI 前端規劃

## 專案概覽

**專案**：playlist-admin - 音樂庫管理 & Spotube 自動化工具
**現狀**：Flutter 桌面應用 (Windows/macOS/Linux)，單一二進制同時支援 GUI + CLI
**版本**：v2.15.91 (2026-10-28)

---

## 1. 現有 GUI 前端評估

### 1.1 架構概覽

| 項目 | 現狀 |
|------|------|
| **框架** | Flutter 3.x (Material 3) |
| **頁面數** | 12 頁 (Home, Search, Jam, Library, Pipeline, Stats, Settings, PlaylistDetail, AudioExtractor, Download, Lyrics, Spotube, Sync, Stats) |
| **服務層** | 45+ 個服務 (PlayerController 52KB, MetadataEnricher 29KB, YouTubeService 35KB 等) |
| **狀態管理** | ChangeNotifier + ValueNotifier + 手動 setState |
| **導航** | 側邊欄 IndexedStack + 詳細頁覆蓋層 + 底部佇列面板 |
| **主題** | 深色/淺色雙主題 + 自定義深色主題 |
| **國際化** | i18n 系統 (zh-TW, en) |

### 1.2 頁面結構與功能矩陣

| 頁面 | 檔案大小 | 核心功能 | 複雜度 |
|------|----------|----------|--------|
| `home_page.dart` | 30KB | 儀表板、播放控制、最近播放、快速動作 | 中 |
| `library_page.dart` | 22KB | 音樂庫瀏覽、搜尋、篩選、播放 | 高 |
| `pipeline_page.dart` | 25KB | **音樂/管道控制台** (12+按鈕問題) | **高** |
| `settings_page.dart` | 33KB | **設定中心** (Spotify登入、Groq、Discord、健康檢查) | **極高** |
| `library_page.dart` | 22KB | 音樂庫管理 | 中 |
| `playlist_detail_page.dart` | 37KB | 歌單詳情、編輯、播放 | 高 |
| `download_page.dart` | 45KB | YouTube/Spotify 下載、佇列管理 | **極高** |
| `search_page.dart` | 11KB | 統合搜尋 (本地+YouTube+Spotify) | 中 |
| `lyrics_page.dart` | 4KB | 歌詞顯示、同步、時間軸微調 | 中 |
| `stats_page.dart` | 36KB | 統計儀表板、圖表 | 中 |
| `audio_extractor_page.dart` | 28KB | 音頻提取、格式轉換 | 中 |
| `spotube_page.dart` | 12KB | Spotube 整合控制 | 低 |
| `sync_page.dart` | 17KB | 跨裝置同步 (QR Code) | 中 |
| `jam_page.dart` | 26KB | 即時合奏/聽歌派對 | 中 |

### 1.3 核心問題識別

#### A. Pipeline 頁面按鈕過多 (已確認)
- **現狀**：12+ 個獨立按鈕平鋪
- **問題**：認知負荷高、視覺雜亂、Warping 折行亂
- **已規劃**：折疊式步驟選單 + 主 CTA + 次要功能分組

#### B. Settings 頁面過於龐大 (33KB)
- **問題**：單檔 33KB，包含 15+ 個設定區塊
- **子問題**：
  - 中文編碼損壞 (已修復待重建)
  - 設定項過多：General、Lyrics、Groq、Discord、Library Health、Sync Server、Update、Tour、OpenCode Skill
  - 部分設定應遷移至專門頁面 (如 Groq 設定應在 Podcast/RAG 區塊)

#### C. Download 頁面過於龐大 (45KB)
- **功能**：YouTube 搜尋、下載佇列、格式選擇、播放清單下載、Spotify 轉換
- **建議**：拆分為「下載管理」主頁 + 「搜尋下載」子頁 + 「佇列管理」側邊欄

#### D. PlayerController 過於龐大 (52KB)
- **職責過多**：播放控制、佇列管理、歌詞預熱、SMTC 整合、串流伺服器、播放歷史、音量控制、均衡器
- **建議**：拆分為 `PlaybackController` + `QueueManager` + `LyricsController` + `StreamController`

#### D. PlayerController 過於龐大 (52KB)
- **職責過多**：播放控制、佇列管理、歌詞預熱、SMTC 整合、串流伺服器、播放歷史、音量控制、均衡器
- **建議**：拆分為 `PlaybackController` + `QueueManager` + `LyricsController` + `StreamController`

### 1.4 UX 問題清單

| 問題 | 影響 | 優先級 |
|------|------|--------|
| Pipeline 按鈕過多 | 高 | P0 (已規劃) |
| Settings 頁面過大 | 高 | P1 |
| Download 頁面過大 | 高 | P1 |
| PlayerController 單體 | 中 | P2 |
| 無鍵盤快捷鍵支援 | 中 | P2 |
| 無命令面板 | 中 | P2 |
| 無深色/淺色主題即時切換動畫 | 低 | P3 |
| 無無障礙支援 (ARIA/語音) | 低 | P3 |

### 1.5 技術債務

| 項目 | 說明 |
|------|------|
| `settings_page.dart` 編碼問題 | 已修復但需重建驗證 |
| `PlayerController` 52KB 單體類別 | 需拆分 |
| `DownloadService` 35KB 處理太多職責 | 需拆分 |
| `MetadataEnricher` 29KB 邏輯複雜 | 需重構 |
| 無單元測試覆蓋率 | 需建立測試架構 |
| 無 E2E 測試 | 需建立 |

---

## 2. TUI 前端規劃

### 2.1 設計理念

**目標**：提供一個鍵盤優先、資源輕量、適合 SSH/遠端/伺服器環境的文字介面，與 GUI 功能對等但操作模式適配終端機。

**核心原則**：
1. **鍵盤優先** - 全功能鍵盤操作，Vim 風格導航
2. **資源輕量** - 無 GPU、無圖形庫、記憶體 < 50MB
3. **單一二進制** - 同一 binary 透過參數切換 `gui` / `tui` / `cli`
4. **鍵盤優先** - Vim 風格 (hjkl, gg, G, /, ?, q, Enter)
5. **即時反饋** - 進度條、Spinner、狀態列、通知彈出
6. **可腳本化** - 所有操作可透過 CLI 參數自動化

### 2.2 技術棧選擇

| 選項 | 推薦 | 理由 |
|------|------|------|
| **Ratatui (Rust)** | ⭐ 首選 | 成熟、效能好、跨平台、Widget 豐富、社群活躍 |
| **Bubble Tea (Go)** | 次選 | Go 生態、但需重寫核心邏輯 |
| **Textual (Python)** | 备选 | 快速原型、但效能/部署較弱 |
| **FTXUI (C++)** | 备选 | 高效能、但 Rust 生態較完整 |

**決策**：使用 **Rust + Ratatui + Crossterm** 開發 TUI 前端，透過 FFI/RPC 與現有 Dart 服務層通訊。

### 2.3 架構設計

```
┌─────────────────────────────────────────────────────────────┐
│                    playlist-admin (單一 binary)              │
├─────────────────────────────────────────────────────────────┤
│  入口參數:  --gui | --tui | --cli <cmd> | --help           │
├─────────────────────────────────────────────────────────────┤
│  共享核心層 (Rust library)                                   │
│  ├── Core Engine: Pipeline, Metadata, Player, Sync         │
│  ├── Storage: SQLite (library.db, podcasts.db, config)     │
│  ├── Network: HTTP Client, WebSocket, gRPC                 │
│  └── Plugins: Spotify, YouTube, Groq, Ollama, Discord      │
├─────────────────────────────────────────────────────────────┤
│  GUI 前端 (Flutter/Dart)          │  TUI 前端 (Rust/Ratatui) │
│  ├── Flutter UI (Material 3)     │  ├── Ratatui Widgets      │
│  ├── Flutter Engine (Skia)       │  ├── Crossterm (終端機)    │
│  ├── Skia/GPU 渲染                │  ├── Crossterm 輸入處理   │
│  └── WebView2 (Spotify 登入)     │  └── 無 GPU/圖形依賴       │
└─────────────────────────────────────────────────────────────┘
```

### 2.4 TUI 介面設計

#### 2.4.1 佈局架構 (參考 Lazygit/k9s)

```
┌─────────────────────────────────────────────────────────────┐
│ Header: [Logo] Playlist Admin v2.15.91  [Tab: Library│Pipeline│Podcast│Settings] │
├──────────────┬──────────────────────────────────────────────┤
│ Sidebar      │ Main Content Area                             │
│ [1] Library  │ ┌─────────────────────────────────────────┐  │
│ [2] Pipeline │ │  Track List / Pipeline Log / Settings    │  │
│ [3] Podcast  │ │  [Table/List/Tree View]                   │  │
│ [3] Podcast  │ │                                           │  │
│ [4] Pipeline │ │                                           │  │
│ [5] Podcast  │ │                                           │  │
│ [6] Settings │ │                                           │  │
│ [7] Settings │ │                                           │  │
│              │ │                                           │  │
├──────────────┼──────────────────────────────────────────────┤
│ Status Bar:  [Playing: Song - Artist]  [Vol: 80%]  [Queue: 5]  [CPU: 12%]  [Mem: 45MB]  [00:45/03:30] │
├─────────────────────────────────────────────────────────────┤
│ Command/Filter: > _  (/:搜尋, ::命令, ?:幫助)               │
└─────────────────────────────────────────────────────────────┘
```

#### 2.4.2 標籤頁設計

| Tab | 快捷鍵 | 內容 | 核心 Widget |
|-----|--------|------|-------------|
| **Library** | `1` / `Alt+1` | 音樂庫瀏覽、搜尋、播放 | `Table` (可排序、篩選、多選) |
| **Pipeline** | `2` / `Alt+2` | 音樂 Pipeline 控制台 | `LogView` + `ProgressBar` + `StepSelector` |
| **Podcast** | `3` / `Alt+3` | Podcast 訂閱、下載、RAG | `TreeView` (Feed > Episodes) |
| **Settings** | `4` / `Alt+4` | 設定中心 | `FormView` (分組表單) |
| **Queue** | `Q` / `Alt+Q` | 播放佇列 | `QueueList` (可拖拽排序) |
| **Logs** | `L` / `Alt+L` | 即時日誌 | `LogView` (篩選、高亮) |

#### 2.4.3 核心 Widget 設計

| Widget | Ratatui 實作 | 功能 |
|--------|-------------|------|
| `TrackTable` | `Table` + `Row` | 可排序欄位、多選、右鍵選單 |
| `PipelineLog` | `List` + `Scrollbar` | 彩色日誌、進度條、步驟標籤 |
| `QueueList` | `List` + `Draggable` | 拖拽排序、右鍵操作 |
| `SettingsForm` | `Form` + `Input` | 分組表單、驗證、即時儲存 |
| `SearchBar` | `LineEdit` + `Popup` | 即時過濾、歷史記錄 |
| `StatusBar` | `LineGauge` | 播放狀態、音量、佇列、系統資源 |
| `CommandPalette` | `Popup` + `FuzzyMatch` | 命令面板 (類 VS Code) |

### 2.5 鍵盤綁定設計 (Vim 風格)

#### 全域導航
| 按鍵 | 動作 |
|------|------|
| `Tab` / `Shift+Tab` | 下一個/上一個面板 |
| `Alt+1~4` | 切換 Tab (Library/Pipeline/Podcast/Settings) |
| `Ctrl+Tab` | 循環面板 |
| `Q` / `Ctrl+Q` | 退出 / 強制退出 |
| `?` | 顯示幫助/鍵盤綁定 |
| `:` | 進入命令模式 |
| `/` | 搜尋/過濾 |
| `Esc` | 取消/返回/關閉彈窗 |

#### Library 面板
| 按鍵 | 動作 |
|------|------|
| `j` / `k` / `j` / `k` | 上下選擇 |
| `gg` / `G` | 首行/末行 |
| `j` / `k` | 上下 |
| `Enter` / `Space` | 播放/暫停 |
| `Space` | 播放/暫停 |
| `n` / `p` | 下一首/上一首 |
| `>` / `<` | 音量 + / - |
| `m` | 靜音切換 |
| `s` / `S` | 停止 / 隨機播放 |
| `a` | 加入佇列 |
| `A` | 加入佇列 (下一首) |
| `d` | 從佇列移除 |
| `Del` | 刪除檔案 (確認) |
| `r` | 重新命名 |
| `i` / `I` | 顯示詳細資訊 |
| `f` / `F` | 顯示/隱藏篩選器 |
| `/` | 搜尋曲目 |
| `?` | 顯示說明 |
| `y` | 複製路徑 |
| `o` | 開啟檔案位置 |
| `Shift+O` | 在檔案管理器開啟 |

#### Pipeline 面板
| 按鍵 | 動作 |
|------|------|
| `Space` | 開始/暫停 Pipeline |
| `p` / `P` | 暫停/繼續 |
| `c` / `C` | 取消/強制停止 |
| `1`~`7` | 跳到步驟 1~7 |
| `r` | 重跑失敗項 |
| `f` | 從失敗處繼續 |
| `l` | 切換日誌詳細度 |
| `s` | 步驟選單 (勾選/取消) |

#### 通用操作
| 按鍵 | 動作 |
|------|------|
| `:` | 命令模式 (如 `:run pipeline`, `:quit`, `:theme dark`) |
| `Ctrl+R` | 重新整理 |
| `Ctrl+S` | 儲存設定 |
| `Ctrl+F` | 全域搜尋 |
| `Ctrl+P` | 命令面板 (類 VS Code) |
| `Ctrl+L` | 清除日誌 |
| `Tab` | 面板間切換 |
| `F1`~`F12` | 預留自訂功能 |

### 2.6 命令模式設計 (類 Vim/Command Palette)

```
:run pipeline [--from N] [--to N] [--step lyrics]  # 執行 pipeline
:run podcast                                    # 執行 podcast pipeline
:run rag [--reset]                              # 重建 RAG 索引
:run artwork [--force]                          # 補齊封面
:run lyrics [--limit N]                         # 下載歌詞
:play <query>                                   # 播放
:queue add <query>                              # 加入佇列
:queue clear                                    # 清空佇列
:queue shuffle                                  # 打亂佇列
:queue save <name>                              # 儲存佇列
:queue load <name>                              # 載入佇列
:theme [dark|light|auto]                        # 切換主題
:config <key> [value]                           # 獲取/設定配置
:log [music|podcast|all] [--level debug]        # 查看日誌
:log clear                                      # 清除日誌
:theme [dark|light|auto]                        # 切換主題
:lang [zh-TW|en]                                # 切換語言
:vol [0-100|+10|-10|mute]                       # 音量控制
:vol mute                                       # 靜音切換
:exit / :quit / :q                              # 退出
:help                                           # 顯示幫助
```

### 2.7 狀態管理架構 (Ratatui + 狀態機)

```rust
// 核心狀態結構
struct AppState {
    // 當前標籤頁
    current_tab: Tab,
    // 各面板狀態
    library: LibraryState,
    pipeline: PipelineState,
    podcast: PodcastState,
    settings: SettingsState,
    queue: QueueState,
    logs: LogState,
    // 全域
    player: PlayerState,
    queue: QueueState,
    config: Config,
    // UI
    current_focus: FocusArea,
    command_mode: Option<CommandMode>,
    command_buffer: String,
    notifications: Vec<Notification>,
}

// 非同步任務管理
struct TaskManager {
    running_tasks: HashMap<TaskId, JoinHandle<()>>,
    progress_tx: mpsc::Sender<ProgressUpdate>,
    cancellation_tokens: HashMap<TaskId, CancellationToken>,
}
```

### 2.8 核心功能對應表 (GUI ↔ TUI)

| 功能 | GUI 實作 | TUI 實作 | 優先級 |
|------|----------|----------|--------|
| 音樂庫瀏覽/搜尋/播放 | `LibraryPage` + `PlayerBar` | `TrackTable` + `PlayerWidget` | P0 |
| Pipeline 控制台 | `PipelinePage` | `PipelineLogView` + `StepSelector` | P0 |
| Podcast 管理 | `PodcastPage` | `PodcastTree` + `EpisodeList` | P0 |
| 設定中心 | `SettingsPage` | `SettingsForm` (分組) | P0 |
| 播放佇列 | `QueuePanel` | `QueueList` (可拖拽) | P0 |
| 歌詞顯示 | `LyricsPage` | `LyricsView` (同步高亮) | P1 |
| 歌詞批次下載 | CLI only | `LyricsDownloader` Widget | P1 |
| 封面補齊 | `ArtworkEmbedder` | `ArtworkWidget` | P1 |
| Metadata 補充 | `MetadataEnricher` | `MetadataWidget` | P1 |
| 封面補齊 | `ArtworkEmbedder` | `ArtworkWidget` | P1 |
| Metadata 補充 | `MetadataEnricher` | `MetadataWidget` | P1 |
| LUFS 正規化 | `LufsService` | `LufsWidget` | P1 |
| 歌詞批次下載 | CLI only | `LyricsDownloader` Widget | P1 |
| RAG 索引 | `RagService` | `RagWidget` | P1 |
| Podcast RAG | `RagService` | `RagWidget` | P1 |
| Study RAG | `StudyRagService` | `StudyRagWidget` | P1 |
| 搜尋 | `SearchPage` | `SearchBar` + `ResultsTable` | P1 |
| 下載管理 | `DownloadPage` | `DownloadQueue` Widget | P1 |
| 音頻提取 | `AudioExtractorPage` | `AudioExtractorWidget` | P2 |
| Jam/派對 | `JamPage` | 暫不支援 | P3 |
| Sync/QR Code | `SyncPage` | QR Code Widget | P2 |
| 統計儀表板 | `StatsPage` | `StatsDashboard` | P2 |
| 音頻提取 | `AudioExtractorPage` | `AudioExtractorWidget` | P2 |
| Jam/派對 | `JamPage` | 暫不支援 | P3 |
| Sync/QR Code | `SyncPage` | QR Code Widget | P2 |
| 統計儀表板 | `StatsPage` | `StatsDashboard` | P2 |
| 導覽/引導 | `OnboardingDialog` | 首次啟動引導 | P2 |
| 更新檢查 | `UpdateService` | 自動/手動更新 | P1 |

### 2.8 資料持久化與同步

| 資料 | 儲存位置 | TUI 存取 |
|------|----------|----------|
| 音樂庫資料庫 | `library.db` (SQLite) | 直接讀寫 |
| Podcast 資料庫 | `podcasts.db` (SQLite) | 直接讀寫 |
| 設定檔 | `config.json` | 直接讀寫 |
| 快照快取 | `snapshot_cache.json` | 讀取 |
| 歌詞快取 | `lyrics/` 目錄 | 讀寫 |
| 封面快取 | `cover_cache.json` | 讀寫 |
| 播放歷史 | `history.db` | 讀寫 |
| 收藏 | `favorites.json` | 讀寫 |
| 佇列狀態 | 記憶體 + `queue_state.json` | 讀寫 |

---

## 3. 實施路線圖

### Phase 1: 基礎架構 (Week 1-2)
- [ ] 建立 Rust workspace (`playlist-admin-core`, `playlist-admin-tui`, `playlist-admin-cli`)
- [ ] 將核心服務移至 Rust library (`playlist-admin-core`)
- [ ] 建立 Ratatui 基礎架構 (Crossterm + Ratatui + Tokio)
- [ ] 實作基礎佈局 (Header, Sidebar, Main, StatusBar, CommandLine)
- [ ] 實作鍵盤事件處理 + Vim 風格導航
- [ ] 實作配置載入 (`config.json` 共享)

### Phase 2: 核心功能 - Library & Playback (Week 3-4)
- [ ] Library: `TrackTable` (排序、篩選、多選、播放)
- [ ] 播放控制: 播放/暫停、上下曲、音量、靜音、進度條
- [ ] 播放佇列: 顯示、操作 (新增/移除/排序/儲存/載入)
- [ ] 播放狀態同步: 標題、藝術家、專輯、封面、進度、時間
- [ ] 音量控制: 滑桿、靜音、鍵盤快捷鍵
- [ ] 播放狀態持久化

### Phase 3: Pipeline & Podcast (Week 5-6)
- [ ] Pipeline Log View: 彩色日誌、進度條、步驟指示器
- [ ] Pipeline 控制: 執行/暫停/取消/重試/從步驟 N 開始
- [ ] 步驟選單: 勾選/取消步驟、從步驟 N 開始
- [ ] Podcast: 訂閱樹、節目列表、下載管理、RAG 索引
- [ ] Pipeline 步驟選單 UI (勾選框 + 從步驟 N 開始)

### Phase 4: Settings & Library Management (Week 7-8)
- [ ] Settings Form: 分組表單 (General, Lyrics, Groq, Discord, Health, Sync, Update)
- [ ] 配置即時儲存 + 驗證
- [ ] Library Health Check UI
- [ ] Metadata Enrichment UI
- [ ] Artwork Backfill UI
- [ ] Lyrics Download UI (Pipeline 步驟 + CLI 獨立命令)
- [ ] Spotify 登入流程 (TUI 友善: 開啟瀏覽器 + 輪詢 cookie)

### Phase 5: 進階功能與優化 (Week 9-10)
- [ ] 命令面板 (`:command` + Fuzzy Match)
- [ ] 全域搜尋 (`/`) + 歷史記錄
- [ ] 命令面板 (`:command`) + Fuzzy Match
- [ ] 鍵盤綁定自訂 (`:bind`)
- [ ] 主題切換 (`:theme dark|light|auto`)
- [ ] 通知系統 (Toast/Toast Stack)
- [ ] 語言切換 (`:lang`)
- [ ] 更新檢查/安裝
- [ ] 鍵盤綁定說明 (`?` / `:help`)
- [ ] 無障礙支援 (高對比度模式、螢幕閱讀器相容)

### Phase 6: 測試、文件、發布 (Week 11-12)
- [ ] 單元測試 (核心邏輯)
- [ ] 整合測試 (Pipeline、Podcast、Playback)
- [ ] 鍵盤綁定測試
- [ ] 文件: `README.md`, `KEYBINDINGS.md`, `CONFIG.md`, `COMMANDS.md`
- [ ] 範例配置檔
- [ ] CI/CD: 自動建構 (Windows/macOS/Linux)、簽名、發布
- [ ] 版本發布: GitHub Release + npm (CLI) + Homebrew/Scoop/AUR

---

## 4. 遷移策略

### 4.1 共享核心庫策略

**核心原則**：Dart 服務層逐步移植至 Rust core library，透過 FFI/RPC 供 Flutter GUI 與 Rust TUI 共用。

| 遷移優先級 | 服務 | 原因 |
|------------|------|------|
| P0 | `ConfigService`, `ConfigModel` | 所有前端共用 |
| P0 | `PlayerController` 核心播放邏輯 | 播放核心 |
| P0 | `MetadataEnricher`, `ArtworkEmbedder` | Pipeline 核心 |
| P0 | `SpotifySession`, `SpotifyGqlClient` | Spotify 整合 |
| P0 | `YoutubeService`, `DownloadService` | 下載核心 |
| P1 | `MetadataReader`, `LufsService` | 音檔處理 |
| P1 | `LyricsService`, `RagService` | 歌詞/RAG |
| P2 | `PodcastService`, `SyncServer` | Podcast/Sync |
| P3 | `JamService`, `StreamServer` | 進階功能 |

### 4.2 共存策略

| 階段 | GUI | TUI | CLI |
|------|-----|-----|-----|
| 現狀 | Flutter (完整) | 無 | Dart (共享 binary) |
| Phase 1-2 | Flutter (完整) | Rust (Library/Playback) | Dart/Rust 共存 |
| Phase 3-4 | Flutter (完整) | Rust (完整 Pipeline/Podcast) | Rust (統一) |
| Phase 5+ | Flutter (維護模式) | **主力** | Rust (統一) |

**長期目標**：TUI 成為主力介面 (資源輕、可遠端、可腳本化)，GUI 進入維護模式。

---

## 5. 風險評估與對策

| 風險 | 機率 | 影響 | 對策 |
|------|------|------|------|
| Rust 學習曲線 | 高 | 高 | 先建立核心庫，再做 TUI；參考 Ratatui 範例 |
| Dart→Rust 移植錯誤 | 中 | 高 | 保留 Dart 版本作為參考，充分測試 |
| 跨平台終端機相容性 | 中 | 中 | 使用 Crossterm (支援 Windows/macOS/Linux) |
| 音訊播放 Rust 移植 | 高 | 高 | 先用 `rodio`/`symphonia`/`cpal`，保留 `media_kit` 給 GUI |
| 現有使用者遷移 | 低 | 中 | 保留 GUI 並行、提供遷移指南 |
| 單一 binary 體積過大 | 中 | 低 | 使用 `strip` + LTO + 分離 debug symbols |

---

## 6. 版本規劃

| 版本 | 目標 | 時間軸 |
|------|------|--------|
| **v2.16.0** | GUI: Pipeline 按鈕重構、Settings 編碼修復、Lyrics Pipeline 整合 | 2026-11 |
| **v2.17.0** | TUI: 基礎架構 + Library + Playback | 2026-12 |
| **v2.18.0** | TUI: Pipeline + Podcast + Settings | 2027-01 |
| **v2.19.0** | TUI: 完整功能對等 + 命令面板 | 2027-02 |
| **v3.0.0** | TUI 為主力、GUI 維護模式、Rust 核心完成 | 2027-03 |

---

## 7. 立即行動項 (本週)

### 本週必完成 (GUI v2.16.0 發布前)
- [x] Pipeline 頁面按鈕重構 (折疊式步驟選單)
- [x] `enable_pipeline_lyrics_download` 配置選項
- [x] CLI `lyrics download` 指令
- [x] Pipeline 加入歌詞下載步驟 (Step 6/7)
- [x] Settings 頁面 Spotify 登入區塊
- [ ] **Settings 頁面中文編碼修復並重建驗證** ← 關鍵
- [ ] 建構 v2.15.92 + 發布
- [ ] 更新 CLI 到 npm (v2.15.92)

### TUI 啟動準備
- [ ] 建立 `playlist-admin-core` Rust crate 專案結構
- [ ] 移植 `ConfigService` + `ConfigModel` 至 Rust
- [ ] 建立 Ratatui 專案骨架
- [ ] 實作基礎佈局 + 鍵盤導航

---

## 附錄: 關鍵檔案對應表

| 功能 | GUI (Dart) | TUI (Rust) 規劃 |
|------|------------|-----------------|
| 音樂庫 | `library_page.dart` | `src/tui/widgets/track_table.rs` |
| Pipeline | `pipeline_page.dart` + `pipeline_orchestrator.dart` | `src/tui/widgets/pipeline_log.rs` |
| Podcast | `podcast_page.dart` | `src/tui/widgets/podcast_tree.rs` |
| Settings | `settings_page.dart` | `src/tui/widgets/settings_form.rs` |
| 播放控制 | `player_bar.dart` + `player_controller.dart` | `src/tui/widgets/player_widget.rs` |
| 佇列 | `queue_panel.dart` | `src/tui/widgets/queue_list.rs` |
| 歌詞 | `lyrics_page.dart` | `src/tui/widgets/lyrics_view.rs` |
| 下載 | `download_page.dart` | `src/tui/widgets/download_queue.rs` |
| 搜尋 | `search_page.dart` | `src/tui/widgets/search_bar.rs` |
| 設定 | `settings_page.dart` | `src/tui/widgets/settings_form.rs` |
| 統計 | `stats_page.dart` | `src/tui/widgets/stats_dashboard.rs` |

---

*文件版本: 1.0*
*建立日期: 2026-10-28*
*最後更新: 2026-10-28*