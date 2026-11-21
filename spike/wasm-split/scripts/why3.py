import sys
sys.argv = ['x', '/tmp/rocx-split/out/unsealed.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph5.py').read().split("core = reach(roots, stop)")[0])
core = reach(roots, stop)
per = {p: reach(fs, set()) for p, fs in entries.items()}
pages = set().union(*per.values())
U = {f for f in defined if f not in core and f not in pages}
inc = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: inc[y].add(x)
kinds = collections.Counter()
for f in U:
    src = inc[f]
    kinds['no incoming' if not src else 'from functions only' if all(s.startswith('F:') for s in src) else 'from data']+=1
print(kinds)
# a closure: walk incoming edges upwards from U until hitting nodes with no incoming edges
tops = set(); seen = set(); todo = list(U)
while todo:
    x = todo.pop()
    if x in seen: continue
    seen.add(x)
    if not inc[x]: tops.add(x)
    todo += list(inc[x])
print('top ancestors of the unassigned:', len(tops), sorted(t[:70] for t in tops)[:15])
print('host-facing names in the object (not roc__p):', sorted(n for n in func_name.values() if not n.startswith('roc__p') and 'host' in n.lower())[:10])
