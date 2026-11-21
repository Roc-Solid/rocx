import { analyse, moveData, binaryen } from "/tmp/rocx-split/repo/src/split.mjs";
import { Runtime } from "/tmp/rocx-split/repo/web/runtime.js";
import { readFileSync, readdirSync } from "node:fs";
const dir = "/tmp/rocx-split/out/whohits";
const chunks = new Map(readdirSync(dir).filter((f) => f.endsWith(".wasm") && f !== "primary.wasm").map((f) => [f.slice(0, -5), readFileSync(`${dir}/${f}`)]));
const plan = JSON.parse(process.env.PLAN ?? "null");
const primary = readFileSync(`${dir}/primary.wasm`);
let runtime;
const orig = Runtime.prototype.placeholder;
Runtime.prototype.placeholder = function (owner, slot) {
	if (owner === "Unreached") {
		const mem = new Uint32Array(this.ex.memory.buffer);
		for (const [name, address] of [["slot", Number(slot)]]) {
			const at = [];
			for (let i = 0; i < mem.length && at.length < 8; i++) if (mem[i] === address) at.push(i * 4);
			console.log(name, address, "found at", at.join(", "));
		}
	}
	return orig.call(this, owner, slot);
};
runtime = await Runtime.load(primary, { chunk: (o) => chunks.get(o), preload: [...chunks.keys()].filter((o) => o !== "Unreached") });
try { runtime.renderToString({ path: process.argv[2], answers: [] }); } catch (e) { console.log(String(e.message).slice(0, 80)); }
