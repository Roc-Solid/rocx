// Four of the app's modules are packages' server modules, copied in as their READMEs say (rocx
// build doesn't copy a package's server-only modules yet, and finds the kinds of actor only in the
// app's own files). This keeps each copy the same as its package's, so the app runs on the packages
// as they are.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { dir } from "./app.mjs";

const copies = {
	"Guard.roc": "packages/guard/server/Guard.roc",
	"Kept.roc": "packages/guard/server/Kept.roc",
	"FlagStore.roc": "packages/guard/server/FlagStore.roc",
	"McpHttp.roc": "packages/mcp/server/McpHttp.roc",
};

for (const [copy, source] of Object.entries(copies)) {
	test(`${copy} is ${source}, as it is`, () => {
		assert.equal(readFileSync(join(dir, copy), "utf8"), readFileSync(join(dir, "..", "..", source), "utf8"), `copy it again: cp ${source} examples/notes/`);
	});
}
