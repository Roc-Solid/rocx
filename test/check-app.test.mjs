// `rocx check [dir]`: an app checked from its sources (rocx build, then the compiler on its server's
// program and its browser's), every problem said at its .rocx line, never what an older build left.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { roc, rocxBinary } from "../server/build.mjs";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const compiler = (() => {
	try {
		return roc();
	} catch {
		return null;
	}
})();
const skip = !compiler && "no roc (run `just setup`, or set ROC)";

const PAGE = `import pf.Html
import pf.Solid exposing [create_signal!]

view! = |_| {
	(count!, set_count!) = create_signal!(0.U64)
	<main>
		<button on:click={|| set_count!(count!() + 1)}>Clicked {count!()} times</button>
	</main>
}
`;

/** An app in a directory of its own: the page given, and the smallest program. */
function app(page) {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "rocx-check-app-")));
	const platform = relative(dir, realpathSync(join(repo, "server", "platform", "main.roc")));
	const files = {
		"main.roc": `app [program] { pf: platform "${platform}" }

import pf.Middleware
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
`,
		"routes/+page.rocx": page,
	};
	for (const [path, content] of Object.entries(files)) {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), content);
	}
	return dir;
}

const check = (dir) => {
	const ran = spawnSync(rocxBinary(), ["check", dir], { encoding: "utf8", env: { ...process.env, ROC: compiler, NO_COLOR: "1" } });
	return { code: ran.status, said: `${ran.stdout}${ran.stderr}` };
};

test("rocx check <dir>: a clean app passes (a number in a hole is text, D-070)", { skip }, () => {
	const dir = app(PAGE);
	try {
		const ran = check(dir);
		assert.equal(ran.code, 0, ran.said);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx check <dir>: from the sources, not an older build: a page broken after a clean build fails at its .rocx line", { skip }, () => {
	const dir = app(PAGE);
	try {
		assert.equal(check(dir).code, 0, "built and checked clean");
		// Broken since: a Bool, which a hole can't show. Nothing builds it again but the check.
		writeFileSync(join(dir, "routes", "+page.rocx"), PAGE.replace("Clicked {count!()} times", "Clicked {count!() > 2} times"));
		const ran = check(dir);
		assert.equal(ran.code, 1, ran.said);
		assert.match(ran.said, /routes\/\+page\.rocx:7:\d+/, "at the .rocx line");
		assert.match(ran.said, /Clicked \{count!\(\) > 2\} times/, "the .rocx line, quoted");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx check <dir>: markup rocx refuses (a <Show>, D-070) fails with rocx's own problem, at its line", { skip }, () => {
	const dir = app(PAGE.replace("<button", "<Show when!={count!() > 3}><p>Many</p></Show>\n\t\t<button"));
	try {
		const ran = check(dir);
		assert.equal(ran.code, 1, ran.said);
		assert.match(ran.said, /routes\/\+page\.rocx:7:\d+: <Show> is gone \(D-070\)/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx check <dir>: warnings alone exit 2; a directory with no routes/ is no app", { skip }, () => {
	const dir = app(PAGE.replace("\t(count!, set_count!)", "\tunused = 1\n\t(count!, set_count!)"));
	try {
		const ran = check(dir);
		assert.equal(ran.code, 2, ran.said);
		assert.match(ran.said, /unused variable[\s\S]*routes\/\+page\.rocx:5:2|routes\/\+page\.rocx:5:2[\s\S]*unused/);
		const none = check(join(dir, "routes"));
		assert.equal(none.code, 2);
		assert.match(none.said, /has no routes\//);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
