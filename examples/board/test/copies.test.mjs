// One of the app's modules is a package's server module, copied in as its README says (rocx build
// finds the kinds of actor only in the app's own files, and presence keeps its room in one). This
// keeps the copy the same as its package's, so the board runs on the package as it is. (packages/guard
// is named in the header, and copied no more: D-043.)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { dir } from "./app.mjs";

const copies = {
	"PresenceServer.roc": "packages/presence/server/PresenceServer.roc",
};

for (const [copy, source] of Object.entries(copies)) {
	test(`${copy} is ${source}, as it is`, () => {
		assert.equal(readFileSync(join(dir, copy), "utf8"), readFileSync(join(dir, "..", "..", source), "utf8"), `copy it again: cp ${source} examples/board/`);
	});
}
