// Spike runner: renders the app, aborting a render on a pending read (a JS exception thrown
// through the Roc frames), and runs it again once what it waits for is in. Reports how many runs
// a render took, what a failed read does, and what an abort leaks.
import { readFileSync } from "node:fs";

class NotReady extends Error {}
class Failed extends Error {}

export async function load(file, { fail = new Set(), delay = 5 } = {}) {
	let ex;
	let taken = null;
	let fetches = 0;
	/** key → { state: "pending" | "ok" | "failed", value, promise } */
	const cache = new Map();
	const encoder = new TextEncoder();
	const decoder = new TextDecoder();
	const text = (ptr, len) => decoder.decode(new Uint8Array(ex.memory.buffer, ptr >>> 0, len >>> 0));
	const start = (key) => {
		if (cache.has(key)) return;
		const entry = { state: "pending" };
		entry.promise = new Promise((resolve) => setTimeout(resolve, delay)).then(() => {
			fetches++;
			Object.assign(entry, fail.has(key) ? { state: "failed", value: `${key} answered 500` } : { state: "ok", value: `<${key.slice(1)}>` });
		});
		cache.set(key, entry);
	};
	const env = {
		js_log: (ptr, len) => console.log(text(ptr, len)),
		js_crashed: (ptr, len) => {
			throw new Error(`roc crashed: ${text(ptr, len)}`);
		},
		js_async_start: (ptr, len) => start(text(ptr, len)),
		js_async_read: (ptr, len) => {
			const key = text(ptr, len);
			start(key);
			const entry = cache.get(key);
			if (entry.state === "pending") throw new NotReady(key);
			if (entry.state === "failed") throw new Failed(entry.value);
			taken = encoder.encode(entry.value);
			return taken.length;
		},
		js_take: (dest) => new Uint8Array(ex.memory.buffer, dest >>> 0, taken.length).set(taken),
	};
	ex = (await WebAssembly.instantiate(readFileSync(file), { env })).instance.exports;
	const arg = (value) => {
		const bytes = encoder.encode(value);
		const ptr = ex.alloc_bytes(bytes.length) >>> 0;
		if (bytes.length) new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
		return [ptr, bytes.length];
	};
	/** Renders `page`; a pending read aborts the run, and the render runs again when every pending value is in. */
	async function render(page, { restore = true } = {}) {
		let runs = 0;
		for (;;) {
			runs++;
			const sp = ex.__stack_pointer.value;
			try {
				ex.render(...arg(page));
				return { out: text(ex.result_ptr(), ex.result_len()), runs };
			} catch (error) {
				// The unwound frames never ran their epilogues: Roc's stack pointer is where the read left it.
				const drift = sp - ex.__stack_pointer.value;
				if (restore) ex.__stack_pointer.value = sp;
				if (error instanceof NotReady) {
					await Promise.all([...cache.values()].filter((entry) => entry.state === "pending").map((entry) => entry.promise));
					render.drift = drift;
					continue;
				}
				if (error instanceof Failed) return { failed: error.message, runs };
				throw error;
			}
		}
	}
	return { ex, cache, fail, render, live: () => Number(ex.live_allocations()), fetches: () => fetches, sp: () => ex.__stack_pointer.value };
}

for (const build of ["app-dev.wasm", "app-size.wasm"]) {
	console.log(`== ${build}`);
	const file = new URL(build, import.meta.url);
	{
		const page = await load(file);
		const first = await page.render("waterfall");
		console.log(`waterfall: ${first.runs} runs, ${page.fetches()} fetches → ${first.out}`);
		console.log(`  each abort left Roc's stack pointer ${render_drift(page)} bytes lower, until restored`);
	}
	{
		const page = await load(file);
		const first = await page.render("parallel");
		console.log(`parallel:  ${first.runs} runs, ${page.fetches()} fetches → ${first.out}`);
	}
	{
		const page = await load(file, { fail: new Set(["/likes"]) });
		const result = await page.render("parallel");
		console.log(`one fails: ${result.runs} runs → failed: ${result.failed}`);
		page.fail.delete("/likes");
		page.cache.delete("/likes"); // a retry: fetched again, and this time it answers
		const again = await page.render("parallel");
		console.log(`  retried, the same instance renders: ${again.failed ?? again.out}`);
	}
	{
		// Leaks. Each run makes one cell the host keeps (on purpose); anything else an abort
		// leaves is a leak: the unwound frames never released what they held.
		const page = await load(file, { delay: 0 });
		await page.render("waterfall");
		const settled = page.live();
		const rounds = 100;
		for (let i = 0; i < rounds; i++) {
			page.cache.clear(); // every value pending again: 5 aborts, then a render that completes
			await page.render("waterfall");
		}
		const perRound = (page.live() - settled) / rounds;
		console.log(`leaks: ${((perRound - 6) / 5).toFixed(2)} allocations per abort (a waterfall round: 5 aborts, 1 completed render, 6 cells kept)`);
	}
	{
		const page = await load(file, { delay: 0 });
		const sp = page.sp();
		for (let i = 0; i < 50; i++) {
			page.cache.clear();
			await page.render("parallel", { restore: false });
		}
		console.log(`without restoring the stack pointer, 50 aborts sink it ${sp - page.sp()} bytes`);
	}
}

function render_drift(page) {
	return page.render.drift ?? "?";
}
