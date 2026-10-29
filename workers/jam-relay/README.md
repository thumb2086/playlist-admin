# Jam Relay - Cloudflare Worker

Spotify Jam 風格的「一起聽」即時同步轉播器。

## 架構

- **Durable Object** (`JamRoom`)：每個房間一個 DO，狀態自動持久化到 Cloudflare 儲存
- **WebSocket** 通訊：低延遲、雙向、支援斷線重連
- **無伺服器**：自動擴展、按需計費

## 協議摘要

### 客戶端 → 伺服器
| 類型 | 用途 | 權限 |
|------|------|------|
| `create` | 建立房間 | 任意 |
| `join` | 加入房間 | 任意 |
| `add` | 加歌 | 房主/成員 |
| `remove` | 移除歌曲 | 僅房主 |
| `play`/`pause` | 播放/暫停 | 僅房主 |
| `seek` | 拖曳進度 | 僅房主 |
| `next`/`prev` | 上/下一首 | 僅房主 |
| `skip_vote` | 投票跳過 | 任意 |
| `chat` | 聊天 | 任意 |
| `vote` | 歌曲投票 | 任意 |
| `search` | 搜尋歌曲 | 任意 |

### 伺服器 → 客戶端
| 類型 | 觸發時機 |
|------|----------|
| `welcome` | 連線成功，回傳 `yourId` + 完整房間狀態 |
| `member_joined` / `member_left` | 成員進出 |
| `track_change` | 歌曲切換 |
| `playback` / `progress` | 播放狀態/進度同步 |
| `queue_update` | 佇列變動 |
| `skip_count` | 跳過票數更新 |
| `chat_item` | 新聊天訊息 |
| `host_next` | 通知房主播放下一首 |
| `promoted` | 房主斷線、成員升格為房主 |
| `search_results` / `search_error` | 搜尋結果 |
| `error` | 錯誤訊息 |

## 本地開發

```bash
cd workers/jam-relay
npm install
npm run dev          # 本地開發 (miniflare)
npm run test         # 跑整合測試
```

## 部署

```bash
# 登入 Cloudflare
wrangler login

# 部署到 staging
wrangler deploy --env staging

# 部署到 production
wrangler deploy --env production
```

部署後會得到類似 `https://jam-relay.cpxru83.workers.dev` 的 URL，更新 `lib/services/jam_service.dart` 的 `_relayUrl`。

## 狀態持久化

Durable Object 自動將房間狀態寫入 Cloudflare 儲存，包含：
- 房間代碼、房主 ID
- 成員清單
- 播放佇列、當前歌曲、播放狀態/進度
- 聊天記錄（最多 50 條）
- 跳過投票數

斷線重啟自動恢復。

## 房主斷線自動升級

房主斷線時，自動將最早加入的成員升格為新房主，`promoted` 事件通知前端切換權限。

## 搜尋代理

成員搜尋 → Relay 廣播給房主 → 房主端呼叫 Spotify/YouTube API → 房主回傳結果 → Relay 轉發給發起者。避免成員端需登入 Spotify。

## 部署檢查清單

- [ ] `wrangler login`
- [ ] `wrangler deploy --env production`
- [ ] 更新 `lib/services/jam_service.dart` 的 `_relayUrl` 指向新部署的 URL
- [ ] Flutter 專案 `flutter build apk/ipa` 重新建置
- [ ] 雙裝置實測：電腦開房 + 手機掃碼加入 → 加歌/投票/聊天/同步播放