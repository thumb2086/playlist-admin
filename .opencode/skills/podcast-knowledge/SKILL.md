---
name: podcast-knowledge
description: Use when the user asks a question about podcast transcripts, study materials, exam questions, or course content. Covers both podcast RAG (rag/query.py) and study RAG (rag/study_query.py). Trigger on words like podcast, 逐字稿, 節目, 試題, 課程, 齒輪, 螺栓, 機件原理, 機械力學, 統測, 四技二專, RAG.
---

# 知識檢索（Podcast + Study RAG）

兩個 ChromaDB collection，同一個 DB：
- **podcasts**：RSS podcast 逐字稿（`rag/query.py`）
- **study**：PDF 試題/課本 + 課程影片逐字稿（`rag/study_query.py`）

## 流程

1. 確認 Ollama 在跑：`Test-NetConnection localhost -Port 11434`
2. 判斷查詢類型：
   - **Podcast 相關**（「某集講什麼」「節目有沒有提到」）→ 用 `rag/query.py`
   - **試題/課程相關**（「某題怎麼解」「齒輪有哪些」「機件原理」）→ 用 `rag/study_query.py`
3. 查詢（在專案根目錄執行）：

   **Podcast：**
   ```
   python rag/query.py "<問題>" --json --no-full --topk 8
   playlist-admin rag query "<問題>" --no-full --topk 8
   ```

   **Study：**
   ```
   python rag/study_query.py "<問題>" --topk 5
   python rag/study_query.py "<問題>" --category 機械 --topk 3
   playlist-admin study query "<問題>" --topk 5
   ```

4. 依 `similarity`（1.0 最高）挑 2–3 個命中回答。
5. 用繁體中文回答，列出引用來源。

## Study RAG 特有參數

- `--category <字串>`：只搜特定分類（如「機械力學」「112學年度」「課程/機械群許凱機件原理」）
- `--answer`：用 Ollama 生成回答（需要 qwen2.5:7b）
- `--json`：JSON 輸出（含 similarity、category、file、chunk）

## 注意

- 若 collection 不存在：`python rag/study_build.py`（全量 ~15min）或 `playlist-admin study build`
- Podcast 重建：`playlist-admin rag build` 或 `python rag/build_db.py`
- 路徑與 DB 從 config.json 自動解析（`rag/_resolve.py`），不要假設路徑
- 問題保持原意，可直接用使用者原句
