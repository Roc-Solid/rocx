// Splits the site's named wasm again with a placeholder map, then renders pages in Node with every
// chunk but Unreached in, naming any Unreached function called.
import { analyse, moveData, binaryen } from "/tmp/rocx-split/repo/src/split.mjs";
import { Runtime } from "/tmp/rocx-split/repo/web/runtime.js";
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
const wasm = "/tmp/rocx-split/repo/site/build/app-split.wasm";
const text = execFileSync(binaryen("wasm-dis"), [wasm], { encoding: "utf8", maxBuffer: 1 << 30 });
const plan = analyse({ object: readFileSync("/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o"), wasm: readFileSync(wasm), text, words: process.env.WORDS !== "0" });
const dir = "/tmp/rocx-split/out/whohits"; rmSync(dir, { recursive: true, force: true }); mkdirSync(dir);
writeFileSync(`${dir}/manifest.txt`, [...plan.functions].map(([o, n]) => `${o}\n${n.sort().join("\n")}`).join("\n\n") + "\n");
execFileSync(binaryen("wasm-split"), ["--multi-split", wasm, "--manifest", `${dir}/manifest.txt`, "--out-prefix", `${dir}/`, "-o", `${dir}/primary.wasm`, "--placeholdermap", "-g"], { stdio: "inherit" });
let table = null; const byIndex = new Map();
for (const line of readFileSync(`${dir}/primary.wasm.placeholders`, "utf8").split("\n").filter(Boolean)) {
	if (line.startsWith("table ")) { table = line.slice(6); continue; }
	const [i, name] = line.split(":"); byIndex.set(`${table}:${i}`, name);
}
const chunks = new Map(readdirSync(dir).filter((f) => f.endsWith(".wasm") && f !== "primary.wasm").map((f) => [f.slice(0, -5), readFileSync(`${dir}/${f}`)]));
const done = moveData(readFileSync(`${dir}/primary.wasm`), chunks, plan.data);
// Load, logging which Unreached placeholder is called.
const orig = Runtime.prototype.placeholder;
const hits = new Map();
const mod = await WebAssembly.compile(done.primary);
const imports = WebAssembly.Module.imports(mod).filter((i) => i.module === "placeholder.Unreached");
const runtime = await Runtime.load(done.primary, { chunk: (o) => done.chunks.get(o), preload: [...done.chunks.keys()].filter((o) => o !== "Unreached") });
// Re-wrap: find the field by trying each Unreached placeholder? Instead patch the instance: call through table b is opaque, so use Error stack names.
for (const path of process.argv.slice(2)) {
	try {
		runtime.renderToString({ path, answers: [] });
		console.log(path, "rendered");
	} catch (error) {
		console.log(path, "->", String(error.message).slice(0, 200));
		const slot = /placeholder (\d+)/.exec(error.message)?.[1];
		if (slot) console.log("  function:", byIndex.get(`1:${slot}`) ?? byIndex.get(`0:${slot}`), "(table 1)", byIndex.get(`1:${slot}`), "(table 0)", byIndex.get(`0:${slot}`));
		console.log(String(error.stack).split("\n").filter((l) => l.includes("wasm")).slice(0, 14).join("\n"));
	}
}
