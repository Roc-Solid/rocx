import sys, collections
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/tmp/rocx-split/out/m.txt', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/dp.json']
exec(open('/tmp/rocx-split/scripts/plan.py').read())
F = 'F:roc__p8ed4a0b2523cdafb6ee3645f741d7f06'
inc = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: inc[y].add(x)
print('owner', owner.get(F), 'incoming', sorted(inc[F]))
for src in sorted(inc[F]):
    print(' ', src, 'owner', owner.get(src), 'its incoming', sorted(inc[src])[:6])
# raw relocations naming the function
idx = [i for i, s in enumerate(syms) if s[1] == F[2:]]
print('symbol indexes', idx)
for sid, cname, s, e in sections:
    if not (cname or '').startswith('reloc.'): continue
    target, j = leb(obj, s); n, j = leb(obj, j)
    for _ in range(n):
        t = obj[j]; j += 1; off, j = leb(obj, j); ix, j = leb(obj, j)
        if t in ADDEND: _, j = sleb(obj, j)
        if ix in idx: print('  reloc', cname, 'type', t, 'offset', off, 'in', ('F:' + func_name.get(body_of(off), '?')) if target == code_index else data_at(off))
