// A package reaches an app by its name in the app's header, never as a file copied in by hand (D-033:
// a package that needs the server names its platform, and lists in browser.roc what the browser's
// half may import). A copy drifts from its package: so no package keeps a module for apps to copy
// (the old `packages/<name>/server/` folders), and no tracked file outside packages/ is a word-for-word
// copy of a package's module. (rocx build's own copies, Generated/, aren't tracked.) `just check`
// runs this, as `just test` does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
// Those still on disk: a file moved or deleted but not yet staged is listed until it is.
const tracked = execFileSync("git", ["ls-files", "-z", "*.roc", "*.rocx"], { cwd: root, encoding: "utf8" })
	.split("\0")
	.filter((path) => path && existsSync(join(root, path)));
const digest = (path) => createHash("sha256").update(readFileSync(join(root, path))).digest("hex");
/** A module small enough to be the same by chance (a one-line header) isn't a copy. */
const big = (path) => readFileSync(join(root, path)).length >= 200;

test("no package keeps modules for apps to copy (a server/ folder): it names the server's platform, with a browser.roc", () => {
	const kept = readdirSync(join(root, "packages")).filter((name) => existsSync(join(root, "packages", name, "server")));
	assert.deepEqual(kept, [], "move packages/<name>/server/*.roc into the package, name `pf: platform \"../../server/platform/main.roc\"` in its main.roc, and list the rest in a browser.roc beside it (as packages/push does)");
});

test("no file outside packages/ is a copy of a package's module: import it by the package's name", () => {
	const ofPackages = new Map();
	// A package's own modules: not its example app's, nor its tests' (apps may share a route).
	const own = (path) => path.startsWith("packages/") && !/^packages\/[^/]+\/(example|test)\//.test(path);
	for (const path of tracked) if (own(path) && big(path)) ofPackages.set(digest(path), path);
	const copies = tracked
		.filter((path) => !path.startsWith("packages/") && big(path))
		.flatMap((path) => {
			const original = ofPackages.get(digest(path));
			return original ? [`${path} is ${original}`] : [];
		});
	assert.deepEqual(copies, [], "name the package in the app's header and import its module (`import <package>.<Module>`); if it can't be imported, that is a gap in the platform or rocx build to fix, not a copy to keep");
});
