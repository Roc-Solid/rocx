import sys
sys.argv = ['x', '/tmp/rocx-split/out/unsealed.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
src = open('/tmp/rocx-split/scripts/graph6.py').read().split("# Data objects holding")[0]
exec(src)
targets = {i for i, (k, nm, v, und) in enumerate(syms) if nm in ('roc__d1284', 'roc__d0', 'roc__d126')}
print('symbols', [(i, syms[i]) for i in targets])
found = collections.Counter()
for sid, cname, s, e in sections:
    if not (cname or '').startswith('reloc.'): continue
    target, j = leb(obj, s); n, j = leb(obj, j)
    for _ in range(n):
        t = obj[j]; j += 1; off, j = leb(obj, j); idx, j = leb(obj, j)
        if t in ADDEND: _, j = sleb(obj, j)
        if idx in targets: found[(cname, t, syms[idx][1])] += 1
print('relocations naming them:', found)
print('global imports', len(global_imports), global_imports[:5])
# exports in the object?
for sid, cname, s, e in sections:
    if sid == 7:
        n, j = leb(obj, s); ex = []
        for _ in range(n): nm2, j = name(obj, j); k2 = obj[j]; j += 1; i2, j = leb(obj, j); ex.append(nm2)
        print('exports', ex[:10])
# symbols flags of roc__d1284
