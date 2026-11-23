// Every function Roc can call in the host says first that the host's code runs (D-057): its first
// line is `let _host = preempt::host();`. The interrupt that cuts off a call past its time limit
// (`server/host/src/preempt.rs`) redirects a thread only while this flag says it runs Roc, so a
// function that forgot the line would let it land in the host's code, holding a lock. Read from the
// sources, so it needs no build: the functions the glue says the host defines for Roc (its runtime
// and hosted symbols, `roc_platform_abi.rs`), every function the host exports, and the `RocHost`
// callbacks the host hands Roc (`roc.rs`'s `host_*`) and the interrupt's own landing (`preempted`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const src = join(dirname(fileURLToPath(import.meta.url)), "..", "host", "src");
const glue = readFileSync(join(src, "roc_platform_abi.rs"), "utf8");
const sources = readdirSync(src)
	.filter((name) => name.endsWith(".rs") && name !== "roc_platform_abi.rs")
	.map((name) => ({ name, text: readFileSync(join(src, name), "utf8") }));

/** The first line a guarded function's body begins with (`host()` alone in preempt.rs itself). */
const GUARD = /^let _host = (crate::)?(preempt::)?host\(\);/;

/** Each `extern "C" fn` a source defines (not a declaration, nor a type): its name, whether it is
 * exported (`#[unsafe(no_mangle)]`), and what its body begins with. */
function definitions({ name: file, text }) {
	const found = [];
	for (const match of text.matchAll(/(#\[unsafe\(no_mangle\)\]\s*)?(?:pub )?(?:unsafe )?extern "C" fn (\w+)\(/g)) {
		let at = match.index + match[0].length;
		for (let depth = 1; depth > 0; at++) {
			if (text[at] === "(") depth++;
			else if (text[at] === ")") depth--;
		}
		const brace = text.indexOf("{", at);
		const semicolon = text.indexOf(";", at);
		if (semicolon !== -1 && semicolon < brace) continue;
		found.push({ file, name: match[2], exported: Boolean(match[1]), body: text.slice(brace + 1).trimStart() });
	}
	return found;
}

/** The names a section of the glue declares, in its `unsafe extern "C" { … }` block. */
function declared(section) {
	const start = glue.indexOf(`// ${section}`);
	assert.ok(start >= 0, `the glue has a "${section}" section`);
	const open = glue.indexOf('unsafe extern "C" {', start);
	const close = glue.indexOf("\n}", open);
	return [...glue.slice(open, close).matchAll(/pub fn (\w+)\(/g)].map((match) => match[1]);
}

const defined = sources.flatMap(definitions);
const byName = new Map(defined.map((each) => [each.name, each]));

test("every function the glue says the host defines for Roc (its runtime and hosted symbols) is defined, and its first line says the host's code runs", () => {
	const wanted = [...declared("Runtime Symbols"), ...declared("Hosted Symbols")];
	assert.ok(wanted.length > 100, `the glue's runtime and hosted symbols: ${wanted.length}`);
	const missing = wanted.filter((name) => !byName.has(name));
	assert.deepEqual(missing, [], "declared by the glue, defined nowhere in the host's sources");
	const unguarded = wanted.filter((name) => !GUARD.test(byName.get(name).body));
	assert.deepEqual(unguarded, [], "Roc calls these: each must begin with `let _host = preempt::host();`");
});

test("every function the host exports, the RocHost callbacks it hands Roc, and the interrupt's landing begin with the same line", () => {
	const exported = defined.filter((each) => each.exported && each.name !== "main");
	assert.ok(exported.length > 100, `exported: ${exported.length}`);
	const callbacks = ["host_alloc", "host_dealloc", "host_realloc", "host_dbg", "host_expect_failed", "host_crashed", "preempted"].map((name) => byName.get(name));
	assert.ok(callbacks.every(Boolean), "roc.rs's RocHost callbacks and preempt.rs's landing are where this test looks");
	const unguarded = [...exported, ...callbacks].filter((each) => !GUARD.test(each.body)).map((each) => `${each.file}: ${each.name}`);
	assert.deepEqual(unguarded, [], "each must begin with `let _host = preempt::host();`");
});

test("the guard's trampoline says Roc runs only once its jump target is set, and the guard puts the flag back however its call ended", () => {
	const roc = sources.find((each) => each.name === "roc.rs").text;
	assert.match(roc, /extern "C" fn run<F: FnOnce\(\) -> R, R>\(data: \*mut c_void\) \{[\s\S]*?let was = preempt::enter_roc\(\);\s*slot\.out = Some\(call\(\)\);\s*preempt::restore\(was\);/);
	assert.match(roc, /let in_roc = preempt::in_roc\(\);[\s\S]*?rocx_guarded\(run::<F, R>[\s\S]*?preempt::restore\(in_roc\);/);
});
