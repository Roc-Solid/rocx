#!/usr/bin/env node
// The whole re-baseline (2026-11-24), in order, from the worktree root:
//   node site/build.mjs --prepare; python3 spike/wasm-split/split2/mark.py;
//   /tmp/rocx-gate.sh spike/wasm-split/split2/build.sh all   (the five builds, the caught objects)
//   wasm-dis /tmp/rocx-split-2/out/marked-debug.wasm -o /tmp/rocx-split-2/out/marked-debug.wat
//   node spike/wasm-split/split2/fix.mjs --roots tight --weak yes   (DIST=<a site/dist> for answers)
// plan.mjs: graph (wasm.mjs readers, locate.mjs layout) → chunks → wasm-split → sizes; late.mjs: the
// render check; doors.mjs: why core is big (DUMP_EDGES=1 node plan.mjs … first).
//
// The preload check as a fixpoint: plan (plan.mjs) → split → render every page with only its chunks
// (late.mjs) → each late call becomes a page → function edge (run-<tag>/extra-edges.json) → again,
// until no page calls into a chunk it didn't load. Then the exact split is checked the same way.
//   node fix.mjs --roots tight --weak yes [--rounds 8]
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const opt = (name, fallback) => (argv.includes(`--${name}`) ? argv[argv.indexOf(`--${name}`) + 1] : fallback);
const roots = opt("roots", "tight");
const weak = opt("weak", "yes");
const addresses = opt("addresses", "yes");
const layoutMode = opt("layout", "locate");
const rounds = Number(opt("rounds", 8));
const tag = `${roots}-${weak === "yes" ? "weak" : "strong"}${addresses === "yes" ? "" : "-noaddr"}${layoutMode === "locate" ? "-located" : ""}-fixed`;
const OUT = "/tmp/rocx-split-2/out";
const RUN = join(OUT, `run-${tag}`);
const extraFile = join(RUN, "extra-edges.json");
const here = new URL(".", import.meta.url).pathname;
const node = (args) => {
	const done = spawnSync("node", args, { cwd: here, encoding: "utf8", maxBuffer: 1 << 28 });
	if (done.status !== 0) throw new Error(`${args.join(" ")}: ${done.stderr}`);
	return done.stdout;
};
spawnSync("mkdir", ["-p", RUN]);
let extra = existsSync(extraFile) ? JSON.parse(readFileSync(extraFile, "utf8")) : [];
const pick = (out) => out.split("\n").filter((l) => /^(main:|exact chunks|merged chunks|== |first load|heaviest|lightest|selected|biggest chunks|object data)/.test(l)).join("\n");
// Each plan (merged, then exact, then merged again with every edge) until a round finds nothing new.
for (const which of ["merged", "exact", "merged"]) {
	for (let round = 1; round <= rounds; round++) {
		const out = node(["plan.mjs", "--roots", roots, "--weak", weak, "--addresses", addresses, "--layout", layoutMode, "--split", which, "--tag", tag]);
		const late = node(["late.mjs", join(RUN, which)]);
		const found = JSON.parse(readFileSync(join(RUN, which, "late.json"), "utf8"));
		const known = new Set(extra.map((e) => e.join(" ")));
		const fresh = found.filter((e) => !known.has(e.join(" ")));
		const differs = late.split("\n").filter((l) => l.includes("differ")).length;
		console.log(`${which} round ${round}: ${out.split("\n").find((l) => l.startsWith(`== ${which}`))} | ${late.trim().split("\n").pop()} | ${differs} renders differ | ${fresh.length} new edges`);
		if (!found.length) {
			console.log(pick(out));
			break;
		}
		extra = [...extra, ...fresh];
		writeFileSync(extraFile, JSON.stringify(extra));
	}
}
console.log(`late-call edges added: ${extra.length} (${new Set(extra.map((e) => e[1])).size} functions)`);
