// The site's own script: says how long the page took to wake up, shows what the runtime does in a
// demo's inspector, and measures the demos that run every frame. The pages themselves are Roc: one
// app, which the server rendered and the browser hydrates (web/start.js loads the runtime and the
// wasm, hydrates the document and tells the page, `rocx:ready`). Each demo sits in an element that
// says which it is (`<div data-demo="echo">`); its inspector is `[data-inspect-signals="echo"]`.

// What the server answered as it rendered the page (`[[name, input, answer]]`: an endpoint's GET is
// `["GET /api/shelf", "", …]`), read before the runtime takes it out of the page: an inspector says
// which of its reads were answered from there.
const answered = JSON.parse(document.querySelector("script.rocx-answers")?.textContent || "[]");

document.addEventListener("rocx:ready", ({ detail: { runtime, ms } }) => {
	const demos = [...document.querySelectorAll("[data-demo]")];
	const watchers = new Map(demos.map((element) => [element.dataset.demo, watchDemo(element)]));
	const demoOf = (node) => (node instanceof Element ? node : node?.parentElement)?.closest?.("[data-demo]")?.dataset.demo;
	// A key, a click, a submit or a drop in a demo begins a turn: what it does, in every demo.
	for (const type of ["input", "click", "submit", "keydown", "drop"]) {
		document.addEventListener(
			type,
			({ target }) => {
				const demo = demoOf(target);
				if (!demo) return;
				last = demo;
				const button = target.closest?.("button");
				if (type === "keydown" || (type === "click" && !button)) return;
				begin(type === "click" ? `click “${button.textContent.trim()}”` : type === "drop" ? `drop on ${tagOf(target.closest?.("section, ul") ?? target)}` : `${type} on ${tagOf(target)}`, demo);
			},
			{ capture: true },
		);
	}
	// What the runtime does, told to the demo it happened in: where the node it touched is; for a
	// fetch or a stream, the demo that asked, which its answer is told to as well.
	const asking = new Map();
	const keyOf = (detail) => detail.url;
	const demoFor = (kind, detail) => {
		const here = [detail.node, ...(detail.nodes ?? [])].map(demoOf).find(Boolean);
		if (here) {
			if (kind === "frame") last = here;
			return here;
		}
		if (["fetch", "listen"].includes(kind)) {
			asking.set(keyOf(detail), last);
			return last;
		}
		if (["fetched", "heard", "unlisten"].includes(kind)) return asking.get(keyOf(detail)) ?? last;
		return last;
	};
	runtime.observer = new Proxy({}, { get: (_, kind) => (detail) => watchers.get(demoFor(kind, detail))?.[kind]?.(detail) });
	for (const [name, watcher] of watchers) watcher.hydrated(ms, answered.filter(([called]) => demoNamed(called) === name));
	document.documentElement.setAttribute("data-hydrated", "");
	awake(performance.now());
});

/** Which demo reads which endpoint as the page renders: the start of its URL, and the demo. */
const READS = [
	["/api/echo/", "echo"],
	["/api/shelf", "shelf"],
	["/api/reader", "bag"],
	["/api/planner", "planner"],
];

/** The demo a GET the page carried was read by (`GET /api/echo/hello`: `echo`), if a demo read it. */
const demoNamed = (called) => READS.find(([start]) => called.startsWith(`GET ${start}`))?.[1] ?? null;

/** The demo the reader last used, or that last ran a frame: what a call or an effect is told to
 * when nothing else says. */
let last = null;

/** How long the page took to wake up, where it says (`data-stat`): `total`, since it was asked for. */
function awake(total) {
	for (const element of document.querySelectorAll('[data-stat="ready"]')) {
		element.textContent = `Here, your browser fetched and compiled it and hydrated this page in ${total.toFixed(0)} ms.`;
	}
	for (const element of document.querySelectorAll('[data-stat="hydrated"]')) {
		element.textContent = `Awake ${total.toFixed(0)} ms after the page asked: fetching and compiling the wasm, then hydrating this page, the server's nodes kept.`;
		element.classList.add("awake");
	}
}

/** A live meter for a demo that runs every frame (`<p data-perf="birds">`): frames a second, and
 * what each cost, Roc and the patches it made together. */
const meters = new Map();
function frame(name, { ms, patches }) {
	document.dispatchEvent(new CustomEvent("rocx:frame", { detail: { demo: name, ms, patches } }));
	const element = document.querySelector(`[data-perf="${name}"]`);
	if (!element) return;
	const meter = meters.get(element) ?? { frames: 0, ms: 0, patches: 0, since: performance.now() };
	meters.set(element, meter);
	meter.frames += 1;
	meter.ms += ms;
	meter.patches += patches;
	const elapsed = performance.now() - meter.since;
	if (elapsed < 500) return;
	const rate = (meter.frames * 1000) / elapsed;
	element.textContent = `${rate.toFixed(0)} frames/s · ${((meter.ms / meter.frames) * 1000).toFixed(0)} µs each, in Roc and patching · ${(meter.patches / meter.frames).toFixed(1)} patches each`;
	meters.set(element, { frames: 0, ms: 0, patches: 0, since: performance.now() });
}

/** Restarts a highlight on an element: a ring that fades, in the colour of what happened. */
function flash(element, kind) {
	if (!(element instanceof Element)) return;
	const name = `signals-flash-${kind}`;
	element.classList.remove(name);
	void element.offsetWidth;
	element.classList.add(name);
	element.addEventListener("animationend", () => element.classList.remove(name), { once: true });
}

/** What a patched node is called: its element's tag. */
const tagOf = (node) => {
	const element = node instanceof Element ? node : node?.parentElement;
	return element ? `<${element.tagName.toLowerCase()}>` : "the page";
};

/** What the runtime is doing now, and why: a key, a click, a server's answer, in a demo. */
let cause = { id: 0, head: "update", demo: null };
const begin = (head, demo) => (cause = { id: cause.id + 1, head, demo });

/**
 * What the runtime does in one demo, on the page: what it reads from the page, asks the server
 * and patches, in the demo's inspector (`<div data-inspect-signals="echo">`), a turn at a time (a
 * key, a click, an answer), with what it patched highlighted where it is (`data-flash`).
 */
function watchDemo(element) {
	const name = element.dataset.demo;
	const list = document.querySelector(`[data-inspect-signals="${name}"] ol`);
	const flashing = element.hasAttribute("data-flash");
	let awake = false;
	let turn = null;

	/** A turn, newest first: what caused it, and a line per kind of thing it did, with how many times. */
	const start = () => {
		list.querySelector(".empty")?.remove();
		const item = document.createElement("li");
		const title = document.createElement("span");
		title.className = "event";
		title.textContent = cause.demo && cause.demo !== name ? `${cause.head}, in the ${cause.demo}` : cause.head;
		item.append(title);
		list.prepend(item);
		while (list.children.length > 30) list.lastElementChild.remove();
		turn = { item, lines: new Map(), cause: cause.id };
	};
	const line = (text, kind = "patch") => {
		if (!list) return;
		if (turn?.cause !== cause.id) start();
		const known = turn.lines.get(text);
		if (known) {
			known.count += 1;
			known.element.textContent = `${text} ×${known.count}`;
			return;
		}
		const span = document.createElement("span");
		span.className = kind;
		span.textContent = text;
		turn.item.append(span);
		turn.lines.set(text, { element: span, count: 1 });
	};
	const brief = (text) => (text.length > 48 ? `${text.slice(0, 47)}…` : text);

	return {
		frame: (detail) => frame(name, detail),
		fetch: ({ method, url, body }) => line(`→ ${method} ${url}${body ? ` ${brief(body)}` : ""}`, "wire"),
		fetched: ({ method, url, status, body, error, ms }) => {
			begin(`${method} ${url} answered in ${ms.toFixed(0)} ms`, name);
			line(error ? `✗ ${error}` : `← ${status} ${brief(body)}`, "wire");
		},
		listen: ({ url }) => line(`→ GET ${url}, listening to its events`, "wire"),
		submit: ({ method, url, input }) => line(`→ ${method ?? "POST"} ${url} ${brief(input)}, not waited for`, "wire"),
		submitted: ({ url, status, body, redirect, error, ms }) => {
			begin(`${url} answered in ${ms.toFixed(0)} ms`, name);
			line(error ? `✗ ${error}` : redirect ? `← ${status}, to ${redirect}` : `← ${status} ${brief(body)}`, "wire");
		},
		revalidate: ({ reads }) => line(`reading the page's ${reads === 1 ? "read" : `${reads} reads`} again, then the move is in`, "wire"),
		glide: ({ key }) => {
			if (awake) line(`glided${key ? ` ${key}` : ""} from its old place`);
		},
		effect: ({ name: called, arg }) => {
			document.dispatchEvent(new CustomEvent("rocx:effect", { detail: { demo: name, name: called, arg: JSON.parse(arg) } }));
			line(`called the page's ${called}(${brief(arg)})`, "wire");
		},
		heard: ({ url, heard }) => {
			begin(`${url} sent`, name);
			line(heard === "Ended" ? "← the end of the stream" : heard.Event !== undefined ? `← an event: ${brief(heard.Event)}` : `✗ ${brief(JSON.stringify(heard))}`, "wire");
		},
		patch: ({ kind, name, node }) => {
			// A node being made (a new row's, say) isn't patched: it is new.
			if (!awake || !node?.isConnected) return;
			const what = { text: "text in", attr: `${name} of`, flag: `${name} of`, class: `class:${name} on`, html: "markup in", root: "markup in" }[kind] ?? kind;
			line(`patched ${what} ${tagOf(node)}`);
			if (flashing && !(node instanceof HTMLInputElement)) flash(node instanceof Element ? node : node.parentElement, "patch");
		},
		row: ({ what, nodes }) => {
			if (!awake) return;
			line(`${what} a row`);
			if (flashing) for (const node of nodes) flash(node, what);
		},
		show: ({ holds, nodes }) => {
			if (!awake) return;
			line(`<Show> switched to ${holds ? "what is inside" : "its fallback"}`);
			if (flashing) for (const node of nodes) flash(node, "show");
		},
		/** Hydrated, with the page, in `ms`; `seeded`, the answers the page came with that are its own. */
		hydrated(ms, seeded) {
			awake = true;
			if (!list) return;
			begin(`hydrated with the page in ${ms.toFixed(1)} ms`, name);
			line("the server's nodes, kept", "patch");
			for (const [called] of seeded) line(`read ${called} from the page: not asked`, "wire");
		},
	};
}
