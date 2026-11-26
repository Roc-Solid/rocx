// spike/wasm-engine: the page's side of native/core's engine run as the browser's host
// (native/core/src/web.rs). The engine keeps the reactive graph and its own document in the wasm;
// after each flush it sends what changed as one batch of ops (dom.rs's `ops`), which this makes on
// the page's DOM. An event is sent to the engine's node it happened on (the engine bubbles it), and
// a call into Roc is guarded here (`js_guarded`): a crash or a read that waits throws through the
// wasm frames (`js_escape`), and the shadow stack is put back.
//
// A spike: it renders the page afresh (no hydration), keeps the server's <head>, and knows no SVG,
// requests or timers yet.

const decoder = new TextDecoder();
const encoder = new TextEncoder();
const ESCAPE = Symbol("rocx escape");
const LAST = 0xffffffff;

export async function start(source, path = location.pathname) {
	let ex;
	const nodes = [];
	const templates = [];
	const ids = new WeakMap();
	const text = (ptr, len) => decoder.decode(new Uint8Array(ex.memory.buffer, ptr, len));
	const env = {
		js_log: (level, ptr, len) => console[["debug", "info", "warn", "error"][level] ?? "log"](text(ptr, len)),
		js_apply: (ptr, len) => apply(new Uint8Array(ex.memory.buffer, ptr, len)),
		js_guarded: (call, data) => {
			const sp = ex.__stack_pointer.value;
			try {
				ex.rocx_call(call, data);
				return 0;
			} catch (error) {
				if (error !== ESCAPE) throw error;
				ex.__stack_pointer.value = sp;
				return 1;
			}
		},
		js_escape: () => {
			throw ESCAPE;
		},
	};
	const response = await source;
	const { instance } =
		response instanceof Response && response.headers.get("content-type")?.startsWith("application/wasm")
			? await WebAssembly.instantiateStreaming(response, { env })
			: await WebAssembly.instantiate(response instanceof Response ? await response.arrayBuffer() : response, { env });
	ex = instance.exports;

	// The engine's document is the page's: its html, head and body are the page's own (the head
	// as the server wrote it, the body emptied: rendered afresh).
	const own = { html: document.documentElement, head: document.head, body: document.body };
	const kept = new Set([document.documentElement, document.head]);

	function make(id, tag) {
		if (tag === "rocx-root") return document.createDocumentFragment();
		const node = own[tag] ?? document.createElement(tag);
		if (tag === "body") node.replaceChildren();
		ids.set(node, id);
		return node;
	}

	// A flush's ops (dom.rs's `ops`): their length, the ops, then their strings, decoded at once, each
	// op's string its length in UTF-16 units from where the last ended.
	function apply(bytes) {
		const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
		const end = 4 + view.getUint32(0, true);
		const texts = decoder.decode(bytes.subarray(end));
		let at = 4;
		let read = 0;
		const u32 = () => {
			const value = view.getUint32(at, true);
			at += 4;
			return value;
		};
		const str = () => {
			const units = u32();
			return texts.slice(read, (read += units));
		};
		while (at < end) {
			const op = bytes[at++];
			switch (op) {
				case 1: {
					const id = u32();
					nodes[id] = make(id, str());
					break;
				}
				case 2: {
					const id = u32();
					nodes[id] = document.createTextNode(str());
					break;
				}
				case 3:
					nodes[u32()] = document.createComment("");
					break;
				case 4:
					nodes[u32()] = document.createDocumentFragment();
					break;
				case 5: {
					const parent = nodes[u32()];
					const node = nodes[u32()];
					const before = u32();
					// The page's own <html>, <head> and <body> are where they are; the head the server's.
					if (kept.has(node) || node === document.body || (kept.has(parent) && parent === document.head)) break;
					if (parent === document.documentElement) break;
					parent.insertBefore(node, before === LAST ? null : nodes[before]);
					break;
				}
				case 6:
					nodes[u32()]?.remove?.();
					break;
				case 7: {
					const id = u32();
					nodes[id].data = str();
					break;
				}
				case 8: {
					const id = u32();
					const name = str();
					const value = str();
					if (!kept.has(nodes[id])) nodes[id].setAttribute(name, value);
					break;
				}
				case 9: {
					const id = u32();
					nodes[id].removeAttribute(str());
					break;
				}
				case 10: {
					const id = u32();
					const name = str();
					const value = str();
					value ? nodes[id].style.setProperty(name, value) : nodes[id].style.removeProperty(name);
					break;
				}
				case 11:
					nodes[u32()] = undefined;
					break;
				case 12: {
					// A template's skeleton, as markup: its first node, to copy.
					const id = u32();
					const template = document.createElement("template");
					template.innerHTML = str();
					templates[id] = template.content.firstChild;
					break;
				}
				case 13: {
					// A copy of one, its nodes the engine's ids in document order.
					const root = templates[u32()].cloneNode(true);
					const count = u32();
					let node = root;
					for (let i = 0; i < count; i++) {
						const id = u32();
						nodes[id] = node;
						if (node.nodeType === 1) ids.set(node, id);
						if (node.firstChild) node = node.firstChild;
						else {
							while (node !== root && !node.nextSibling) node = node.parentNode;
							node = node === root ? null : node.nextSibling;
						}
					}
					break;
				}
				case 14: {
					const old = nodes[u32()];
					old.replaceWith(nodes[u32()]);
					break;
				}
				default:
					throw new Error(`rocx engine: op ${op} at ${at - 1}`);
			}
		}
	}

	function send(id, name, value) {
		const named = encoder.encode(name);
		const said = encoder.encode(value);
		// The scratch first: making room may grow the memory, which detaches the buffer read before.
		const ptr = ex.rocx_scratch(named.length + said.length);
		const into = new Uint8Array(ex.memory.buffer, ptr, named.length + said.length);
		into.set(named);
		into.set(said, named.length);
		ex.rocx_event(id, named.length, said.length);
	}

	for (const type of ["click", "input", "change", "keydown", "submit"]) {
		document.addEventListener(type, (event) => {
			for (const node of event.composedPath()) {
				const id = ids.get(node);
				if (id === undefined) continue;
				const target = event.target;
				const value = type === "keydown" ? event.key : target?.type === "checkbox" ? String(target.checked) : String(target?.value ?? "");
				send(id, type, value);
				return;
			}
		});
	}

	const where = encoder.encode(path);
	const ptr = ex.rocx_scratch(where.length);
	new Uint8Array(ex.memory.buffer, ptr, where.length).set(where);
	ex.rocx_start(where.length);
	return ex;
}
