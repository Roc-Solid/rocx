import { analyse, binaryen } from "/tmp/rocx-split/repo/src/split.mjs";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
const wasm = "/tmp/rocx-split/repo/site/build/app-split.wasm";
const text = execFileSync(binaryen("wasm-dis"), [wasm], { encoding: "utf8", maxBuffer: 1 << 30 });
const plan = analyse({ object: readFileSync("/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o"), unsealed: readFileSync("/tmp/rocx-split/out/caught2/unsealed.o"), wasm: readFileSync(wasm), text });
const { owner, edges, roots, entries, canonical, publicNames } = plan.debug;
console.log("public names:", [...publicNames].slice(0, 6), "canonical roc_mount ->", canonical.get("F:roc_mount"));
console.log("roc_mount in text?", text.includes("(func $roc_mount "), "| edges from F:roc_mount:", edges.get("F:roc_mount")?.size);
for (const f of ["F:roc__pa26406365c9698ff460a69bdc20db101", "F:roc__p6f64ce9bbc1c03cc327cf21c97281a14"]) {
	const inc = [...edges].filter(([, t]) => t.has(f)).map(([k]) => k);
	console.log(f.slice(0, 26), "owner", owner.get(f), "incoming", inc.slice(0, 5));
}
console.log("entries Syntax:", entries.get("SyntaxPage"), "Calls:", entries.get("CallsPage"));
