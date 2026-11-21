# From ONE build's text (wasm-dis), a split manifest: each page's own functions, the functions 2+
# pages share, and everything else (core). Entries are found by the marker string "rocx-chunk:<Page>"
# rocx put in each page's entry closure. Edges: direct calls, and i32.const k naming table slot k.
# Function pointers stored in data (4-byte words naming a slot) count as reachable from core.
import re, sys, json, collections
wat = open(sys.argv[1]).read().split('\n')
funcs = {}; order = []; cur = None
elems = {}; datas = []; exports = []
def unescape(s):
    out = bytearray(); i = 0
    while i < len(s):
        c = s[i]
        if c == '\\':
            n = s[i+1]
            if n in '0123456789abcdef' and i+2 < len(s) and s[i+2] in '0123456789abcdef': out.append(int(s[i+1:i+3], 16)); i += 3; continue
            out.append({'n': 10, 't': 9, 'r': 13, '"': 34, "'": 39, '\\': 92}[n]); i += 2; continue
        out += c.encode(); i += 1
    return bytes(out)
for line in wat:
    if line.startswith(' (func '):
        cur = line.split()[1]; funcs[cur] = {'calls': set(), 'consts': set()}; order.append(cur); continue
    if line.startswith(' (elem '):
        m = re.match(r' \(elem \S+ \(i32\.const (\d+)\) (.*)\)$', line); base = int(m[1])
        for i, f in enumerate(m[2].split()): elems[base + i] = f
        continue
    if line.startswith(' (data '):
        m = re.match(r' \(data \S+ \(i32\.const (\d+)\) "(.*)"\)$', line)
        if m: datas.append((int(m[1]), unescape(m[2])))
        continue
    if line.startswith(' (export '):
        m = re.search(r'\(func (\$\S+)\)\)', line)
        if m: exports.append(m[1])
        continue
    if cur and line.startswith('  '):
        for m in re.finditer(r'\(call (\$\S+)', line): funcs[cur]['calls'].add(m[1])
        for m in re.finditer(r'\(i32\.const (-?\d+)\)', line): funcs[cur]['consts'].add(int(m[1]))
slots = len(elems) + 1
def refs(f):
    d = funcs.get(f)
    if not d: return set()
    return d['calls'] | {elems[k] for k in d['consts'] if k in elems}
# Markers.
entries = {}
for off, b in datas:
    for m in re.finditer(rb'rocx-chunk:(\w+)', b):
        addr = off + m.start(); end = off + m.end()
        users = [f for f in order if any(addr - 16 <= c <= end for c in funcs[f]['consts'])]
        entries[m[1].decode()] = users
missing = [p for p, u in entries.items() if len(u) != 1]
print('pages', len(entries), 'with one marked function', len(entries) - len(missing), 'ambiguous', {p: len(entries[p]) for p in missing})
# Data words naming a slot: reachable from core.
data_ptrs = set()
for off, b in datas:
    for i in range(0, len(b) - 3):
        if (off + i) % 4: continue
        v = int.from_bytes(b[i:i+4], 'little')
        if 1 <= v < slots and v in elems: data_ptrs.add(elems[v])
entry_fns = {u[0]: p for p, u in entries.items() if len(u) >= 1 for _ in [0]}
stop = set(entry_fns)
def reach(roots, stop):
    seen = set(); todo = [r for r in roots if r not in stop]
    while todo:
        f = todo.pop()
        if f in seen: continue
        seen.add(f)
        todo += [g for g in refs(f) if g not in seen and g not in stop]
    return seen
roots_core = set(exports) | (data_ptrs if '--data' in sys.argv else set())
core = reach(roots_core, stop)
per = {p: reach([f], set()) - core for f, p in entry_fns.items()}
count = collections.Counter(f for s in per.values() for f in s)
own = {p: {f for f in s if count[f] == 1} for p, s in per.items()}
shared = {f for f, n in count.items() if n > 1}
size = lambda fs: len(fs)
print('functions', len(funcs), 'core', len(core), 'shared', len(shared), 'own', {p: len(s) for p, s in sorted(own.items()) if s})
blocks = [p + '\n' + '\n'.join(sorted(s)) for p, s in sorted(own.items()) if s]
if shared: blocks.append('Shared\n' + '\n'.join(sorted(shared)))
open(sys.argv[2], 'w').write('\n\n'.join(blocks) + '\n')
