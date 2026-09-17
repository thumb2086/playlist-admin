# AGENTS.md

## Release 流程

版本號**不用手動改** `pubspec.yaml`。CI 自動從 git tag 填入。

### 步驟
1. 改好程式碼，commit 到 main
2. 本地編譯 + 測試：`flutter build windows --release --dart-define=APP_VERSION=<ver>` → 跑 CLI smoke test
3. 跑 `dart analyze` 確認 0 errors
4. 決定版號（看 `git tag -l "v2.*" --sort=-v:refname` 最新是多少）
5. `git tag v2.x.x`
6. `git push origin main`
7. `git push origin v2.x.x`
8. CI 自動：build Windows → Inno Setup 打包 → 上傳 GitHub Release

### 版本號規則
- `pubspec.yaml` 裡的 `version` 保持不動（3.0.0-beta.1 或預設值即可）
- `lib/version.dart` 的 `APP_VERSION` 由 build 時的 `--dart-define=APP_VERSION=` 注入
- CI 從 tag 解析版本號：`v2.14.0` → `APP_VERSION=2.14.0`

### 範例
```bash
git tag v2.15.0
git push origin main
git push origin v2.15.0
# 完事，等 CI 跑完去 GitHub Releases 下載
```

## Build 驗證

```bash
dart analyze lib/services/groq_native_service.dart lib/services/download_service.dart lib/services/youtube_service.dart
```

修改任何 dart 檔後都要跑 `dart analyze` 確認 0 errors。

## 測試流程

改完程式碼後，必須本地編譯 + CLI 測試，全部通過才發版本。

### 步驟
```powershell
# 1. 編譯
flutter build windows --release --dart-define=APP_VERSION=<ver>

# 2. CLI smoke test
$exe = "build\windows\x64\runner\Release\playlist-admin.exe"
$env:PA_CLI_ARGS = '["status"]'; & $exe  # 測 status
$env:PA_CLI_ARGS = '["podcast"]'; & $exe  # 測 podcast pipeline

# 3. RAG 測試
python rag/study_query.py "齒輪有哪些" --topk 3  # study RAG
python rag/query.py "test" --topk 1 --json       # podcast RAG
```

### 失敗處理
- `dart analyze` 有 error → 修好再重來
- CLI crash → 看 stderr 輸出，修 bug
- Podcast pipeline 卡住 → 確認 data 目錄的 rag 腳本是最新版
- YouTube 下載失敗 → 確認 `yt_cookies.txt` 存在且有效

### 已知缺陷追蹤
測試腳本會依照發現的缺陷更新。每次修 bug 後補測試案例。

## npm 發布

npm 包名：`playlist-admin`（帳號 `thumb2087`，已搶注）
版本號：跟 Flutter GUI 對齊（如 GUI v2.15.14 → npm 2.15.14）

### 步驟
1. 更新 `package.json` 的 `version` 跟 GUI 對齊
2. `npm publish`

### 注意
- `npm publish` 會自動 `npm pkg fix` 修正 bin 路徑
- 包含：`cli/index.js`、`rag/*.py`、`rag/README.md`
- 如果 `npm publish` 四處 404，確認 `npm whoami` 是 `thumb2087`

## RAG 腳本同步

`rag/*.py` 是唯一真相來源。release 打包的是 `assets/tools/rag/`。
CI（flutter-release.yml）在每次 build 前自動同步，本地改完不用手動複製。
`tools/flutter_download_bridge.py` → `assets/tools/` 同理自動同步。

### ⚠️ Data 目錄也要同步
App 實際執行的 RAG 腳本在 **data 目錄**（`C:\Users\CPXru\Music\playlist-admin\rag\`），不是 project 目錄。
改完 `rag/*.py` 後**必須**同步到 data 目錄，否則 app 用的是舊版：
```powershell
Copy-Item rag\*.py "C:\Users\CPXru\Music\playlist-admin\rag\" -Force
```
忘記同步的後果：`_SKIP_DIRS` filter 無效，課程逐字稿被灌進 podcast DB（曾灌入 11828 筆）。

## 工作紀律

- 不要用 shell 寫檔案（Set-Content / echo 重定向會毀掉中文編碼）：讀用 Read，改用 Edit，驗證用 `python -c` 只印 ASCII。
- tool 輸出偶爾把中文顯示成 `?`（顯示假象）：拿不準時用 Python 比 bytes/hash，不要憑顯示下結論。
