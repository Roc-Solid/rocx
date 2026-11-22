// The app's MCP server (/mcp) as an AI client talks to it: JSON-RPC over Streamable HTTP, with a
// personal access token. The handshake, the tools listed with their hints, each tool called, the
// resources and prompts; refused without a token, writes refused to a read-only one, another
// person's notes out of reach, and the limit on calls.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { bearer, makeToken, noDatabase, noteIds, signIn, started } from "./app.mjs";

describe("Notes over MCP", { skip: noDatabase }, () => {
	let running, app, db, ada, writer, reader;
	before(async () => {
		// 40 calls a minute for each token here, so the limit's test can reach it.
		running = await started({ env: { NOTES_MCP_PER_MINUTE: "40" } });
		({ app, db } = running);
		ada = await signIn(app, "ada@example.com");
		writer = await makeToken(ada, "Claude", "write");
		reader = await makeToken(ada, "Inspector", "read");
	});
	after(() => running?.stop());

	let next = 1;
	/** A JSON-RPC request to /mcp with `token` (none: `null`): the HTTP answer. */
	const ask = (token, method, params = {}) => {
		const client = token ? bearer(app, token) : app.client();
		return client.json("/mcp", { jsonrpc: "2.0", id: next++, method, params }, "POST", { accept: "application/json, text/event-stream" });
	};
	/** A JSON-RPC request's result (or its error, for a test to see). */
	const rpc = async (token, method, params = {}) => {
		const answer = await ask(token, method, params);
		assert.equal(answer.status, 200, answer.text);
		const message = answer.json();
		return message.result ?? { error: message.error };
	};
	/** A tool's answer: what it says (its structured content) or, for a tool error, why. */
	const call = async (token, name, args) => {
		const result = await rpc(token, "tools/call", { name, arguments: args });
		return result.isError ? { refused: result.content[0].text } : result.structuredContent;
	};

	test("initialize: the server, its version, what it offers, and how to use it", async () => {
		const result = await rpc(writer, "initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } });
		assert.equal(result.protocolVersion, "2025-11-25");
		assert.deepEqual(result.serverInfo, { name: "acme-notes", title: "Notes", version: "1.0.0" });
		assert.deepEqual(Object.keys(result.capabilities).sort(), ["prompts", "resources", "tools"]);
		assert.match(result.instructions, /search_notes/);
		const initialized = await bearer(app, writer).json("/mcp", { jsonrpc: "2.0", method: "notifications/initialized" }, "POST", { accept: "application/json, text/event-stream" });
		assert.equal(initialized.status, 202);
	});

	test("tools/list: six tools, those that only read marked so, each with its schemas", async () => {
		const { tools } = await rpc(writer, "tools/list");
		assert.deepEqual(tools.map((tool) => tool.name), ["search_notes", "read_note", "create_note", "append_to_note", "tag_note", "archive_note"]);
		const hints = Object.fromEntries(tools.map((tool) => [tool.name, tool.annotations ?? {}]));
		assert.equal(hints.search_notes.readOnlyHint, true);
		assert.equal(hints.read_note.readOnlyHint, true);
		for (const name of ["create_note", "append_to_note", "tag_note", "archive_note"]) assert.notEqual(hints[name].readOnlyHint, true, name);
		assert.equal(hints.create_note.destructiveHint, false);
		assert.equal(hints.tag_note.idempotentHint, true);
		const create = tools.find((tool) => tool.name === "create_note");
		assert.deepEqual(create.inputSchema.required.sort(), ["body", "tags", "title"]);
		assert.equal(create.inputSchema.properties.tags.type, "array");
		assert.equal(tools.find((tool) => tool.name === "archive_note").inputSchema.properties.archived.type, "boolean");
		// An endpoint with an id in its path: the id is an argument, beside its body's fields.
		const schema = (name) => tools.find((tool) => tool.name === name).inputSchema;
		assert.deepEqual(schema("read_note"), { type: "object", properties: { id: { type: "string" } }, required: ["id"] });
		assert.deepEqual(schema("append_to_note").required, ["id", "text"]);
		assert.deepEqual(Object.keys(schema("tag_note").properties), ["id", "tags"]);
		assert.equal(tools.find((tool) => tool.name === "read_note").outputSchema.properties.title.type, "string");
	});

	test("tools/call: search, read, create, append, tag and archive, as the token's person", async () => {
		const found = await call(writer, "search_notes", { query: "sourdough OR loaf" });
		assert.deepEqual(found.result.map((note) => note.title), ["Sourdough schedule"]);
		const id = found.result[0].id;

		const note = await call(writer, "read_note", { id });
		assert.match(note.body, /stretch and folds/);
		assert.deepEqual(note.tags, ["kitchen"]);

		const made = await call(writer, "create_note", { title: "Ideas from the call", body: "- Try rye flour", tags: ["Kitchen", "ideas"] });
		assert.deepEqual([made.title, made.tags], ["Ideas from the call", ["kitchen", "ideas"]]);
		const added = await call(writer, "append_to_note", { id: made.id, text: "- Ask about the oven" });
		assert.equal(added.body, "- Try rye flour\n\n- Ask about the oven");
		assert.deepEqual((await call(writer, "tag_note", { id: made.id, tags: ["baking"] })).tags, ["baking"]);
		assert.equal((await call(writer, "archive_note", { id: made.id, archived: true })).archived, true);
		assert.deepEqual((await call(writer, "search_notes", { query: "rye" })).result.map((each) => [each.title, each.archived]), [["Ideas from the call", true]]);

		// What a page shows is what the agent wrote.
		assert.equal((await ada.read(`/notes/${made.id}`)).note.body, "- Try rye flour\n\n- Ask about the oven");
		const [row] = await db.sql`select n.title from notes n join people p on p.id = n.person_id where n.id = ${made.id} and p.email = 'ada@example.com'`;
		assert.equal(row.title, "Ideas from the call");
	});

	test("a tool's refusal goes back to the model, saying why", async () => {
		assert.deepEqual(await call(writer, "create_note", { title: "", body: "", tags: [] }), { refused: "A note needs a title." });
		assert.deepEqual(await call(writer, "read_note", { id: "99999999" }), { refused: "Not found" });
		assert.match((await call(writer, "tag_note", { id: "1", tags: ["not a tag"] })).refused, /letters, digits and dashes/);
		assert.match((await call(writer, "read_note", { id: 12 })).refused, /id/);
		const unknown = await rpc(writer, "tools/call", { name: "delete_everything", arguments: {} });
		assert.ok(unknown.error, JSON.stringify(unknown));
	});

	test("no token, a bad one, or a browser's cookie alone: 401, before anything is read", async () => {
		const none = await ask(null, "tools/list");
		assert.equal(none.status, 401);
		assert.match(none.headers.get("www-authenticate"), /^Bearer/);
		assert.equal((await ask("acme_pat_not-a-real-one", "tools/list")).status, 401);
		assert.equal((await ask(`acme_pat_${"A".repeat(43)}`, "tools/list")).status, 401);
		const cookie = await ada.json("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/list" }, "POST", { accept: "application/json, text/event-stream" });
		assert.equal(cookie.status, 401, "an AI client needs a token of its own");
	});

	test("a read-only token searches and reads, and every write is refused", async () => {
		const ids = await noteIds(db, "ada@example.com");
		assert.ok((await call(reader, "search_notes", { query: "launch" })).result.length > 0);
		assert.equal((await call(reader, "read_note", { id: ids["Shed ideas"] })).title, "Shed ideas");
		const before = await db.sql`select id, body, tags, archived from notes order by id`;
		const refusal = "This token can only read. Make one that may write in Settings.";
		assert.deepEqual(await call(reader, "create_note", { title: "Nope", body: "", tags: [] }), { refused: refusal });
		assert.deepEqual(await call(reader, "append_to_note", { id: ids["Shed ideas"], text: "Nope" }), { refused: refusal });
		assert.deepEqual(await call(reader, "tag_note", { id: ids["Shed ideas"], tags: [] }), { refused: refusal });
		assert.deepEqual(await call(reader, "archive_note", { id: ids["Shed ideas"], archived: true }), { refused: refusal });
		assert.deepEqual(await db.sql`select id, body, tags, archived from notes order by id`, before, "nothing changed");
	});

	test("another person's notes are out of reach of a token: its tools, its resources, its prompts", async () => {
		const theirs = (await noteIds(db, "bo@example.com"))["Telemetry dashboard"];
		assert.deepEqual(await call(writer, "read_note", { id: theirs }), { refused: "Not found" });
		assert.deepEqual(await call(writer, "append_to_note", { id: theirs, text: "hello" }), { refused: "Not found" });
		assert.deepEqual(await call(writer, "archive_note", { id: theirs, archived: true }), { refused: "Not found" });
		assert.ok(!(await call(writer, "search_notes", { query: "telemetry" })).result.some((note) => note.id === theirs));
		const read = await rpc(writer, "resources/read", { uri: `notes://note/${theirs}` });
		assert.ok(read.error, JSON.stringify(read));
		const prompt = await rpc(writer, "prompts/get", { name: "summarize_note", arguments: { id: theirs } });
		assert.ok(prompt.error || prompt.isError || !JSON.stringify(prompt).includes("Altitude"), JSON.stringify(prompt));
		const [row] = await db.sql`select body, archived from notes where id = ${theirs}`;
		// SQLite keeps a boolean as 1 or 0, which is what node:sqlite reads.
		assert.deepEqual([row.body.includes("hello"), row.archived], [false, 0]);
	});

	test("resources: the index, and each note as Markdown", async () => {
		const { resources } = await rpc(writer, "resources/list");
		assert.deepEqual(resources.map((each) => each.uri), ["notes://index"]);
		const { resourceTemplates } = await rpc(writer, "resources/templates/list");
		assert.deepEqual(resourceTemplates.map((each) => each.uriTemplate), ["notes://note/{id}"]);

		const index = (await rpc(writer, "resources/read", { uri: "notes://index" })).contents[0];
		assert.equal(index.mimeType, "text/markdown");
		assert.match(index.text, /^# Your notes\n\n- \[Trip to the coast\]\(notes:\/\/note\/\d+\) \(pinned\) #travel #weekend/);
		assert.ok(!index.text.includes("Old flat"), "archived notes aren't listed");

		const id = (await noteIds(db, "ada@example.com"))["Shed ideas"];
		const note = (await rpc(writer, "resources/read", { uri: `notes://note/${id}` })).contents[0];
		assert.equal(note.uri, `notes://note/${id}`);
		assert.match(note.text, /^# Shed ideas\n\nTags: #home #ideas\n\nThe shed could be a workshop/);
	});

	test("prompts: summarize a note, and capture text as one", async () => {
		const { prompts } = await rpc(writer, "prompts/list");
		assert.deepEqual(prompts.map((prompt) => prompt.name), ["summarize_note", "capture"]);
		const id = (await noteIds(db, "ada@example.com"))["Reading list"];
		const summary = await rpc(writer, "prompts/get", { name: "summarize_note", arguments: { id } });
		assert.equal(summary.description, "Summarize “Reading list”");
		assert.match(summary.messages[0].content.text, /# Reading list/);
		const capture = await rpc(writer, "prompts/get", { name: "capture", arguments: { text: "call the plumber", tags: "home" } });
		assert.match(capture.messages[0].content.text, /create_note[\s\S]*call the plumber/);
		const missing = await rpc(writer, "prompts/get", { name: "summarize_note", arguments: {} });
		assert.ok(missing.error, JSON.stringify(missing));
	});

	test("calls are limited for each token: past the limit, 429, and other tokens go on", async () => {
		const busy = await makeToken(ada, "Busy agent", "read");
		let refused = null;
		for (let sent = 0; sent < 60 && !refused; sent++) {
			const answer = await ask(busy, "tools/list");
			if (answer.status === 429) refused = { sent, answer };
			else assert.equal(answer.status, 200, answer.text);
		}
		assert.ok(refused, "never refused");
		assert.equal(refused.sent, 40);
		assert.match(refused.answer.headers.get("retry-after"), /^\d+$/);
		assert.equal((await ask(reader, "tools/list")).status, 200);
	});
});
