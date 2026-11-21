# The exact reference graph of the app's relocatable wasm object (from an `output: Archive` build):
# functions and data objects as nodes; calls, address-taken functions and data references (code and
# data relocations) as edges. Page entries are the functions referencing the data object holding
# "rocx-chunk:<Page>". Writes a wasm-split manifest: each page's own functions, the shared ones.
import sys, re, collections
obj = open(sys.argv[1], 'rb').read()
def leb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
        if x < 0x80: return r, i
def sleb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
        if x < 0x80:
            if x & 0x40: r -= 1 << s
            return r, i
def name(b, i):
    n, i = leb(b, i); return b[i:i+n].decode(errors='replace'), i + n
sections = []; i = 8
while i < len(obj):
    sid = obj[i]; i += 1; size, i = leb(obj, i); start = i; cname = None
    if sid == 0: cname, start = name(obj, i)
    sections.append((sid, cname, start, i + size)); i += size
imported_funcs = 0; bodies = []; segs = []
for idx, (sid, cname, s, e) in enumerate(sections):
    if sid == 2:
        n, j = leb(obj, s)
        for _ in range(n):
            _, j = name(obj, j); _, j = name(obj, j); kind = obj[j]; j += 1
            if kind == 0: _, j = leb(obj, j); imported_funcs += 1
            elif kind == 1: j += 1; fl, j = leb(obj, j); _, j = leb(obj, j); j = leb(obj, j)[1] if fl & 1 else j
            elif kind == 2: fl, j = leb(obj, j); _, j = leb(obj, j); j = leb(obj, j)[1] if fl & 1 else j
            elif kind == 3: j += 2
            elif kind == 4: j += 1; _, j = leb(obj, j)
    if sid == 10:
        code_index = idx; n, j = leb(obj, s)
        for _ in range(n):
            sz, j2 = leb(obj, j); bodies.append((j - s, j2 + sz - s)); j = j2 + sz
    if sid == 11:
        data_index = idx; n, j = leb(obj, s)
        for _ in range(n):
            fl, j = leb(obj, j)
            if fl in (0, 2):
                if fl == 2: _, j = leb(obj, j)
                assert obj[j] == 0x41, obj[j]; _, j = sleb(obj, j + 1); assert obj[j] == 0x0b; j += 1
            sz, j = leb(obj, j); segs.append((j - s, sz, obj[j:j+sz])); j += sz
# Symbols.
syms = []
for sid, cname, s, e in sections:
    if cname != 'linking': continue
    _, j = leb(obj, s)
    while j < e:
        kind = obj[j]; j += 1; size, j = leb(obj, j); end = j + size
        if kind == 8:
            n, k = leb(obj, j)
            for _ in range(n):
                sk = obj[k]; k += 1; fl, k = leb(obj, k); undefined = fl & 0x10
                if sk in (0, 2, 4, 5):
                    index, k = leb(obj, k); nm = None
                    if not undefined or fl & 0x40: nm, k = name(obj, k)
                    syms.append(('f' if sk == 0 else 'o', nm, index, undefined))
                elif sk == 1:
                    nm, k = name(obj, k)
                    if not undefined:
                        seg, k = leb(obj, k); off, k = leb(obj, k); sz, k = leb(obj, k); syms.append(('d', nm, (seg, off, sz), 0))
                    else: syms.append(('d', nm, None, 1))
                elif sk == 3: _, k = leb(obj, k); syms.append(('s', None, None, 0))
        j = end
func_name = {}
for kind, nm, index, und in syms:
    if kind == 'f' and nm and index >= imported_funcs: func_name[index - imported_funcs] = nm
def body_of(off):
    lo, hi = 0, len(bodies) - 1
    while lo <= hi:
        m = (lo + hi) // 2; a, b = bodies[m]
        if off < a: hi = m - 1
        elif off >= b: lo = m + 1
        else: return m
data_syms = [(seg, off, sz, nm) for kind, nm, v, und in syms if kind == 'd' and v for (seg, off, sz) in [v]]
by_seg = collections.defaultdict(list)
for seg, off, sz, nm in data_syms: by_seg[seg].append((off, sz, nm))
def data_at(segoff):
    for si, (start, sz, _) in enumerate(segs):
        if start <= segoff < start + sz:
            rel = segoff - start
            for off, dsz, nm in by_seg[si]:
                if off <= rel < off + max(dsz, 1): return 'D:' + nm
            return f'D:seg{si}'
ADDEND = {3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 22, 23, 25}
TABLE = {1, 2, 12, 18, 19, 24}; CALL = {0, 26}; MEM = {3, 4, 5, 11, 14, 15, 16, 17, 21, 23, 25}
edges = collections.defaultdict(set)
memrefs = collections.defaultdict(list)
for sid, cname, s, e in sections:
    if not (cname or '').startswith('reloc.'): continue
    target, j = leb(obj, s); n, j = leb(obj, j)
    for _ in range(n):
        t = obj[j]; j += 1; off, j = leb(obj, j); idx, j = leb(obj, j)
        addend = 0
        if t in ADDEND: addend, j = sleb(obj, j)
        kind, nm, v, und = syms[idx]
        dest = None
        if t in CALL | TABLE and kind == 'f' and nm: dest = 'F:' + nm
        elif t in MEM and kind == 'd' and nm: dest = 'D:' + nm
        if not dest: continue
        if target == code_index:
            b = body_of(off)
            if b is not None and b in func_name:
                edges['F:' + func_name[b]].add(dest)
                if dest.startswith('D:'): memrefs[dest].append(('F:' + func_name[b], addend))
        elif target == data_index:
            src = data_at(off)
            if src:
                edges[src].add(dest)
                if dest.startswith('D:'): memrefs[dest].append((src, addend))
# Data objects holding a marker, and the functions referencing them: the page entries.
entries = {}
for seg, off, sz, nm in data_syms:
    blob = segs[seg][2][off:off+sz]
    for m in re.finditer(rb'rocx-chunk:([A-Za-z]+Page)', blob):
        found = set(); frontier = {x for x, a in memrefs['D:' + nm] if m.start() - 16 <= a <= m.start()}
        for _ in range(4):
            found |= {x for x in frontier if x.startswith('F:')}
            frontier = {y for x in frontier if x.startswith('D:') for y, _a in memrefs[x]}
        entries.setdefault(m[1].decode(), set()).update(found)
print('pages', len(entries), {p: len(f) for p, f in entries.items() if len(f) != 1} or 'each has one entry function')
stop = set().union(*entries.values())
import json, subprocess
final = set(json.loads(subprocess.check_output(['python3', '-I', sys.argv[4], sys.argv[3]])))
defined = {'F:' + n for n in func_name.values() if n in final}
print('object functions', len(func_name), 'in the final module', len(defined))
for k in list(edges): 
    edges[k] = {y for y in edges[k] if not y.startswith('F:') or y in defined}
    if k.startswith('F:') and k not in defined: del edges[k]
referenced = set().union(*edges.values())
roots = {f for f in defined if not f[2:].startswith('roc__p')}
print('roots', sorted(r[2:] for r in roots)[:12])
def reach(rs, stop):
    seen = set(); todo = [r for r in rs if r not in stop]
    while todo:
        x = todo.pop()
        if x in seen: continue
        seen.add(x); todo += [y for y in edges.get(x, ()) if y not in seen and y not in stop]
    return seen
core = reach(roots, stop)
per = {p: reach(fs, set()) - core for p, fs in entries.items()}
count = collections.Counter(x for s in per.values() for x in s if x.startswith('F:'))
own = {p: {x[2:] for x in s if x.startswith('F:') and count[x] == 1} for p, s in per.items()}
shared = {x[2:] for x, n in count.items() if n > 1}
corefn = {x for x in core if x.startswith('F:')}
print('functions', len(defined), 'roots', len(roots), 'core', len(corefn), 'shared', len(shared))
print('own', {p: len(s) for p, s in sorted(own.items(), key=lambda kv: -len(kv[1])) if s})
blocks = [p + '\n' + '\n'.join(sorted(s)) for p, s in sorted(own.items()) if s]
if shared: blocks.append('Shared\n' + '\n'.join(sorted(shared)))
open(sys.argv[2], 'w').write('\n\n'.join(blocks) + '\n')
