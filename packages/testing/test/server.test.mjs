// server.mjs without the toolchain: its client against a plain Node server standing in for a Roc
// Solid one (cookies kept and cleared, Origin and Referer sent as a browser sends them, redirects
// seen, not followed), server-sent events read as they come, the mailbox waited for, links in a
// message, a story's path as rocx build names it. app.test.mjs does the same against a real app.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repo } from "../build.mjs";
import { ReadError, Server, links, storyPath, until } from "../server.mjs";

let http;
let server;
/** What the stand-in server was asked, last first. */
const asked = [];
let mail = [];

before(async () => {
	http = createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		const body = Buffer.concat(chunks).toString();
		asked.unshift({ method: request.method, url: request.url, headers: request.headers, body });
		const send = (status, headers, text = "") => {
			response.writeHead(status, headers);
			response.end(text);
		};
		switch (`${request.method} ${request.url}`) {
			case "GET /":
				return send(200, { "content-type": "text/html; charset=utf-8", "set-cookie": ["a=1; Path=/", "b=two%20words; Path=/; HttpOnly"] }, '<main><h1>Home</h1><a href="/b">B</a></main>');
			case "POST /form":
				return send(303, { location: "/", "set-cookie": ["rocx-flash=%7B%22status%22%3A400%2C%22body%22%3A%22no%22%7D; Path=/; Max-Age=60", "a=; Path=/; Max-Age=0"] });
			case "GET /notes/count":
				return send(200, { "content-type": "application/json" }, JSON.stringify({ n: 2 }));
			case "GET /notes/secret":
				return send(401, { "content-type": "text/plain" }, "members only");
			case "GET /ticks":
				response.writeHead(200, { "content-type": "text/event-stream" });
				response.write(": a comment\n\ndata: 1\n\nevent: named\ndata: two\ndata: lines\nid: 7\n\n");
				setTimeout(() => response.end("data: 3\r\n\r\n"), 20);
				return;
			case "GET /__rocx/mail.json":
				return send(200, { "content-type": "application/json" }, JSON.stringify(mail));
			default:
				return send(404, { "content-type": "text/plain" }, "nothing here");
		}
	});
	await new Promise((resolve) => http.listen(0, "127.0.0.1", resolve));
	const url = `http://127.0.0.1:${http.address().port}`;
	server = new Server(url, { exitCode: 0 }, () => "");
});

after(() => new Promise((resolve) => http.close(resolve)));

test("client: cookies kept and cleared, Origin on what changes, Referer from the last page, redirects seen", async () => {
	const browser = server.client();
	const page = await browser.get("/");
	assert.equal(page.status, 200);
	assert.equal(asked[0].headers.accept, "text/html");
	assert.equal(asked[0].headers.origin, undefined, "a GET carries no Origin");
	assert.deepEqual([...browser.cookies], [["a", "1"], ["b", "two%20words"]]);
	assert.equal(page.dom.getByRole("heading").text, "Home");
	assert.equal(browser.page, `${server.url}/`);

	const posted = await browser.post("/form", { name: "Ada Lovelace", plan: "a&b" });
	assert.equal(asked[0].body, "name=Ada+Lovelace&plan=a%26b");
	assert.equal(asked[0].headers["content-type"], "application/x-www-form-urlencoded");
	assert.match(asked[0].headers.accept, /^text\/html/, "as a browser's plain form");
	assert.equal(asked[0].headers.origin, server.origin);
	assert.equal(asked[0].headers.referer, `${server.url}/`);
	assert.equal(asked[0].headers.cookie, "a=1; b=two%20words");
	assert.equal(posted.status, 303, "not followed");
	assert.equal(posted.location, "/");
	assert.deepEqual(browser.flash, { status: 400, body: "no" });
	assert.equal(browser.cookies.has("a"), false, "Max-Age=0 clears it");

	const followed = await posted.follow();
	assert.equal(followed.status, 200);
	assert.equal(asked[0].url, "/");

	await browser.submit("/form", { name: "Ada" });
	assert.equal(asked[0].headers["x-rocx-submission"], "1");
	assert.equal(asked[0].headers.accept, "application/json");

	const answer = await browser.json("/nowhere", { a: 1 }, "PUT");
	assert.deepEqual([asked[0].method, asked[0].headers["content-type"], asked[0].body, answer.status, answer.text], ["PUT", "application/json", '{"a":1}', 404, "nothing here"]);
	assert.throws(() => answer.follow(), /a 404 isn't a redirect/);
});

test("client: an endpoint read as a page reads it, its answer parsed; a refusal, thrown with its status", async () => {
	const browser = server.client();
	assert.deepEqual(await browser.read("/notes/count"), { n: 2 });
	assert.deepEqual([asked[0].method, asked[0].url, asked[0].headers.accept], ["GET", "/notes/count", "application/json"]);
	await assert.rejects(browser.read("/notes/secret"), (error) => error instanceof ReadError && error.status === 401 && error.message === "GET /notes/secret: 401 members only");
});

test("client: server-sent events, as they come, until the stream ends", async () => {
	const events = await server.client().events("/ticks");
	assert.equal(asked[0].headers.accept, "text/event-stream");
	assert.deepEqual(await events.take(5), [
		{ event: "message", data: "1", id: null },
		{ event: "named", data: "two\nlines", id: "7" },
		{ event: "message", data: "3", id: null },
	]);
	assert.equal(await events.next(), null);
	await assert.rejects(server.client().events("/nowhere"), /\/nowhere isn't a stream of events: 404 nothing here/);
	const seen = [];
	for await (const event of await server.client().events("/ticks")) {
		seen.push(event.data);
		if (seen.length === 2) break;
	}
	assert.deepEqual(seen, ["1", "two\nlines"], "a loop that stops hangs up");
});

test("mailbox: waited for by its fields, after the ones already there; links in it", async () => {
	mail = [{ to: "ada@example.com", subject: "Old", text: "", html: "" }];
	setTimeout(() => mail.push({ to: "ada@example.com", subject: "Welcome, Ada", text: "Go to https://notes.example/a?x=1, then.", html: "" }), 60);
	const found = await server.waitForMail({ to: "ada@example.com", subject: /^Welcome/ }, { after: 1 });
	assert.equal(found.subject, "Welcome, Ada");
	assert.deepEqual(links(found), ["https://notes.example/a?x=1"], "the comma after it isn't the link's");
	assert.deepEqual(links({ html: '<p>Hi <a href="/x">x</a> <a>no link</a> <a href="https://y.example">y</a></p>', text: "https://ignored.example" }), ["/x", "https://y.example"]);
	await assert.rejects(server.waitForMail({ subject: "Never" }, { ms: 100 }), /timed out after 100 ms waiting for the mail; the mailbox has: \[\{"to":"ada@example.com","subject":"Old"\},\{"to":"ada@example.com","subject":"Welcome, Ada"\}\]/);
});

test("until: the first truthy value, or a timeout that says what it waited for", async () => {
	let n = 0;
	assert.equal(await until(() => ++n >= 3 && n, { every: 1 }), 3);
	await assert.rejects(until(() => false, { ms: 30, what: "Godot" }), /timed out after 30 ms waiting for Godot/);
});

test("storyPath: a story's path, as rocx build names it", async () => {
	const { storyIds, STORIES_PATH } = await import(pathToFileURL(join(repo, "rocx-cli", "rocx.mjs")).href);
	const stories = [
		{ file: "Ui/Callout.rocx", module: "Ui/Callout", component: "Callout", name: "Tip", def: "story_tip", line: 6 },
		{ file: "stories/Landing.rocx", module: "stories/Landing", component: "Split", name: "Wide hero!", def: "story_wide_hero", line: 9 },
	];
	const ids = storyIds(stories).map((story) => `${STORIES_PATH}/${story.id}`);
	assert.deepEqual([storyPath("Ui/Callout", "Tip"), storyPath("stories/Landing", "Wide hero!", "Split")], ids);
});
