#!/usr/bin/env python3
# frames.py BINARY [N] [FILTER]: the N largest stack frames of BINARY's functions (arm64 macOS, otool),
# read from their prologues: register saves (`stp …, [sp, #-N]!`), `sub sp, sp, #N[, lsl #12]`, and a
# stack-probe loop's target (`sub x9, sp, #P, lsl #12`, maybe `sub x9, x9, #R`), with what the prologue
# takes after the loop. FILTER: a substring the function's name must have (_roc__p: Roc's procedures).
import re, subprocess, sys
binary = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 8
want = sys.argv[3] if len(sys.argv) > 3 else ''
out = subprocess.run(['otool', '-tv', binary], capture_output=True, text=True).stdout
num = r'(0x[0-9a-f]+|\d+)'
pre = re.compile(r'\tstp\t.*\[sp, #-' + num + r'\]!')
subsp = re.compile(r'\tsub\tsp, sp, #' + num + r'(, lsl #12)?$')
probe = re.compile(r'\tsub\tx9, sp, #' + num + r'(, lsl #12)?$')
probe2 = re.compile(r'\tsub\tx9, x9, #' + num + r'$')
loop_end = re.compile(r'\t(b\.ne|b\.gt)\t|\tmov\tsp, x9$')
frames = {}
fn = None
def finish():
    if fn is not None and want in fn:
        frames[fn] = total + probing
for line in out.splitlines():
    if line and not line[0].isspace() and line.endswith(':'):
        finish(); fn = line[:-1]; count = 0; total = 0; probing = 0; in_loop = False; done = False; continue
    if fn is None or done: continue
    count += 1
    if count > 48 or '\tbl\t' in line or '\tret' in line: done = True; continue
    m = pre.search(line)
    if m: total += int(m.group(1), 0); continue
    m = probe.search(line)
    if m: probing = int(m.group(1), 0) * (4096 if m.group(2) else 1); in_loop = True; continue
    m = probe2.search(line)
    if m and in_loop: probing += int(m.group(1), 0); continue
    if in_loop:
        if loop_end.search(line): in_loop = False
        continue
    m = subsp.search(line)
    if m: total += int(m.group(1), 0) * (4096 if m.group(2) else 1)
finish()
for f, v in sorted(frames.items(), key=lambda kv: -kv[1])[:n]:
    print(f'{v:>9} B  {v/1024:8.1f} KiB  {f}')
