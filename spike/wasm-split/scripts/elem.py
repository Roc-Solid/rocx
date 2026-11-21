exec(open('/tmp/rocx-split/scripts/graph5.py').read().split("core = reach(roots, stop)")[0])
core = reach(roots, stop)
per = {p: reach(fs, set()) for p, fs in entries.items()}
U = {f for f in defined if f not in core and f not in set().union(*per.values())}
# the object's elem section
for idx, (sid, cname, s, e) in enumerate(sections):
    if sid == 9:
        n, j = leb(obj, s); print('elem segments', n)
        for _ in range(n):
            fl, j = leb(obj, j); print(' flags', fl)
            if fl in (0, 2, 4, 6):
                if fl in (2, 6): _, j = leb(obj, j)
                op = obj[j]; off, j = sleb(obj, j + 1); j += 1; print(' offset op', hex(op), off)
            if fl in (1, 2, 3): j += 1
            cnt, j = leb(obj, j); fns = []
            for _ in range(cnt): fi, j = leb(obj, j); fns.append(fi)
            names = ['F:' + func_name.get(fi - imported_funcs, '?') for fi in fns]
            print(' entries', cnt, 'unassigned among them', sum(1 for x in names if x in U), 'core', sum(1 for x in names if x in core))
