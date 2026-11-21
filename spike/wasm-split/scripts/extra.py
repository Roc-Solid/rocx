import sys, json, subprocess
sys.argv = ['x', '/tmp/rocx-split/out/marked-ar/roc_app_llvm_wasm32_size.o', '/tmp/rocx-split/out/m.txt', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/dp.json']
exec(open('/tmp/rocx-split/scripts/plan.py').read().replace("OBJ, MANIFEST, FINAL, FUNCS, DATAPLAN = sys.argv[1:6]", "OBJ, MANIFEST, FINAL, FUNCS, DATAPLAN = sys.argv[1:6]; sys_argv_keep = list(sys.argv)"))
nopages = json.loads(subprocess.check_output(['python3', '-I', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/boxy/core.wasm']))
allf = json.loads(subprocess.check_output(['python3', '-I', '/tmp/rocx-split/scripts/funcs.py', FINAL]))
corefns = {x[2:] for x in core if x.startswith('F:')}
extra = {f for f in corefns if f not in nopages}
print('core functions', len(corefns), 'not in the no-pages build', len(extra), 'code bytes', sum(allf.get(f, 0) for f in extra))
# For each extra function, the root-path: BFS from roots recording parents
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
# Group extras by the first node on their path that is not in the no-pages core (the "door")
doors = collections.Counter(); door_bytes = collections.Counter()
for f in extra:
    p = path('F:' + f)
    door = next((n for n in p if (n.startswith('F:') and n[2:] not in nopages) or n.startswith('D:')), p[-1])
    # prefer the last core-in-both node before the door, to name who opens it
    i = p.index(door); opener = p[i - 1] if i > 0 else door
    doors[(opener[:48], door[:48])] += 1; door_bytes[(opener[:48], door[:48])] += allf.get(f, 0)
for k, n in door_bytes.most_common(12): print(n, 'bytes', doors[k], 'fns via', k)
