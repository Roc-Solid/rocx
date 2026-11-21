# Where every function and data object goes: core, a page, Shared (2+ pages), or Unreached.
# Writes the wasm-split manifest and a data plan (address, size, owner) as JSON.
import sys, re, subprocess, bisect, json
OBJ, MANIFEST, FINAL, FUNCS, DATAPLAN = sys.argv[1:6]
src = open('/tmp/rocx-split/scripts/graph7.py').read().split("exec(\"core = reach(roots, stop)\" + tail)")[0]
sys.argv = sys.argv[:5]
exec(src)
# Data words in the final module that point into a data object: data → data edges.
fin = open(FINAL, 'rb').read(); i = 8; final_segs = []
while i < len(fin):
    sid = fin[i]; i += 1; size, i = leb(fin, i); end = i + size
    if sid == 11:
        n, j = leb(fin, i)
        for _ in range(n):
            fl, j = leb(fin, j); assert fl == 0 and fin[j] == 0x41; off, j = sleb(fin, j + 1); j += 1; sz, j = leb(fin, j)
            final_segs.append((off, fin[j:j+sz])); j += sz
    i = end
dd = 0
for off, b in final_segs:
    for k in range((-off) % 4, len(b) - 3, 4):
        w = int.from_bytes(b[k:k+4], 'little')
        if w >= BASE:
            to = obj_at(w); frm = obj_at(off + k)
            if to and frm and to != frm and to not in edges[frm]: edges[frm].add(to); dd += 1
print('data→data edges recovered', dd)
core = reach(roots, stop)
per = {p: reach(fs, set()) - core for p, fs in entries.items()}
count = collections.Counter(x for s in per.values() for x in s)
owner = {}
for x in core: owner[x] = 'core'
for p, s in per.items():
    for x in s: owner[x] = p if count[x] == 1 else 'Shared'
nodes = defined | {'D:' + o[2] for o in objs}
for x in nodes:
    owner.setdefault(x, 'Unreached')
by = collections.defaultdict(list)
for x, o in owner.items():
    if x.startswith('F:') and x in defined and o != 'core': by[o].append(x[2:])
print('functions by owner', {o: len(v) for o, v in sorted(by.items(), key=lambda kv: -len(kv[1]))[:8]}, 'core', sum(1 for x, o in owner.items() if o == 'core' and x.startswith('F:')))
open(MANIFEST, 'w').write('\n\n'.join(o + '\n' + '\n'.join(sorted(v)) for o, v in sorted(by.items())) + '\n')
plan = [(a, sz, owner.get('D:' + nm, 'Unreached')) for a, sz, nm in objs]
dbytes = collections.Counter()
for a, sz, o in plan: dbytes[o] += sz
print('data bytes by owner', dict(dbytes.most_common(8)))
json.dump(plan, open(DATAPLAN, 'w'))
needs = {p: sorted({owner[x] for x in reach(fs, set()) if owner.get(x) not in (None, 'core', p)}) for p, fs in entries.items()}
json.dump(needs, open(DATAPLAN.replace('.json', '-needs.json'), 'w'))
