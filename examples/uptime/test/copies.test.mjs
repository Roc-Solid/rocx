// Otel.roc is packages/otel's `server/Otel.roc`, copied into the app as that package's README says:
// `rocx build` lists the kinds of actor defined in the app's own files only, and the meter is one.
// This keeps the copy the package's, word for word, so a change there isn't missed here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { dir } from "./uptime.mjs";

test("Otel.roc is packages/otel/server/Otel.roc, unchanged", () => {
	const copy = readFileSync(join(dir, "Otel.roc"), "utf8");
	const original = readFileSync(join(dir, "..", "..", "packages", "otel", "server", "Otel.roc"), "utf8");
	assert.equal(copy, original, "copy packages/otel/server/Otel.roc into examples/uptime again");
});
