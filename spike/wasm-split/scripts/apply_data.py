# Moves data out of the primary module into the chunks that own it (dataplan.json: [address, size,
# owner]), at the same addresses: a chunk's active segments write it into the shared memory when it is
# instantiated. Zero runs are dropped (fresh memory is zero). Rewrites the split dir's modules in place.
import sys, json, collections
d, plan_path = sys.argv[1], sys.argv[2]
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
def uleb(n):
    out = bytearray()
    while True:
        x = n & 0x7f; n >>= 7
        if n: out.append(x | 0x80)
        else: out.append(x); return bytes(out)
def sleb_enc(n):
    out = bytearray()
    while True:
        x = n & 0x7f; n >>= 7
        if (n == 0 and not x & 0x40) or (n == -1 and x & 0x40): out.append(x); return bytes(out)
        out.append(x | 0x80)
def sections(b):
    i = 8; out = []
    while i < len(b):
        sid = b[i]; i += 1; size, i = leb(b, i); out.append([sid, b[i:i+size]]); i += size
    return out
def write(path, secs, head):
    with open(path, 'wb') as f:
        f.write(head)
        for sid, p in secs: f.write(bytes([sid]) + uleb(len(p)) + p)
def runs(pieces, gap=8):
    # pieces: {address: byte}; contiguous non-zero runs, joined across zero gaps shorter than `gap`
    out = []; addrs = sorted(a for a, v in pieces.items() if v)
    for a in addrs:
        if out and a - (out[-1][0] + len(out[-1][1])) < gap:
            start, buf = out[-1]; buf.extend(b'\0' * (a - start - len(buf))); buf.append(pieces[a])
        else: out.append((a, bytearray([pieces[a]])))
    return out
def data_section(segs):
    p = uleb(len(segs))
    for a, buf in segs: p += b'\x00\x41' + sleb_enc(a) + b'\x0b' + uleb(len(buf)) + bytes(buf)
    return p
primary = open(f'{d}/primary.wasm', 'rb').read(); psecs = sections(primary)
memory_limits = [p for sid, p in psecs if sid == 5][0][1:]
image = {}
for sid, p in psecs:
    if sid == 11:
        n, j = leb(p, 0)
        for _ in range(n):
            fl, j = leb(p, j); off, j = sleb(p, j + 1); j += 1; sz, j = leb(p, j)
            for k in range(sz): image[off + k] = p[j + k]
            j += sz
moved = collections.defaultdict(dict)
for a, sz, owner in json.load(open(plan_path)):
    if owner == 'core': continue
    for k in range(a, a + sz):
        if k in image: moved[owner][k] = image.pop(k)
psegs = runs(image)
out = []
for sid, p in psecs:
    if sid == 11: p = data_section(psegs)
    if sid == 12: p = uleb(len(psegs))
    out.append([sid, p])
write(f'{d}/primary.wasm', out, primary[:8])
import os
for owner, pieces in moved.items():
    path = f'{d}/{owner}.wasm'
    if not os.path.exists(path): print('no module for', owner, len(pieces), 'bytes stay'); continue
    b = open(path, 'rb').read(); secs = sections(b); segs = runs(pieces)
    assert not any(s == 11 for s, _ in secs)
    imp = [x for x in secs if x[0] == 2]
    has_mem = False
    if imp:
        p = imp[0][1]; n, j = leb(p, 0)
        for _ in range(n):
            l, j = leb(p, j); j += l; l, j = leb(p, j); j += l; kind = p[j]; j += 1
            if kind == 0: _, j = leb(p, j)
            elif kind == 1: j += 1; fl, j = leb(p, j); _, j = leb(p, j); j = leb(p, j)[1] if fl & 1 else j
            elif kind == 2: has_mem = True; fl, j = leb(p, j); _, j = leb(p, j); j = leb(p, j)[1] if fl & 1 else j
            elif kind == 3: j += 2
    if not has_mem:
        entry = uleb(7) + b'primary' + uleb(6) + b'memory' + b'\x02' + memory_limits
        if imp:
            p = imp[0][1]; n, j = leb(p, 0); imp[0][1] = uleb(n + 1) + p[j:] + entry
        else:
            k2 = max(i for i, (s2, _) in enumerate(secs) if s2 < 2) + 1 if any(s2 < 2 for s2, _ in secs) else 0
            secs.insert(k2, [2, uleb(1) + entry])
    k = max(i for i, (s, _) in enumerate(secs) if s in range(1, 11)) + 1
    secs.insert(k, [11, data_section(segs)])
    write(path, secs, b[:8])
print('primary data segments', len(psegs), 'bytes', sum(len(x) for _, x in psegs), '| moved', {o: len(v) for o, v in moved.items()})
