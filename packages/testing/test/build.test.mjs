// An app with a type error, and one with a warning alone. Roc says "… while successfully building"
// of both and writes an executable for both (the error's crashes where the error is), but exits 1 on
// an error and 2 on warnings alone. rocx build only writes the app's Roc, so it succeeds either way;
// rocx check fails, at the line in the .rocx file, with Roc's exit code, and so does buildForTests,
// on a warning too (D-044). Needs the toolchain (`just setup`, and the server's host built, as
// `just test` builds it).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { buildForTests, repo, serverBuild } from "../build.mjs";

const { nativeTarget, roc, rocxBinary } = await serverBuild();
const compiler = (() => {
	try {
		return roc();
	} catch {
		return null;
	}
})();
const skip =
	(!compiler && "no roc (run `just setup`, or set ROC)") ||
	(!existsSync(join(repo, "server", "platform", "targets", nativeTarget(), "libhost.a")) && "the server's host isn't built (`just test` builds it)");

const PAGE = `import pf.Html

## The page at /.
view! = |_| {
	visits = 3.U64
	<main>
		<h1>Hello</h1>
		<p>{visits.to_str()} visits</p>
	</main>
}
`;

/** The app, in a directory of its own: a page, and the smallest program, on the server platform. */
function app(page) {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "rocx-testing-build-")));
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

const rocx = (...args) => spawnSync(rocxBinary(), args, { encoding: "utf8", env: { ...process.env, ROC: compiler } });

test("a type error: rocx build writes the app's Roc, and rocx check and buildForTests fail at its .rocx line", { skip }, async () => {
	const dir = app(PAGE.replace("{visits.to_str()} visits", "{visits} visits"));
	try {
		const built = rocx("build", dir);
		assert.equal(built.status, 0, `${built.stdout}${built.stderr}`);
		const checked = rocx("check", "--", compiler, "check", join(dir, "main.roc"));
		assert.equal(checked.status, 1, checked.stdout);
		assert.match(checked.stdout, /routes\/\+page\.rocx:8:\d+/);
		assert.match(checked.stdout, /<p>\{visits\} visits<\/p>/, "the .rocx line, quoted");
		await assert.rejects(buildForTests(dir, { client: false }), (error) => {
			assert.match(error.message, /failed \(1\)/);
			assert.match(error.message, /type mismatch/);
			assert.match(error.message, /routes\/\+page\.rocx:8:\d+/, "said at the .rocx line");
			return true;
		});
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a warning alone: rocx check says it (exit 2), and buildForTests fails on it too, at its .rocx line", { skip }, async () => {
	const dir = app(PAGE.replace("\tvisits = 3.U64\n", "\tvisits = 3.U64\n\tunused = 1\n"));
	try {
		assert.equal(rocx("build", dir).status, 0);
		const checked = rocx("check", "--", compiler, "check", join(dir, "main.roc"));
		assert.equal(checked.status, 2, checked.stdout);
		assert.match(checked.stdout, /unused variable/);
		assert.match(checked.stdout, /routes\/\+page\.rocx:6:2/);
		await assert.rejects(buildForTests(dir, { client: false }), /failed \(2\):[\s\S]*unused variable[\s\S]*routes\/\+page\.rocx:6:2/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
