import sys
sys.argv = ['x', '/tmp/rocx-split/out/marked-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph7.py').read().split("exec(\"core = reach(roots, stop)\" + tail)")[0])
a = 1162400
o = obj_at(a)
print('object at', a, o, [x for x in objs if x[2] == (o or 'D:')[2:]])
targets = sorted(edges.get(o, ()))
print('it points at', len(targets), 'nodes; functions:', [t[2:60] for t in targets if t.startswith('F:')][:12])
inc = [x for x, ys in edges.items() if o in ys]
print('referenced by', len(inc), [x[:60] for x in inc[:8]])
for t in targets:
    fs = [y for y in edges.get(t, ()) if y.startswith('F:')]
    ds = [y for y in edges.get(t, ()) if y.startswith('D:')]
    size = [x for x in objs if 'D:' + x[2] == t]
    print(t[:40], 'size', size[0][1] if size else '?', 'fns', len(fs), 'data', len(ds), [f[2:40] for f in fs[:4]])
