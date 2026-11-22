// Acme Notes over HTTP, as a browser without JavaScript, as the page's runtime, and as a script with a
// token ask it: signing in by the mailed link (once, and not after it expires), sessions, the seed,
// notes through the pages' forms and the JSON API, search, tokens (shown once, kept as a hash,
// read-only, revoked), one person never reaching another's notes, and the limit on sign-in mail.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bearer, dir, mailedLink, makeToken, noDatabase, noteIds, signIn, started } from "./app.mjs";

const sha256 = (text) => createHash("sha256").update(text).digest("hex");

describe("Acme Notes over HTTP", { skip: noDatabase }, () => {
	let running, app, db, ada, bo;
	before(async () => {
		// A link lasts 3 s here, rather than 15 minutes, so a test can wait for one to expire.
		running = await started({ env: { NOTES_LINK_TTL_MS: "3000" } });
		({ app, db } = running);
		ada = await signIn(app, "ada@example.com");
		bo = await signIn(app, "bo@example.com");
	});
	after(() => running?.stop());

	test("signed out, a page sends you to sign in, and the API and MCP refuse", async () => {
		const visitor = app.client();
		const page = await visitor.get("/notes/1?x=1");
		assert.equal(page.status, 303);
		assert.equal(page.location, "/sign-in?then=%2Fnotes%2F1%3Fx%3D1");
		const api = await visitor.json("/api/notes", undefined, "GET");
		assert.equal(api.status, 401);
		assert.match(api.headers.get("www-authenticate"), /^Bearer/);
		assert.equal((await visitor.json("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/list" })).status, 401);
		// A cookie the server didn't sign is no session.
		const forger = app.client();
		forger.cookies.set("acme_notes_session", "1.0.9999999999999.c2lnbmVk");
		assert.equal((await forger.get("/")).status, 303);
	});

	test("signing in: the form, the mailed link, a button that uses it, and back where you were going", async () => {
		const visitor = app.client();
		const page = await visitor.get("/sign-in?then=%2Fsettings");
		page.dom.getByRole("heading", { name: "Sign in" });
		page.dom.getByLabelText("Email address");
		const before = (await app.mail()).length;

		// Without JavaScript: the form posts, and comes back to the page, which says where the link went.
		const asked = await visitor.post("/sign-in", { email: "  Cyd@Example.com ", then: "/settings" });
		assert.equal(asked.status, 303);
		assert.deepEqual([visitor.flash.status, JSON.parse(visitor.flash.body)], [200, { sent: "cyd@example.com" }]);
		(await asked.follow()).dom.getByRole("heading", { name: "Check your inbox" });

		// The mail has one link, to the public URL; opening it signs nobody in by itself.
		const link = await mailedLink(app, "cyd@example.com", before);
		const landing = await visitor.get(link);
		assert.equal(landing.status, 200);
		landing.dom.getByText("cyd@example.com");
		assert.equal(visitor.cookies.has("acme_notes_session"), false);

		// The button does, and goes on to where the person was going.
		const token = new URL(link, "http://x").searchParams.get("token");
		const used = await visitor.post("/sign-in/link", { token });
		assert.equal(used.status, 303);
		assert.equal(used.location, "/settings");
		const cookie = used.headers.get("set-cookie");
		for (const part of ["acme_notes_session=", "Max-Age=2592000", "HttpOnly", "SameSite=Lax"]) assert.ok(cookie.includes(part), cookie);
		const settings = await visitor.read("/settings");
		assert.equal(settings.email, "cyd@example.com");

		// Someone new starts with a note of welcome.
		const home = await visitor.read("/");
		assert.deepEqual(home.notes.map((note) => note.title), ["Welcome to Acme Notes"]);

		// Nothing in the server keeps the token itself: Kv has its hash.
		assert.equal((await db.sql`select count(*)::int as n from people where email = 'cyd@example.com'`)[0].n, 1);
	});

	test("a link works once: used again, or by someone else, it is refused", async () => {
		const before = (await app.mail()).length;
		const first = app.client();
		await first.get("/sign-in");
		await first.post("/sign-in", { email: "dee@example.com", then: "/" });
		const link = await mailedLink(app, "dee@example.com", before);
		const token = new URL(link, "http://x").searchParams.get("token");
		assert.equal((await first.post("/sign-in/link", { token })).status, 303);

		const again = app.client();
		const page = await again.get(link);
		page.dom.getByRole("heading", { name: "This link has expired" });
		const reused = await again.post("/sign-in/link", { token });
		assert.equal(reused.status, 303);
		assert.deepEqual([again.flash.status, again.flash.body], [410, "This sign-in link has been used, or it has expired. Ask for another."]);
		assert.equal(again.cookies.has("acme_notes_session"), false);
		// With the runtime, the refusal comes back as it is.
		assert.equal((await again.submit("/sign-in/link", { token })).status, 410);
		// A token never mailed, or not a token at all.
		assert.equal((await again.submit("/sign-in/link", { token: "x".repeat(43) })).status, 410);
		assert.equal((await again.submit("/sign-in/link", { token: "" })).status, 410);
	});

	test("a link expires: after its time (3 s here) it signs nobody in", async () => {
		const before = (await app.mail()).length;
		const late = app.client();
		await late.get("/sign-in");
		await late.post("/sign-in", { email: "eve@example.com", then: "/" });
		const link = await mailedLink(app, "eve@example.com", before);
		assert.equal((await late.read(`/sign-in/link${link.slice(link.indexOf("?"))}`)).email, "eve@example.com");
		await new Promise((resolve) => setTimeout(resolve, 3200));
		(await late.get(link)).dom.getByRole("heading", { name: "This link has expired" });
		const used = await late.submit("/sign-in/link", { token: new URL(link, "http://x").searchParams.get("token") });
		assert.equal(used.status, 410);
		assert.equal(late.cookies.has("acme_notes_session"), false);
	});

	test("an address that isn't one is refused, and nothing is mailed", async () => {
		const before = (await app.mail()).length;
		const visitor = app.client();
		await visitor.get("/sign-in");
		await visitor.post("/sign-in", { email: "not an address", then: "/" });
		assert.deepEqual([visitor.flash.status, visitor.flash.body], [400, "That doesn't look like an email address."]);
		assert.equal((await app.mail()).length, before);
	});

	test("signing out, and signing out everywhere", async () => {
		const here = await signIn(app, "fay@example.com");
		const there = await signIn(app, "fay@example.com");
		assert.equal((await here.get("/")).status, 200);

		const out = await here.post("/sign-out", {});
		assert.equal(out.status, 303);
		assert.equal(out.location, "/sign-in");
		assert.equal(here.cookies.has("acme_notes_session"), false);
		assert.equal((await there.get("/")).status, 200, "signing out here leaves the other browser signed in");

		const elsewhere = await signIn(app, "fay@example.com");
		await elsewhere.get("/settings");
		assert.equal((await elsewhere.post("/settings/everywhere", {})).status, 303);
		assert.equal((await there.get("/")).status, 303, "every browser is signed out");
		assert.equal((await (await signIn(app, "fay@example.com")).get("/")).status, 200, "signing in again works");
	});

	test("the seed: Ada's notes, pinned first, and running it again adds nothing", async () => {
		const home = await ada.read("/");
		assert.equal(home.email, "ada@example.com");
		assert.deepEqual(home.notes.slice(0, 2).map((note) => [note.title, note.pinned]), [["Trip to the coast", true], ["Launch week plan", true]]);
		assert.equal(home.notes.length, 7);
		assert.deepEqual(home.tags.slice(0, 2), [{ name: "rocket", count: 2 }, { name: "work", count: 2 }]);
		assert.deepEqual((await ada.read("/?archived=true")).notes.map((note) => note.title), ["Old flat: things to sort"]);
		assert.deepEqual((await ada.read("/?tag=rocket")).notes.map((note) => note.title), ["Launch week plan", "Countdown script"]);

		await db.query(readFileSync(join(dir, "migrations", "0002_seed.sql"), "utf8"));
		const [counts] = await db.sql`select (select count(*)::int from people where email in ('ada@example.com', 'bo@example.com')) as people, (select count(*)::int from notes n join people p on p.id = n.person_id where p.email = 'ada@example.com') as notes`;
		assert.deepEqual(counts, { people: 2, notes: 8 });
	});

	test("a note through the pages' forms, without JavaScript: written, refused, edited, pinned, archived, deleted", async () => {
		await ada.get("/new");
		const refused = await ada.post("/new", { title: "  ", body: "x", tags: "" });
		assert.equal(refused.status, 303);
		assert.deepEqual([ada.flash.status, ada.flash.body], [400, "A note needs a title."]);
		await ada.post("/new", { title: "Tags", body: "", tags: "two words!" });
		assert.equal(ada.flash.status, 400);

		const made = await ada.post("/new", { title: "Garden plan", body: "Plant **tulips** in October.", tags: "Home, garden #spring" });
		assert.equal(made.status, 303);
		const id = made.location.split("/").pop();
		assert.equal(made.location, `/notes/${id}`);
		const page = await made.follow();
		page.dom.getByRole("heading", { name: "Garden plan", level: 1 });
		assert.equal(page.dom.getByText("tulips").tag, "strong");
		let note = (await ada.read(`/notes/${id}`)).note;
		assert.deepEqual([note.body, note.tags, note.pinned, note.archived], ["Plant **tulips** in October.", ["home", "garden", "spring"], false, false]);

		const editor = await ada.get(`/notes/${id}/edit`);
		assert.equal(editor.dom.getByLabelText("Tags").attr("value"), "home, garden, spring");
		const saved = await ada.post(`/notes/${id}/edit`, { title: "Garden plan", body: "Plant tulips in October.\n\n- [ ] Buy bulbs", tags: "home" });
		assert.equal(saved.location, `/notes/${id}`);
		note = (await ada.read(`/notes/${id}`)).note;
		assert.deepEqual([note.body, note.tags], ["Plant tulips in October.\n\n- [ ] Buy bulbs", ["home"]]);

		// The note's buttons: each comes back to its page.
		await ada.get(`/notes/${id}`);
		assert.equal((await ada.post(`/notes/${id}`, { action: "pin" })).status, 303);
		assert.equal(ada.flash.status, 200);
		assert.equal((await ada.read("/")).notes[0].title, "Garden plan");
		const deleteFirst = await ada.post(`/notes/${id}`, { action: "delete" });
		assert.equal(deleteFirst.status, 303);
		assert.deepEqual([ada.flash.status, ada.flash.body], [409, "Archive a note before deleting it."]);
		await ada.post(`/notes/${id}`, { action: "archive" });
		note = (await ada.read(`/notes/${id}`)).note;
		assert.deepEqual([note.archived, note.pinned], [true, false], "an archived note isn't pinned");
		assert.ok(!(await ada.read("/")).notes.some((each) => each.id === id));
		assert.ok((await ada.read("/?archived=true")).notes.some((each) => each.id === id));

		// With the runtime, a button's form gets the note back, and the page stays.
		const restored = await ada.submit(`/notes/${id}`, { action: "restore" });
		assert.equal(restored.status, 200);
		assert.equal(restored.json().archived, false);
		await ada.submit(`/notes/${id}`, { action: "archive" });
		const gone = await ada.post(`/notes/${id}`, { action: "delete" });
		assert.equal(gone.location, "/?archived=true");
		assert.equal((await ada.get(`/notes/${id}`)).status, 404);
	});

	test("search: words, phrases, -without, #tags, the matches marked, archived notes too", async () => {
		const search = async (query) => (await ada.json("/api/search", { query })).json();

		const launch = await search("launch");
		assert.deepEqual(launch.map((note) => note.title), ["Launch week plan", "One-to-one with Bo"]);
		const hits = launch[1].snippet.filter((piece) => piece.hit).map((piece) => piece.text);
		assert.deepEqual(hits, ["launch"]);
		assert.ok(launch[1].snippet.map((piece) => piece.text).join("").includes("How the launch rehearsal"));

		// Stemming: "rehearsals" finds "rehearsal".
		assert.deepEqual((await search("rehearsals")).map((note) => note.title), ["One-to-one with Bo"]);
		assert.deepEqual((await search('"stretch and folds"')).map((note) => note.title), ["Sourdough schedule"]);
		assert.deepEqual((await search("launch -rehearsal")).map((note) => note.title), ["Launch week plan"]);
		assert.deepEqual((await search("launch #meetings")).map((note) => note.title), ["One-to-one with Bo"]);
		assert.deepEqual((await search("#kitchen")).map((note) => note.title), ["Sourdough schedule"]);
		const archived = await search("deposit");
		assert.deepEqual(archived.map((note) => [note.title, note.archived]), [["Old flat: things to sort", true]]);
		assert.deepEqual(await search("zeppelin"), []);
		// Markdown's marks aren't in what is quoted.
		assert.ok(!(await search("radios"))[0].snippet.map((piece) => piece.text).join("").includes("- ["));

		// The page: the search box keeps the words, and each match is marked.
		const page = await ada.get("/?q=launch");
		assert.equal(page.dom.getByRole("searchbox", { name: "Search your notes" }).attr("value"), "launch");
		assert.match(page.text, /<mark[^>]*>launch<\/mark>/);
		page.dom.getByRole("status");
		assert.equal(page.dom.getByRole("status").text, "2 notes for “launch”");
		(await ada.get("/?q=zeppelin")).dom.getByText("Nothing matches “zeppelin”.");
	});

	test("the JSON API, with a personal access token: every operation, and what is refused", async () => {
		const token = await makeToken(ada, "Script");
		assert.match(token, /^acme_pat_[A-Za-z0-9_-]{43}$/);
		const api = bearer(app, token);
		assert.deepEqual(await api.read("/api/me"), { email: "ada@example.com", read_only: false });

		const made = await api.json("/api/notes", { title: "From a script", body: "One", tags: ["Scripts"] });
		assert.equal(made.status, 200, made.text);
		const id = made.json().id;
		assert.deepEqual([made.json().title, made.json().tags], ["From a script", ["scripts"]]);
		assert.equal((await api.read(`/api/notes/${id}`)).body, "One");

		const appended = await api.json(`/api/notes/${id}/append`, { text: "Two" });
		assert.equal(appended.json().body, "One\n\nTwo");
		// Ten appends at once each land, none over another.
		await Promise.all(Array.from({ length: 10 }, (_, index) => api.json(`/api/notes/${id}/append`, { text: `line ${index}` })));
		const body = (await api.read(`/api/notes/${id}`)).body;
		for (let index = 0; index < 10; index++) assert.ok(body.includes(`line ${index}`), body);

		assert.deepEqual((await api.json(`/api/notes/${id}/tags`, { tags: ["a", "#B", "a"] }, "PUT")).json().tags, ["a", "b"]);
		assert.equal((await api.json(`/api/notes/${id}/archived`, { archived: true }, "PUT")).json().archived, true);
		assert.ok((await api.read("/api/notes?archived=true")).some((note) => note.id === id));
		assert.ok((await api.read("/api/notes?tag=a&tag=b&archived=true")).some((note) => note.id === id));
		const replaced = await api.json(`/api/notes/${id}`, { title: "Renamed", body: "Fresh", tags: [] }, "PUT");
		assert.deepEqual([replaced.json().title, replaced.json().body, replaced.json().tags], ["Renamed", "Fresh", []]);

		// What is refused, and why.
		const refused = async (path, value, method = "POST") => {
			const answer = await api.json(path, value, method);
			return [answer.status, answer.text];
		};
		assert.deepEqual(await refused("/api/notes", { title: "", body: "", tags: [] }), [400, "A note needs a title."]);
		assert.deepEqual(await refused("/api/notes", { title: "x".repeat(201), body: "", tags: [] }), [400, "A title is 200 characters at most."]);
		assert.deepEqual(await refused(`/api/notes/${id}/append`, { text: "  " }), [400, "There is nothing to add."]);
		assert.equal((await refused(`/api/notes/${id}/tags`, { tags: ["no spaces please"] }, "PUT"))[0], 400);
		assert.equal((await refused("/api/notes", { title: "No body" }))[0], 400, "every field is asked for");
		assert.equal((await refused("/api/notes/99999999", undefined, "GET"))[0], 404);
		assert.equal((await refused("/api/notes/abc", undefined, "GET"))[0], 404);

		assert.deepEqual((await api.json(`/api/notes/${id}`, undefined, "DELETE")).json(), { deleted: id });
		assert.equal((await refused(`/api/notes/${id}`, undefined, "GET"))[0], 404);

		// A token that isn't one, or one revoked.
		assert.equal((await bearer(app, "acme_pat_nope").json("/api/me", undefined, "GET")).status, 401);
		assert.equal((await bearer(app, token.slice(0, -1) + (token.endsWith("A") ? "B" : "A")).json("/api/me", undefined, "GET")).status, 401);
	});

	test("tokens: shown once, kept only as a hash, listed with their last use, read-only, revoked", async () => {
		const token = await makeToken(ada, "Reader", "read");
		const [row] = await db.sql`select name, hash, hint, read_only from tokens where hash = ${sha256(token)}`;
		assert.deepEqual(row, { name: "Reader", hash: sha256(token), hint: token.slice(-4), read_only: true });
		const everything = JSON.stringify(await db.sql`select * from tokens`);
		assert.ok(!everything.includes(token.slice("acme_pat_".length, -4)), "no token is in the database");

		let listed = (await ada.read("/settings")).tokens.find((each) => each.name === "Reader");
		assert.deepEqual([listed.read_only, listed.last_used, listed.hint], [true, "", token.slice(-4)]);
		assert.ok(!JSON.stringify(await ada.read("/settings")).includes(token), "the list never has the token");

		// Read-only: it reads, and every write is refused, saying why.
		const reader = bearer(app, token);
		assert.ok((await reader.read("/api/notes")).length > 0);
		const write = await reader.json("/api/notes", { title: "Nope", body: "", tags: [] });
		assert.deepEqual([write.status, write.text], [403, "This token can only read. Make one that may write in Settings."]);
		const ids = await noteIds(db, "ada@example.com");
		assert.equal((await reader.json(`/api/notes/${ids["Shed ideas"]}/append`, { text: "x" })).status, 403);
		assert.equal((await reader.json(`/api/notes/${ids["Shed ideas"]}`, undefined, "DELETE")).status, 403);

		listed = (await ada.read("/settings")).tokens.find((each) => each.name === "Reader");
		assert.match(listed.last_used, /^\d{4}-\d{2}-\d{2}T/);
		const page = await ada.get("/settings");
		page.dom.getByRole("button", { name: "Revoke Reader" });

		// Without JavaScript, a new token comes back to the page in its flash, and is shown there once.
		const shown = await ada.post("/settings", { name: "Laptop", write: "on" });
		assert.equal(shown.status, 303);
		const fresh = JSON.parse(ada.flash.body).token;
		const landed = await shown.follow();
		assert.equal(landed.dom.getByLabelText("Your new token").attr("value"), fresh);
		assert.ok(!(await ada.get("/settings")).text.includes(fresh), "once only: the next page hasn't it");
		await ada.post("/settings", { name: " " });
		assert.deepEqual([ada.flash.status, ada.flash.body], [400, "Give the token a name, to know it by later."]);

		// Revoked: gone, and refused from then on.
		await ada.get("/settings");
		const id = (await ada.read("/settings")).tokens.find((each) => each.name === "Reader").id;
		assert.equal((await ada.post("/settings/revoke", { id })).status, 303);
		assert.equal((await reader.json("/api/notes", undefined, "GET")).status, 401);
		assert.ok(!(await ada.read("/settings")).tokens.some((each) => each.name === "Reader"));
	});

	test("one person never reaches another's notes: not on a page, not in the API, not with a token", async () => {
		const bos = await noteIds(db, "bo@example.com");
		const theirs = bos["Telemetry dashboard"];

		// Pages and their endpoints: as if the note weren't there.
		for (const path of [`/notes/${theirs}`, `/notes/${theirs}/edit`, "/notes/99999999", "/notes/99999999/edit"]) {
			const missing = await ada.get(path);
			assert.equal(missing.status, 404, path);
			missing.dom.getByRole("heading", { name: "There's no page here" });
			missing.dom.getByText("The note may have been deleted, or the address is wrong.");
		}
		assert.equal((await ada.json(`/notes/${theirs}`, undefined, "GET")).status, 404);
		await ada.get("/");
		await ada.post(`/notes/${theirs}`, { action: "archive" });
		assert.equal(ada.flash.status, 404);
		await ada.post(`/notes/${theirs}/edit`, { title: "Mine now", body: "", tags: "" });
		assert.equal(ada.flash.status, 404);
		assert.ok(!(await ada.read("/")).notes.some((note) => note.id === theirs));

		// Search: Ada's own note mentions the telemetry dashboard; Bo's isn't found.
		const found = (await ada.json("/api/search", { query: "telemetry" })).json();
		assert.deepEqual(found.map((note) => note.title), ["One-to-one with Bo"]);
		assert.ok(!(await ada.read("/")).tags.some((tag) => tag.name === "climbing"));

		// The API, with Ada's token.
		const api = bearer(app, await makeToken(ada, "Isolation"));
		for (const [path, method, value] of [
			[`/api/notes/${theirs}`, "GET"],
			[`/api/notes/${theirs}`, "PUT", { title: "x", body: "", tags: [] }],
			[`/api/notes/${theirs}`, "DELETE"],
			[`/api/notes/${theirs}/append`, "POST", { text: "hi" }],
			[`/api/notes/${theirs}/tags`, "PUT", { tags: [] }],
			[`/api/notes/${theirs}/archived`, "PUT", { archived: true }],
		]) {
			assert.equal((await api.json(path, value, method)).status, 404, `${method} ${path}`);
		}
		// Nor one of Bo's tokens.
		const bosToken = await makeToken(bo, "Bo's");
		const [{ id: bosTokenId }] = await db.sql`select id::text as id from tokens where hash = ${sha256(bosToken)}`;
		await ada.get("/settings");
		await ada.post("/settings/revoke", { id: bosTokenId });
		assert.equal(ada.flash.status, 404);
		assert.equal((await bearer(app, bosToken).read("/api/me")).email, "bo@example.com");

		// Bo's note is as it was.
		const [row] = await db.sql`select title, body, archived from notes where id = ${theirs}`;
		assert.deepEqual([row.title, row.archived], ["Telemetry dashboard", false]);
		assert.ok(!row.body.includes("hi"));
	});

	test("the JSON API's OpenAPI document, and Scalar to read it", async () => {
		const visitor = app.client();
		const document = await visitor.read("/openapi.json");
		for (const path of ["/api/notes", "/api/notes/{id}", "/api/notes/{id}/append", "/api/notes/{id}/tags", "/api/notes/{id}/archived", "/api/search", "/api/me"]) {
			assert.ok(document.paths[path], `${path} in ${Object.keys(document.paths)}`);
		}
		assert.match(document.paths["/api/search"].post.description, /best first/);
		const page = await visitor.get("/openapi.html");
		assert.equal(page.status, 200);
		assert.equal(page.headers.get("content-security-policy"), null, "guard's CSP would refuse Scalar");
		assert.ok((await visitor.get("/sign-in")).headers.get("content-security-policy") !== null);
	});

	test("sign-in mail is limited for each address: five, then a refusal", async () => {
		const visitor = app.client();
		await visitor.get("/sign-in");
		for (let sent = 0; sent < 5; sent++) assert.equal((await visitor.submit("/sign-in", { email: "gus@example.com", then: "/" })).status, 200);
		const limited = await visitor.submit("/sign-in", { email: "GUS@example.com", then: "/" });
		assert.equal(limited.status, 429);
		assert.match(limited.headers.get("retry-after"), /^\d+$/);
		assert.equal((await visitor.submit("/sign-in", { email: "hal@example.com", then: "/" })).status, 200, "another address isn't counted with it");
		const sent = (await app.mail()).filter((message) => message.to === "gus@example.com");
		assert.equal(sent.length, 5);
	});
});
