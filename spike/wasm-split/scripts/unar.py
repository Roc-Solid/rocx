# Extracts a GNU ar archive's members into a directory.
import sys, os
d = open(sys.argv[1], 'rb').read(); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
assert d[:8] == b'!<arch>\n'; i = 8; longnames = b''
while i < len(d):
    h = d[i:i+60]; name = h[:16].decode().strip(); size = int(h[48:58]); body = d[i+60:i+60+size]
    if name == '//': longnames = body
    elif name != '/':
        if name.startswith('/'): o = int(name[1:]); name = longnames[o:longnames.index(b'\n', o)].decode()
        name = name.rstrip('/'); open(os.path.join(out, os.path.basename(name)), 'wb').write(body); print(name, size)
    i += 60 + size + (size & 1)
