import sys, collections
sys.argv = ['x', '/tmp/rocx-split/out/caught2/unsealed.o', '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph6.py').read().split("core = reach(roots, stop)")[0])
for F in ['roc__p6f64ce9bbc1c03cc327cf21c97281a14', 'roc__pb88b385d41a83a96d3e87622ada6b5ae']:
    idx = [i for i, s in enumerate(syms) if s[1] == F]
    print(F[:24], 'symbols', [(i, syms[i]) for i in idx])
    for sid, cname, s, e in sections:
        if not (cname or '').startswith('reloc.'): continue
        target, j = leb(obj, s); n, j = leb(obj, j)
        for _ in range(n):
            t = obj[j]; j += 1; off, j = leb(obj, j); ix, j = leb(obj, j)
            if t in ADDEND: _, j = sleb(obj, j)
            if ix in idx: print('   reloc', cname, 'type', t, 'from', ('F:' + func_name.get(body_of(off), '?'))[:50] if target == code_index else data_at(off))
    print('   in entries:', any('F:' + F in v for v in entries.values()), '| page of marker:', [p for p, v in entries.items() if 'F:' + F in v])
