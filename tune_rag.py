import io
p = 'rag/build_db.py'
c = io.open(p, encoding='utf-8').read()

# 1) /api/embed 加 options：num_batch 拉高，讓 GPU 一次吃到更多 token
old = """    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": model, "input": texts},
        timeout=600,
    )"""
new = """    # GPU 利用率低（實測 7~13%、SM 只有 660 MHz）的原因不是算力不足，
    # 而是每次只餵 512 token 進 GPU，中文短 chunk 時 GPU 大半時間在等下一批。
    # num_batch 拉到 8192 讓一次進更多；keep_alive 確保模型不被卸載重載。
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={
            "model": model,
            "input": texts,
            "keep_alive": "30m",
            "options": {"num_batch": 8192, "num_ctx": 8192},
        },
        timeout=600,
    )"""
assert old in c, 'embed anchor'
c = c.replace(old, new, 1)

# 2) 單筆 fallback 同樣帶 options
old = """            r2 = requests.post(
                f"{OLLAMA_URL}/api/embed",
                json={"model": model, "input": [t]},
                timeout=600,
            )"""
new = """            r2 = requests.post(
                f"{OLLAMA_URL}/api/embed",
                json={"model": model, "input": [t],
                      "keep_alive": "30m",
                      "options": {"num_batch": 8192, "num_ctx": 8192}},
                timeout=600,
            )"""
if old in c:
    c = c.replace(old, new, 1)
    print('fallback patched')

# 3) 併發與每批文字數
c = c.replace('add_argument("--workers", type=int, default=6,',
              'add_argument("--workers", type=int, default=8,', 1)
c = c.replace('add_argument("--batch", type=int, default=64,',
              'add_argument("--batch", type=int, default=192,', 1)

io.open(p, 'w', encoding='utf-8').write(c)
print('build_db tuned: num_batch=8192 batch=192 workers=8')