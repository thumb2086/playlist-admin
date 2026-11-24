# playlist-admin OpenTUI

opencode 風格的終端介面。**所有邏輯仍在 Dart 引擎**（`lib/cli_main.dart`，與 GUI 同一份實作），
這個 TUI 只負責版面與互動，每個動作 spawn 一次 exe 並串流它的 stdout。

> 為什麼是薄的：GUI / CLI / TUI 三者行為永遠一致，改 Dart 不用改 TS。

## 執行

```powershell
# 1. 先 build exe（含 -dev 避免觸發自動更新提示）
flutter build windows --release --dart-define=APP_VERSION=<ver>-dev

# 2. 啟動 TUI（需真實 TTY：Windows Terminal / PowerShell，不要在 IDE 內建 console）
cd tui-opentui
bun run index.ts
```

環境變數：

| 變數 | 用途 |
|---|---|
| `PA_EXE` | 指定 exe 路徑（預設自動找 `../build/windows/x64/runner/Release/playlist-admin.exe`） |

## 鍵盤

| 鍵 | 動作 |
|---|---|
| `↑` `↓` | 選指令 |
| `Enter` | 執行 |
| `Tab` | 在指令清單 / 搜尋框切換 |
| `Esc` | 清空搜尋並回清單 |
| `Ctrl+C` / `F10` | 離開 |

## 版面

```
playlist-admin TUI | <狀態> | ● 執行中 | <exe 路徑>
┌ 指令 ────────────┐ ┌ 輸出 ─────────────────────────┐
│ › 狀態           │ │ $ playlist-admin status       │
│   執行 Pipeline  │ │ Library: ...                  │
│   Podcast ...    │ │ — exit 0 —                    │
└──────────────────┘ └───────────────────────────────┘
[搜尋指令…]
```

## 新增指令

改 `core.ts` 的 `COMMANDS` 一行即可（`args` 就是 `PA_CLI_ARGS` 的內容）。

```ts
{ id: "lyrics", label: "歌詞下載", hint: "lyrics download", args: ["lyrics", "download"] },
```

## 與舊 TUI 的關係

`lib/tui/tui_main.dart`（Dart 內建 TUI）仍保留，`playlist-admin tui` 走那條。
這個 OpenTUI 版是**新入口**，需要 Bun；Dart 版不需要任何 runtime，兩者可並存。