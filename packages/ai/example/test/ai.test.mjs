// packages/ai against a stand-in for Anthropic's Messages API (./stand-in.mjs): the example app (..)
// built, started with ANTHROPIC_BASE_URL pointed at the stand-in, and asked to chat (an assistant
// agent handing work to two others it uses as tools, one with the notes tools, over several turns,
// streamed), to sum up the notes (one answer, whole) and to read a meal into a record (structured
// outputs). Each test checks what the app sent the API as
// well as what it made of the answer. The real API is never asked.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testSqlite, until } from "../../../testing/index.mjs";
import { KEY, standIn } from "./stand-in.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

let built;
let api;
let app;
// The example names no database, so it is a SQLite one (D-105): a file of the tests' own, which a
// DATABASE_URL in the environment doesn't override.
const db = testSqlite({ prefix: "rocx-ai-" });

before(async () => {
	built = await buildForTests(dir, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	api = await standIn();
	app = await startServer(built.server, { database: db.url, statics: built.statics, env: { ANTHROPIC_API_KEY: KEY, ANTHROPIC_BASE_URL: api.url, ANTHROPIC_MODEL: "" } });
});

after(async () => {
	await app?.stop();
	await api?.close();
	await db.drop();
});

/** Says `text` in `chat`, and reads the answer's events until it is done: each event's data. */
async function say(client, chat, text) {
	const posted = await client.json(`/api/chat/${chat}`, { text });
	assert.equal(posted.status, 200, posted.text);
	const events = await client.events(`/api/chat/${chat}`);
	const heard = [];
	for (;;) {
		const event = await events.next();
		if (!event || event.event === "end") break;
		const data = JSON.parse(event.data);
		heard.push(data);
		if (data.done) break;
	}
	events.close();
	return heard;
}

/** The text of what was heard, and the status lines shown meanwhile (`agent|status`). */
const textOf = (heard) => heard.map((data) => data.text).join("");
const statusesOf = (heard) => heard.filter((data) => data.status).map((data) => `${data.agent}|${data.status}`);

test("the start says the default model (a call may name its own), and where the API is when it isn't Anthropic's", async () => {
	await until(() => JSON.stringify(app.logs()).includes("ai.model"), { ms: 5000 });
	assert.ok(JSON.stringify(app.logs()).includes(`default AI model: claude-opus-5-5, at ${api.url}`), JSON.stringify(app.logs()));
});

test("a chat: the assistant hands the note to the notes keeper, an agent it uses as a tool; its answer streams; the next turn sends the conversation back as it came", async () => {
	const client = app.client();
	const sent = api.requests.length;
	// The assistant: thinking, text, and the notes keeper handed a task.
	api.turn({
		blocks: [
			{ type: "thinking", thinking: "", signature: "sig-thinking-1" },
			{ type: "text", text: "I'll note that. " },
			{ type: "thinking", thinking: "Handing this to the notes keeper.", signature: "sig-progress-1" },
			{ type: "tool_use", id: "toolu_01", name: "notes_keeper", input: { task: "Add a note: Buy oat milk" } },
		],
		stop: "tool_use",
	});
	// The notes keeper, a conversation of its own: its tool, then its answer.
	api.turn({ blocks: [{ type: "tool_use", id: "toolu_k1", name: "add_note", input: { text: "Buy oat milk" } }], stop: "tool_use" });
	api.turn({ blocks: [{ type: "text", text: "Added note 1: Buy oat milk." }] });
	// The assistant again, with the keeper's answer.
	api.turn({ blocks: [{ type: "text", text: "Noted: buy oat milk." }] });
	const heard = await say(client, "c1", "Remember to buy oat milk");
	assert.equal(textOf(heard), "I'll note that. Noted: buy oat milk.");
	assert.deepEqual(
		statusesOf(heard),
		["assistant|Handing this to the notes keeper.", "assistant|Seeing to your notes…", "notes_keeper|Writing that down…"],
		"the assistant's progress note, then the agent it calls with what the agent says it does, then the keeper's own tool, passed up",
	);
	const done = heard.at(-1);
	assert.equal(done.done, true);
	assert.equal(done.problem, "");
	assert.deepEqual(done.notes, [{ id: 1, text: "Buy oat milk" }]);

	const [assistant1, keeper1, keeper2, assistant2] = api.requests.slice(sent).map((request) => request.body);
	const headers = api.requests[sent].headers;
	assert.equal(headers["anthropic-version"], "2026-10-21");
	assert.equal(headers["x-api-key"], KEY);
	assert.equal(headers["anthropic-beta"], "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18", "the fallback's beta, and the progress notes'");
	assert.equal(assistant1.model, "claude-opus-5-5");
	assert.equal(assistant1.stream, true);
	assert.equal(assistant1.max_tokens, 64000);
	assert.equal(assistant1.fallbacks, "default");
	assert.deepEqual(assistant1.cache_control, { type: "ephemeral" });
	assert.deepEqual(assistant1.output_config, { effort: "low" });
	assert.match(assistant1.system, /^You are the user's assistant/);
	assert.deepEqual(assistant1.thinking, { type: "adaptive", display: "updates" }, "updates asked for: the model's progress notes as text");
	assert.equal(assistant1.temperature, undefined);
	assert.deepEqual(assistant1.messages, [{ role: "user", content: [{ type: "text", text: "Remember to buy oat milk" }] }]);
	assert.deepEqual(assistant1.tools.map((tool) => tool.name), ["notes_keeper", "nutritionist"]);
	const keeperTool = assistant1.tools[0];
	assert.match(keeperTool.description, /^Keeps the user's notes/);
	assert.deepEqual(Object.keys(keeperTool.input_schema.properties), ["task"]);
	assert.deepEqual(keeperTool.input_schema.required, ["task"]);

	// The keeper: its own system prompt, tools and conversation, started from the task alone; asked
	// for its updates, as its caller listens.
	assert.match(keeper1.system, /You keep the user's notes/);
	assert.deepEqual(keeper1.thinking, { type: "adaptive", display: "updates" });
	assert.deepEqual(keeper1.messages, [{ role: "user", content: [{ type: "text", text: "Add a note: Buy oat milk" }] }]);
	assert.deepEqual(keeper1.tools.map((tool) => tool.name), ["list_notes", "add_note", "remove_note"]);
	const add = keeper1.tools.find((tool) => tool.name === "add_note");
	assert.equal(add.description, "Adds a note of the text given. Answers the note, with its id.");
	assert.deepEqual(add.input_schema, { type: "object", properties: { text: { type: "string" } }, required: ["text"] });
	assert.equal(add.eager_input_streaming, true);
	assert.deepEqual(keeper2.messages.at(-1), { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_k1", content: [{ type: "text", text: '{"id":1,"text":"Buy oat milk"}' }] }] });

	// The assistant's turn goes back exactly as it came, its thinking's signature too; then the keeper's answer.
	assert.deepEqual(assistant2.messages.slice(1), [
		{
			role: "assistant",
			content: [
				{ type: "thinking", thinking: "", signature: "sig-thinking-1" },
				{ type: "text", text: "I'll note that. " },
				{ type: "thinking", thinking: "Handing this to the notes keeper.", signature: "sig-progress-1" },
				{ type: "tool_use", id: "toolu_01", name: "notes_keeper", input: { task: "Add a note: Buy oat milk" } },
			],
		},
		{ role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_01", content: [{ type: "text", text: "Added note 1: Buy oat milk." }] }] },
	]);

	// Each agent's turns are on the log under its name.
	const labels = app.logs().filter((line) => line.msg === "ai.turn").map((line) => line.label);
	for (const name of ["assistant", "notes_keeper"]) assert.ok(labels.includes(name), JSON.stringify(labels));

	// The chat goes on: the whole conversation, then the new message.
	const third = api.requests.length;
	const again = await say(client, "c1", "Thanks");
	assert.equal(textOf(again), "You said: Thanks");
	const messages = api.requests[third].body.messages;
	assert.equal(messages.length, 5);
	assert.deepEqual(messages[3], { role: "assistant", content: [{ type: "text", text: "Noted: buy oat milk." }] });
	assert.deepEqual(messages[4], { role: "user", content: [{ type: "text", text: "Thanks" }] });
});

test("a turn cut off at max_tokens as it wrote a tool call: the call isn't run, and the conversation kept has no tool_use without its result, so the next turn can be sent", async () => {
	const client = app.client();
	const sent = api.requests.length;
	api.turn({ blocks: [{ type: "text", text: "Let me add " }, { type: "tool_use", id: "toolu_cut", name: "notes_keeper", input: { task: "Add a n" } }], stop: "max_tokens" });
	const heard = await say(client, "c-cut", "Remember the bread");
	assert.equal(textOf(heard), "Let me add ");
	assert.equal(heard.at(-1).problem, "");
	assert.equal(api.requests.length, sent + 1, "the cut call wasn't run: no agent was asked");
	api.turn({ blocks: [{ type: "text", text: "Sure, noted." }] });
	assert.equal(textOf(await say(client, "c-cut", "Go on")), "Sure, noted.");
	const next = api.requests.at(-1).body;
	assert.deepEqual(
		next.messages.map((message) => message.role),
		["user", "assistant", "user"],
	);
	const blocks = next.messages.flatMap((message) => (typeof message.content === "string" ? [] : message.content));
	assert.ok(!blocks.some((block) => block.type === "tool_use"), JSON.stringify(next.messages));
	assert.ok(blocks.some((block) => block.type === "text" && block.text === "Let me add "), "what it wrote before it was cut off is kept");
});

test("a tool's refusal, arguments that don't fit, input that isn't JSON and an agent given no task go back to the model as tool errors", async () => {
	const sent = api.requests.length;
	api.turn({
		blocks: [
			{ type: "tool_use", id: "toolu_k", name: "notes_keeper", input: { task: "Tidy up the notes" } },
			{ type: "tool_use", id: "toolu_n", name: "nutritionist", input: {} },
		],
		stop: "tool_use",
	});
	api.turn({
		blocks: [
			{ type: "tool_use", id: "toolu_a", name: "remove_note", input: { id: 99 } },
			{ type: "tool_use", id: "toolu_b", name: "add_note", input: { words: "no text field" } },
			{ type: "tool_use", id: "toolu_c", name: "add_note", raw: '{"text": "cut off' },
			{ type: "tool_use", id: "toolu_d", name: "delete_everything", input: {} },
		],
		stop: "tool_use",
	});
	api.turn({ blocks: [{ type: "text", text: "Those didn't work." }] });
	api.turn({ blocks: [{ type: "text", text: "I couldn't tidy up." }] });
	const heard = await say(app.client(), "c2", "Tidy up");
	assert.equal(textOf(heard), "I couldn't tidy up.");
	assert.deepEqual(statusesOf(heard), [
		"assistant|Seeing to your notes…",
		"notes_keeper|Crossing it out…",
		"notes_keeper|Writing that down…",
		"notes_keeper|Writing that down…",
		"assistant|Counting the calories…",
	], "each tool as it starts to run, in order, the keeper's passed up; none for a tool the app doesn't have");
	assert.equal(api.requests.length, sent + 4, "the nutritionist, given no task, never asked the API");

	const keeper2 = api.requests[sent + 2].body;
	assert.deepEqual(keeper2.messages[1].content[2], { type: "tool_use", id: "toolu_c", name: "add_note", input: {} });
	const results = keeper2.messages[2].content;
	assert.deepEqual(results.map((result) => [result.tool_use_id, result.is_error]), [["toolu_a", true], ["toolu_b", true], ["toolu_c", true], ["toolu_d", true]]);
	assert.equal(results[0].content[0].text, "There is no note 99.");
	assert.match(results[1].content[0].text, /^Invalid arguments for add_note/);
	assert.equal(results[2].content[0].text, 'The input for add_note wasn\'t JSON: {"text": "cut off');
	assert.equal(results[3].content[0].text, "There is no tool named delete_everything.");

	const assistant2 = api.requests[sent + 3].body.messages.at(-1).content;
	assert.deepEqual(assistant2, [
		{ type: "tool_result", tool_use_id: "toolu_k", content: [{ type: "text", text: "Those didn't work." }] },
		{ type: "tool_result", tool_use_id: "toolu_n", content: [{ type: "text", text: "nutritionist needs a task: what to do, in words." }], is_error: true },
	]);
});

test("an agent that fails is a tool error its caller can act on", async () => {
	const sent = api.requests.length;
	api.turn({ blocks: [{ type: "tool_use", id: "toolu_x", name: "nutritionist", input: { task: "Two eggs" } }], stop: "tool_use" });
	api.fail(400, "invalid_request_error", "messages: too long");
	api.turn({ blocks: [{ type: "text", text: "The nutritionist is out." }] });
	const heard = await say(app.client(), "c4", "What's in two eggs?");
	assert.equal(textOf(heard), "The nutritionist is out.");
	const result = api.requests[sent + 2].body.messages.at(-1).content[0];
	assert.equal(result.is_error, true);
	assert.equal(result.content[0].text, "nutritionist couldn't do it: the API answered 400: invalid_request_error: messages: too long");
});

test("the notes summed up: one answer, whole", async () => {
	const sent = api.requests.length;
	api.turn({ blocks: [{ type: "thinking", thinking: "", signature: "s" }, { type: "text", text: "You need oat milk." }] });
	const answer = await app.client().json("/api/notes/summary", {});
	assert.equal(answer.status, 200, answer.text);
	assert.deepEqual(answer.json(), { text: "You need oat milk." });
	const body = api.requests[sent].body;
	assert.equal(body.system, "Sum up these notes for the person who wrote them, in one plain sentence that speaks to them as you.");
	assert.equal(body.thinking, undefined, "no updates asked for: nothing about thinking sent");
	assert.equal(api.requests[sent].headers["anthropic-beta"], "server-side-fallback-2026-07-01");
	assert.deepEqual(body.messages, [{ role: "user", content: [{ type: "text", text: "- Buy oat milk" }] }]);
	assert.equal(body.tools, undefined);
});

test("a meal read into a record: the schema the API is sent, and the answer read into the type", async () => {
	const sent = api.requests.length;
	api.turn({ blocks: [{ type: "text", text: '{"items":[{"food":"egg","grams":100,"kcal":143},{"food":"toast","grams":30,"kcal":80}],"total_kcal":223}' }] });
	const answer = await app.client().json("/api/meal", { text: "two eggs and toast" });
	assert.equal(answer.status, 200, answer.text);
	assert.deepEqual(answer.json(), { items: [{ food: "egg", grams: 100, kcal: 143 }, { food: "toast", grams: 30, kcal: 80 }], total_kcal: 223 });
	const format = api.requests[sent].body.output_config;
	assert.equal(format.effort, "low");
	assert.deepEqual(format.format, {
		type: "json_schema",
		schema: {
			type: "object",
			properties: {
				items: { type: "array", items: { type: "object", properties: { food: { type: "string" }, grams: { type: "integer" }, kcal: { type: "integer" } }, required: ["food", "grams", "kcal"], additionalProperties: false } },
				total_kcal: { type: "integer" },
			},
			required: ["items", "total_kcal"],
			additionalProperties: false,
		},
	});
});

test("an answer that doesn't fit the type is a problem the app can say, not a crash", async () => {
	api.turn({ blocks: [{ type: "text", text: '{"items":[{"food":"egg","grams":-5,"kcal":1}],"total_kcal":1}' }] });
	const answer = await app.client().json("/api/meal", { text: "an egg" });
	assert.equal(answer.status, 502);
	assert.match(answer.text, /the answer didn't fit its type/);
});

test("a 429 is tried again after retry-after; a 400 isn't", async () => {
	const sent = api.requests.length;
	api.fail(429, "rate_limit_error", "Slow down", { retryAfter: 0 });
	api.turn({ blocks: [{ type: "text", text: "Fine now." }] });
	const answer = await app.client().json("/api/notes/summary", {});
	assert.deepEqual(answer.json(), { text: "Fine now." });
	assert.equal(api.requests.length, sent + 2);
	assert.ok(app.logs().some((line) => line.msg === "ai.retry" || JSON.stringify(line).includes("ai.retry")), JSON.stringify(app.logs().slice(-5)));

	api.fail(400, "invalid_request_error", "max_tokens: too large");
	const refused = await app.client().json("/api/notes/summary", {});
	assert.equal(refused.status, 502);
	assert.match(refused.text, /the API answered 400: invalid_request_error: max_tokens: too large/);
	assert.equal(api.requests.length, sent + 3);
});

test("an overloaded stream before any text is tried again", async () => {
	const sent = api.requests.length;
	api.fail(200, "overloaded_error", "Overloaded", { inStream: true });
	api.turn({ blocks: [{ type: "text", text: "Back." }] });
	const answer = await app.client().json("/api/notes/summary", {});
	assert.deepEqual(answer.json(), { text: "Back." });
	assert.equal(api.requests.length, sent + 2);
});

test("a refusal is the app's to say", async () => {
	api.turn({ blocks: [], stop: "refusal", category: "cyber" });
	const answer = await app.client().json("/api/notes/summary", {});
	assert.equal(answer.status, 502);
	assert.match(answer.text, /the model declined \(cyber\)/);
});

test("a page that goes stops the model: the API's stream is closed before its end", async () => {
	const client = app.client();
	const before = api.closed;
	api.turn({ blocks: [{ type: "text", text: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen" }], delayMs: 150 });
	await client.json("/api/chat/c3", { text: "Count slowly" });
	const events = await client.events("/api/chat/c3");
	const first = await events.next();
	assert.ok(first, "an event before hanging up");
	events.close();
	await until(() => api.closed > before, { ms: 5000 });
});

test("each turn is logged: its model, why it stopped, its tokens", async () => {
	const turns = app.logs().filter((line) => JSON.stringify(line).includes("ai.turn"));
	assert.ok(turns.length >= 5, JSON.stringify(turns));
	const line = JSON.stringify(turns[0]);
	for (const part of ['"model":"claude-opus-5-5"', '"input":25', '"output":42', '"cache_read":12']) assert.ok(line.includes(part), line);
});
