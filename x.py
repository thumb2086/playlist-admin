import io
c = io.open(r'api/chat.js', encoding='utf-8', errors='replace').read()
lines = c.split('\n')
out = []
for i in range(735, 775):
    out.append('%d| %s' % (i + 1, lines[i]))
io.open(r'C:\Users\CPXru\Desktop\thumb\Projects\groq-router\pre.txt', 'w', encoding='utf-8').write('\n'.join(out))
print('ok')
"