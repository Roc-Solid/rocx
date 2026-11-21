import { analyse, binaryen } from "/tmp/rocx-split/repo/src/split.mjs";
import { Runtime } from "/tmp/rocx-split/repo/web/runtime.js";
import { startServer, nativePage } from "/tmp/rocx-split/repo/site/build.mjs";
import { readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
const wasm = "/tmp/rocx-split/repo/site/build/app-split.wasm";
const text = execFileSync(binaryen("wasm-dis"), [wasm], { encoding: "utf8", maxBuffer: 1 << 30 });
const plan = analyse({ object: readFileSync("/tmp/rocx-split/out/site-ar/roc_app_llvm_wasm32_size.o"), unsealed: readFileSync("/tmp/rocx-split/out/caught2/unsealed.o"), wasm: readFileSync(wasm), text });
const dir = "/tmp/rocx-split/out/latestack"; rmSync(dir, { recursive: true, force: true }); mkdirSync(dir);
writeFileSync(`${dir}/manifest.txt`, [...plan.functions].map(([o, n]) => `${o}\n${n.sort().join("\n")}`).join("\n\n") + "\n");
execFileSync(binaryen("wasm-split"), ["--multi-split", wasm, "--manifest", `${dir}/manifest.txt`, "--out-prefix", `${dir}/`, "-o", `${dir}/primary.wasm`, "-g"], { stdio: "ignore" });
const site = await startServer();
try {
	for (const [path, page] of process.argv.slice(2).map((arg) => arg.split("="))) {
		const native = await nativePage(site.url, path);
		const runtime = await Runtime.load(readFileSync(`${dir}/primary.wasm`), { chunk: (o) => readFileSync(`${dir}/${o}.wasm`), preload: plan.needs.get(page) });
		try {
			const ok = runtime.renderToString({ path, answers: native.answers, regions: native.regions }).html === native.html;
			console.log(path, "renders", ok ? "as the server does" : "DIFFERENTLY");
		} catch (error) {
			console.log(path, "->", error.message.slice(0, 120));
			console.log(String(error.stack).split("\n").filter((l) => l.includes(".wasm")).slice(0, 8).map((l) => l.trim().slice(0, 140)).join("\n"));
		}
	}
} finally { await site.stop(); }
