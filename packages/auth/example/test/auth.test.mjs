// packages/auth (D-072), through its example app: signing in by a mailed link (used once, gone when
// used, refused by `admit!`, never sending the browser to another site), at an OpenID Connect
// provider and at a GitHub-like one (both stood in for by a server of the test's own, which checks
// PKCE's verifier, the client's secret and the redirect URI, and makes the ID token), what a state
// that doesn't match does, `Auth.required` and `Auth.optional`, signing out, a user's sessions
// listed and ended, the dev sign-in under `--dev` only, and the cookies' `__Host-` names on HTTPS.
// The example is built for SQLite (always) and for Postgres (when DATABASE_URL is set), each in
// build/<database>/app, its providers pointed at the stand-in.
//
//   node --test 'packages/auth/example/test/*.test.mjs'
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, links, startServer, testDatabase, testSqlite } from "../../../testing/index.mjs";

const example = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The route the tests add: an app's own way in (`Auth.sign_in!`), for the user the body names. */
const asRoute = `import pf.Server
import pf.Endpoint
import auth.Auth

## POST /test/as: signed in as \`user\`, as an app that checked a password of its own would sign
## someone in. Written by packages/auth's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { user : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Auth.sign_in!(Server.redirect("/private"), body.user) {
		Ok(answer) => Err(Answer(answer))
		Err(DbErr(why)) => Err(Status(503, why))
	}
`;

const base64url = (text) => Buffer.from(text).toString("base64url");

/**
 * The stand-in for the providers: an OpenID Connect one (`/token`) and a GitHub-like one
 * (`/hub/token`, `/api/user`, `/api/user/emails`). A test hands it a code first (`grant`), with the
 * PKCE challenge, the nonce and the redirect URI the app sent the browser off with, and who signs
 * in; the token endpoints refuse anything else.
 */
async function provider() {
	const codes = new Map();
	const server = createServer(async (request, response) => {
		let body = "";
		for await (const chunk of request) body += chunk;
		const url = new URL(request.url, "http://x");
		const reply = (status, value) => {
			response.writeHead(status, { "content-type": "application/json" });
			response.end(JSON.stringify(value));
		};
		if (request.method === "POST" && (url.pathname === "/token" || url.pathname === "/hub/token")) {
			const form = new URLSearchParams(body);
			const granted = codes.get(form.get("code"));
			const verifier = form.get("code_verifier") ?? "";
			const challenge = createHash("sha256").update(verifier).digest("base64url");
			if (!granted) return reply(400, { error: "invalid_grant" });
			if (form.get("client_id") !== "test-client" || form.get("client_secret") !== "test-secret") return reply(401, { error: "invalid_client" });
			if (challenge !== granted.challenge) return reply(400, { error: "invalid_grant", error_description: "PKCE" });
			if (form.get("redirect_uri") !== granted.redirect) return reply(400, { error: "invalid_grant", error_description: "redirect_uri" });
			if (form.get("grant_type") !== "authorization_code") return reply(400, { error: "unsupported_grant_type" });
			codes.delete(form.get("code"));
			if (url.pathname === "/hub/token") return reply(200, { access_token: `hub-${granted.who.id}`, token_type: "bearer" });
			const claims = { iss: origin, aud: "test-client", exp: Math.floor(Date.now() / 1000) + 300, sub: granted.who.sub, nonce: granted.nonce, email: granted.who.email, email_verified: granted.who.verified ?? true, name: granted.who.name ?? "" };
			return reply(200, { access_token: "a", token_type: "Bearer", id_token: `${base64url('{"alg":"RS256"}')}.${base64url(JSON.stringify({ ...claims, ...granted.who.claims }))}.signature` });
		}
		const bearer = (request.headers.authorization ?? "").replace(/^Bearer hub-/, "");
		if (url.pathname === "/api/user") return reply(200, { id: Number(bearer), login: `octo${bearer}`, name: null });
		if (url.pathname === "/api/user/emails") return reply(200, [{ email: `octo${bearer}@example.com`, primary: true, verified: true }]);
		reply(404, { error: "not_found" });
	});
	await new Promise((done) => server.listen(0, "127.0.0.1", done));
	const origin = `http://127.0.0.1:${server.address().port}`;
	return {
		origin,
		/** A code for the sign-in the app sent the browser off with (`away`, its URL), as `who`. */
		grant(away, who) {
			const asked = new URL(away).searchParams;
			const code = `code-${codes.size}-${Math.random().toString(36).slice(2)}`;
			codes.set(code, { challenge: asked.get("code_challenge"), nonce: asked.get("nonce"), redirect: asked.get("redirect_uri"), who });
			return { code, state: asked.get("state") };
		},
		close: () => new Promise((done) => server.close(done)),
	};
}

/** The example for `database`, in build/<database>/app, its providers pointed at `fake`: its folder. */
function app(database, fake) {
	const dir = join(example, "build", database, "app");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	for (const each of ["routes", "migrations", "Accounts.roc", "Middlewares.roc", "Problem.roc"]) cpSync(join(example, each), join(dir, each), { recursive: true });
	const providers = [
		"Auth.google",
		"Auth.github",
		`Auth.oidc({ name: "test", label: "Test", issuer: "${fake}", authorize_url: "${fake}/authorize", token_url: "${fake}/token", client_id_env: "TEST_CLIENT_ID", client_secret_env: "TEST_CLIENT_SECRET" })`,
		`{ ..Auth.github, name: "hub", label: "Hub", flow: GitHub("${fake}/api"), authorize_url: "${fake}/hub/authorize", token_url: "${fake}/hub/token", client_id_env: "HUB_CLIENT_ID", client_secret_env: "HUB_CLIENT_SECRET" }`,
	];
	const main = readFileSync(join(example, "main.roc"), "utf8")
		.replaceAll('"../', '"../../../../')
		.replace("providers: [Auth.google, Auth.github]", `providers: [${providers.join(", ")}]`)
		.replace('database: Sqlite("data/auth.db")', `database: ${database === "sqlite" ? 'Sqlite("data/auth.db")' : "Postgres"}`);
	assert.match(main, /name: "hub"/, "the stand-in's providers written");
	writeFileSync(join(dir, "main.roc"), main);
	mkdirSync(join(dir, "routes", "test", "as"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "as", "+server.roc"), asRoute);
	return dir;
}

const env = { TEST_CLIENT_ID: "test-client", TEST_CLIENT_SECRET: "test-secret", HUB_CLIENT_ID: "test-client", HUB_CLIENT_SECRET: "test-secret", GOOGLE_CLIENT_ID: "", GITHUB_CLIENT_ID: "" };

const databases = ["sqlite", ...(process.env.DATABASE_URL ? ["postgres"] : [])];

for (const database of databases) {
	describe(`on ${database === "sqlite" ? "SQLite" : "Postgres"}`, () => {
		let fake;
		let built;
		let db;
		let server;

		before(async () => {
			fake = await provider();
			built = await buildForTests(app(database, fake.origin), { client: false, opt: process.env.ROCX_TEST_OPT ?? "dev" });
			db = database === "sqlite" ? testSqlite() : await testDatabase();
			server = await startServer(built.server, { database: db.url, env });
		});

		after(async () => {
			await server?.stop();
			await db?.drop();
			await fake?.close();
		});

		/** The token of a mailed link asked for `email`, going on to `then`. The link opens the app's page (`link_page`). */
		async function mailedLink(client, email, then = "/") {
			const before = (await server.mail()).length;
			const asked = await client.json("/sign-in", { email, then });
			assert.equal(asked.status, 200, asked.text);
			const message = await server.waitForMail({ to: email.trim() }, { after: before });
			const url = new URL(links(message)[0]);
			assert.equal(url.pathname, "/sign-in/link");
			return url.searchParams.get("token");
		}

		/** The link's page opened, then its button pressed (the token posted to /auth/link): the answer. */
		async function used(client, token) {
			const page = await client.get(`/sign-in/link?token=${token}`);
			assert.equal(page.status, 200, page.text);
			return client.post("/auth/link", { token });
		}

		/** A new browser, signed in by a mailed link as `email`. */
		async function signedIn(email) {
			const client = server.client();
			const opened = await used(client, await mailedLink(client, email));
			assert.equal(opened.status, 303, opened.text);
			return client;
		}

		/** Signs `client` in at the provider `name` as `who`: the callback's answer. */
		async function atProvider(client, name, who, then = "/private") {
			const away = await client.get(`/auth/${name}?then=${encodeURIComponent(then)}`);
			assert.equal(away.status, 303, away.text);
			assert.ok(away.location.startsWith(`${fake.origin}/${name === "hub" ? "hub/" : ""}authorize?`), away.location);
			const { code, state } = fake.grant(away.location, who);
			return client.get(`/auth/${name}/callback?code=${code}&state=${state}`);
		}

		test("signed out: the optional middleware says so, the required one sends a page to sign in and refuses the rest", async () => {
			const client = server.client();
			assert.deepEqual(await client.read("/me"), { signed_in: false, user: "", email: "", identities: [] });
			const page = await client.get("/private");
			assert.equal(page.status, 303);
			assert.equal(page.location, "/sign-in?then=%2Fprivate");
			const api = await client.request("/private", { headers: { accept: "application/json" } });
			assert.equal(api.status, 401);
		});

		test("a mailed link signs in once, its address lower-cased, and goes where it was asked to", async () => {
			const client = server.client();
			const token = await mailedLink(client, "  Ada@Example.COM ", "/private?tab=2");
			// Looking (its page, a mail scanner) doesn't use it.
			assert.deepEqual(await server.client().read(`/sign-in/link?token=${token}`), { email: "ada@example.com" });
			assert.deepEqual(await server.client().read(`/sign-in/link?token=${token}`), { email: "ada@example.com" });
			const opened = await used(client, token);
			assert.equal(opened.status, 303);
			assert.equal(opened.location, "/private?tab=2");
			assert.ok(client.cookies.has("session"), "the session cookie set");
			const me = await client.read("/me");
			assert.equal(me.signed_in, true);
			assert.equal(me.email, "ada@example.com");
			assert.deepEqual(me.identities, ["email:ada@example.com"]);
			assert.deepEqual(await client.read("/private"), { user: me.user });
			// Used: the link is gone, by its page and by /auth/link, posted or opened.
			assert.equal((await server.client().request(`/sign-in/link?token=${token}`, { headers: { accept: "application/json" } })).status, 410);
			const again = await server.client().post("/auth/link", { token });
			assert.equal(again.status, 303);
			assert.equal(again.location, "/sign-in?error=link");
			assert.equal((await server.client().get(`/auth/link?token=${token}`)).location, "/sign-in?error=link");
			// The same address signs in as the same user.
			const later = await signedIn("ada@example.com");
			assert.equal((await later.read("/me")).user, me.user);
		});

		test("a link never sends the browser to another site after, and one that isn't a token is refused", async () => {
			const client = server.client();
			const opened = await used(client, await mailedLink(client, "grace@example.com", "//elsewhere.example/x"));
			assert.equal(opened.location, "/");
			// Opened straight at /auth/link (an app without a link page), a link signs in too.
			const straight = server.client();
			const went = await straight.get(`/auth/link?token=${await mailedLink(straight, "grace@example.com", "/private")}`);
			assert.equal(went.location, "/private");
			assert.equal((await straight.read("/me")).email, "grace@example.com");
			const forged = await server.client().get("/auth/link?token=not-a-token");
			assert.equal(forged.location, "/sign-in?error=link");
			const bad = await server.client().json("/sign-in", { email: "not an address", then: "/" });
			assert.equal(bad.status, 400);
		});

		test("admit! turns an address away: the sign-in page says why, and no session starts", async () => {
			const client = server.client();
			const opened = await used(client, await mailedLink(client, "mallory@refused.example", "/private"));
			assert.equal(opened.status, 303);
			assert.equal(opened.location, "/sign-in?error=refused&reason=This%20address%20isn%27t%20allowed%20in.&email=mallory%40refused.example&then=%2Fprivate");
			assert.ok(!client.cookies.has("session"));
			assert.equal((await client.read("/me")).signed_in, false);
		});

		test("an app's own way in (Auth.sign_in!): a session for the user it names, which the middleware reads", async () => {
			const client = server.client();
			const signed = await client.json("/test/as", { user: "user-from-a-password" });
			assert.equal(signed.status, 303, signed.text);
			assert.equal(signed.location, "/private");
			assert.deepEqual(await client.read("/private"), { user: "user-from-a-password" });
			assert.equal((await client.read("/sessions")).length, 1);
		});

		test("signing out ends the session: its cookie gone, and the old cookie signs no one in", async () => {
			const client = await signedIn("lin@example.com");
			const kept = client.cookies.get("session");
			const out = await client.post("/auth/sign-out", { then: "/private" });
			assert.equal(out.status, 303);
			assert.equal(out.location, "/private");
			assert.ok(!client.cookies.has("session"));
			const stale = server.client();
			stale.cookies.set("session", kept);
			assert.equal((await stale.read("/me")).signed_in, false);
		});

		test("a user's sessions: listed, one ended from another, then every one", async () => {
			const first = await signedIn("kim@example.com");
			const second = await signedIn("kim@example.com");
			const listed = await first.read("/sessions");
			assert.equal(listed.length, 2);
			assert.equal(listed.filter((session) => session.current).length, 1);
			const other = listed.find((session) => !session.current);
			assert.deepEqual((await first.json("/sessions", { revoke: other.id, everywhere: false })).json(), { ended: 1 });
			assert.equal((await second.read("/me")).signed_in, false);
			assert.equal((await first.read("/me")).signed_in, true);
			const third = await signedIn("kim@example.com");
			assert.deepEqual((await third.json("/sessions", { revoke: "", everywhere: true })).json(), { ended: 2 });
			assert.equal((await first.read("/me")).signed_in, false);
			assert.equal((await third.read("/me")).signed_in, false);
		});

		test("an OpenID Connect provider: off with PKCE and a nonce, back with a code, signed in as its subject", async () => {
			const client = server.client();
			const back = await atProvider(client, "test", { sub: "subject-1", email: "Oidc@Example.com", name: "Oda" });
			assert.equal(back.status, 303, back.text);
			assert.equal(back.location, "/private");
			assert.ok(!client.cookies.has("auth-state"), "the state cookie gone");
			const me = await client.read("/me");
			assert.equal(me.email, "oidc@example.com");
			assert.deepEqual(me.identities, ["test:oidc@example.com"]);
			// The same subject with another address is the same user.
			const again = server.client();
			await atProvider(again, "test", { sub: "subject-1", email: "renamed@example.com" });
			assert.equal((await again.read("/me")).user, me.user);
			// An address the provider doesn't say is verified isn't taken: admit! has none to go on.
			const unverified = await atProvider(server.client(), "test", { sub: "subject-2", email: "who@example.com", verified: false });
			assert.match(unverified.location, /^\/sign-in\?error=refused&reason=test%20didn[^&]*&then=%2Fprivate$/);
		});

		test("a GitHub-like provider: the code traded, then its API asked who signed in", async () => {
			const client = server.client();
			const back = await atProvider(client, "hub", { id: 4242 }, "/");
			assert.equal(back.location, "/");
			const me = await client.read("/me");
			assert.equal(me.email, "octo4242@example.com");
			assert.deepEqual(me.identities, ["hub:octo4242@example.com"]);
		});

		test("back from a provider with a state that isn't the browser's, an error, or a token for someone else's nonce: no session", async () => {
			const client = server.client();
			const away = await client.get("/auth/test?then=/private");
			const { code } = fake.grant(away.location, { sub: "s", email: "s@example.com" });
			const wrong = await client.get(`/auth/test/callback?code=${code}&state=wrong`);
			assert.equal(wrong.location, "/sign-in?error=state");
			assert.ok(!client.cookies.has("auth-state"), "the state cookie gone anyway");
			const none = await server.client().get(`/auth/test/callback?code=${code}&state=wrong`);
			assert.equal(none.location, "/sign-in?error=state");
			const denied = server.client();
			const off = await denied.get("/auth/test");
			const state = new URL(off.location).searchParams.get("state");
			const refused = await denied.get(`/auth/test/callback?error=access_denied&state=${state}`);
			assert.equal(refused.location, "/sign-in?error=provider&reason=access_denied");
			const stolen = server.client();
			const out = await stolen.get("/auth/test");
			const granted = fake.grant(out.location, { sub: "t", email: "t@example.com", claims: { nonce: "someone-else's" } });
			const replayed = await stolen.get(`/auth/test/callback?code=${granted.code}&state=${granted.state}`);
			assert.match(replayed.location, /^\/sign-in\?error=provider&reason=the%20ID%20token%27s%20nonce/);
			assert.ok(!stolen.cookies.has("session"));
		});

		test("a provider whose client id isn't set: its button isn't offered, and its endpoint says why", async () => {
			const offered = await server.client().read("/sign-in");
			assert.deepEqual(
				offered.providers.map((each) => each.name),
				["test", "hub"],
			);
			assert.equal(offered.dev, false);
			const google = await server.client().get("/auth/google?then=/private");
			assert.equal(google.location, "/sign-in?error=provider&reason=Signing%20in%20with%20Google%20isn%27t%20set%20up%3A%20GOOGLE_CLIENT_ID%20is%20empty.&then=%2Fprivate");
		});

		test("the dev sign-in is there under --dev only; on HTTPS the cookies are __Host- and Secure", async () => {
			assert.equal((await server.client().post("/auth/dev", { email: "dev@example.com" })).status, 404);
			const dev = await startServer(built.server, { database: db.url, dev: true, env: { ...env, PUBLIC_URL: "https://auth.example" } });
			try {
				const client = dev.client();
				const signed = await client.post("/auth/dev", { email: "Dev@Example.com", then: "/private" });
				assert.equal(signed.status, 303);
				assert.equal(signed.location, "/private");
				const cookie = signed.headers.getSetCookie().find((line) => line.startsWith("__Host-session="));
				assert.ok(cookie, "the session cookie is __Host-session");
				assert.match(cookie, /; Secure/);
				assert.match(cookie, /; HttpOnly/);
				assert.equal((await client.read("/me")).email, "dev@example.com");
				const away = await client.get("/auth/test");
				assert.ok(away.headers.getSetCookie().some((line) => line.startsWith("__Host-auth-state=")), "the state cookie is __Host-auth-state");
				assert.ok(new URL(away.location).searchParams.get("redirect_uri").startsWith("https://auth.example/auth/test/callback"));
			} finally {
				await dev.stop();
			}
		});
	});
}
