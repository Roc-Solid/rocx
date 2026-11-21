import sys, collections
addrs = [int(a) for a in sys.argv[1:]]
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/tmp/rocx-split/out/m.txt', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py', '/tmp/rocx-split/out/dp.json']
exec(open('/tmp/rocx-split/scripts/plan.py').read())
for a in addrs:
    o = obj_at(a)
    inc = [x for x, ys in edges.items() if o in ys]
    print(a, '->', o, 'owner', owner.get(o), 'referenced by', [(x[:40], owner.get(x)) for x in inc[:6]])
