#!/usr/bin/env node
// Takes the example apps' screenshots for their docs pages, into site/static/shots/<app>/<scene>.webp
// (committed): each app built and started as its tests start it (its own test helpers where it has
// them, on a database of its own), given something to show (people, a room, a few days of meals),
// then each scene opened in Chromium, in the dark (the docs are), on a wide screen (1280 by 800) or
// a phone (390 by 844, at twice the pixels), and taken as WebP. site/AppNotes.roc names the scenes
// and says what each shows; a page shows those there are.
//
//   node site/example-shots.mjs              every app's
//   node site/example-shots.mjs tasks plate  those alone
//
// It needs Chromium; every app with a database is on SQLite (D-045), a file of its own each run.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { buildForTests, launchBrowser, startServer, testDatabase, testSqlite, until } from "../packages/testing/index.mjs";
import { database, exampleNames, root } from "./example-apps.mjs";

const out = join(root, "site", "static", "shots");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** An example's own test helpers (examples/<app>/test/<file>). */
const helpers = (app, file) => import(pathToFileURL(join(root, "examples", app, "test", file)).href);

/** An app with no helpers of its own: built, and started on the database its program names (a
 * SQLite file of its own, or a Postgres database of its own), or none. `{ app, stop() }`. */
async function plain(name, env = {}) {
	const dir = join(root, "examples", name);
	const built = await buildForTests(dir);
	const kind = database(dir, readFileSync(join(dir, "main.roc"), "utf8"));
	if (kind === "SQLite") {
		const db = testSqlite();
		const app = await startServer(built.server, { statics: built.statics, database: db.url, env });
		return { app, stop: async () => (await app.stop(), await db.drop()) };
	}
	if (kind === "Postgres") {
		const db = await testDatabase();
		const app = await startServer(built.server, { statics: built.statics, database: db.url, env });
		return { app, stop: async () => (await app.stop(), await db.drop()) };
	}
	const app = await startServer(built.server, { statics: built.statics, env });
	return { app, stop: () => app.stop() };
}

/** A scene: `path` opened (as `client`, its cookies, if given), `act(tab)` done, and the page taken. */
async function shoot(browser, base, app, file, path, { phone = false, client = null, act = null, settle = 500 } = {}) {
	const tab = await browser.open(`${base}${path}`, { cookies: client?.cookies ?? [], strict: false });
	try {
		await tab.page.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
		await tab.page.send("Emulation.setDeviceMetricsOverride", phone ? { width: 390, height: 844, deviceScaleFactor: 2, mobile: true } : { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
		if (act) await act(tab);
		// Transitions and glides finish, and the fonts settle.
		await sleep(settle);
		await until(async () => (await tab.page.eval("document.getAnimations().filter((a) => a.playState === 'running').length")) === 0, { what: "the page to stop moving", ms: 5000 }).catch(() => {});
		const { data } = await tab.page.send("Page.captureScreenshot", { format: "webp", quality: 82 });
		mkdirSync(join(out, app), { recursive: true });
		writeFileSync(join(out, app, `${file}.webp`), Buffer.from(data, "base64"));
		if (tab.errors.length > 0) throw new Error(`${app}/${file}: the page threw ${JSON.stringify(tab.errors)}`);
		console.log(`${app}/${file} (${phone ? "phone" : "wide"})`);
	} finally {
		tab.close();
	}
}

/** Each app's scenes, as site/AppNotes.roc names them. */
const scenes = {
	async tasks(browser) {
		const run = await plain("tasks");
		try {
			const me = run.app.client();
			await me.get("/me");
			await me.post("/me", { person: "avery" });
			await shoot(browser, run.app.url, "tasks", "list", "/lists/1", { client: me });
			await shoot(browser, run.app.url, "tasks", "lists", "/", { client: me, phone: true });
			await shoot(browser, run.app.url, "tasks", "task", "/tasks/1", { client: me, phone: true });
		} finally {
			await run.stop();
		}
	},

	async journal(browser) {
		const { build, start } = await helpers("journal", "journal.mjs");
		const app = await start(await build());
		try {
			await shoot(browser, app.url, "journal", "home", "/en");
			await shoot(browser, app.url, "journal", "post", "/en/posts/night-trains", { phone: true });
			await shoot(browser, app.url, "journal", "polish", "/pl", { phone: true });
		} finally {
			await app.stop();
		}
	},

	async board(browser) {
		const { started, as } = await helpers("board", "app.mjs");
		const run = await started();
		try {
			const ada = await as(run.app, run.db, "Ada");
			await shoot(browser, run.app.url, "board", "board", "/b/launch", { client: ada });
			await shoot(browser, run.app.url, "board", "card", "/b/launch", {
				client: ada,
				act: async (tab) => {
					await (await tab.findByRole("link", { name: "Book the launch pad" })).click();
					await tab.findByRole("heading", { level: 2, name: "Book the launch pad" });
				},
			});
		} finally {
			await run.stop();
		}
	},

	async quiz(browser) {
		const { started, openRoom, follow } = await helpers("quiz", "app.mjs");
		const run = await started();
		// The players stay in the room, each following it as a phone's tab does, while the big screen is taken.
		const streams = [];
		try {
			const host = run.app.client();
			const code = await openRoom(host, "Around the Globe");
			for (const name of ["Ada", "Bo", "Cyd", "Dee"]) {
				const player = run.app.client();
				await player.get("/");
				await player.post("/join", { code, name });
				streams.push(await follow(player, code, `${name}-tab`));
			}
			await shoot(browser, run.app.url, "quiz", "lobby", `/host/${code}`, { client: host, settle: 1000 });
			await shoot(browser, run.app.url, "quiz", "join", "/", { phone: true });
		} finally {
			for (const stream of streams) stream.close();
			await run.stop();
		}
	},

	async uptime(browser) {
		const { build, fakeTarget, start } = await helpers("uptime", "uptime.mjs");
		const target = await fakeTarget();
		const run = await start(await build(), target);
		try {
			const sql = run.db.sql.bind(run.db);
			// Four services, each with a day of checks every half hour and ninety days rolled up; Search
			// down for the last hour and a half, with its incident open. Moments are milliseconds, days
			// their date as text (SQLite, D-045).
			const now = Date.now();
			const minutes = (n) => now - n * 60_000;
			const services = [
				["Website", "Public", 120, 0],
				["API", "Public", 85, 0],
				["Payments", "Backend", 210, 0],
				["Search", "Backend", 160, 3],
			];
			let search = 0;
			for (const [name, group, latency, failing] of services) {
				const [row] = await sql`insert into monitors (name, url, interval_s, group_name, threshold, next_check_at) values (${name}, ${`${target.url}/${name.toLowerCase()}`}, 1800, ${group}, 3, ${now + 86_400_000}) returning id`;
				const id = Number(row.id);
				if (name === "Search") search = id;
				for (let i = 47; i >= 0; i--) {
					const up = i >= failing;
					await sql`insert into checks (monitor_id, at, up, status, latency_ms, error) values (${id}, ${minutes(i * 30)}, ${up}, ${up ? 200 : 503}, ${Math.round(latency * (0.8 + 0.4 * Math.abs(Math.sin(i + id))))}, ${up ? "" : "expected 200, got 503"})`;
				}
				for (let day = 1; day <= 90; day++) {
					const down = (day * 7 + id * 3) % 41 === 0 ? 3 : 0;
					await sql`insert into daily (monitor_id, day, checks, up, latency_ms_sum) values (${id}, date('now', ${`-${day} days`}), 48, ${48 - down}, ${48 * latency}) on conflict do nothing`;
				}
				if (failing > 0) {
					await sql`update monitors set streak = ${failing} where id = ${id}`;
					const [incident] = await sql`insert into incidents (monitor_id, title, opened_at) values (${id}, ${`${name} is down`}, ${minutes(90)}) returning id`;
					await sql`insert into incident_updates (incident_id, at, state, body) values (${incident.id}, ${minutes(90)}, 'investigating', ${"Searches time out: we're looking into it."})`;
				}
			}
			await shoot(browser, run.app.url, "uptime", "status", "/", { settle: 1200 });
			await shoot(browser, run.app.url, "uptime", "monitor", `/monitors/${search}`, { settle: 1200 });
		} finally {
			await run.stop();
			await target.close();
		}
	},

	async notes(browser) {
		const { started, signIn } = await helpers("notes", "app.mjs");
		const run = await started();
		try {
			const ada = await signIn(run.app, "ada@example.com");
			const notes = [
				["Garden plan", "Plant **tulips** in October, and the garlic before the first frost.\n\n- [ ] Order bulbs\n- [x] Clear the bed", "Home, garden"],
				["Reading list", "1. *The Peregrine*\n2. *Underland*\n3. Anything by Ursula K. Le Guin", "Books"],
				["Trip to the coast", "Trains leave at **8:12** and **9:40**. Book the cottage by Friday.", "Travel"],
				["Bread", "75% water, 2% salt, an overnight rise in the fridge.", "Kitchen, recipes"],
			];
			for (const [title, body, tags] of notes) await ada.post("/new", { title, body, tags });
			await shoot(browser, run.app.url, "notes", "notes", "/", { client: ada });
			const page = await ada.get("/");
			const id = /href="\/notes\/(\d+)"/.exec(page.text)?.[1];
			await shoot(browser, run.app.url, "notes", "edit", `/notes/${id}/edit`, { client: ada, settle: 800 });
		} finally {
			await run.stop();
		}
	},

	async checkboxes(browser) {
		// Its own helpers start it with its stylesheet (static/), which gives the grid its height.
		const { box, build, say, start } = await helpers("checkboxes", "million.mjs");
		const app = await start(await build());
		const run = { app, stop: () => app.stop() };
		const client = run.app.client();
		// A heart, and a few boxes about it, drawn for the width the page lays its rows out by.
		const heart = ["..XX...XX..", ".XXXX.XXXX.", "XXXXXXXXXXX", "XXXXXXXXXXX", ".XXXXXXXXX.", "..XXXXXXX..", "...XXXXX...", "....XXX....", ".....X....."];
		// The columns once the page has laid its rows out for the window's width (8 to 64 boxes beside
		// each row's number, Grid.columns), as it does once it has measured the grid.
		const laidOut = async (tab) => {
			const check = "(() => { const grid = document.querySelector('.grid'); const want = Math.min(Math.max(Math.floor((grid.clientWidth - 76) / 28), 8), 64); const has = grid.querySelector('.row').querySelectorAll('input').length; return has === want ? has : 0; })()";
			return until(() => tab.page.eval(check), { what: "the grid laid out for the window", ms: 5000 });
		};
		const draw = async (tab, from) => {
			const columns = await laidOut(tab);
			const at = (row, column) => from + row * columns + column;
			const boxes = [];
			heart.forEach((line, row) => [...line].forEach((cell, column) => cell === "X" && boxes.push(at(row + 3, column + Math.floor((columns - 11) / 2)))));
			let seed = 7 + (from % 997);
			for (let row = 0; row < 26; row++) {
				for (let column = 0; column < columns; column++) {
					seed = (seed * 1103515245 + 12345) % 2147483648;
					if (seed / 2147483648 < 0.06 && (row < 2 || row > 12)) boxes.push(at(row, column));
				}
			}
			const checked = async () => Number((await tab.page.eval("document.querySelector('.checked').textContent")).replaceAll(",", ""));
			const before = await checked();
			for (let i = 0; i < boxes.length; i += 200) await say(client, "shots", ...boxes.slice(i, i + 200).map((index) => box(index)));
			await until(async () => (await checked()) >= before + boxes.length, { what: "the boxes to show", ms: 5000 });
			return columns;
		};
		try {
			await shoot(browser, run.app.url, "checkboxes", "grid", "/", { act: (tab) => draw(tab, 0), settle: 600 });
			await shoot(browser, run.app.url, "checkboxes", "far", "/", {
				settle: 600,
				act: async (tab) => {
					const columns = await laidOut(tab);
					const row = Math.floor(500_000 / columns);
					await tab.page.eval(`document.querySelector('.grid').scrollTop = ${row * 28}`);
					await until(async () => (await tab.page.eval(`Boolean(document.querySelector('[aria-label="Box ${(row * columns + 1).toLocaleString("en-US")}"]'))`)), { what: "the rows half a million down", ms: 5000 });
					await draw(tab, row * columns);
				},
			});
		} finally {
			await run.stop();
		}
	},

	async plate(browser) {
		const run = await plain("plate");
		try {
			const me = run.app.client();
			const today = (await me.read("/")).today;
			const day = (offset) => {
				const date = new Date(`${today}T12:00:00Z`);
				date.setUTCDate(date.getUTCDate() + offset);
				return date.toISOString().slice(0, 10);
			};
			const food = async (words) => (await me.read(`/add?q=${encodeURIComponent(words)}`)).hits[0].id;
			const foods = {
				oats: await food("cereals oats regular quick not fortified dry"),
				milk: await food("milk reduced fat fluid 2% milkfat vitamin"),
				banana: await food("bananas raw"),
				chicken: await food("chicken broilers fryers breast meat only cooked roasted"),
				rice: await food("rice white long grain regular enriched cooked"),
				broccoli: await food("broccoli raw"),
				salmon: await food("fish salmon atlantic farmed cooked dry heat"),
				yogurt: await food("yogurt greek plain nonfat"),
				almonds: await food("nuts almonds"),
			};
			const log = (name, amount, unit, meal, on) => me.submit(`/foods/${foods[name]}`, { amount: String(amount), unit, meal, day: on });
			for (let back = 6; back >= 0; back--) {
				const on = day(-back);
				await log("oats", 50 + back * 5, "g", "breakfast", on);
				await log("milk", 1, "0", "breakfast", on);
				await log("banana", 1, "0", "breakfast", on);
				await log(back % 2 ? "chicken" : "salmon", 140 + back * 10, "g", "lunch", on);
				await log("rice", 1, "0", "lunch", on);
				if (back > 0) await log("broccoli", 1, "0", "dinner", on);
				if (back % 3 === 0) await log("almonds", 30, "g", "snacks", on);
				await log("yogurt", 150, "g", "snacks", on);
			}
			for (const [back, kg] of [[6, 72.4], [4, 72.1], [2, 71.9], [0, 71.6]]) await me.submit("/weights", { day: day(-back), kg: String(kg) });
			await shoot(browser, run.app.url, "plate", "diary", "/", { phone: true });
			await shoot(browser, run.app.url, "plate", "food", `/foods/${foods.banana}?meal=snacks`, { phone: true });
			await shoot(browser, run.app.url, "plate", "trends", "/trends", { settle: 1500 });
		} finally {
			await run.stop();
		}
	},
};

async function main(wanted) {
	const names = exampleNames().filter((name) => scenes[name] && (wanted.length === 0 || wanted.includes(name)));
	for (const name of wanted) if (!scenes[name]) throw new Error(`no scenes for ${name} (there are ${Object.keys(scenes).join(", ")})`);
	const browser = await launchBrowser();
	if (!browser) throw new Error("no Chromium: set CHROME, or install one");
	try {
		for (const name of names) {
			rmSync(join(out, name), { recursive: true, force: true });
			await scenes[name](browser);
		}
	} finally {
		await browser.close();
	}
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
	main(process.argv.slice(2)).catch((error) => {
		console.error(error.stack ?? error);
		process.exit(1);
	});
}
