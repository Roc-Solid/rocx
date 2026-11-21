import sys, json, subprocess, collections
sys.argv = ['x', '/tmp/rocx-split/out/marked-ar/roc_app_llvm_wasm32_size.o', '/tmp/rocx-split/out/m.txt', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/dp.json']
exec(open('/tmp/rocx-split/scripts/plan.py').read())
from collections import deque
parent = {}; q = deque()
for r in roots:
    if r not in stop: parent[r] = None; q.append(r)
while q:
    x = q.popleft()
    for y in edges.get(x, ()):
        if y not in parent and y not in stop: parent[y] = x; q.append(y)
def path(x):
    out = []
    while x is not None: out.append(x); x = parent[x]
    return out[::-1]
via = [f for f in core if f.startswith('F:') and 'D:roc__d830_1' in path(f)]
print('core functions reached through roc__d830_1:', len(via))
for f in via[:4]: print(' -> '.join(n[:34] for n in path(f)))
# what each page reaches among them
for p, fs in entries.items():
    r = reach(fs, set())
    n = [f for f in via if f in r]
    if n: print(p, 'reaches', len(n))
