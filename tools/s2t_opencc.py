"""1) 還原 .bak（撤掉上一版錯誤的字典轉換）2) 用 OpenCC s2tw 正確轉繁。"""
import io, os, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import opencc

ROOT = r'C:\Users\CPXru\Music\playlist-admin\podcasts'
cc = opencc.OpenCC('s2tw')

files = sorted(glob.glob(os.path.join(ROOT, '**', '*.txt'), recursive=True))
restored = 0
for p in files:
    bak = p + '.bak'
    if os.path.exists(bak):
        io.open(p, 'w', encoding='utf-8').write(io.open(bak, encoding='utf-8', errors='replace').read())
        restored += 1
print('還原 .bak:', restored)

conv = same = 0
for p in files:
    t = io.open(p, encoding='utf-8', errors='replace').read()
    new = cc.convert(t)
    if new != t:
        bak = p + '.bak'
        if not os.path.exists(bak):
            io.open(bak, 'w', encoding='utf-8').write(t)
        io.open(p, 'w', encoding='utf-8').write(new)
        conv += 1
    else:
        same += 1
print('OpenCC 轉換:', conv, '/ 無需轉:', same)