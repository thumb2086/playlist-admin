"""把 podcast 逐字稿 (.txt) 建立成 ChromaDB 向量資料庫
用法: python rag/build_db.py [--data DIR] [--db DIR] [--model MODEL] [--reset] [--workers N]
"""
import argparse
import os
import re
import sys
import hashlib
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chromadb
import requests

from _resolve import podcast_downloads_dir, chroma_db_dir

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

OLLAMA_URL = "http://localhost:11434"


def embed_one_batch(model: str, texts: list[str]) -> tuple[list[str], list[list[float]]]:
    """單批 embedding；400 時逐個重試，回傳 (成功文字, 對應向量)"""
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": model, "input": texts},
        timeout=600,
    )
    if resp.status_code == 400:
        kept: list[str] = []
        vectors: list[list[float]] = []
        for t in texts:
            r2 = requests.post(
                f"{OLLAMA_URL}/api/embed",
                json={"model": model, "input": [t]},
                timeout=600,
            )
            if r2.status_code == 400:
                print(f"!! 跳過問題 chunk (len={len(t)}): {t[:100]!r}")
                continue
            r2.raise_for_status()
            kept.append(t)
            vectors.append(r2.json()["embeddings"][0])
        return kept, vectors
    resp.raise_for_status()
    return texts, resp.json()["embeddings"]


def embed_texts(model: str, texts: list[str], batch: int = 32, workers: int = 6) -> tuple[list[str], list[list[float]]]:
    """併發呼叫 Ollama /api/embed；回傳 (成功文字, 對應向量)"""
    batches = [texts[i:i + batch] for i in range(0, len(texts), batch)]
    if len(batches) <= 1:
        if not batches:
            return [], []
        return embed_one_batch(model, batches[0])

    kept_all: list[str] = []
    vectors: list[list[float]] = []
    results: list[tuple[list[str], list[list[float]]]] = [None] * len(batches)
    with ThreadPoolExecutor(max_workers=workers) as ex:
        fut = {ex.submit(embed_one_batch, model, b): i for i, b in enumerate(batches)}
        for f in as_completed(fut):
            results[fut[f]] = f.result()
    for k, v in results:
        if k is None:
            continue
        kept_all.extend(k)
        vectors.extend(v)
    return kept_all, vectors


def read_text_file(path: Path) -> str:
    """讀檔，自動嘗試 UTF-8 / Big5 / GBK"""
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "big5", "gb18030"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def split_sentences(text: str) -> list[str]:
    """依中文句號斷句，過濾空白行。
    空白壓成單空格不斷字：舊寫法刪掉所有空白，英文全黏在一起傷 embedding。
    （query.py 的 normalize 已同步改同一規則，否則 offset 對不上。）"""
    text = re.sub(r"\s+", " ", text).strip()
    parts = re.split(r"(?<=[。！？!?；;])", text)
    return [p.strip() for p in parts if len(p.strip()) >= 4]


def make_chunks(sentences: list[str], max_len: int = 600, overlap: int = 60) -> list[str]:
    """句子接成 chunk，每塊約 max_len 字元，前後重疊 overlap；超長句強制硬切"""
    chunks: list[str] = []
    cur = ""
    for s in sentences:
        while len(s) > max_len:
            if cur:
                chunks.append(cur)
                cur = cur[-overlap:] if len(cur) > overlap else cur
            chunks.append(s[:max_len])
            s = s[max_len:]
        if len(cur) + len(s) > max_len and cur:
            chunks.append(cur)
            tail = cur[-overlap:] if len(cur) > overlap else cur
            cur = tail + s
        else:
            cur += s
    if cur:
        chunks.append(cur)
    return chunks


def detect_meta(path: Path) -> dict:
    """從檔名/路徑猜節目、日期與來源類型"""
    parts = path.parts
    show = parts[-2] if len(parts) >= 2 else "unknown"
    name = path.stem
    m = re.search(r"(20\d{2})[_\-_](\d{1,2})[_\-_](\d{1,2})", name)
    date = f"{m.group(1)}-{m.group(2).zfill(2)}-{m.group(3).zfill(2)}" if m else ""
    source = "course" if re.search(r"夜工智|機械群|課程", str(path)) else "podcast"
    return {"show": show, "file": name, "date": date, "source": source}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(podcast_downloads_dir()))
    ap.add_argument("--db", default=str(chroma_db_dir()))
    ap.add_argument("--model", default="bge-m3")
    ap.add_argument("--reset", action="store_true", help="重建資料庫")
    ap.add_argument("--limit", type=int, default=0, help="只索引前 N 篇 (測試用)")
    ap.add_argument("--workers", type=int, default=6, help="併發 embedding 數")
    ap.add_argument("--batch", type=int, default=64, help="每批 embedding 數量")
    args = ap.parse_args()

    # 先拿鎖再開 PersistentClient：反過來雙進程仍會同時開 SQLite。
    lock_file = Path(args.db) / ".build.lock"
    if lock_file.exists():
        # stale 鎖：mtime 超過 30 分鐘（kill -9 殘留）直接清掉重拿。
        try:
            age = time.time() - lock_file.stat().st_mtime
        except Exception:
            age = 0
        if age < 1800:
            print("另一個 build_db 正在寫入此 DB，本次跳過（避免 ChromaDB 寫入衝突）")
            sys.exit(2)
        try:
            lock_file.unlink()
            print("清掉過期 build lock，繼續執行")
        except Exception:
            pass
    try:
        fd = os.open(str(lock_file), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as lf:
            lf.write(f"{os.getpid()}|{time.time()}")
    except FileExistsError:
        print("另一個 build_db 正在寫入此 DB，本次跳過（避免 ChromaDB 寫入衝突）")
        sys.exit(2)

    client = chromadb.PersistentClient(path=args.db)
    try:
        _main_build(client, args)
    finally:
        try:
            lock_file.unlink()
        except Exception:
            pass


def _main_build(client, args) -> None:
    if args.reset:
        try:
            client.delete_collection("podcasts")
        except Exception:
            pass
    col = client.get_or_create_collection(
        "podcasts",
        metadata={"hnsw:space": "cosine"},
    )

    # ── Dedup: remove duplicate sig entries, keep first only ──────
    total = col.count()
    if total > 0:
        sig_to_ids: dict[str, list[str]] = {}
        offset = 0
        while offset < total:
            batch = col.get(limit=5000, offset=offset, include=["metadatas"])
            ids = batch["ids"]
            metas = batch["metadatas"]
            for rid, m in zip(ids, metas):
                sig = (m or {}).get("sig", "")
                if sig:
                    sig_to_ids.setdefault(sig, []).append(rid)
            offset += 5000
        to_delete = [ids[1:] for ids in sig_to_ids.values() if len(ids) > 1]
        flat_delete = [item for sublist in to_delete for item in sublist]
        if flat_delete:
            print(f"Dedup: removing {len(flat_delete)} duplicate records...")
            for i in range(0, len(flat_delete), 4500):
                col.delete(ids=flat_delete[i:i+4500])
            print(f"Dedup done. New count: {col.count()}")

    # 已索引內容 hash 去重 - 分段讀取避免 SQL 變數超限
    done_sigs: set[str] = set()
    offset = 0
    while True:
        batch = col.get(limit=5000, offset=offset, include=["metadatas"])["metadatas"]
        if not batch:
            break
        for m in batch:
            if m and m.get("sig"):
                done_sigs.add(m["sig"])
        offset += 5000
        if offset > 1000000:
            break

    # 一次性遷移: 舊版 chunks 沒有 sig — 從 metadata 的 path 讀檔補上，
    # 避免 1662 篇全部被當新的重嵌入。
    def file_sig(path: Path) -> str:
        raw = path.read_bytes()
        # Strip BOM and normalize whitespace to avoid false re-embeds
        if raw.startswith(b'\xef\xbb\xbf'):
            raw = raw[3:]
        return hashlib.md5(raw).hexdigest()

    migrated = 0
    to_update_ids: list[str] = []
    to_update_metas: list[dict] = []
    offset = 0
    while True:
        got = col.get(limit=5000, offset=offset, include=["metadatas"])
        batch = got["metadatas"]
        ids = got["ids"]
        if not batch:
            break
        for rid, m in zip(ids, batch):
            if not m or m.get("sig"):
                continue
            p = m.get("path")
            if not p or not os.path.exists(p):
                continue
            try:
                sig = file_sig(Path(p))
                m["sig"] = sig
                done_sigs.add(sig)
                to_update_ids.append(rid)
                to_update_metas.append(m)
                migrated += 1
            except Exception:
                pass
        offset += 5000
        if offset > 1000000:
            break
    # 寫回 DB：舊寫法只加記憶體 set，從不寫回，每次啟動重掃且刪檔殘留。
    for i in range(0, len(to_update_ids), 4500):
        try:
            col.update(
                ids=to_update_ids[i:i + 4500],
                metadatas=to_update_metas[i:i + 4500],
            )
        except Exception as e:
            print(f"migration write-back failed: {e}")
            break
    if migrated:
        print(f"migrated {migrated} legacy chunks to content-sig dedup")

    # 無內容/失敗檔案的跳過清單:0 chunks 的檔案不會寫進 DB,
    # 若沒有持久狀態會每次 pipeline 都被當「待索引」重試。
    skip_state_file = Path(args.db) / "_skipped_files.json"
    skipped: set[str] = set()
    if skip_state_file.exists():
        try:
            import json
            skipped = set(json.loads(skip_state_file.read_text(encoding="utf-8")))
        except Exception:
            skipped = set()

    # 檔案內容 hash — 內容更新(來源切換)時 sig 變 → 重嵌入
    def has_content(path: Path) -> bool:
        return bool(make_chunks(split_sentences(read_text_file(path))))

    # 過濾非 podcast 的 .txt：目錄黑名單 + 檔名/大小門檻
    _SKIP_DIRS = {
        'podcast_rag', '__pycache__', 'chroma_db', 'node_modules', '.git',
        # 課程逐字稿已移到 study collection，不該出現在 podcast DB
        'T夜工智CoCo英文S', 'T夜工智張瑀國文S', 'T夜工智胡傑數學S',
        '機械群劉徹機械力學', '機械群劉徹機械力學S',
        '機械群許凱機件原理', '機械群許凱機件原理S',
        '機械群陳海程機械製圖', '機械群陳海程機械製圖S',
        '機械群陳海程機械製造與實習', '機械群陳海程機械製造與實習S',
    }
    _SKIP_STEMS = {'README', 'changelog', 'license', 'requirements', 'setup', 'config'}
    _MIN_TXT_BYTES = 100  # podcast 逐字稿至少 ~100 bytes

    def _is_valid_podcast_txt(f: Path) -> bool:
        # 跳過黑名單目錄下的所有檔案
        for part in f.relative_to(Path(args.data)).parts[:-1]:
            if part in _SKIP_DIRS:
                return False
        # 跳過已知非逐字稿檔名
        if f.stem.lower() in _SKIP_STEMS:
            return False
        # 跳過太短的檔案（通常是設定檔或說明）
        try:
            if f.stat().st_size < _MIN_TXT_BYTES:
                return False
        except OSError:
            return False
        return True

    files = [
        f for f in sorted(Path(args.data).rglob("*.txt"))
        if _is_valid_podcast_txt(f)
        and file_sig(f) not in done_sigs
        and not (f.stem in skipped and not has_content(f))
    ]
    if args.limit:
        files = files[: args.limit]
    print(f"待索引 {len(files)} 篇 (已嵌入 {len(done_sigs)} 篇, 無內容跳過 {len(skipped)} 篇)")

    total_chunks = 0
    t_start = time.time()
    for i, f in enumerate(files, 1):
        text = read_text_file(f)
        chunks = make_chunks(split_sentences(text))
        # token 保險: 單 chunk 超過 2800 字元就再切
        final_chunks: list[str] = []
        for ch in chunks:
            final_chunks.extend(
                [ch[i:i + 2800] for i in range(0, len(ch), 2800)] if len(ch) > 2800 else [ch]
            )
        chunks = final_chunks
        if not chunks:
            # 空/太短內容: 標記為已跳過, 避免每次重試
            skipped.add(f.stem)
            import json
            skip_state_file.parent.mkdir(parents=True, exist_ok=True)
            skip_state_file.write_text(
                json.dumps(sorted(skipped), ensure_ascii=False, indent=1),
                encoding="utf-8",
            )
            continue
        meta = detect_meta(f)
        sig = file_sig(f)
        try:
            kept_chunks, vectors = embed_texts(args.model, chunks, batch=args.batch, workers=args.workers)
        except requests.exceptions.ConnectionError:
            print("無法連線 Ollama，請先啟動 (ollama serve) 並 pull bge-m3")
            sys.exit(1)
        except Exception as e:
            # 單檔失敗（500/429/timeout）不可中斷整個索引：
            # 跳過，下次增量 run 會自動補上（dedup：沒寫入就不在 done_sigs）。
            print(f"!! 跳過 {meta['file']}: {e}")
            continue
        if not kept_chunks:
            continue
        # ID 混入 show+sig+檔名：同節目同內容不同檔也互不相撞；
        # 寫入成功立刻登記 done_sigs（批次內第二檔直接跳過，不等下次 run）。
        try:
            col.delete(where={"path": str(f)})
        except Exception as e:
            print(f"!! 清舊 chunks 失敗 {meta['file']}: {e}")
        ids = [
            hashlib.md5(f"{meta['show']}|{meta['file']}|{sig}|{j}".encode()).hexdigest()
            for j in range(len(kept_chunks))
        ]
        metadatas = [
            {**meta, "sig": sig, "chunk": j, "chars": len(c), "path": str(f)}
            for j, c in enumerate(kept_chunks)
        ]
        try:
            col.add(ids=ids, documents=kept_chunks, metadatas=metadatas, embeddings=vectors)
        except Exception as e:
            # DuplicateID 等單檔失敗不可崩整個 build：下次增量補上。
            print(f"!! 寫入失敗跳過 {meta['file']}: {e}")
            continue
        done_sigs.add(sig)
        total_chunks += len(kept_chunks)
        if i % 5 == 0 or i == len(files):
            elapsed = time.time() - t_start
            speed = i / elapsed
            eta = (len(files) - i) / speed if speed > 0 else 0
            print(
                f"[{i}/{len(files)}] {i/len(files)*100:.1f}% | "
                f"{speed:.2f}篇/秒 | 剩餘ETA {eta/60:.1f}分 | "
                f"chunks累計 {total_chunks} | {meta['show'][:10]}/{meta['file'][:25]}",
                flush=True,
            )

    print(f"完成! 共 {len(files)} 篇, {total_chunks} 個 chunk")


if __name__ == "__main__":
    main()