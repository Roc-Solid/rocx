import sys, re, subprocess, collections
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph7.py').read().split("exec(\"core = reach(roots, stop)\" + tail)")[0])
rng = {nm: (a, max(sz, 1)) for a, sz, nm in objs}
txt = subprocess.check_output(['nix', 'shell', 'nixpkgs#binaryen', '-c', 'wasm-dis', FINAL], text=True)
fconst = collections.defaultdict(set); cur = None
for line in txt.split('\n'):
    if line.startswith(' (func '): cur = line.split()[1]; continue
    for m in re.finditer(r'\(i32\.const (\d+)\)', line): fconst[int(m[1])].add(cur)
consts = sorted(fconst)
words = []
fin = open(FINAL, 'rb').read(); i = 8
while i < len(fin):
    sid = fin[i]; i += 1; size, i = leb(fin, i); end = i + size
    if sid == 11:
        n, j = leb(fin, i)
        for _ in range(n):
            fl, j = leb(fin, j); off, j = sleb(fin, j + 1); j += 1; sz, j = leb(fin, j)
            for k in range(0, sz - 3, 1):
                words.append((off + k, int.from_bytes(fin[j+k:j+k+4], 'little')))
            j += sz
    i = end
import bisect
level = {'roc__d0', 'roc__d13'}; seen = set(level)
for depth in range(8):
    nxt = set(); fns = set()
    for nm in level:
        a, sz = rng[nm]
        lo = bisect.bisect_left(consts, a); hi = bisect.bisect_left(consts, a + sz)
        for c in consts[lo:hi]: fns |= fconst[c]
        for at, w in words:
            if a <= w < a + sz:
                src = obj_at(at)
                if src and src[2:] not in seen: nxt.add(src[2:])
                elif not src: fns.add(f'<data at {at}, outside the app objects>')
    print('depth', depth, 'data', sorted(nxt)[:8], len(nxt), 'functions', sorted(fns)[:6])
    if fns: break
    seen |= nxt; level = nxt
    if not nxt: break
