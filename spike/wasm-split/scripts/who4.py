import sys, collections
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/tmp/rocx-split/out/m.txt', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/dp.json']
exec(open('/tmp/rocx-split/scripts/plan.py').read())
o = obj_at(1135360)
print('object at 1135360:', o, [x for x in objs if 'D:' + x[2] == o], 'owner', owner.get(o))
print('its edges', sorted(edges.get(o, ()))[:10])
inc = [x for x, ys in edges.items() if o in ys]
print('referenced by', inc[:10], [owner.get(x) for x in inc[:10]])
