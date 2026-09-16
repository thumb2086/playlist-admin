"""RAG 檢索: 問題 -> bge-m3 -> top-k 片段 -> 自動附加命中檔案的完整原文
用法:
  python rag/query.py "問題" --topk 8          # 文字輸出
  python rag/query.py "問題" --json            # JSON 輸出 (含 full_text)
  python rag/query.py "問題" --no-full         # 不回傳全文, 只回傳命中片段
  python rag/query.py "問題" --answer          # 用 Ollama qwen2.5:7b 生成回答
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chromadb
import requests

from build_db import read_text_file
from _resolve import chroma_db_dir

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
CHAT_MODEL = os.environ.get("OLLAMA_CHAT_MODEL", "qwen2.5:7b")


def embed_one(model: str, text: str) -> list[float]:
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed", json={"model": model, "input": [text]}, timeout=120
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


def normalize(text: str) -> str:
    # 與 build_db.split_sentences 同規則（單空格），否則 chunk offset 對不上。
    # 注意：此規則變更前的舊 chunks 是無空白版，offset 可能為 -1（僅顯示用，不影響檢索）。
    return re.sub(r"\s+", " ", text).strip()


def locate_chunk(full_norm: str, chunk: str, window: int = 100) -> int:
    head = chunk[:window]
    idx = full_norm.find(head)
    if idx < 0:
        head = chunk[:window // 2]
        idx = full_norm.find(head)
    return idx


def pick_chat_models() -> list[str]:
    """回傳可嘗試的 chat 模型順序：env 指定 → 本機非 embedding 模型 → cloud 模型"""
    forced = os.environ.get("OLLAMA_CHAT_MODEL", "").strip()
    try:
        tags = requests.get(f"{OLLAMA_URL}/api/tags", timeout=30).json().get("models", [])
    except Exception:
        return [forced] if forced else []
    local = [m["name"] for m in tags if m.get("size", 0) > 0]
    cloud = [m["name"] for m in tags if m.get("size", 0) == 0]
    banned = {"bge-m3", "bge-m3:latest"}
    local = [m for m in local if m not in banned]
    if forced:
        return [forced, *local, *cloud]
    return [*local, *cloud]


def generate_answer(question: str, hits: list[dict], quiet: bool = False) -> str:
    """用 Ollama 生成基於檢索片段的回答；全部模型都失敗就回傳錯誤訊息。
    quiet=True 時不印 token（--json 模式：stdout 只能有 JSON，否則解析失敗）。"""
    context = "\n".join(
        f"[{h['show']} | {h['date']} | {h['file']}]\n{h['chunk']}"
        for h in hits
    )
    prompt = (
        "你是 Podcast 內容助理。請只根據以下 Podcast 逐字稿片段回答使用者的問題，"
        "回答用繁體中文，簡潔、分點陳述，並在結尾列出引用來源（節目、日期、檔名）。\n\n"
        f"片段資料：\n{context}\n\n問題：{question}"
    )
    errors = []
    for model in pick_chat_models():
        try:
            resp = requests.post(
                f"{OLLAMA_URL}/api/chat",
                json={
                    "model": model,
                    "messages": [{"role": "user", "content": prompt}],
                    "stream": True,
                },
                timeout=600,
                stream=True,
            )
            if resp.status_code in (400, 401, 404):
                errors.append(f"{model}: HTTP {resp.status_code}")
                continue
            resp.raise_for_status()
            answer = []
            for line in resp.iter_lines():
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                    token = chunk.get("message", {}).get("content", "")
                    if token:
                        answer.append(token)
                        if not quiet:
                            print(token, end="", flush=True)
                except json.JSONDecodeError:
                    pass
            if not quiet:
                print()  # 換行
            return "".join(answer).strip()
        except requests.RequestException as e:
            errors.append(f"{model}: {e}")
    if errors:
        raise RuntimeError(" | ".join(errors))
    return ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("question", nargs="?", help="要查的問題")
    ap.add_argument("--db", default=str(chroma_db_dir()))
    ap.add_argument("--embed", default="bge-m3")
    ap.add_argument("--topk", type=int, default=8)
    ap.add_argument("--json", action="store_true", help="輸出 JSON (含 full_text)")
    ap.add_argument("--no-full", action="store_true", help="不回傳全文")
    ap.add_argument("--out", default="", help="JSON 輸出檔路徑 (與 --json 併用)")
    ap.add_argument("--show", default="", help="只搜指定節目")
    ap.add_argument("--answer", action="store_true", help="用 Ollama 生成回答 (qwen2.5:7b)")
    ap.add_argument("--topk-answer", type=int, default=6, help="生成回答使用的片段數")
    args = ap.parse_args()

    if not args.question:
        args.question = input("問題: ").strip()
    if not args.question:
        sys.exit(1)

    client = chromadb.PersistentClient(path=args.db)
    col = client.get_collection("podcasts")
    qvec = embed_one(args.embed, args.question)
    fetch_n = max(args.topk * 5, 50) if args.show else args.topk
    res = col.query(query_embeddings=[qvec], n_results=fetch_n)

    raw_hits = []
    docs = res["documents"][0] if res.get("documents") else []
    metas = res["metadatas"][0] if res.get("metadatas") else []
    dists = res["distances"][0] if res.get("distances") else []
    for doc, meta, dist in zip(docs, metas, dists):
        if args.show and args.show not in meta.get("show", ""):
            continue
        raw_hits.append({
            "similarity": round(1 - dist, 3),
            "show": meta.get("show", "?"),
            "date": meta.get("date", ""),
            "file": meta.get("file", "?"),
            "path": meta.get("path", ""),
            "chunk": doc,
        })

    by_file: dict[str, dict] = {}
    for h in raw_hits:
        key = h["path"] or h["file"]
        if key not in by_file:
            e = {k: h[k] for k in ("show", "date", "file", "path")}
            e["hits"] = []
            e["best_similarity"] = 0.0
            by_file[key] = e
        by_file[key]["hits"].append(h)
        by_file[key]["best_similarity"] = max(
            by_file[key]["best_similarity"], h["similarity"]
        )

    results = []
    for key, e in sorted(
        by_file.items(), key=lambda kv: kv[1]["best_similarity"], reverse=True
    ):
        entry = {
            "show": e["show"],
            "date": e["date"],
            "file": e["file"],
            "best_similarity": e["best_similarity"],
            "hits": [
                {"similarity": h["similarity"], "chunk": h["chunk"]}
                for h in e["hits"]
            ],
        }
        if not args.no_full and e["path"]:
            # 檔案被搬走/刪除時跳過全文（舊寫法直接拋 FileNotFoundError 整個查詢崩潰）。
            try:
                full = read_text_file(Path(e["path"]))
            except (OSError, FileNotFoundError):
                full = ""
            if full:
                full_norm = normalize(full)
                entry["full_text"] = full
                entry["full_text_norm_len"] = len(full_norm)
                entry["offsets"] = [
                    locate_chunk(full_norm, h["chunk"]) for h in e["hits"]
                ]
        results.append(entry)

    if args.json:
        payload = {"question": args.question, "results": results}
        if args.answer:
            try:
                payload["answer"] = generate_answer(
                    args.question, raw_hits[: max(args.topk_answer, 3)], quiet=True
                )
            except Exception as e:
                payload["answer_error"] = f"(Ollama 生成失敗: {e})"
        out = json.dumps(payload, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).write_text(out, encoding="utf-8")
            print(f"已寫入 {args.out}")
        else:
            print(out)
        return

    for r in results:
        print(f"\n[相似度 {r['best_similarity']}] {r['show']} | {r['date']} | {r['file']}")
        if "full_text" in r:
            print(f"  (全文 {len(r['full_text'])} 字, 命中偏移 {r['offsets']})")
        for h in r["hits"][:2]:
            print(f"  > {h['chunk'][:120]}...")


if __name__ == "__main__":
    main()