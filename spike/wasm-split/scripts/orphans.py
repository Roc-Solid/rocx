import sys
sys.argv = ['x', '/tmp/rocx-split/out/marked-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
src = open('/tmp/rocx-split/scripts/graph6.py').read()
# keep symbol flags
src = src.replace("sk = obj[k]; k += 1; fl, k = leb(obj, k); undefined = fl & 0x10", "sk = obj[k]; k += 1; fl, k = leb(obj, k); undefined = fl & 0x10; flags_list.append(fl)")
src = src.replace("syms = []\n", "syms = []\nflags_list = []\n")
exec(src.split("core = reach(roots, stop)")[0])
core = reach(roots, stop)
per = {p: reach(fs, set()) for p, fs in entries.items()}
pages = set().union(*per.values())
inc = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: inc[y].add(x)
orph = [x for x in edges if x.startswith('D:') and not inc[x] and x not in core and x not in pages]
fl = collections.Counter()
for i, (k, nm, v, und) in enumerate(syms):
    if k == 'd' and 'D:' + nm in orph: fl[hex(flags_list[i])] += 1
print('orphan data objects pointing at functions:', len(orph), 'symbol flags:', fl)
U = {f for f in defined if f not in core and f not in pages}
only = {f for f in U if all(s in orph or s in U for s in inc[f])}
print('unassigned functions', len(U), 'reached only from orphan data or each other:', len(only))
names = collections.Counter(nm.rsplit('.', 1)[0] for nm in (x[2:] for x in orph))
print('orphan names', names.most_common(5))
