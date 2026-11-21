import sys, collections
F = 'F:roc__pa26406365c9698ff460a69bdc20db101'
for label, path in [('composed', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o'), ('unsealed', '/tmp/rocx-split/out/caught2/unsealed.o')]:
    sys.argv = ['x', path, '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
    exec(open('/tmp/rocx-split/scripts/graph6.py').read().split("core = reach(roots, stop)")[0])
    inc = collections.defaultdict(set)
    for x, ys in edges.items():
        for y in ys: inc[y].add(x)
    print(label, 'references to it:', sorted(inc[F]))
    for src in sorted(inc[F]):
        print('   ', src, '<-', sorted(inc[src])[:8])
print('--- upward from the target in the unsealed graph')
frontier = {F}; seen = {F}
for d in range(12):
    nxt = set()
    for x in frontier:
        for y in inc.get(x, ()):
            if y not in seen: seen.add(y); nxt.add(y)
    print(' depth', d, sorted(n[:44] for n in nxt)[:8], len(nxt))
    if not nxt: break
    frontier = nxt
