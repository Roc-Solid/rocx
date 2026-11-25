// A stand-in for Anthropic's Messages API, for packages/ai's tests: `POST /v1/messages` with
// `"stream": true`, answered with the server-sent events the API sends (message_start, each content
// block's start, deltas and stop, message_delta, message_stop), each event written in two pieces so
// the app's reader meets an event split across chunks. What it answers is what the test queued
// (`turn`, `fail`); with nothing queued, a turn that echoes the last user message. It keeps every
// request (`requests`: headers and body), and notes a stream the app closed before its end
// (`closed`). The real API is never asked.
//
//   const api = await standIn();     // ANTHROPIC_BASE_URL=api.url, ANTHROPIC_API_KEY=KEY
//   api.turn({ blocks: [{ type: "text", text: "Hi" }] });
import { createServer } from "node:http";

/** The key the stand-in takes (`x-api-key`); any other is a 401. */
export const KEY = "sk-ant-standin-0000";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The last user message's text. */
function lastUserText(body) {
	const user = [...(body.messages ?? [])].reverse().find((message) => message.role === "user");
	if (!user) return "";
	if (typeof user.content === "string") return user.content;
	return user.content.filter((block) => block.type === "text").map((block) => block.text).join("");
}

/** The events of a turn: `blocks` as the API streams them, then why it stopped. */
function eventsOf(turn, model) {
	const events = [{ type: "message_start", message: { id: `msg_${Math.random().toString(36).slice(2)}`, type: "message", role: "assistant", model: turn.model ?? model, content: [], stop_reason: null, usage: { input_tokens: 25, cache_creation_input_tokens: 0, cache_read_input_tokens: 12, output_tokens: 1 } } }];
	turn.blocks.forEach((block, index) => {
		if (block.type === "text") {
			events.push({ type: "content_block_start", index, content_block: { type: "text", text: "" } });
			for (const piece of block.text.match(/\S+\s*|\s+/g) ?? []) events.push({ type: "content_block_delta", index, delta: { type: "text_delta", text: piece } });
		} else if (block.type === "thinking") {
			events.push({ type: "content_block_start", index, content_block: { type: "thinking", thinking: "", signature: "" } });
			if (block.thinking) events.push({ type: "content_block_delta", index, delta: { type: "thinking_delta", thinking: block.thinking } });
			events.push({ type: "content_block_delta", index, delta: { type: "signature_delta", signature: block.signature } });
		} else if (block.type === "tool_use") {
			events.push({ type: "content_block_start", index, content_block: { type: "tool_use", id: block.id, name: block.name, input: {} } });
			const json = block.raw ?? JSON.stringify(block.input);
			const half = Math.floor(json.length / 2);
			for (const piece of [json.slice(0, half), json.slice(half)]) events.push({ type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: piece } });
		} else {
			events.push({ type: "content_block_start", index, content_block: block });
		}
		events.push({ type: "content_block_stop", index });
	});
	const details = turn.stop === "refusal" ? { type: "refusal", category: turn.category ?? null, explanation: null } : null;
	events.push({ type: "message_delta", delta: { stop_reason: turn.stop ?? "end_turn", stop_sequence: null, stop_details: details }, usage: { output_tokens: 42 } });
	events.push({ type: "message_stop" });
	return events;
}

export async function standIn() {
	const api = {
		url: "",
		/** Every request, oldest first: `{ headers, body }`. */
		requests: [],
		/** How many streams the app closed before their end. */
		closed: 0,
		/** What to answer next, in order. */
		queue: [],
		/** A turn to answer with: `{ blocks, stop, category, model, delayMs }`. */
		turn(turn) {
			api.queue.push({ kind: "turn", ...turn });
		},
		/** An error answer: its status, the error's type and message, and `retry-after`; or an error event in the stream (`inStream`). */
		fail(status, type, message, { retryAfter, inStream = false } = {}) {
			api.queue.push({ kind: "fail", status, type, message, retryAfter, inStream });
		},
		close: () => {},
	};
	const server = createServer((request, response) => {
		let text = "";
		request.on("data", (chunk) => (text += chunk));
		request.on("end", async () => {
			if (request.method !== "POST" || request.url !== "/v1/messages") {
				response.writeHead(404).end();
				return;
			}
			const body = JSON.parse(text);
			api.requests.push({ headers: request.headers, body });
			if (request.headers["x-api-key"] !== KEY) {
				response.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } }));
				return;
			}
			const next = api.queue.shift() ?? { kind: "turn", blocks: [{ type: "text", text: `You said: ${lastUserText(body)}` }] };
			if (next.kind === "fail" && !next.inStream) {
				const headers = { "content-type": "application/json" };
				if (next.retryAfter !== undefined) headers["retry-after"] = String(next.retryAfter);
				response.writeHead(next.status, headers).end(JSON.stringify({ type: "error", error: { type: next.type, message: next.message } }));
				return;
			}
			response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
			let ended = false;
			response.on("close", () => {
				if (!ended) api.closed += 1;
			});
			const events = next.kind === "fail" ? [{ type: "message_start", message: { id: "msg_x", model: body.model, usage: { input_tokens: 1, output_tokens: 0 } } }, { type: "error", error: { type: next.type, message: next.message } }] : eventsOf(next, body.model);
			for (const event of events) {
				if (response.destroyed) return;
				const written = `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
				const half = Math.floor(written.length / 2);
				response.write(written.slice(0, half));
				await sleep(next.delayMs ?? 1);
				if (response.destroyed) return;
				response.write(written.slice(half));
			}
			ended = true;
			response.end();
		});
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	api.url = `http://127.0.0.1:${server.address().port}`;
	api.close = () => new Promise((resolve) => {
		server.closeAllConnections();
		server.close(resolve);
	});
	return api;
}
