# Goal
- GoalID: 7f3a1c2e-8b4d-4e9f-a0c1-d2e3f4a5b6c7
- Status: achieved
- Created: 2026-09-14T12:50:00+08:00
- Updated: 2026-09-14T12:55:00+08:00

## Objective
修復 Podcast Pipeline：YouTube 字幕搜尋返回錯誤影片導致 RAG 索引缺失。

**Root Cause：** `cmd_youtube_subs` 從 YouTube 搜尋 HTML 中取第一個 video ID，未驗證影片是否屬於目標 podcast。科技浪 EP154 的搜尋返回了「思想實驗室」的影片（關鍵字重疊），下載的字幕/.txt 跟已索引的思想實驗室 ep113 完全相同（MD5 一致），RAG dedup 正確跳過。

## Stopping condition
- [x] `_pick_best_video` 驗證影片 title/channel 是否包含 podcast name 關鍵字
- [x] `podcast_service.dart` 傳遞 podcast name 作為第三參數
- [x] `dart analyze` 0 errors
- [x] 刪除錯誤的 EP154 .srt/.txt 檔案
- [x] 清除 processed cache 中的 EP154 條目

## Verification
```bash
dart analyze lib/services/podcast_service.dart
python -c "import importlib.util; spec = importlib.util.spec_from_file_location('b', 'tools/flutter_download_bridge.py'); m = importlib.util.module_from_spec(spec); print('_pick_best_video' in dir(m))"
```

## Progress log
- [2026-09-14T12:50] checkpoint：分析 root cause — YouTube 搜尋取 first result 未驗證 podcast 所屬
- [2026-09-14T12:52] checkpoint：實作 `_pick_best_video()` — 用 yt-dlp extract_info 檢查 title/channel 是否含 podcast 關鍵字
- [2026-09-14T12:53] checkpoint：更新 `podcast_service.dart` 傳 podcastName 作為第三參數；同步 `assets/tools/` 副本
- [2026-09-14T12:54] checkpoint：`dart analyze` 0 errors；刪除錯誤 EP154 檔案；清除 cache
- [2026-09-14T12:55] achieved：下次 pipeline 執行時科技浪 EP154 將被正確下載並索引

## 還剩什麼
下次 pipeline 執行會自動重新處理科技浪 EP154（cache 已清除，檔案已刪除）。手動觸發可跑 `podcast-pipeline` 命令。
