import sys, re, subprocess
sys.argv = ['x', '/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o', '/dev/null', '/tmp/rocx-split/repo/site/build/app-split.wasm', '/tmp/rocx-split/scripts/funcs.py']
exec(open('/tmp/rocx-split/scripts/graph7.py').read().split("exec(\"core = reach(roots, stop)\" + tail)")[0])
want = {nm: (a, sz) for a, sz, nm in objs if nm in ('roc__d0', 'roc__d0_1', 'roc__d13_1', 'roc__d13')}
print(want)
txt = subprocess.check_output(['nix', 'shell', 'nixpkgs#binaryen', '-c', 'wasm-dis', FINAL], text=True)
cur = None
for line in txt.split('\n'):
    if line.startswith(' (func '): cur = line.split()[1]
    for m in re.finditer(r'\(i32\.const (\d+)\)', line):
        v = int(m[1])
        for nm, (a, sz) in want.items():
            if a <= v < a + max(sz, 1) or v == a: print('const', v, '->', nm, 'in', cur)
# data words anywhere
fin = open(FINAL, 'rb').read(); i = 8
while i < len(fin):
    sid = fin[i]; i += 1; size, i = leb(fin, i); end = i + size
    if sid == 11:
        n, j = leb(fin, i)
        for _ in range(n):
            fl, j = leb(fin, j); off, j = sleb(fin, j + 1); j += 1; sz, j = leb(fin, j)
            for k in range(0, sz - 3):
                w = int.from_bytes(fin[j+k:j+k+4], 'little')
                for nm, (a, s2) in want.items():
                    if a <= w < a + max(s2, 1): print('word at', off + k, 'aligned' if (off + k) % 4 == 0 else 'UNALIGNED', '->', nm, 'from', obj_at(off + k))
            j += sz
    i = end
