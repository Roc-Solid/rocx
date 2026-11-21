import sys, collections
# names of the combined objects holding the sidebar's struct and its description string
exec(open('/tmp/rocx-split/scripts/segs.py').read().split('for p in sys.argv')[0])
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
src = open('/tmp/rocx-split/scripts/graph7.py').read().split("exec(\"core = reach(roots, stop)\" + tail)")[0]
exec(src)
want = {obj_at(1139356), obj_at(1138988), 'D:roc__d13', 'D:roc__d13_1', 'D:roc__d0_1', 'D:roc__d0'}
print('combined names:', want)
sys.argv = ['x', '/tmp/rocx-split/out/caught2/unsealed.o', '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph6.py').read().split("core = reach(roots, stop)")[0])
inc = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: inc[y].add(x)
for w in sorted(want):
    print(w, '<-', sorted(inc.get(w, ()))[:6])
def up(start, depth=8):
    frontier = {start}; seen = set()
    for d in range(depth):
        nxt = set()
        for x in frontier:
            for y in inc.get(x, ()):
                if y not in seen: seen.add(y); nxt.add(y)
        fns = [y for y in nxt if y.startswith('F:')]
        print('  depth', d, 'functions', [f[:40] for f in fns][:5], 'data', [y for y in nxt if y.startswith('D:')][:5])
        if fns or not nxt: break
        frontier = nxt
for start in ['D:roc__d0_1', 'D:roc__d68_1']:
    print(start); up(start)
flags_of = {}
