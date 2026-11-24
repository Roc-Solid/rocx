// reports.js: rocx's output read into problems (the compiler's reports in fixtures.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

import { checked } from "./fixtures.mjs";

const { Reports } = createRequire(import.meta.url)("../reports.js");

const read = (text) => {
	const reports = new Reports();
	const said = text.split("\n").map((line) => reports.push(line));
	reports.end();
	return { reports, said, problems: reports.list() };
};


test("the compiler's reports, remapped: severity, place, the carets' width, the text without the quoted line", () => {
	const { problems } = read(checked);
	assert.equal(problems.length, 2);
	assert.deepEqual(problems[0], {
		severity: "warning",
		file: "routes/+page.rocx",
		line: 7,
		column: 2,
		width: 6,
		message:
			"unused variable\n\nVariable unused is defined here and then never used.\n\nIf you don't need this variable, prefix it with an underscore like _unused to\nsuppress this warning.",
	});
	assert.equal(problems[1].severity, "error");
	assert.equal(problems[1].line, 11);
	assert.equal(problems[1].column, 4);
	assert.equal(problems[1].width, 2);
	assert.equal(
		problems[1].message,
		"type mismatch\n\nThe first argument being passed to this function has the wrong type.\n\nThis argument has the type:\n\n    () => I64\n\nBut the function needs the first argument to be:\n\n    () => Str",
	);
});

test("rocx's own problems: with a column, with a line alone, with neither", () => {
	const { problems } = read(
		[
			"✗ routes/+page.rocx:3:5: <br> has no children or closing tag: write <br />",
			"    \t\t<br>",
			"        ^",
			"⚠ Ui/Card.rocx:12: the browser's copy imports Db, which only the server has",
			"✗ routes/api/+server.roc: a +server answers methods: define one of get, post",
			"rocx dev: rocx build failed; fix it and save again",
		].join("\n"),
	);
	assert.deepEqual(
		problems.map(({ severity, file, line, column, width, message }) => [severity, file, line, column, width, message]),
		[
			["error", "routes/+page.rocx", 3, 5, 1, "<br> has no children or closing tag: write <br />"],
			["warning", "Ui/Card.rocx", 12, 1, 1, "the browser's copy imports Db, which only the server has"],
			["error", "routes/api/+server.roc", 1, 1, 1, "a +server answers methods: define one of get, post"],
		],
	);
});

test("a build's start drops the problems before it, and its end says so", () => {
	const reports = new Reports();
	for (const line of checked.split("\n")) reports.push(line);
	assert.deepEqual(reports.push("rocx dev: the server's build failed; fix it and save again"), { started: false, ended: true, changed: false });
	assert.equal(reports.list().length, 2);
	assert.deepEqual(reports.push("rocx dev: routes/+page.rocx changed"), { started: true, ended: false, changed: true });
	assert.equal(reports.list().length, 0);
	assert.deepEqual(reports.push("rocx dev: built hello in 2.4 s"), { started: false, ended: true, changed: false });
	assert.deepEqual(reports.push("rocx site dev: routes/tooling/+page.rocx changed").started, true);
	assert.equal(reports.push("rocx dev: the server's host didn't build").ended, true);
	// The docs site's (`just dev`, rocx site dev).
	assert.equal(reports.push("rocx site: routes/tooling/+page.rocx changed").started, true);
	assert.equal(reports.push("rocx site: built in 4.1 s (dev backend; numbers from the last `just site`)").ended, true);
	assert.equal(reports.push("rocx site: the build failed; fix it and save again").ended, true);
	// Not an end: the server stopping, a file written.
	assert.equal(reports.push("rocx dev: the server stopped (1); save a file to build and start it again").ended, false);
	assert.equal(reports.push("rocx: 3 files written").ended, false);
});

test("one report said by the server's build and again by the browser's is one problem", () => {
	const { problems } = read(checked + checked);
	assert.equal(problems.length, 2);
});

test("colours and carriage returns are ignored; a report rocx couldn't place is left out", () => {
	const { problems } = read(
		[
			"\x1b[31m── ✗ absolute platform path ────────────────────────────────────────────────────\x1b[0m\r",
			"",
			"Absolute paths are not allowed for platform specifications.",
			"",
			"\x1b[1m── ✗ type mismatch ──── routes/+page.rocx:11:4\x1b[0m\r",
			"",
			"The first argument being passed to this function has the wrong type.",
		].join("\n"),
	);
	assert.equal(problems.length, 1);
	assert.equal(problems[0].file, "routes/+page.rocx");
	assert.equal(problems[0].message, "type mismatch\n\nThe first argument being passed to this function has the wrong type.");
});

test("a path with spaces in a report's first line", () => {
	const { problems } = read("── ✗ type mismatch ──── my app/routes/+page.rocx:2:1\n\nWhy.\n");
	assert.equal(problems[0].file, "my app/routes/+page.rocx");
});

test("rocx dev's builds: the count before each build's reports ends the report before it; blank lines dropped", () => {
	// A build that succeeds says its warnings with the blank lines left out, the server's build's and
	// then the browser's.
	const warning = [
		"── ● unused variable ────────────── examples/hello/routes/+page.rocx:7:2",
		"Variable unused is defined here and then never used.",
		"unused = 5",
		"^^^^^^",
		"If you don't need this variable, prefix it with an underscore like _unused to",
		"suppress this warning.",
	];
	const { problems } = read(
		[
			"0 errors and 1 warning found in 612ms while successfully building:",
			"    examples/hello/build/server.building",
			...warning,
			"0 errors and 1 warning found in 431ms while successfully building:",
			"    examples/hello/build/client/static/rocx/app.wasm.building",
			...warning,
			"rocx dev: built examples/hello in 3.2 s",
		].join("\n"),
	);
	assert.equal(problems.length, 1);
	assert.equal(
		problems[0].message,
		"unused variable\n\nVariable unused is defined here and then never used.\nIf you don't need this variable, prefix it with an underscore like _unused to\nsuppress this warning.",
	);
	assert.equal(problems[0].file, "examples/hello/routes/+page.rocx");
});
