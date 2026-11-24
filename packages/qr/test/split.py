"""Splits codes.roc's output (argv[1]) into a PNG (each module 4 pixels) and a .txt of its text a code,
in argv[2], with the standard library alone."""
import struct, sys, zlib

def png(bits, side, path, scale=4):
    rows = []
    for y in range(side):
        row = bytearray()
        for x in range(side):
            row += bytes([0 if bits[y * side + x] else 255]) * scale
        rows += [b"\x00" + bytes(row)] * scale
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    width = side * scale
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, width, 8, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))

lines = open(sys.argv[1]).read().split("\n")
at = 0
while at < len(lines):
    line = lines[at]
    if line.startswith("# "):
        _, level, version, text = line.split(" ", 3)
        name = f"{level}-{int(version):02d}"
        if text == "too long":
            print(f"{name}: too long", file=sys.stderr)
            at += 1
            continue
        side = int(lines[at + 2].split()[0])
        bits = [int(b) for row in lines[at + 3 : at + 3 + side] for b in row.split()]
        png(bits, side, f"{sys.argv[2]}/{name}.png")
        open(f"{sys.argv[2]}/{name}.txt", "w").write(text)
        at += 3 + side
    else:
        at += 1
