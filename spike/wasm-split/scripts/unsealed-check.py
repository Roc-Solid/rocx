import sys, collections
sys.argv = ['x', '/tmp/rocx-split/out/unsealed.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph6.py').read().split("core = reach(roots, stop)")[0])
F = 'roc__p8ed4a0b2523cdafb6ee3645f741d7f06'
print('in unsealed:', any(s[1] == F for s in syms))
idx = [i for i, s in enumerate(syms) if s[1] == F]
for sid, cname, s, e in sections:
    if not (cname or '').startswith('reloc.'): continue
    target, j = leb(obj, s); n, j = leb(obj, j)
    for _ in range(n):
        t = obj[j]; j += 1; off, j = leb(obj, j); ix, j = leb(obj, j)
        if t in ADDEND: _, j = sleb(obj, j)
        if ix in idx: print('  reloc', cname, 'type', t, 'in', ('F:' + func_name.get(body_of(off), '?')) if target == code_index else data_at(off))
# also count table relocs in data vs combined
