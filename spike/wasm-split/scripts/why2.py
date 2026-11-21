exec(open('/tmp/rocx-split/scripts/graph5.py').read().split("core = reach(roots, stop)")[0])
core = reach(roots, stop)
per = {p: reach(fs, set()) for p, fs in entries.items()}
allpages = set().union(*per.values())
U = {f for f in defined if f not in core and f not in allpages}
incoming = collections.defaultdict(set)
for x, ys in edges.items():
    for y in ys: incoming[y].add(x)
tops = {f for f in defined if not (incoming[f] & (defined | {d for d in incoming[f] if d.startswith('D:')}))}
print('unassigned', len(U), 'of which nothing in the app references', len(U & tops))
fromtops = reach(tops - stop - roots, stop)
print('reached from those unreferenced functions:', len(U & fromtops))
# Of the unreferenced ones: do pages' code reach them via something not followed? Print a few with their callees.
import itertools
for f in itertools.islice(sorted(U & tops), 6): print(f[:60], 'calls', len(edges.get(f, ())), 'reached-by', len(incoming[f]))
