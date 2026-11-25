// templates/app/, the app `rocx new` makes, tested as rocx new would make it: generated into
// templates/build/<database>/app (generate.mjs: its packages and platform at the path back to this
// repository, its name `acme`, its title `Acme`), then for each database it can be on (SQLite
// always; Turso, on a file; Postgres when DATABASE_URL is set): `rocx check` (both programs
// type-checked), `rocx lint`, `rocx check --sql` (its SQL against the engine), its Roc expects (what
// `rocx test` runs), then built (the browser's half too, on SQLite) and started, and asked as people
// use it (app.mjs), in Chromium too on SQLite.
//
//   ROC=.tools/roc-active node --test 'templates/test/*.test.mjs'
//   ROCX_TEST_OPT=speed builds the server optimized (`--opt=speed`).
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildForTests, serverBuild, startServer, storyPath, testDatabase, testSqlite } from "../../packages/testing/index.mjs";
import { describeApp } from "./app.mjs";
import { generate, repo, template } from "./generate.mjs";

/** The databases the template is tested on: Postgres only where there is one to make databases in. */
const flavors = [
	{ database: "sqlite", name: "SQLite" },
	{ database: "turso", name: "Turso" },
	...(process.env.DATABASE_URL ? [{ database: "postgres", name: "Postgres" }] : []),
];

/** A database of the test's own for `database`: its `url` for the server, and `drop()`. */
async function own(database) {
	if (database === "postgres") return testDatabase();
	const db = testSqlite({ prefix: `rocx-template-${database}-` });
	if (database === "turso") db.url = `turso:${db.path}`;
	return db;
}

/** rocx with `args`, from the repository's root: what it said, after checking it exited 0. */
async function rocx(...args) {
	const { roc, rocxBinary } = await serverBuild();
	const done = spawnSync(rocxBinary(), args, { cwd: repo, encoding: "utf8", maxBuffer: 1 << 28, env: { ...process.env, ROC: roc() } });
	assert.equal(done.status, 0, `rocx ${args.join(" ")}:\n${done.stdout}${done.stderr}`);
	return `${done.stdout}${done.stderr}`;
}

test("the template's main.roc says SQLite, on the line rocx new changes, and fills in each placeholder", () => {
	const main = readFileSync(join(template, "main.roc"), "utf8");
	assert.match(main, /\n\tdatabase: Sqlite\("data\/app\.db"\),\n/);
	assert.match(main, /cookie: "\{\{name\}\}_session"/);
	assert.match(main, /pf: platform "\{\{root\}\}\/server\/platform\/main\.roc"/);
});

for (const { database, name } of flavors) {
	describe(`on ${name}`, () => {
		const dir = join(repo, "templates", "build", database, "app");
		const browser = database === "sqlite";
		let built;
		let db;
		let server;

		before(async () => {
			generate(dir, { database });
			built = await buildForTests(dir, { client: browser, opt: process.env.ROCX_TEST_OPT ?? "dev" });
			db = await own(database);
			// Two-factor sign-in seals its secrets under a key from APP_SECRET, without which the app
			// starts only under --dev.
			server = await startServer(built.server, { database: db.url, statics: built.statics, env: { APP_SECRET: "the template test's secret, 32 characters or more" } });
		});

		after(async () => {
			await server?.stop();
			await db?.drop();
		});

		test("the program says its database", () => {
			const main = readFileSync(join(dir, "main.roc"), "utf8");
			assert.match(main, { sqlite: /database: Sqlite\("data\/app\.db"\),/, turso: /database: Turso\("data\/app\.db"\),/, postgres: /database: Postgres,/ }[database]);
		});

		test("rocx check (both programs), rocx lint, rocx check --sql and the Roc expects pass", async () => {
			const relative = join("templates", "build", database, "app");
			await rocx("check", relative);
			await rocx("lint", relative);
			assert.match(await rocx("check", "--sql", relative), /no problems/);
			const { roc } = await serverBuild();
			assert.match(await rocx("check", "--", roc(), "test", join(relative, "main.roc")), /tests passed/);
		});

		if (database === "sqlite") {
			test("a dev build's stories: the bar's, each alone in the page's frame, and the catalog lists them", async () => {
				const dev = await buildForTests(dir, { out: join(dir, "build", "dev"), client: false, dev: true });
				const db = await own(database);
				const catalog = await startServer(dev.server, { database: db.url, dev: true });
				try {
					const client = catalog.client();
					const story = await client.get(storyPath("components/Nav", "Signed in"));
					assert.equal(story.status, 200, story.text);
					assert.equal(story.dom.getAllByRole("link", { name: "Acme" }).length, 1, "the bar the story shows, not the layout's too");
					story.dom.getByRole("button", { name: "Sign out" });
					const out = await client.get(storyPath("components/Nav", "Signed out"));
					out.dom.getByRole("link", { name: "Sign in" });
					const listed = await client.get("/__rocx/stories");
					assert.equal(listed.status, 200);
					assert.ok(listed.text.includes('"id":"components/Nav/signed-in"'), "the catalog lists the story");
				} finally {
					await catalog.stop();
					await db.drop();
				}
			});
		}

		describeApp(() => ({ server, built, fresh: () => own(database) }), { browser });
	});
}
