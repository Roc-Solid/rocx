// Why is core big? Reads run-<tag>/edges.json (DUMP_EDGES=1 node plan.mjs …). For each core function
// that only some pages reach (reach from a page through everything but other pages' entries), the
// path from a root, and the first node on it that only pages reach ("the door"), summed by door.
import { readFileSync } from "node:fs";
const tag = process.argv[2] ?? "tight-strong";
const g = JSON.parse(readFileSync(`/tmp/rocx-split-2/out/run-${tag}/edges.json`, "utf8"));
const edges = new Map(Object.entries(g.edges).map(([k, v]) => [k, v]));
const stop = new Set(g.stop);
const size = new Map(Object.entries(g.size));
const pages = Object.keys(g.entries);
const bfs = (from, stopAt) => {
	const parent = new Map(from.map((n) => [n, null]));
	const q = [...from];
	while (q.length) {
		const n = q.shift();
		for (const m of edges.get(n) ?? []) if (!parent.has(m) && !stopAt.has(m)) { parent.set(m, n); q.push(m); }
	}
	return parent;
};
const core = bfs(g.roots.filter((r) => !stop.has(r)), stop);
const pageReach = new Map(pages.map((p) => [p, new Set(bfs(g.entries[p], new Set([...stop].filter((s) => !g.entries[p].includes(s)))).keys())]));
const count = new Map();
for (const s of pageReach.values()) for (const n of s) count.set(n, (count.get(n) ?? 0) + 1);
// "Page-ish": core functions fewer than half the pages reach (or none).
const pageish = [...core.keys()].filter((n) => n.startsWith("F:") && (count.get(n) ?? 0) < pages.length / 2 && (count.get(n) ?? 0) > 0);
const total = pageish.reduce((a, n) => a + (+size.get(n) || 0), 0);
console.log(`core ${core.size} nodes; page-ish core functions ${pageish.length}, ${(total / 1024).toFixed(1)} KB raw`);
const pathOf = (n) => { const out = []; for (let x = n; x !== null; x = core.get(x)) out.push(x); return out.reverse(); };
const doors = new Map();
for (const n of pageish) {
	const path = pathOf(n);
	// The door: the last node on the path that more than half the pages reach (or that no page reaches), then the next.
	let i = path.length - 1;
	while (i > 0 && (count.get(path[i - 1]) ?? 0) < pages.length / 2 && (count.get(path[i - 1]) ?? 0) > 0) i--;
	const door = `${path[i - 1] ?? "(root)"} -> ${path[i]}`;
	const d = doors.get(door) ?? doors.set(door, { bytes: 0, n: 0, path: path.slice(0, i + 1) }).get(door);
	d.bytes += +size.get(n) || 0; d.n++;
}
const byRoot = new Map();
for (const [door, d] of doors) { const r = d.path[0]; byRoot.set(r, (byRoot.get(r) ?? 0) + d.bytes); }
console.log("by root:", [...byRoot].sort((a, b) => b[1] - a[1]).slice(0, 10).map(([r, b]) => `${r.slice(0, 50)} ${(b / 1024).toFixed(1)}KB`).join(" | "));
for (const [door, d] of [...doors].sort((a, b) => b[1].bytes - a[1].bytes).slice(0, 25)) console.log(`${(d.bytes / 1024).toFixed(1).padStart(6)} KB ${String(d.n).padStart(4)} fns  ${d.path.map((x) => x.slice(0, 44) + `[${count.get(x) ?? 0}]`).join(" > ")}`);
