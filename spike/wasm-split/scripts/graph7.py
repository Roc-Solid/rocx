# graph6 + edges the combine step folded into constants: an i32.const in a final function that falls
# inside a data object's final address range (object offset + BASE) is a reference to that object.
import sys, re, subprocess, bisect
OBJ, MANIFEST, FINAL, FUNCS = sys.argv[1:5]
src = open('/tmp/rocx-split/scripts/graph6.py').read()
head, tail = src.split("core = reach(roots, stop)")
exec(head)
BASE = int(sys.argv[5]) if len(sys.argv) > 5 else 1048704
seg_off = []
s = [x for x in sections if x[0] == 11][0][2]
n, j = leb(obj, s)
for _ in range(n):
    fl, j = leb(obj, j); assert obj[j] == 0x41; off, j = sleb(obj, j + 1); j += 1; sz, j = leb(obj, j); seg_off.append(off); j += sz
objs = sorted((BASE + seg_off[v[0]] + v[1], max(v[2], 1), nm) for kind, nm, v, und in syms if kind == 'd' and v)
starts = [o[0] for o in objs]
def obj_at(a):
    i = bisect.bisect_right(starts, a) - 1
    if i >= 0 and objs[i][0] <= a < objs[i][0] + objs[i][1]: return 'D:' + objs[i][2]
txt = subprocess.check_output(['nix', 'shell', 'nixpkgs#binaryen', '-c', 'wasm-dis', FINAL], text=True)
cur = None; added = 0
for line in txt.split('\n'):
    if line.startswith(' (func '): cur = 'F:' + line.split()[1][1:]; continue
    if cur and line.startswith('  '):
        for m in re.finditer(r'\(i32\.const (\d+)\)', line):
            a = int(m[1])
            if a >= BASE:
                dsym = obj_at(a)
                if dsym and cur in defined and dsym not in edges[cur]: edges[cur].add(dsym); added += 1
print('edges recovered from constants', added)
exec("core = reach(roots, stop)" + tail)
