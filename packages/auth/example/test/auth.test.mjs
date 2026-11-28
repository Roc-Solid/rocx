// packages/auth (D-072), through its example app: signing in by a mailed link (used once, gone when
// used, refused by `admit!`, never sending the browser to another site), at an OpenID Connect
// provider and at a GitHub-like one (both stood in for by a server of the test's own, which checks
// PKCE's verifier, the client's secret and the redirect URI, and makes the ID token), what a state
// that doesn't match does, `Auth.required` and `Auth.optional`, signing out, a user's sessions
// listed and ended, the dev sign-in under `--dev` only, the cookies' `__Host-` names on HTTPS, and
// two-factor sign-in (D-081): turning it on with an authenticator app's code (computed here with
// Node's crypto, RFC 6238), a sign-in that waits for its code (not signed in meanwhile, the code
// page, a wrong code, a code used twice, a recovery code used once, too many wrong codes, too
// long), turning it off and new recovery codes (each needing a code), a provider's sign-in asking
// too, impersonation not asking, an admin's route that wants it on, and the server refusing to
// start without the app's secret (but under `--dev`).
// The example is built for SQLite (always) and for Postgres (when DATABASE_URL is set), each in
// build/<database>/app, its providers pointed at the stand-in.
//
//   node --test 'packages/auth/example/test/*.test.mjs'
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { createServer } from "node:http";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, links, startServer, testDatabase, testSqlite } from "../../../testing/index.mjs";

const example = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The routes the tests add: an app's own way in (`Auth.sign_in!`, going on to `Auth.path!(then)`), and switching person (`Auth.switch!`), for the user the body names. */
const asRoute = `import pf.Server
import pf.Endpoint
import auth.Auth

## POST /test/as: signed in as \`user\`, as an app that checked a password of its own would sign
## someone in, going on to \`then\` (a path of this site, else home). Written by packages/auth's
## tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { user : Str, then : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Auth.sign_in!(Server.redirect(Auth.path!(body.then)), body.user) {
		Ok(answer) => Err(Answer(answer))
		Err(DbErr(why)) => Err(Status(503, why))
	}
`;
const switchRoute = `import pf.Server
import pf.Endpoint
import auth.Auth

## POST /test/switch: the request's session ended and one for \`user\` started, in one step.
post! : { request : Server.Request, params : {}, context : {}, body : { user : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ request, body, .. }|
	match Auth.switch!(request, Server.redirect("/"), body.user) {
		Ok(answer) => Err(Answer(answer))
		Err(DbErr(why)) => Err(Status(503, why))
	}
`;

/** The route the roles test adds: a user's grants forgotten (`Roles.forget!`), as an app that deletes a person would. */
const forgetRoute = `import pf.Server
import pf.Endpoint
import auth.Roles

## POST /test/forget: every grant of \`user\`'s forgotten. Written by packages/auth's tests into the
## app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { user : Str } } => Try({ forgotten : U64 }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Roles.forget!(body.user) {
		Ok(count) => Ok({ forgotten: count })
		Err(DbErr(why)) => Err(Status(503, why))
	}
`;

/** The route the users test adds: a user forgotten (`Auth.forget!`), as an app that deletes a person would. */
const forgetUserRoute = `import pf.Server
import pf.Endpoint
import auth.Auth

## POST /test/forget-user: \`user\` forgotten, everything the package keeps for them. Written by
## packages/auth's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { user : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Auth.forget!(body.user) {
		Ok({}) => Ok({})
		Err(DbErr(why)) => Err(Status(503, why))
	}
`;

/** The route the users test adds: the user with an address, made if there is none (`Auth.user_with_address!`), as an app that invites someone would. */
const addressRoute = `import pf.Server
import pf.Endpoint
import auth.Auth

## POST /test/user-with-address: the id of the user with \`email\`, made if there is none. Written
## by packages/auth's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : {}, body : { email : Str } } => Try({ user : Str }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Auth.user_with_address!(body.email) {
		Ok(user) => Ok({ user: user })
		Err(NotAnAddress) => Err(Status(400, "not an address"))
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
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
	for (const each of ["routes", "migrations", "Middlewares.roc", "Policy.roc"]) cpSync(join(example, each), join(dir, each), { recursive: true });
	const providers = [
		"Auth.google",
		"Auth.github",
		`Auth.oidc({ name: "test", label: "Test", issuer: "${fake}", authorize_url: "${fake}/authorize", token_url: "${fake}/token", client_id_env: "TEST_CLIENT_ID", client_secret_env: "TEST_CLIENT_SECRET" })`,
		`{ ..Auth.github, name: "hub", label: "Hub", flow: GitHub("${fake}/api"), authorize_url: "${fake}/hub/authorize", token_url: "${fake}/hub/token", client_id_env: "HUB_CLIENT_ID", client_secret_env: "HUB_CLIENT_SECRET" }`,
	];
	// The providers are the app's list (Accounts.providers), which the plugin and the provider routes
	// are both given (D-116).
	const accounts = readFileSync(join(example, "Accounts.roc"), "utf8").replace("providers = [Auth.google, Auth.github]", `providers = [${providers.join(", ")}]`);
	assert.match(accounts, /name: "hub"/, "the stand-in's providers written");
	writeFileSync(join(dir, "Accounts.roc"), accounts);
	const main = readFileSync(join(example, "main.roc"), "utf8")
		.replaceAll('"../', '"../../../../')
		.replace('database: Sqlite("data/auth.db")', `database: ${database === "sqlite" ? 'Sqlite("data/auth.db")' : "Postgres"}`);
	writeFileSync(join(dir, "main.roc"), main);
	mkdirSync(join(dir, "routes", "test", "as"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "as", "+server.roc"), asRoute);
	mkdirSync(join(dir, "routes", "test", "switch"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "switch", "+server.roc"), switchRoute);
	mkdirSync(join(dir, "routes", "test", "forget"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "forget", "+server.roc"), forgetRoute);
	mkdirSync(join(dir, "routes", "test", "forget-user"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "forget-user", "+server.roc"), forgetUserRoute);
	mkdirSync(join(dir, "routes", "test", "user-with-address"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "user-with-address", "+server.roc"), addressRoute);
	return dir;
}

const env = {
	TEST_CLIENT_ID: "test-client",
	TEST_CLIENT_SECRET: "test-secret",
	HUB_CLIENT_ID: "test-client",
	HUB_CLIENT_SECRET: "test-secret",
	GOOGLE_CLIENT_ID: "",
	GITHUB_CLIENT_ID: "",
	ADMIN_EMAILS: "boss@example.com, chief@example.com",
	APP_SECRET: "a test secret of the example's, at least 32 characters long",
};

/** The bytes Base32 text (RFC 4648) stands for, its spaces left out. */
function base32(text) {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
	let bits = "";
	for (const char of text.replace(/[\s=]/g, "").toUpperCase()) bits += alphabet.indexOf(char).toString(2).padStart(5, "0");
	return Buffer.from(bits.match(/.{8}/g).map((byte) => parseInt(byte, 2)));
}

/** The 30-second step now (RFC 6238's T). */
const stepNow = () => Math.floor(Date.now() / 30_000);

/** The six-digit code an authenticator app shows for `secret` (its bytes) at `step` (RFC 6238, SHA-1). */
function totp(secret, step) {
	const counter = Buffer.alloc(8);
	counter.writeBigUInt64BE(BigInt(step));
	const mac = createHmac("sha1", secret).update(counter).digest();
	const at = mac[19] & 0x0f;
	return String((mac.readUInt32BE(at) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

/** Six digits that are no code of `secret`'s near now. */
function wrongCode(secret) {
	const near = [-1, 0, 1].map((offset) => totp(secret, stepNow() + offset));
	for (let n = 0; ; n++) {
		const code = String(n).padStart(6, "0");
		if (!near.includes(code)) return code;
	}
}

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
			const asked = await client.json("/api/sign-in", { email, then });
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
			assert.deepEqual(await client.read("/me"), { signed_in: false, user: "", email: "", identities: [], real_user: "", impersonating: false });
			const page = await client.get("/private");
			assert.equal(page.status, 303);
			assert.equal(page.location, "/sign-in?then=%2Fprivate");
			const api = await client.request("/private", { headers: { accept: "application/json" } });
			assert.equal(api.status, 401);
			assert.equal(api.text, "Sign in first, at /sign-in.", "the plugin's refusal");
		});

		test("a mailed link signs in once, its address lower-cased, and goes where it was asked to", async () => {
			const client = server.client();
			const token = await mailedLink(client, "  Ada@Example.COM ", "/private?tab=2");
			// Looking (its page, a mail scanner) doesn't use it.
			assert.deepEqual(await server.client().read(`/api/sign-in/link?token=${token}`), { email: "ada@example.com" });
			assert.deepEqual(await server.client().read(`/api/sign-in/link?token=${token}`), { email: "ada@example.com" });
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
			assert.equal((await server.client().request(`/api/sign-in/link?token=${token}`, { headers: { accept: "application/json" } })).status, 410);
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
			const tabbed = server.client();
			assert.equal((await used(tabbed, await mailedLink(tabbed, "grace@example.com", "/\t/elsewhere.example/x"))).location, "/", "a tab, which a browser drops from a URL, too");
			// Opened straight at /auth/link (an app without a link page), a link signs in too.
			const straight = server.client();
			const went = await straight.get(`/auth/link?token=${await mailedLink(straight, "grace@example.com", "/private")}`);
			assert.equal(went.location, "/private");
			assert.equal((await straight.read("/me")).email, "grace@example.com");
			const forged = await server.client().get("/auth/link?token=not-a-token");
			assert.equal(forged.location, "/sign-in?error=link");
			// An expired link still says where it was going.
			const late = server.client();
			const token = await mailedLink(late, "grace@example.com", "/private");
			await db.query("update auth_links set expires_at = 0");
			assert.equal((await late.post("/auth/link", { token })).location, "/sign-in?error=link&then=%2Fprivate");
			const bad = await server.client().json("/api/sign-in", { email: "not an address", then: "/" });
			assert.equal(bad.status, 400);
		});

		test("admit! turns an address away: the sign-in page says why, and no session starts", async () => {
			const client = server.client();
			const opened = await used(client, await mailedLink(client, "mallory@refused.example", "/private"));
			assert.equal(opened.status, 303);
			assert.equal(opened.location, "/sign-in?error=refused&reason=This%20address%20isn%27t%20allowed%20in.&email=mallory%40refused.example&then=%2Fprivate");
			assert.ok(!client.cookies.has("session"));
			assert.equal((await client.read("/me")).signed_in, false);
			// What admit! wrote as it turned them away stays.
			assert.deepEqual(
				(await db.query("select email from turned_away")).map((row) => row.email),
				["mallory@refused.example"],
			);
		});

		test("an app's own way in (Auth.sign_in!, Auth.path!), switching person in one step (Auth.switch!), and a session whose user is gone (Auth.required_with)", async () => {
			const ann = await signedIn("ann@example.com");
			const annId = (await ann.read("/me")).user;
			const client = server.client();
			const signed = await client.json("/test/as", { user: annId, then: "/private" });
			assert.equal(signed.status, 303, signed.text);
			assert.equal(signed.location, "/private");
			assert.equal((await client.read("/private")).user, annId);
			assert.equal((await client.json("/test/as", { user: annId, then: "//elsewhere.example" })).location, "/", "Auth.path! keeps it on the site");
			assert.equal((await client.json("/test/as", { user: annId, then: "/\t/elsewhere.example" })).location, "/", "a tab, which a browser drops from a URL, too");
			// Switching: one Set-Cookie, the old session gone.
			const bea = await signedIn("bea@example.com");
			const beaId = (await bea.read("/me")).user;
			const before = await client.read("/sessions");
			const switched = await client.json("/test/switch", { user: beaId });
			assert.equal(switched.headers.getSetCookie().filter((line) => line.startsWith("session=")).length, 1);
			assert.equal((await client.read("/me")).user, beaId);
			const old = before.find((session) => session.current).id;
			assert.equal((await db.query(`select count(*) as n from auth_sessions where id = '${old}'`))[0].n == 0, true, "the old session ended");
			// A session whose user is gone ends, and is answered as signed out.
			await db.query(`delete from auth_identities where user_id = '${beaId}'`);
			await db.query(`delete from auth_users where id = '${beaId}'`);
			const gone = await client.request("/private", { headers: { accept: "application/json" } });
			assert.equal(gone.status, 401);
			assert.ok(!client.cookies.has("session"), "its cookie cleared");
			assert.equal((await bea.read("/me")).signed_in, true, "optional doesn't read the user's row");
		});

		test("an admin impersonates someone (Auth.impersonate!): the routes see them, the session stays the admin's, until it is stopped or runs out", async () => {
			const boss = await signedIn("boss@example.com");
			const bossId = (await boss.read("/me")).user;
			const cal = await signedIn("cal@example.com");
			const calId = (await cal.read("/me")).user;
			assert.equal((await cal.json("/impersonate", { email: "boss@example.com" })).status, 403, "only an admin may");
			const acting = await boss.json("/impersonate", { email: "cal@example.com" });
			assert.equal(acting.status, 200, acting.text);
			const me = await boss.read("/me");
			assert.deepEqual([me.user, me.real_user, me.impersonating, me.email], [calId, bossId, true, "cal@example.com"]);
			assert.equal((await boss.read("/private")).user, calId);
			assert.deepEqual(
				(await boss.read("/sessions")).length,
				(await cal.read("/sessions")).length,
				"/sessions lists the user acted as's sessions (the routes see them)",
			);
			assert.equal((await boss.json("/impersonate/stop", {})).status, 200);
			assert.deepEqual([(await boss.read("/me")).user, (await boss.read("/me")).impersonating], [bossId, false]);
			// It runs out.
			await boss.json("/impersonate", { email: "cal@example.com" });
			assert.equal((await boss.read("/me")).user, calId);
			await db.query("update auth_sessions set acting_until = 0 where acting_as is not null");
			assert.equal((await boss.read("/me")).user, bossId, "back to the admin once its time is up");
		});

		/** The status of GET /pro for `client`: 200 while they hold Pro, 403 otherwise. */
		const pro = async (client) => (await client.request("/pro", { headers: { accept: "application/json" } })).status;

		test("roles (D-127): an admin gives Pro as a gift, for good or for days, and ends it; a trial once; Pro from either; every grant kept, and forgotten with the user", async () => {
			const boss = await signedIn("boss@example.com");
			const bossId = (await boss.read("/me")).user;
			const dee = await signedIn("dee@example.com");
			const deeId = (await dee.read("/me")).user;
			const day = 24 * 60 * 60 * 1000;
			assert.equal(await pro(dee), 403, "no Pro yet");
			assert.deepEqual(await dee.read("/roles"), { pro: false, grants: [] });
			assert.equal((await dee.json("/roles/grant", { email: "dee@example.com", days: 0, note: "" })).status, 403, "only an admin gives one");

			// A gift for good: Pro, and the grant as of! reads it.
			assert.equal((await boss.json("/roles/grant", { email: "dee@example.com", days: 0, note: "a friend" })).status, 200);
			assert.equal(await pro(dee), 200);
			const gifted = await dee.read("/roles");
			assert.equal(gifted.pro, true);
			assert.deepEqual(gifted.grants.map(({ since_ms, ...grant }) => grant), [{ role: "pro", via: "gift", by: bossId, ends_ms: 0, note: "a friend", state: "current", revoked_by: "" }]);
			const kept = await db.query(`select role, via, granted_by from auth_roles where user_id = '${deeId}'`);
			assert.deepEqual(kept.map((row) => ({ ...row })), [{ role: '"Pro"', via: '"Gift"', granted_by: bossId }], "each tag kept as its JSON");

			// A trial too, once; the gift ended, the trial keeps Pro; the trial runs out.
			const trial = await dee.json("/trial", {});
			assert.equal(trial.status, 200, trial.text);
			assert.equal((await dee.json("/trial", {})).status, 409, "a trial once");
			assert.deepEqual(await (await boss.json("/roles/revoke", { email: "dee@example.com" })).json(), { revoked: true });
			assert.deepEqual(await (await boss.json("/roles/revoke", { email: "dee@example.com" })).json(), { revoked: false }, "none lasts now");
			assert.equal(await pro(dee), 200, "the trial still holds it");
			await db.query(`update auth_roles set ends_at = 1 where user_id = '${deeId}' and via = '"Trial"'`);
			assert.equal(await pro(dee), 403, "the trial ran out");
			assert.equal((await dee.json("/trial", {})).status, 409, "and doesn't come again");
			const ended = (await dee.read("/roles")).grants;
			assert.deepEqual(ended.map((grant) => [grant.via, grant.state, grant.revoked_by]).sort(), [["gift", "revoked", bossId], ["trial", "ended", ""]]);

			// A gift again, for 30 days: a new grant (the last one ended); then for 60, while it lasts: the same one, its end moved.
			const before = Date.now();
			await boss.json("/roles/grant", { email: "dee@example.com", days: 30, note: "" });
			assert.equal(await pro(dee), 200);
			let grants = (await dee.read("/roles")).grants;
			assert.equal(grants.length, 3);
			assert.equal(grants[0].state, "current");
			assert.ok(grants[0].ends_ms >= before + 30 * day && grants[0].ends_ms <= Date.now() + 30 * day, String(grants[0].ends_ms));
			await boss.json("/roles/grant", { email: "dee@example.com", days: 60, note: "longer" });
			grants = (await dee.read("/roles")).grants;
			assert.equal(grants.length, 3, "the same grant, longer");
			assert.deepEqual([grants[0].note, grants[0].ends_ms >= before + 60 * day], ["longer", true]);

			// A grant that ran out and is given again starts a row of its own.
			await db.query(`update auth_roles set ends_at = 1 where user_id = '${deeId}' and via = '"Gift"' and closed_at is null`);
			await boss.json("/roles/grant", { email: "dee@example.com", days: 0, note: "" });
			grants = (await dee.read("/roles")).grants;
			assert.deepEqual([grants.length, grants[0].via, grants[0].state, grants[0].ends_ms], [4, "gift", "current", 0], "the newest first: a gift for good");
			assert.deepEqual(grants.map((grant) => grant.state).sort(), ["current", "ended", "ended", "revoked"]);
		});

		test("roles: grants at once open one grant; an admin acting as someone sees their Pro; forget! leaves no grant", async () => {
			const boss = await signedIn("boss@example.com");
			const eve = await signedIn("eve@example.com");
			const eveId = (await eve.read("/me")).user;
			const answers = await Promise.all(Array.from({ length: 8 }, (_, n) => boss.json("/roles/grant", { email: "eve@example.com", days: n + 1, note: `grant ${n}` })));
			assert.deepEqual(answers.map((answer) => answer.status), Array(8).fill(200), answers.map((answer) => answer.text).join(" "));
			const open = await db.query(`select count(*) as open from auth_roles where user_id = '${eveId}' and closed_at is null`);
			assert.equal(Number(open[0].open), 1, "one grant, whichever came last");
			assert.equal(await pro(eve), 200);
			// Impersonating: the routes see the user acted as, roles too.
			assert.equal(await pro(boss), 403, "the admin holds none");
			await boss.json("/impersonate", { email: "eve@example.com" });
			assert.equal(await pro(boss), 200, "acting as eve, eve's Pro");
			await boss.json("/impersonate/stop", {});
			// Forgotten with the user.
			assert.deepEqual(await (await boss.json("/test/forget", { user: eveId })).json(), { forgotten: 1 });
			assert.equal(await pro(eve), 403);
			assert.deepEqual(await eve.read("/roles"), { pro: false, grants: [] });
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
			assert.equal((await again.read("/me")).email, "renamed@example.com", "the user's address is the provider's now");
			// An address the provider doesn't say is verified isn't taken: admit! has none to go on.
			const unverified = await atProvider(server.client(), "test", { sub: "subject-2", email: "who@example.com", verified: false });
			assert.match(unverified.location, /^\/sign-in\?error=refused&reason=test%20didn[^&]*&then=%2Fprivate$/);
		});

		test("the package's users (Auth.user_for!): a version 7 UUID, one user for an address however they sign in, an address that follows the provider's, Auth.forget!, and Auth.user_with_address!", async () => {
			const byLink = await signedIn("uma@example.com");
			const me = await byLink.read("/me");
			assert.match(me.user, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, "a version 7 UUID");
			const made = parseInt(me.user.replaceAll("-", "").slice(0, 12), 16);
			assert.ok(Math.abs(made - Date.now()) < 60_000, "led by the time it was made");
			const [row] = await db.query(`select email from auth_users where id = '${me.user}'`);
			assert.equal(row.email, "uma@example.com");
			// A provider giving the same verified address: the same user.
			const atTest = server.client();
			await atProvider(atTest, "test", { sub: "subject-uma", email: "Uma@Example.com" });
			assert.equal((await atTest.read("/me")).user, me.user);
			assert.deepEqual((await atTest.read("/me")).identities.sort(), ["email:uma@example.com", "test:uma@example.com"]);
			// Another user's address isn't taken from them.
			const vicId = (await (await signedIn("vic@example.com")).read("/me")).user;
			await atProvider(server.client(), "test", { sub: "subject-uma", email: "vic@example.com" });
			assert.equal((await atTest.read("/me")).email, "uma@example.com", "vic keeps theirs");
			assert.equal((await db.query(`select id from auth_users where email = 'vic@example.com'`))[0].id, vicId);
			// The provider's address changes: the user's does, and their mailed links to the old one end.
			await atProvider(server.client(), "test", { sub: "subject-uma", email: "uma.new@example.com" });
			assert.equal((await atTest.read("/me")).email, "uma.new@example.com");
			assert.deepEqual((await atTest.read("/me")).identities, ["test:uma.new@example.com"]);
			const oldAddress = await signedIn("uma@example.com");
			assert.notEqual((await oldAddress.read("/me")).user, me.user, "the old address is someone new");
			// Forgotten: their sessions, an admin acting as them, their identities and grants, their row.
			assert.equal((await atTest.json("/trial", {})).status, 200);
			const boss = await signedIn("boss@example.com");
			const bossId = (await boss.read("/me")).user;
			assert.equal((await boss.json("/impersonate", { email: "uma.new@example.com" })).status, 200);
			assert.equal((await boss.read("/me")).user, me.user);
			const forgotten = await server.client().json("/test/forget-user", { user: me.user });
			assert.equal(forgotten.status, 200, forgotten.text);
			assert.equal((await byLink.read("/me")).signed_in, false);
			assert.equal((await atTest.read("/me")).signed_in, false);
			assert.deepEqual([(await boss.read("/me")).user, (await boss.read("/me")).impersonating], [bossId, false], "the admin is themselves again");
			for (const [table, column] of [["auth_users", "id"], ["auth_identities", "user_id"], ["auth_sessions", "user_id"], ["auth_sessions", "acting_as"], ["auth_roles", "user_id"]]) {
				const [left] = await db.query(`select count(*) as n from ${table} where ${column} = '${me.user}'`);
				assert.equal(Number(left.n), 0, `${table}.${column}`);
			}
			const back = server.client();
			await atProvider(back, "test", { sub: "subject-uma", email: "uma.new@example.com" });
			const again = (await back.read("/me")).user;
			assert.ok(again && again !== me.user, "signing in again makes a new user");
			// Named before signing in (an invitation, an admin letting them in ahead): the same user then.
			const ahead = await (await server.client().json("/test/user-with-address", { email: " Wes@Example.com " })).json();
			assert.match(ahead.user, /^[0-9a-f]{8}-[0-9a-f]{4}-7/);
			assert.deepEqual(await (await server.client().json("/test/user-with-address", { email: "wes@example.com" })).json(), ahead, "found, not made again");
			assert.equal((await (await signedIn("wes@example.com")).read("/me")).user, ahead.user, "their first sign-in finds them");
			assert.equal((await server.client().json("/test/user-with-address", { email: "not an address" })).status, 400);
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
			const offered = await server.client().read("/api/sign-in");
			assert.deepEqual(
				offered.providers.map((each) => each.name),
				["test", "hub"],
			);
			assert.equal(offered.dev, false);
			const google = await server.client().get("/auth/google?then=/private");
			assert.equal(google.location, "/sign-in?error=provider&reason=Signing%20in%20with%20Google%20isn%27t%20set%20up%3A%20GOOGLE_CLIENT_ID%20is%20empty.&then=%2Fprivate");
		});

		/**
		 * Turns on two-factor sign-in for the signed-in `client`, its first code taken at the step
		 * now: its secret's bytes, its recovery codes, and that step (the next code must be later).
		 */
		async function enrolled(client) {
			const started = await client.json("/two-factor", {});
			assert.equal(started.status, 200, started.text);
			const { secret } = started.json();
			const bytes = base32(secret);
			const step = stepNow();
			const confirmed = await client.json("/two-factor/confirm", { code: totp(bytes, step) });
			assert.equal(confirmed.status, 200, confirmed.text);
			return { secret: bytes, codes: confirmed.json().recovery_codes, step };
		}

		/** A new browser signed in by a link as `email`, going on to `then`, whose sign-in now waits for its code: it, and where it went. */
		async function waiting(email, then = "/private") {
			const client = server.client();
			const opened = await used(client, await mailedLink(client, email, then));
			assert.equal(opened.status, 303, opened.text);
			return { client, location: opened.location };
		}

		test("two-factor: started (an otpauth URI for the app), a wrong first code refused, the right one turns it on with ten recovery codes; the secret and the codes aren't kept in clear", async () => {
			const client = await signedIn("tf-ann@example.com");
			const user = (await client.read("/me")).user;
			assert.deepEqual(await client.read("/two-factor"), { state: "off", recovery_codes: 0, secret: "" });
			const started = (await client.json("/two-factor", {})).json();
			assert.match(started.secret, /^([A-Z2-7]{4} ){7}[A-Z2-7]{4}$/, "20 bytes of Base32, in groups of four");
			const uri = new URL(started.uri);
			assert.equal(uri.protocol, "otpauth:");
			assert.equal(uri.host, "totp");
			assert.equal(decodeURIComponent(uri.pathname), "/Auth example:tf-ann@example.com");
			assert.equal(uri.searchParams.get("secret"), started.secret.replaceAll(" ", ""));
			assert.equal(uri.searchParams.get("issuer"), "Auth example");
			assert.deepEqual(await client.read("/two-factor"), { state: "pending", recovery_codes: 0, secret: started.secret }, "its secret again, while it waits");
			// Starting again makes another secret: the first one's codes don't turn it on.
			const again = (await client.json("/two-factor", {})).json();
			assert.notEqual(again.secret, started.secret);
			const secret = base32(again.secret);
			assert.equal((await client.json("/two-factor/confirm", { code: totp(base32(started.secret), stepNow()) })).status, 400);
			assert.equal((await client.json("/two-factor/confirm", { code: wrongCode(secret) })).status, 400);
			const confirmed = await client.json("/two-factor/confirm", { code: totp(secret, stepNow()) });
			assert.equal(confirmed.status, 200, confirmed.text);
			const codes = confirmed.json().recovery_codes;
			assert.equal(codes.length, 10);
			assert.equal(new Set(codes).size, 10);
			for (const code of codes) assert.match(code, /^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/);
			assert.deepEqual(await client.read("/two-factor"), { state: "on", recovery_codes: 10, secret: "" });
			assert.equal((await client.json("/two-factor", {})).status, 409, "on already");
			// Kept sealed, and as hashes.
			const [row] = await db.query(`select secret, enabled_at, last_step from auth_two_factor where user_id = '${user}'`);
			assert.ok(!row.secret.includes(again.secret.replaceAll(" ", "")));
			assert.ok(!Buffer.from(row.secret, "base64url").includes(secret), "the secret's bytes aren't in what is kept");
			assert.ok(Number(row.enabled_at) > 0 && Number(row.last_step) > 0);
			const kept = (await db.query(`select id from auth_recovery_codes where user_id = '${user}'`)).map((each) => each.id);
			assert.equal(kept.length, 10);
			for (const code of codes) assert.ok(!kept.includes(code) && !kept.includes(code.replaceAll("-", "")));
		});

		test("two-factor: a sign-in waits for its code (not signed in meanwhile, a page goes to the code page), a wrong code says so, the right one signs in under a new token; a code is good once, and so is a recovery code", async () => {
			const first = await signedIn("tf-bo@example.com");
			const user = (await first.read("/me")).user;
			const { secret, codes, step } = await enrolled(first);
			const { client, location } = await waiting("tf-bo@example.com", "/private?tab=2");
			assert.equal(location, "/sign-in/code?then=%2Fprivate%3Ftab%3D2");
			const waitingToken = client.cookies.get("session");
			assert.ok(waitingToken, "the cookie holds the waiting sign-in");
			assert.equal((await client.read("/me")).signed_in, false, "not signed in while it waits");
			const page = await client.get("/sessions");
			assert.equal(page.status, 303);
			assert.equal(page.location, "/sign-in/code?then=%2Fsessions", "a page goes to the code page");
			assert.equal((await client.request("/private", { headers: { accept: "application/json" } })).status, 401);
			assert.deepEqual(await client.read("/api/sign-in/code"), { email: "tf-bo@example.com", tries_left: 5 });
			const shown = await client.get("/sign-in/code?then=%2Fprivate%3Ftab%3D2");
			assert.equal(shown.status, 200);
			assert.ok(shown.dom.getByRole("textbox", { name: "Code" }));
			(await server.client().get("/sign-in/code")).dom.getByRole("heading", { level: 1, name: "Sign in again" });
			// A wrong code: back to the code page, saying so.
			const wrong = await client.post("/auth/code", { code: wrongCode(secret), then: "/private?tab=2" });
			assert.equal(wrong.status, 303);
			assert.equal(wrong.location, "/sign-in/code?error=code&then=%2Fprivate%3Ftab%3D2");
			assert.equal((await client.read("/api/sign-in/code")).tries_left, 4);
			// The code the first one was confirmed with is used: refused.
			assert.equal((await client.post("/auth/code", { code: totp(secret, step), then: "/private?tab=2" })).location, "/sign-in/code?error=code&then=%2Fprivate%3Ftab%3D2");
			// The next step's code (the window takes one either side), with an app's space in it.
			const code = totp(secret, step + 1);
			const right = await client.post("/auth/code", { code: `${code.slice(0, 3)} ${code.slice(3)}`, then: "/private?tab=2" });
			assert.equal(right.status, 303, right.text);
			assert.equal(right.location, "/private?tab=2");
			assert.notEqual(client.cookies.get("session"), waitingToken, "a new token");
			assert.deepEqual(await client.read("/private"), { user });
			const stale = server.client();
			stale.cookies.set("session", waitingToken);
			assert.equal((await stale.read("/me")).signed_in, false, "the token it waited with signs no one in");
			// The same code again, in another sign-in: refused.
			const replay = await waiting("tf-bo@example.com");
			assert.equal((await replay.client.post("/auth/code", { code, then: "/private" })).location, "/sign-in/code?error=code&then=%2Fprivate");
			// A recovery code, once (typed in capitals, without its dashes).
			const recovered = await replay.client.post("/auth/code", { code: codes[0].replaceAll("-", "").toUpperCase(), then: "/private" });
			assert.equal(recovered.location, "/private");
			assert.equal((await replay.client.read("/me")).user, user);
			assert.deepEqual(await first.read("/two-factor"), { state: "on", recovery_codes: 9, secret: "" });
			const twice = await waiting("tf-bo@example.com");
			assert.equal((await twice.client.post("/auth/code", { code: codes[0], then: "/private" })).location, "/sign-in/code?error=code&then=%2Fprivate");
			assert.ok(server.logs().some((line) => line.msg === "auth: signed in with a recovery code" && line.user === user));
			// Cancelling (signing out) ends the waiting sign-in.
			await twice.client.post("/auth/sign-out", {});
			assert.ok(!twice.client.cookies.has("session"));
			assert.equal(Number((await db.query(`select count(*) as n from auth_waiting where user_id = '${user}'`))[0].n), 0);
		});

		test("two-factor: the fifth wrong code ends the sign-in, and one that waited too long is gone", async () => {
			const { secret, codes } = await enrolled(await signedIn("tf-cy@example.com"));
			const { client } = await waiting("tf-cy@example.com", "/private");
			for (let tries = 1; tries < 5; tries++) {
				assert.equal((await client.post("/auth/code", { code: wrongCode(secret), then: "/private" })).location, "/sign-in/code?error=code&then=%2Fprivate", `try ${tries}`);
			}
			const ended = await client.post("/auth/code", { code: "not-a-code", then: "/private" });
			assert.equal(ended.location, "/sign-in?error=attempts&then=%2Fprivate");
			assert.ok(!client.cookies.has("session"), "its cookie cleared");
			const after = server.client();
			assert.equal((await after.post("/auth/code", { code: codes[0], then: "/private" })).location, "/sign-in?error=timeout&then=%2Fprivate", "no sign-in waits");
			const slow = await waiting("tf-cy@example.com");
			await db.query("update auth_waiting set expires_at = 0");
			assert.equal((await slow.client.post("/auth/code", { code: codes[0], then: "/private" })).location, "/sign-in?error=timeout&then=%2Fprivate");
			assert.equal((await slow.client.get("/private")).location, "/sign-in?then=%2Fprivate", "signed out once it has gone");
		});

		test("two-factor: new recovery codes and turning it off each need a code; off, signing in doesn't ask", async () => {
			const client = await signedIn("tf-di@example.com");
			const { secret, codes, step } = await enrolled(client);
			assert.equal((await client.json("/two-factor/recovery-codes", { code: wrongCode(secret) })).status, 400);
			const renewed = await client.json("/two-factor/recovery-codes", { code: totp(secret, step + 1) });
			assert.equal(renewed.status, 200, renewed.text);
			const fresh = renewed.json().recovery_codes;
			assert.equal(fresh.length, 10);
			assert.equal((await client.json("/two-factor/disable", { code: codes[1] })).status, 400, "the old codes are gone");
			assert.equal((await client.json("/two-factor/disable", { code: "" })).status, 400);
			assert.equal((await client.json("/two-factor/disable", { code: fresh[3] })).status, 200);
			assert.deepEqual(await client.read("/two-factor"), { state: "off", recovery_codes: 0, secret: "" });
			assert.equal((await client.json("/two-factor/disable", { code: fresh[4] })).status, 409, "off already");
			const { location } = await waiting("tf-di@example.com", "/private");
			assert.equal(location, "/private", "signed in at once");
		});

		test("two-factor: a user's wrong codes count across sign-ins and turning it off, a right one sets the count back; the tenth in a row and their codes are refused for a quarter of an hour, a right one too, at a sign-in as well", async () => {
			const client = await signedIn("tf-lk@example.com");
			const user = (await client.read("/me")).user;
			const { secret, codes } = await enrolled(client);
			const misses = async () => Number((await db.query(`select misses from auth_two_factor where user_id = '${user}'`))[0].misses);
			for (let tries = 1; tries <= 4; tries++) assert.equal((await client.json("/two-factor/disable", { code: wrongCode(secret) })).status, 400);
			const first = await waiting("tf-lk@example.com");
			for (let tries = 1; tries <= 4; tries++) {
				assert.equal((await first.client.post("/auth/code", { code: wrongCode(secret), then: "/private" })).location, "/sign-in/code?error=code&then=%2Fprivate");
			}
			assert.equal(await misses(), 8, "four here, four at the sign-in");
			assert.equal((await client.json("/two-factor/recovery-codes", { code: codes[0] })).status, 200, "a right code before the tenth");
			assert.equal(await misses(), 0);
			assert.equal((await client.json("/two-factor/recovery-codes", { code: wrongCode(secret) })).status, 400);
			for (let tries = 2; tries <= 10; tries++) assert.equal((await client.json("/two-factor/disable", { code: wrongCode(secret) })).status, 400, `try ${tries}`);
			const refused = await client.json("/two-factor/disable", { code: totp(secret, stepNow() + 1) });
			assert.equal(refused.status, 429, "a right code, refused while it waits");
			assert.equal(await misses(), 10, "not looked at, nor counted");
			const second = await waiting("tf-lk@example.com");
			const locked = await second.client.post("/auth/code", { code: totp(secret, stepNow() + 1), then: "/private" });
			assert.equal(locked.location, "/sign-in?error=locked&then=%2Fprivate");
			assert.ok(!second.client.cookies.has("session"), "the sign-in ended");
			await db.query(`update auth_two_factor set missed_at = 0 where user_id = '${user}'`);
			const third = await waiting("tf-lk@example.com");
			const signed = await third.client.post("/auth/code", { code: totp(secret, stepNow() + 1), then: "/private" });
			assert.equal(signed.location, "/private", "a quarter of an hour on, a right code signs in");
			assert.equal(await misses(), 0);
		});

		test("two-factor: a provider's sign-in asks too; an admin impersonating them isn't asked; /admin wants its admins to have it on", async () => {
			const user = server.client();
			await atProvider(user, "test", { sub: "tf-subject", email: "tf-eve@example.com" });
			const eve = (await user.read("/me")).user;
			const { codes } = await enrolled(user);
			const later = server.client();
			const back = await atProvider(later, "test", { sub: "tf-subject", email: "tf-eve@example.com" }, "/private");
			assert.equal(back.location, "/sign-in/code?then=%2Fprivate");
			assert.equal((await later.post("/auth/code", { code: codes[0], then: "/private" })).location, "/private");
			assert.equal((await later.read("/me")).user, eve);
			// An admin acting as them sees the app as they do, with no code.
			const chief = await signedIn("chief@example.com");
			assert.equal((await chief.json("/impersonate", { email: "tf-eve@example.com" })).status, 200);
			assert.equal((await chief.read("/private")).user, eve);
			assert.equal((await chief.json("/two-factor", {})).status, 403, "nor may they change how the person signs in");
			assert.equal((await chief.json("/impersonate/stop", {})).status, 200);
			// /admin: its admins must have turned two-factor on.
			const refused = await chief.request("/admin", { headers: { accept: "application/json" } });
			assert.equal(refused.status, 403);
			assert.match(refused.text, /Turn on two-factor sign-in first/);
			assert.equal((await user.request("/admin", { headers: { accept: "application/json" } })).status, 403, "not an admin");
			await enrolled(chief);
			assert.deepEqual(await chief.read("/admin"), { admin: (await chief.read("/me")).user });
		});

		test("two-factor needs the app's secret: the server doesn't start without it, but under --dev", async () => {
			await assert.rejects(startServer(built.server, { database: db.url, env: { ...env, APP_SECRET: "" } }), /two-factor sign-in needs APP_SECRET/);
			await assert.rejects(startServer(built.server, { database: db.url, env: { ...env, APP_SECRET: "too short" } }), /APP_SECRET is too short/);
			const dev = await startServer(built.server, { database: db.url, dev: true, env: { ...env, APP_SECRET: "" } });
			try {
				assert.ok(dev.logs().some((line) => /development key/.test(line.msg ?? "")));
				const client = dev.client();
				assert.equal((await client.post("/auth/dev", { email: "tf-dev@example.com", then: "/private" })).location, "/private");
				const { codes } = await enrolled(client);
				const again = dev.client();
				assert.equal((await again.post("/auth/dev", { email: "tf-dev@example.com", then: "/private" })).location, "/sign-in/code?then=%2Fprivate", "the dev sign-in asks too");
				assert.equal((await again.post("/auth/code", { code: codes[0] })).location, "/private");
			} finally {
				await dev.stop();
			}
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
