"""真實 chunk 下 num_ctx 的影響（batch 512）。"""
import io, json, os, sys, time, glob, importlib.util, pathlib, urllib.request
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.argv = ['x']
spec = importlib.util.spec_from_file_location('bd', 'rag/build_db.py')
bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)

files = sorted(glob.glob(r'C:\Users\CPXru\Music\playlist-admin\podcasts\**\*.txt', recursive=True))
files = [f for f in files if os.path.getsize(f) > 100][:20]
chunks = []
for f in files:
    t = bd.read_text_file(pathlib.Path(f))
    for ch in bd.make_chunks(bd.split_sentences(t)):
        chunks.extend([ch[i:i+2800] for i in range(0, len(ch), 2800)] if len(ch) > 2800 else [ch])
chunks = chunks[:512]
print('chunks', len(chunks), 'avg chars', sum(len(c) for c in chunks)//len(chunks))

for ctx in (512, 1024, 2048, 4096):
    body = json.dumps({'model': 'bge-m3', 'input': chunks, 'keep_alive': '30m',
                       'options': {'num_batch': 8192, 'num_ctx': ctx}}).encode()
    req = urllib.request.Request('http://localhost:11434/api/embed', data=body,
                                 headers={'Content-Type': 'application/json'})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.loads(r.read())
    dt = time.time() - t0
    n = len(d.get('embeddings', []))
    print(f'num_ctx={ctx:>5}  {dt:7.2f}s  → {n/dt:5.1f} chunks/s')
