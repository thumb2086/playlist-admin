"""Build study RAG: PDF 試題/課本 + 課程逐字稿 → ChromaDB study collection
用法:
  python rag/study_build.py                          # 增量建庫
  python rag/study_build.py --reset                  # 清空重建
  python rag/study_build.py --pdf-root <DIR>         # 自訂 PDF 根目錄
  python rag/study_build.py --limit 10               # 只建前 10 個 PDF（測試用）
"""
import argparse
import hashlib
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chromadb
import requests

from _resolve import find_base, chroma_db_dir

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

COLLECTION = "study"
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
EMBED_MODEL = os.environ.get("OLLAMA_EMBED_MODEL", "bge-m3")

# ── Embedding ────────────────────────────────────────────────────────

def embed_one_batch(model: str, texts: list[str]) -> tuple[list[str], list[list[float]]]:
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": model, "input": texts},
        timeout=120,
    )
    if resp.status_code == 400:
        ok, vecs = [], []
        for t in texts:
            try:
                r2 = requests.post(
                    f"{OLLAMA_URL}/api/embed",
                    json={"model": model, "input": [t]}, timeout=120,
                )
                r2.raise_for_status()
                ok.append(t)
                vecs.append(r2.json()["embeddings"][0])
            except Exception:
                pass
        return ok, vecs
    resp.raise_for_status()
    return texts, resp.json()["embeddings"]


def embed_texts(model: str, texts: list[str], batch: int = 32, workers: int = 6):
    batches = [texts[i:i + batch] for i in range(0, len(texts), batch)]
    if len(batches) <= 1:
        return embed_one_batch(model, batches[0]) if batches else ([], [])
    kept, vecs = [], []
    results = [None] * len(batches)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        fut = {ex.submit(embed_one_batch, model, b): i for i, b in enumerate(batches)}
        for f in as_completed(fut):
            results[fut[f]] = f.result()
    for k, v in results:
        if k is None:
            continue
        kept.extend(k)
        vecs.extend(v)
    return kept, vecs


# ── PDF extraction ───────────────────────────────────────────────────

def extract_pdf_text(pdf_path: Path) -> str:
    """用 PyMuPDF 提取 PDF 文字"""
    try:
        import fitz
        doc = fitz.open(str(pdf_path))
        parts = []
        for page in doc:
            parts.append(page.get_text())
        doc.close()
        return "\n".join(parts)
    except Exception as e:
        return f"[PDF extraction error: {e}]"


# ── Chunking ─────────────────────────────────────────────────────────

def split_sentences(text: str) -> list[str]:
    text = re.sub(r"\s+", " ", text).strip()
    parts = re.split(r"(?<=[。！？!?；;\n])", text)
    return [p.strip() for p in parts if len(p.strip()) >= 4]


def make_chunks(sentences: list[str], max_len: int = 800, overlap: int = 80) -> list[str]:
    """句子接成 chunk，max_len 較大（試題需要更多上下文）"""
    chunks: list[str] = []
    cur = ""
    for s in sentences:
        if len(cur) + len(s) > max_len and cur:
            chunks.append(cur.strip())
            # overlap: 保留尾巴
            overlap_text = cur[-overlap:] if len(cur) > overlap else cur
            cur = overlap_text + " " + s
        else:
            cur = cur + " " + s if cur else s
    if cur.strip():
        chunks.append(cur.strip())
    # 超長強制硬切
    final = []
    for ch in chunks:
        if len(ch) > 2800:
            final.extend(ch[i:i + 2800] for i in range(0, len(ch), 2800))
        else:
            final.append(ch)
    return final


def file_sig(path: Path) -> str:
    return hashlib.md5(str(path.resolve()).encode()).hexdigest()


def content_sig(text: str) -> str:
    return hashlib.md5(text[:4096].encode()).hexdigest()


# ── PDF discovery ────────────────────────────────────────────────────

def discover_pdfs(root: Path) -> list[tuple[str, Path]]:
    """回傳 (category, pdf_path) 列表"""
    results = []
    for dirpath, dirnames, filenames in os.walk(str(root)):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        dp = Path(dirpath)
        rel = dp.relative_to(root)
        category = str(rel).replace("\\", "/") if str(rel) != "." else root.name
        for f in sorted(filenames):
            if f.lower().endswith(".pdf"):
                results.append((category, dp / f))
    return results


def discover_txt_transcripts(podcasts_dir: Path) -> list[tuple[str, Path]]:
    """掃描 podcast 資料夾中的課程目錄（非 RSS）"""
    results = []
    # 課程目錄名單（有 .txt 逐字稿的非 RSS 資料夾）
    course_dirs = [
        'T夜工智CoCo英文S', 'T夜工智張瑀國文S', 'T夜工智胡傑數學S',
        '機械群劉徹機械力學', '機械群劉徹機械力學S',
        '機械群許凱機件原理', '機械群許凱機件原理S',
        '機械群陳海程機械製圖', '機械群陳海程機械製圖S',
        '機械群陳海程機械製造與實習', '機械群陳海程機械製造與實習S',
    ]
    for name in course_dirs:
        d = podcasts_dir / name
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.txt")):
            results.append((f"課程/{name}", f))
    return results


# ── Main ─────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Build study RAG")
    ap.add_argument("--reset", action="store_true", help="清空重建")
    ap.add_argument("--pdf-root", default="", help="PDF 根目錄")
    ap.add_argument("--limit", type=int, default=0, help="只建前 N 個 PDF（測試）")
    ap.add_argument("--db", default=str(chroma_db_dir()))
    ap.add_argument("--embed", default=EMBED_MODEL)
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    # Resolve PDF root
    if args.pdf_root:
        pdf_root = Path(args.pdf_root)
    else:
        # Auto-discover: check Desktop, then common locations
        home = Path.home()
        candidates = [
            home / "Desktop" / "四技二專歷屆試題與解答",
            find_base() / "study_materials",
        ]
        pdf_root = None
        for c in candidates:
            if c.exists():
                pdf_root = c
                break
        if pdf_root is None:
            print("找不到 PDF 目錄。請用 --pdf-root 指定。")
            sys.exit(1)

    print(f"PDF 根目錄: {pdf_root}")

    # Connect ChromaDB
    client = chromadb.PersistentClient(path=args.db)
    if args.reset:
        try:
            client.delete_collection(COLLECTION)
            print("已清空 study collection")
        except Exception:
            pass
    col = client.get_or_create_collection(
        COLLECTION,
        metadata={"hnsw:space": "cosine"},
    )

    # Existing signatures (dedup)
    existing = col.get(include=["metadatas"])
    done_sigs: set[str] = set()
    if existing["ids"]:
        for meta in existing["metadatas"]:
            sig = meta.get("sig", "")
            if sig:
                done_sigs.add(sig)
    print(f"已存在 {len(existing['ids'])} 筆, 已知 sig {len(done_sigs)} 個")

    # Discover files
    pdfs = discover_pdfs(pdf_root)
    transcripts = discover_txt_transcripts(find_base() / "podcasts")
    all_files = [(cat, p, "pdf") for cat, p in pdfs] + [(cat, p, "txt") for cat, p in transcripts]
    print(f"發現 {len(pdfs)} 個 PDF, {len(transcripts)} 個逐字稿")

    if args.limit:
        all_files = all_files[:args.limit]
        print(f"測試模式: 只建前 {args.limit} 個")

    # Extract → chunk → embed
    total_chunks = 0
    t_start = time.time()

    for fi, (category, fpath, ftype) in enumerate(all_files, 1):
        if ftype == "pdf":
            sig = file_sig(fpath)
            if sig in done_sigs:
                continue
            text = extract_pdf_text(fpath)
        else:
            text = fpath.read_text(encoding="utf-8-sig", errors="replace")
            sig = content_sig(text[:4096])
            if sig in done_sigs:
                continue

        if not text or len(text.strip()) < 20:
            continue

        chunks = make_chunks(split_sentences(text))
        if not chunks:
            continue

        # Token safety: 2800 chars per chunk
        final_chunks = []
        for ch in chunks:
            if len(ch) > 2800:
                final_chunks.extend(ch[i:i + 2800] for i in range(0, len(ch), 2800))
            else:
                final_chunks.append(ch)
        chunks = final_chunks

        # Embed
        kept, vectors = embed_texts(args.embed, chunks, workers=args.workers)
        if not kept:
            continue

        # Write to ChromaDB
        prefix = f"study_{sig[:8]}"
        ids = [f"{prefix}_{i}" for i in range(len(kept))]
        metas = [
            {
                "category": category,
                "file": fpath.name,
                "path": str(fpath),
                "sig": sig if i == 0 else "",  # only first chunk carries sig
                "chunk_index": i,
                "total_chunks": len(kept),
                "source_type": ftype,
            }
            for i in range(len(kept))
        ]

        batch_size = 4500
        for bi in range(0, len(ids), batch_size):
            col.add(
                ids=ids[bi:bi + batch_size],
                documents=kept[bi:bi + batch_size],
                metadatas=metas[bi:bi + batch_size],
                embeddings=vectors[bi:bi + batch_size],
            )

        total_chunks += len(kept)
        elapsed = time.time() - t_start
        pct = fi / len(all_files) * 100
        rate = fi / elapsed if elapsed > 0 else 0
        eta = (len(all_files) - fi) / rate if rate > 0 else 0
        print(
            f"\r  [{fi}/{len(all_files)}] {pct:.1f}% "
            f"| {rate:.2f} files/s | ETA {eta / 60:.1f}min "
            f"| chunks累計 {total_chunks} | {category}/{fpath.name[:30]}",
            end="", flush=True,
        )

    print(f"\n完成! 共 {total_chunks} 個新 chunk, 總計 {col.count()} 筆")


if __name__ == "__main__":
    main()
