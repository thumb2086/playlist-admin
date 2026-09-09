# AGENTS.md

## Release 流程

版本號**不用手動改** `pubspec.yaml`。CI 自動從 git tag 填入。

### 步驟
1. 改好程式碼，commit 到 main
2. 決定版號（看 `git tag -l "v2.*" --sort=-v:refname` 最新是多少）
3. `git tag v2.x.x`
4. `git push origin main`
5. `git push origin v2.x.x`
6. CI 自動：build Windows → Inno Setup 打包 → 上傳 GitHub Release

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
