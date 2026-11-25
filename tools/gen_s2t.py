"""產生 assets/s2t_opencc.json：給 Dart 端 ChineseConverter 用的 簡→繁 對照表。

★ 為什麼需要：原本 assets/zhcdict.json 是分區結構，Dart 只收了 value 為 String
   的頂層鍵（SIMPONLY/TRADONLY 兩個字串），真正的 zh2Hans 完全沒載入
   → isLoaded=true 但等於沒轉，逐字稿一直是簡體。

做法（讓 Dart 的「最長前綴比對」等於 OpenCC 的結果）：
  1. 單字層：對每個 CJK 字元跑 OpenCC s2tw，不同的就收
  2. 詞組層：掃語料，找出「逐字轉 ≠ 整詞轉」的 n-gram（2–4 字），
     這些就是 头发→頭髮 這類歧視性詞組，必須加進去，否則最長前綴會選錯
輸出：{ "简": "繁", ... }（扁平）
"""
import io, json, os, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import opencc

ROOT = r'C:\Users\CPXru\Music\playlist-admin\podcasts'
OUT = r'C:\Users\CPXru\Desktop\thumb\Projects\playlist-admin-src\assets\s2t_opencc.json'

cc = opencc.OpenCC('s2tw')

# ---- 1. 單字層 ----
table = {}
for cp in range(0x3400, 0xA000):          # CJK 基本+擴充A
    ch = chr(cp)
    t = cc.convert(ch)
    if t != ch and len(t) == 1:
        table[ch] = t
print('單字層:', len(table))

# ---- 2. 詞組層（從語料找逐字轉 != 整詞轉的 n-gram）----
phrases = {}
files = sorted(glob.glob(os.path.join(ROOT, '**', '*.txt'), recursive=True))
for p in files[:400]:                      # 取前 400 檔當代表樣本，夠了
    t = io.open(p, encoding='utf-8', errors='replace').read()
    n = len(t)
    for N in (4, 3, 2):
        for i in range(n - N + 1):
            g = t[i:i + N]
            if not all('\u3400' <= c <= '\u9fff' for c in g):
                continue
            whole = cc.convert(g)
            if whole == g:
                continue
            bychar = ''.join(table.get(c, c) for c in g)
            if whole != bychar:
                phrases[g] = whole
print('詞組層:', len(phrases))

table.update(phrases)
with io.open(OUT, 'w', encoding='utf-8') as f:
    json.dump(table, f, ensure_ascii=False, sort_keys=True)
print('輸出:', OUT, '共', len(table), '筆')