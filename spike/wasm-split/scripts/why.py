exec(open('/tmp/rocx-split/scripts/graph5.py').read().split("core = reach(roots, stop)")[0])
core = reach(roots, stop)
# How much does core shrink if data objects with many function edges are not followed?
fan = sorted(((sum(1 for y in edges[x] if y.startswith('F:')), x) for x in core if x.startswith('D:')), reverse=True)[:8]
print('data objects in core with the most function pointers:', fan)
nodata = reach(roots, stop | {x for n, x in fan[:3]})
print('core functions', sum(1 for x in core if x.startswith('F:')), 'without the top 3 tables', sum(1 for x in nodata if x.startswith('F:')))
# Which roots pull in the most?
big = sorted(((sum(1 for y in reach([r], stop) if y.startswith('F:')), r) for r in roots), reverse=True)[:8]
print('roots that reach the most functions:', big)
