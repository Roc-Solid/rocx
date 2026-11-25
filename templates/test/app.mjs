// The tests of an app made from templates/app/, as people use it, over HTTP: signed out, signing in
// by a mailed link (its page, its button), the account page, signing out here and everywhere, a
// sign-in that never sends the browser to another site, what a failed one says, the sign-in mail's
// limits, a post from another site, the 404 page, the dev sign-in and a provider's button under
// `--dev`, two-factor sign-in (set up on the account page, a sign-in waiting at the code page,
// turned off); and, given a browser, the pages hydrated under the security headers' CSP. template.test.mjs
// runs them on each database; any test may run them on an app `rocx new` made.
//
//   describeApp(() => ({ server, built, fresh }), { browser: true });
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { launchBrowser, links, startServer, within } from "../../packages/testing/index.mjs";

let addresses = 0;

/**
 * Someone at a browser, from an address of their own: what the proxy in front says, in
 * `X-Forwarded-For` (the app trusts one proxy: `Middlewares.proxies`), so the sign-in mail's limit
 * from each client counts each of them apart.
 */
export function person(server) {
	addresses += 1;
	return server.client({ headers: { "x-forwarded-for": `198.18.${(addresses >> 8) & 255}.${addresses & 255}` } });
}

/** The token of a link mailed to `email` (lower-case), going on to `then`, asked for by `client`. */
export async function mailedLink(server, client, email, then = "/") {
	const before = (await server.mail()).length;
	const asked = await client.json("/sign-in/mail", { email, then });
	assert.equal(asked.status, 200, asked.text);
	const message = await server.waitForMail({ to: email }, { after: before });
	const url = new URL(links(message)[0]);
	assert.equal(url.pathname, "/sign-in/link");
	return url.searchParams.get("token");
}

/** The bytes Base32 text (RFC 4648) stands for, its spaces left out. */
function base32(text) {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	let bits = "";
	for (const char of text.replace(/\s/g, "")) bits += alphabet.indexOf(char).toString(2).padStart(5, "0");
	return Buffer.from(bits.match(/.{8}/g).map((byte) => parseInt(byte, 2)));
}

/** The six-digit code an authenticator app shows for `secret` (its bytes) at the 30-second `step` (RFC 6238). */
function totp(secret, step) {
	const counter = Buffer.alloc(8);
	counter.writeBigUInt64BE(BigInt(step));
	const mac = createHmac("sha1", secret).update(counter).digest();
	return String((mac.readUInt32BE(mac[19] & 0x0f) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

/** A new browser, signed in as `email` by a mailed link. */
export async function signedIn(server, email) {
	const client = person(server);
	const opened = await client.post("/auth/link", { token: await mailedLink(server, client, email) });
	assert.equal(opened.status, 303, opened.text);
	assert.ok(client.cookies.has("acme_session"), "the session cookie set");
	return client;
}

/**
 * The app's tests, for the app `app()` gives once its `before` has run: `{ server, built, fresh }`,
 * its server started (`--debug`, for the mailbox), how it was built (`buildForTests`), and a way to
 * a database of its own for another server (`fresh()`: its `url`, and `drop()`; Turso locks its
 * file, so two servers can't share one). With `browser`, the pages in Chromium too (skipped when
 * there is none; the app must be built with its browser's half).
 */
export function describeApp(app, { browser = false } = {}) {
	test("signed out: the front page offers to sign in, and /account sends a page to sign in and refuses the rest", async () => {
		const { server } = app();
		const client = person(server);
		const home = await client.get("/");
		assert.equal(home.status, 200);
		home.dom.getByRole("heading", { level: 1, name: "Your app is running" });
		assert.equal(home.dom.getByRole("link", { name: "Sign in" }).attr("href"), "/sign-in");
		assert.equal(home.dom.getByRole("link", { name: "Acme" }).attr("href"), "/");
		assert.match(home.text, /<title>Home · Acme<\/title>/);
		// packages/guard's security headers.
		assert.match(home.headers.get("content-security-policy") ?? "", /script-src 'self' 'wasm-unsafe-eval'/);
		assert.equal(home.headers.get("x-content-type-options"), "nosniff");
		assert.equal(home.headers.get("x-frame-options"), "SAMEORIGIN");
		const page = await client.get("/account");
		assert.equal(page.status, 303);
		assert.equal(page.location, "/sign-in?then=%2Faccount");
		const api = await client.request("/account", { headers: { accept: "application/json" } });
		assert.equal(api.status, 401);
		assert.deepEqual(await client.read("/api/me"), { email: "" });
	});

	test("signing in by a mailed link: the link's page, its button, then the account with the address and one session", async () => {
		const { server } = app();
		const client = person(server);
		const form = await client.get("/sign-in?then=%2Faccount");
		assert.equal(form.status, 200);
		form.dom.getByRole("heading", { level: 1, name: "Sign in" });
		assert.equal(form.dom.getByLabelText("Email address").attr("type"), "email");
		assert.equal(form.dom.queryByRole("heading", { name: "Dev sign-in" }), null, "no dev sign-in without --dev");
		assert.equal(form.dom.queryAllByRole("link", { name: /^Continue with / }).length, 0, "no provider is set up");
		// The form, posted as a browser without JavaScript posts it: back to the page, which says where the link went.
		const before = (await server.mail()).length;
		const sent = await client.post("/sign-in/mail", { email: "  Ada@Example.com ", then: "/account" });
		assert.equal(sent.status, 303, sent.text);
		const told = await sent.follow();
		told.dom.getByRole("heading", { name: "Check your inbox" });
		assert.ok(told.dom.getByRole("status").text.includes("ada@example.com"));
		const message = await server.waitForMail({ to: "ada@example.com" }, { after: before });
		assert.equal(message.subject, "Sign in to Acme");
		assert.equal(message.from, "Acme <hello@example.com>");
		const url = new URL(links(message)[0]);
		assert.equal(url.pathname, "/sign-in/link");
		const token = url.searchParams.get("token");
		// Its page says whom it signs in, and signs nobody in by itself (a mail scanner may open it).
		const landing = await client.get(`/sign-in/link?token=${token}`);
		assert.equal(landing.status, 200);
		landing.dom.getByRole("heading", { name: "Sign in?" });
		assert.ok(landing.text.includes("ada@example.com"));
		assert.ok(!client.cookies.has("acme_session"));
		const opened = await client.post("/auth/link", { token });
		assert.equal(opened.status, 303);
		assert.equal(opened.location, "/account");
		assert.ok(client.cookies.has("acme_session"), "the session cookie, named after the app");
		const account = await client.get("/account");
		assert.equal(account.status, 200);
		account.dom.getByRole("heading", { level: 1, name: "Your account" });
		assert.ok(account.dom.getByText(/^You sign in as/).text.includes("ada@example.com"));
		const sessions = account.dom.getByRole("list");
		assert.equal(sessions.text.includes("This browser"), true);
		assert.equal(account.dom.getAllByRole("listitem").length, 1);
		assert.deepEqual(
			(await client.read("/account")).sessions.map((session) => [session.current, session.started]),
			[[true, "today"]],
		);
		// The bar says who is signed in.
		const home = await client.get("/");
		assert.equal(home.dom.getByRole("link", { name: "ada@example.com" }).attr("href"), "/account");
		home.dom.getByRole("button", { name: "Sign out" });
		assert.deepEqual(await client.read("/api/me"), { email: "ada@example.com" });
		// Used, the link is gone: its page says so.
		const again = await person(server).get(`/sign-in/link?token=${token}`);
		again.dom.getByRole("heading", { name: "This link has expired" });
		assert.equal((await person(server).request(`/sign-in/link?token=${token}`, { headers: { accept: "application/json" } })).status, 410);
	});

	test("signing out: the session ends, its cookie goes, and /account asks to sign in again", async () => {
		const { server } = app();
		const client = await signedIn(server, "lin@example.com");
		const kept = client.cookies.get("acme_session");
		const out = await client.post("/auth/sign-out", {});
		assert.equal(out.status, 303);
		assert.equal(out.location, "/");
		assert.ok(!client.cookies.has("acme_session"));
		assert.equal((await client.get("/account")).status, 303);
		const stale = person(server);
		stale.cookies.set("acme_session", kept);
		assert.deepEqual(await stale.read("/api/me"), { email: "" }, "the old cookie signs no one in");
	});

	test("signing out everywhere ends each of the user's sessions", async () => {
		const { server } = app();
		const first = await signedIn(server, "kim@example.com");
		const second = await signedIn(server, "kim@example.com");
		const listed = (await first.read("/account")).sessions;
		assert.equal(listed.length, 2);
		assert.equal(listed.filter((session) => session.current).length, 1);
		await first.get("/account");
		const out = await first.post("/account", {});
		assert.equal(out.status, 303, out.text);
		assert.equal(out.location, "/sign-in");
		assert.ok(!first.cookies.has("acme_session"));
		assert.deepEqual(await first.read("/api/me"), { email: "" });
		assert.deepEqual(await second.read("/api/me"), { email: "" });
	});

	test("a sign-in never sends the browser to another site after, nor does signing out", async () => {
		const { server } = app();
		const client = person(server);
		const opened = await client.post("/auth/link", { token: await mailedLink(server, client, "grace@example.com", "//elsewhere.example/x") });
		assert.equal(opened.status, 303);
		assert.equal(opened.location, "/");
		const out = await client.post("/auth/sign-out", { then: "https://elsewhere.example/" });
		assert.equal(out.location, "/");
	});

	test("a sign-in that failed comes back to the sign-in page, saying why", async () => {
		const { server } = app();
		const client = person(server);
		const forged = await client.post("/auth/link", { token: "not-a-token" });
		assert.equal(forged.location, "/sign-in?error=link");
		const page = await forged.follow();
		assert.match(page.dom.getByRole("alert").text, /link/i);
		const bad = await client.json("/sign-in/mail", { email: "not an address", then: "/" });
		assert.equal(bad.status, 400);
	});

	test("the sign-in mail is limited: 5 an hour to an address, and 5 a minute from a client", async () => {
		const { server } = app();
		for (let i = 0; i < 5; i += 1) {
			const asked = await person(server).json("/sign-in/mail", { email: "busy@example.com", then: "/" });
			assert.equal(asked.status, 200, `mail ${i + 1}: ${asked.text}`);
		}
		const sixth = await person(server).json("/sign-in/mail", { email: "BUSY@example.com", then: "/" });
		assert.equal(sixth.status, 429, "a sixth to the address, from another client, in any case");
		assert.ok(Number(sixth.headers.get("retry-after")) > 0);
		const client = person(server);
		for (let i = 0; i < 5; i += 1) {
			const asked = await client.json("/sign-in/mail", { email: `many${i}@example.com`, then: "/" });
			assert.equal(asked.status, 200, `mail ${i + 1}: ${asked.text}`);
		}
		assert.equal((await client.json("/sign-in/mail", { email: "many5@example.com", then: "/" })).status, 429, "a sixth from the client");
		// A browser without JavaScript goes back to the form, which says when to try again.
		await client.get("/sign-in");
		const refused = await client.post("/sign-in/mail", { email: "many6@example.com", then: "/" });
		assert.equal(refused.status, 303);
		const page = await refused.follow();
		assert.match(page.dom.getByRole("alert").text, /^Too many requests: try again in \d+ s\.$/);
	});

	test("two-factor sign-in: set up on the account page (a QR code, and its key), turned on with the app's code (the recovery codes shown once); a sign-in then waits at the code page; turned off with a code", async () => {
		const { server } = app();
		const client = await signedIn(server, "tf@example.com");
		(await client.get("/account")).dom.getByRole("button", { name: "Set up" });
		// The forms, posted as a browser without JavaScript posts them.
		const setUp = await client.post("/account/two-factor", {});
		assert.equal(setUp.status, 303, setUp.text);
		const pending = await setUp.follow();
		pending.dom.getByRole("img", { name: "A QR code for your authenticator app" });
		const key = pending.dom.getByText(/^([A-Z2-7]{4} ){7}[A-Z2-7]{4}$/).text;
		const secret = base32(key);
		const step = Math.floor(Date.now() / 30_000);
		const wrong = await (await client.post("/account/two-factor/confirm", { code: totp(secret, step + 5) })).follow();
		assert.match(wrong.dom.getByRole("alert").text, /isn't the code your app shows/);
		assert.equal(wrong.dom.getByText(/^([A-Z2-7]{4} ){7}[A-Z2-7]{4}$/).text, key, "the same key, after a wrong code");
		const on = await (await client.post("/account/two-factor/confirm", { code: totp(secret, step) })).follow();
		const codes = within(on.dom.getByRole("status"))
			.getAllByRole("listitem")
			.map((item) => item.text.trim());
		assert.equal(codes.length, 10);
		for (const code of codes) assert.match(code, /^[a-z2-7]{4}(-[a-z2-7]{4}){3}$/);
		on.dom.getByText(/^On: signing in asks for the code/);
		assert.equal((await client.get("/account")).dom.queryByRole("status"), null, "the recovery codes are shown once");
		// Signing in again waits for a code.
		const other = person(server);
		const opened = await other.post("/auth/link", { token: await mailedLink(server, other, "tf@example.com", "/account") });
		assert.equal(opened.location, "/sign-in/code?then=%2Faccount");
		const codePage = await opened.follow();
		codePage.dom.getByRole("heading", { level: 1, name: "Enter your code" });
		assert.ok(codePage.text.includes("tf@example.com"));
		assert.equal((await other.get("/account")).location, "/sign-in/code?then=%2Faccount", "not signed in while it waits");
		const missed = await other.post("/auth/code", { code: totp(secret, step + 5), then: "/account" });
		assert.equal(missed.location, "/sign-in/code?error=code&then=%2Faccount");
		assert.match((await missed.follow()).dom.getByRole("alert").text, /^That code didn't work/);
		const signed = await other.post("/auth/code", { code: totp(secret, step + 1), then: "/account" });
		assert.equal(signed.location, "/account");
		// Turned off with a recovery code: signing in asks no more.
		await other.get("/account");
		const off = await (await other.post("/account/two-factor/off", { code: codes[0] })).follow();
		off.dom.getByRole("button", { name: "Set up" });
		const later = person(server);
		const straight = await later.post("/auth/link", { token: await mailedLink(server, later, "tf@example.com", "/account") });
		assert.equal(straight.location, "/account");
	});

	test("a post from another site's page is refused", async () => {
		const { server } = app();
		const elsewhere = server.client({ origin: "https://elsewhere.example", headers: { "x-forwarded-for": "198.18.255.1" } });
		assert.equal((await elsewhere.json("/sign-in/mail", { email: "x@example.com", then: "/" })).status, 403);
		assert.equal((await elsewhere.post("/auth/sign-out", {})).status, 403);
	});

	test("a path no page has is the app's 404 page", async () => {
		const { server } = app();
		const missing = await person(server).get("/no/such/page");
		assert.equal(missing.status, 404);
		missing.dom.getByRole("heading", { name: "There's nothing here" });
		assert.equal(missing.dom.getByRole("link", { name: "Back home" }).attr("href"), "/");
	});

	test("under --dev: the dev sign-in, and a provider's button once its variables are set; without --dev, no dev sign-in", async () => {
		const { server, built, fresh } = app();
		assert.equal((await person(server).post("/auth/dev", { email: "dev@example.com" })).status, 404);
		const db = await fresh();
		const dev = await startServer(built.server, { database: db.url, dev: true, statics: built.statics, env: { GITHUB_CLIENT_ID: "test-client", GITHUB_CLIENT_SECRET: "test-secret" } }).catch(async (error) => {
			await db.drop();
			throw error;
		});
		try {
			const client = person(dev);
			const page = await client.get("/sign-in?then=%2Faccount");
			page.dom.getByRole("heading", { name: "Dev sign-in" });
			assert.equal(page.dom.getByRole("link", { name: "Continue with GitHub" }).attr("href"), "/auth/github?then=%2Faccount");
			const away = await client.get("/auth/github?then=%2Faccount");
			assert.equal(away.status, 303);
			assert.ok(away.location.startsWith("https://github.com/login/oauth/authorize?"), away.location);
			const signed = await client.post("/auth/dev", { email: "Dev@Example.com", then: "/account" });
			assert.equal(signed.status, 303);
			assert.equal(signed.location, "/account");
			const account = await client.get("/account");
			assert.equal(account.status, 200);
			assert.ok(account.dom.getByText(/^You sign in as/).text.includes("dev@example.com"));
		} finally {
			await dev.stop();
			await db.drop();
		}
	});

	if (browser) {
		let chromium = null;
		after(() => chromium?.close());

		test("in a browser: the sign-in page hydrates under the CSP and sends the link without leaving; the account page hydrates, and turns two-factor sign-in on", async (t) => {
			const { server } = app();
			chromium = await launchBrowser();
			if (!chromium) return t.skip("no Chromium");
			const tab = await chromium.open(`${server.url}/sign-in`);
			await (await tab.getByLabelText("Email address")).fill("tab@example.com");
			await (await tab.getByRole("button", { name: "Email me a link" })).click();
			await tab.findByRole("heading", { name: "Check your inbox" });
			await server.waitForMail({ to: "tab@example.com" });
			assert.deepEqual(tab.errors, []);
			assert.deepEqual(
				tab.console.filter((line) => line.type === "error"),
				[],
			);
			await tab.close();
			const client = await signedIn(server, "tab@example.com");
			const account = await chromium.open(`${server.url}/account`, { cookies: client.cookies });
			await account.findByText("This browser");
			await account.findByRole("link", { name: "tab@example.com" });
			// Two-factor sign-in set up and turned on without leaving the page: its QR code drawn in the browser.
			await (await account.getByRole("button", { name: "Set up" })).click();
			await account.findByRole("img", { name: "A QR code for your authenticator app" });
			const key = (await account.findByText(/^([A-Z2-7]{4} ){7}[A-Z2-7]{4}$/)).text;
			await (await account.getByLabelText("The code your app shows")).fill(totp(base32(key), Math.floor(Date.now() / 30_000)));
			await (await account.getByRole("button", { name: "Turn on" })).click();
			await account.findByText(/^On: signing in asks for the code/);
			assert.equal((await account.findAllByText(/^[a-z2-7]{4}(-[a-z2-7]{4}){3}$/)).length, 10, "the recovery codes");
			assert.deepEqual(account.errors, []);
			await account.close();
		});
	}
}
