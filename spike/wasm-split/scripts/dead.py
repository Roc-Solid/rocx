import sys, re
sys.argv = ['x', '/tmp/rocx-split/out/marked-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/out/marked3.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph6.py').read().split("core = reach(roots, stop)")[0])
BASE = 1048704
core = reach(roots, stop)
per = {p: reach(fs, set()) for p, fs in entries.items()}
pages = set().union(*per.values())
inc = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: inc[y].add(x)
datasym = {nm: (seg, off, sz) for kind, nm, v, und in syms if kind == 'd' and v for (seg, off, sz) in [v]}
# object segment offsets (active, pre-laid-out)
seg_off = []
d = obj; s = [x for x in sections if x[0] == 11][0][2]
n, j = leb(d, s)
for _ in range(n):
    fl, j = leb(d, j); assert d[j] == 0x41; off, j = sleb(d, j + 1); j += 1; sz, j = leb(d, j); seg_off.append(off); j += sz
def addr(nm): seg, off, sz = datasym[nm]; return BASE + seg_off[seg] + off, sz
orph = [x[2:] for x in edges if x.startswith('D:') and not inc[x] and x not in core and x not in pages and x[2:] in datasym]
ranges = sorted(addr(nm) for nm in orph)
starts = {a for a, sz in ranges}
# every i32.const in the final code, and every aligned data word
wat = open('/tmp/rocx-split/out/marked3.wat').read() if False else None
import subprocess
txt = subprocess.check_output(['nix', 'shell', 'nixpkgs#binaryen', '-c', 'wasm-dis', '/tmp/rocx-split/out/marked3.wasm'], text=True)
consts = {int(m) for m in re.findall(r'\(i32\.const (-?\d+)\)', txt)}
hit_code = starts & consts
words = set()
for m in re.finditer(r'\(data \S+ \(i32\.const (\d+)\) "(.*)"\)', txt):
    pass
print('orphan data objects', len(orph), 'whose address appears as an i32.const in code:', len(hit_code))
