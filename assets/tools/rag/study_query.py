"""Study RAG 查詢: 問題 → bge-m3 → top-k 片段
用法:
  python rag/study_query.py "問題"                    # 文字輸出
  python rag/study_query.py "問題" --json             # JSON 輸出
  python rag/study_query.py "問題" --topk 5           # 前 5 個結果
  python rag/study_query.py "問題" --category 機械    # 只搜某分類
  python rag/study_query.py "問題" --answer           # Ollama 生成回答
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

from _resolve import chroma_db_dir

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
CHAT_MODEL = os.environ.get("OLLAMA_CHAT_MODEL", "qwen2.5:7b")
COLLECTION = "study"


def embed_one(model: str, text: str) -> list[float]:
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed", json={"model": model, "input": [text]}, timeout=120
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


def read_file(path_str: str) -> str:
    p = Path(path_str)
    if not p.exists():
        return ""
    for enc in ("utf-8-sig", "utf-8", "big5", "gb18030"):
        try:
            return p.read_text(encoding=enc)
        except (UnicodeDecodeError, UnicodeError):
            continue
    return p.read_text(encoding="utf-8", errors="replace")


def pick_chat_models() -> list[str]:
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
    context = "\n".join(
        f"[{h['category']} | {h['file']}]\n{h['chunk']}" for h in hits
    )
    prompt = (
        "你是學習助理，專精四技二專統一入學測驗與機械群專業科目。"
        "請只根據以下學習資料片段回答使用者的問題，"
        "回答用繁體中文，簡潔、分點陳述，並在結尾列出引用來源。\n\n"
        f"片段資料：\n{context}\n\n問題：{question}"
    )
    errors = []
    for model in pick_chat_models():
        try:
            resp = requests.post(
                f"{OLLAMA_URL}/api/chat",
                json={"model": model, "messages": [{"role": "user", "content": prompt}], "stream": True},
                timeout=600, stream=True,
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
                print()
            return "".join(answer).strip()
        except requests.RequestException as e:
            errors.append(f"{model}: {e}")
    if errors:
        raise RuntimeError(" | ".join(errors))
    return ""


def main():
    ap = argparse.ArgumentParser(description="Study RAG query")
    ap.add_argument("question", nargs="?", help="要查的問題")
    ap.add_argument("--db", default=str(chroma_db_dir()))
    ap.add_argument("--embed", default="bge-m3")
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--category", default="", help="只搜某分類")
    ap.add_argument("--answer", action="store_true", help="用 Ollama 生成回答")
    ap.add_argument("--topk-answer", type=int, default=4)
    args = ap.parse_args()

    if not args.question:
        args.question = input("問題: ").strip()
    if not args.question:
        sys.exit(1)

    client = chromadb.PersistentClient(path=args.db)
    try:
        col = client.get_collection(COLLECTION)
    except Exception:
        print(f"找不到 {COLLECTION} collection。請先執行: python rag/study_build.py")
        sys.exit(1)

    qvec = embed_one(args.embed, args.question)
    fetch_n = max(args.topk * 5, 30) if args.category else args.topk
    where_filter = {"category": {"$contains": args.category}} if args.category else None
    res = col.query(
        query_embeddings=[qvec],
        n_results=fetch_n,
        where=where_filter,
    )

    raw_hits = []
    docs = res["documents"][0] if res.get("documents") else []
    metas = res["metadatas"][0] if res.get("metadatas") else []
    dists = res["distances"][0] if res.get("distances") else []
    for doc, meta, dist in zip(docs, metas, dists):
        if args.category and args.category not in meta.get("category", ""):
            continue
        raw_hits.append({
            "similarity": round(1 - dist, 3),
            "category": meta.get("category", "?"),
            "file": meta.get("file", "?"),
            "path": meta.get("path", ""),
            "source_type": meta.get("source_type", "?"),
            "chunk": doc,
        })

    if args.json:
        payload = {"question": args.question, "results": raw_hits[:args.topk]}
        if args.answer:
            try:
                payload["answer"] = generate_answer(
                    args.question, raw_hits[:args.topk_answer], quiet=True
                )
            except Exception as e:
                payload["answer_error"] = str(e)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    print(f"\n🔍 {args.question}\n")
    for i, h in enumerate(raw_hits[:args.topk], 1):
        print(f"[{i}] 類似度 {h['similarity']} | {h['source_type']} | {h['category']}/{h['file']}")
        print(f"    {h['chunk'][:150]}...")
        print()


if __name__ == "__main__":
    main()
