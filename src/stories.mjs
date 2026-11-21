// Stories: the ways a component looks, written beside it (`<story name="Tip">…</story>` in its
// block), and a dev build's catalog of them at /__rocx/stories, Storybook's job. The transpiler
// makes each story a definition in its place (`story_tip`), which every build checks and only a
// dev build (`rocx build --dev`) calls: Generated/Routes answers /__rocx/stories/<id> with the
// story in the app's layout, and /__rocx/stories with this file's catalog, a page of its own.
//
// A story is a component's. An app's stories/ directory holds modules of stories alone, of drafts
// beside one another (`stories/Landing.rocx`): a dev build compiles them for their stories, and the
// app's own build skips the directory, so nothing in it (its <style>s neither) is published.

import { MARKER, rocString } from "./transpile.mjs";

/** Where the catalog is, and each story under it: a dev build's, beside the host's `/__rocx/mail`. */
export const STORIES_PATH = "/__rocx/stories";

/** An app's directory of modules that hold stories alone (`stories/Landing.rocx`, drafts beside one
 * another): a dev build compiles them, and another build skips the directory, its styles too. */
export const STORIES_DIR = "stories";

const kebab = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");

/**
 * Each story (`{ file, module, component, name, def, line }`, as rocx build finds them) with its
 * id, the rest of its URL: the module's path, the component's name unless it is the module's
 * (`Ui/Callout/tip`, `stories/Landing/Split/hero`), and its name. Throws when two would be one.
 */
export function storyIds(stories) {
	const seen = new Map();
	return stories.map((story) => {
		const last = story.module.split("/").pop();
		const id = [story.module, ...(story.component === last ? [] : [story.component]), kebab(story.name)].join("/");
		const other = seen.get(id);
		if (other) throw new Error(`${story.file}:${story.line}: the story "${story.name}" would be at ${STORIES_PATH}/${id}, as ${other.file}:${other.line}'s is: rename one`);
		const placed = { ...story, id, alias: `Story${story.module.split("/").map((part) => part.replace(/(^|[^A-Za-z0-9])([a-z0-9])/g, (_, __, c) => c.toUpperCase()).replace(/[^A-Za-z0-9]/g, "")).join("")}` };
		seen.set(id, placed);
		return placed;
	});
}

/** Generated/Stories.roc: the catalog's page, which Generated/Routes answers /__rocx/stories with. */
export function storiesModule(stories, { title = "app", root = process.cwd() } = {}) {
	const html = catalogHtml(stories, { title, root });
	return [
		"## A dev build's catalog of the app's stories (`<story>` in a component's block): the page",
		"## Generated/Routes answers /__rocx/stories with. Written by rocx build --dev.",
		"Stories := [].{",
		"\tcatalog : Str",
		`\tcatalog = Str.join_with([\n${html.split("\n").map((line) => `\t\t${rocString(line)},`).join("\n")}\n\t], "\\n")`,
		"}",
		"",
		`${MARKER} the app's stories: rocx build --dev writes it.`,
		"",
	].join("\n");
}

const escapeHtml = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");


// The catalog's icons: lines on a 24-unit grid, drawn in the text's colour.
const icon = (paths) => `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
const ICONS = {
	panel: icon('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>'),
	search: icon('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
	expand: icon('<path d="M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4"/>'),
	shrink: icon('<path d="M9 4v4a1 1 0 0 1-1 1H4M20 9h-4a1 1 0 0 1-1-1V4M15 20v-4a1 1 0 0 1 1-1h4M4 15h4a1 1 0 0 1 1 1v4"/>'),
	component: icon('<path d="M12 3 20 7.5v9L12 21l-8-4.5v-9Z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/>'),
	draft: icon('<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M9 21V9"/>'),
	book: icon('<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5Z"/><path d="M4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/>'),
};

/**
 * The catalog: the stories down the side in two parts, each by component: drafts, the modules in
 * stories/ (whole pages, so few), then components' (`<story>` in a component's block), each part
 * with its icon and colour; the one picked (the URL's hash) in a frame, with its kind and where it
 * is written; or a component's stories side by side. The frame can fill
 * the window (full screen: F, and Esc or the button in its corner to come back), and the side can
 * fold away (S). Both stay as they were when a rebuild reloads the page. A page of its own (it
 * isn't the app's), whose script needs nothing but the list it is given.
 */
export function catalogHtml(stories, { title = "app", root = process.cwd() } = {}) {
	const kindOf = (file) => (file.startsWith(`${STORIES_DIR}/`) ? "draft" : "component");
	// Drafts first, the order they are listed and walked (↑↓) in; otherwise as rocx build found them.
	const list = stories
		.map(({ id, file, component, name, line }) => ({ id, file, component, name, line, kind: kindOf(file), path: `${root}/${file}` }))
		.sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "draft" ? -1 : 1));
	// In a <script>, `</` would end it: JSON may have it in a name.
	const data = JSON.stringify(list).replace(/</g, "\\u003c");
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stories · ${escapeHtml(title)}</title>
<meta name="color-scheme" content="light dark">
<style>
:root {
	--bg: #f4f4f7; --side: #fbfbfd; --panel: #ffffff; --ink: #18171f; --muted: #66636f; --faint: #9a97a6;
	--rule: #e6e5ec; --hover: #efeef4; --accent: #7c5cff; --accent-ink: #5a3fd6; --accent-soft: #efeaff;
	--shadow: 0 1px 2px rgb(20 18 30 / 0.06), 0 6px 24px rgb(20 18 30 / 0.06);
	--sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
	--mono: ui-monospace, "SF Mono", Menlo, monospace;
	font: 13.5px/1.45 var(--sans);
	color: var(--ink);
	background: var(--bg);
}
@media (prefers-color-scheme: dark) {
	:root {
		--bg: #0d0d12; --side: #111117; --panel: #16161e; --ink: #ecebf3; --muted: #a09eaf; --faint: #6d6b7e;
		--rule: #23232d; --hover: #1c1c25; --accent: #a99bff; --accent-ink: #c9c0ff; --accent-soft: rgb(169 155 255 / 0.14);
		--shadow: 0 1px 2px rgb(0 0 0 / 0.4), 0 8px 30px rgb(0 0 0 / 0.35);
	}
}
/* Each kind's colour, the site's neon where it reads: components violet (the site's --violet, the
   catalog's own accent), drafts amber (its --warn). What a kind's part holds takes its accent. */
[data-kind="draft"] { --accent: #d98e04; --accent-ink: #9a5a00; --accent-soft: #fff1cf; }
@media (prefers-color-scheme: dark) {
	[data-kind="draft"] { --accent: #ffd447; --accent-ink: #ffe27d; --accent-soft: rgb(255 212 71 / 0.12); }
}
* { box-sizing: border-box; }
body { margin: 0; height: 100vh; display: grid; grid-template-columns: 16.5rem minmax(0, 1fr); overflow: hidden; }
body.folded { grid-template-columns: minmax(0, 1fr); }
body.folded aside { display: none; }
button { font: inherit; color: inherit; }
kbd { display: inline-grid; place-items: center; min-width: 1.35em; padding: 0 0.3em; border: 1px solid var(--rule); border-bottom-width: 2px; border-radius: 4px; background: var(--panel); color: var(--muted); font: 600 10.5px/1.5 var(--mono); }
.icon { display: inline-grid; place-items: center; width: 1.9rem; height: 1.9rem; padding: 0; border: 0; border-radius: 7px; background: none; color: var(--muted); cursor: pointer; }
.icon:hover { background: var(--hover); color: var(--ink); }
.icon.on { background: var(--accent-soft); color: var(--accent-ink); }

aside { display: flex; flex-direction: column; min-height: 0; background: var(--side); border-right: 1px solid var(--rule); }
.brand { display: flex; align-items: center; gap: 0.6rem; padding: 0.9rem 0.75rem 0.9rem 1rem; }
.logo { display: grid; place-items: center; width: 1.9rem; height: 1.9rem; border-radius: 8px; background: linear-gradient(135deg, var(--accent), #e05bd8); color: white; }
.brand-text { flex: 1; min-width: 0; line-height: 1.2; }
.brand-text strong { display: block; font-size: 14px; }
.brand-text small { color: var(--faint); }
.search { display: flex; align-items: center; gap: 0.5rem; margin: 0 0.75rem 0.5rem; padding: 0 0.6rem; height: 2.1rem; border: 1px solid var(--rule); border-radius: 8px; background: var(--panel); color: var(--faint); }
.search:focus-within { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.search input { flex: 1; min-width: 0; border: 0; outline: 0; background: none; color: var(--ink); font: inherit; }
.search input::-webkit-search-cancel-button { display: none; }
nav { flex: 1; overflow: auto; padding: 0 0.5rem 1rem; }
.part + .part { margin-top: 0.6rem; border-top: 1px solid var(--rule); }
.part-head { position: sticky; top: 0; z-index: 1; display: flex; align-items: center; gap: 0.6rem; padding: 0.7rem 0.5rem 0.5rem; background: var(--side); }
.mark { display: grid; flex: none; place-items: center; width: 1.75rem; height: 1.75rem; border-radius: 7px; background: var(--accent-soft); color: var(--accent); }
.part-name { flex: 1; min-width: 0; line-height: 1.3; }
.part-name strong { display: block; color: var(--accent-ink); font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }
.part-name small { display: block; overflow: hidden; color: var(--faint); font: 11px var(--mono); text-overflow: ellipsis; white-space: nowrap; }
.part-head .count { min-width: 1.5rem; padding: 0 0.4rem; border-radius: 999px; background: var(--accent-soft); color: var(--accent-ink); text-align: center; }
.component { display: flex; align-items: center; gap: 0.5rem; padding: 0.3rem 0.6rem 0.3rem 0.5rem; border-radius: 7px; color: var(--ink); font-weight: 600; text-decoration: none; }
.component:hover { background: var(--hover); }
.component.on { background: var(--accent-soft); color: var(--accent-ink); }
.component > svg { color: var(--accent); flex: none; }
.component .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.count { color: var(--faint); font: 500 11px var(--mono); }
.stories { margin: 0.1rem 0 0.35rem 1.05rem; padding: 0 0 0 0.6rem; border-left: 1px solid var(--rule); list-style: none; }
.stories a { display: block; margin: 1px 0; padding: 0.28rem 0.6rem; border-radius: 6px; color: var(--muted); text-decoration: none; }
.stories a:hover { background: var(--hover); color: var(--ink); }
.stories a.on { background: var(--accent-soft); color: var(--accent-ink); font-weight: 600; }
.none { margin: 1.5rem 0.75rem; color: var(--faint); }
.keys { display: flex; flex-wrap: wrap; gap: 0.35rem 0.75rem; padding: 0.7rem 1rem; border-top: 1px solid var(--rule); color: var(--faint); font-size: 11.5px; }
.keys span { display: inline-flex; align-items: center; gap: 0.25rem; }

main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
.bar { display: flex; align-items: center; gap: 0.6rem; min-height: 3.1rem; padding: 0.4rem 0.75rem 0.4rem 1rem; border-bottom: 1px solid var(--rule); background: var(--panel); }
.badge { display: inline-flex; flex: none; align-items: center; gap: 0.35rem; height: 1.55rem; padding: 0 0.6rem 0 0.45rem; border-radius: 999px; background: var(--accent-soft); color: var(--accent-ink); font-size: 12px; font-weight: 600; }
.badge svg { width: 13px; height: 13px; color: var(--accent); }
.crumbs { display: flex; align-items: baseline; gap: 0.4rem; min-width: 0; white-space: nowrap; }
.crumbs .of { color: var(--muted); text-decoration: none; }
.crumbs a.of:hover { color: var(--ink); text-decoration: underline; }
.crumbs .sep { color: var(--faint); }
.crumbs strong { font-size: 14px; }
.where { overflow: hidden; text-overflow: ellipsis; color: var(--faint); font: 12px var(--mono); text-decoration: none; white-space: nowrap; }
a.where:hover { color: var(--accent-ink); text-decoration: underline; }
.spacer { flex: 1; }
.tool { display: inline-flex; align-items: center; gap: 0.45rem; height: 2rem; padding: 0 0.7rem; border: 1px solid var(--rule); border-radius: 8px; background: var(--panel); color: var(--ink); cursor: pointer; white-space: nowrap; }
.tool:hover { border-color: var(--accent); color: var(--accent-ink); }
.tool.on { border-color: var(--accent); background: var(--accent-soft); color: var(--accent-ink); }
.stage { flex: 1; min-height: 0; overflow: auto; padding: 1rem; }
.one { height: 100%; border: 1px solid var(--rule); border-radius: 10px; background: var(--panel); box-shadow: var(--shadow); overflow: hidden; }
.one iframe { display: block; width: 100%; height: 100%; border: 0; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(26rem, 1fr)); gap: 1rem; align-items: start; }
.cell { border: 1px solid var(--rule); border-radius: 10px; background: var(--panel); box-shadow: var(--shadow); overflow: hidden; }
.cell header { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; padding: 0.45rem 0.6rem 0.45rem 0.85rem; border-bottom: 1px solid var(--rule); }
.cell header a { color: var(--ink); font-weight: 600; text-decoration: none; }
.cell header a:hover { color: var(--accent-ink); }
.cell .line { color: var(--faint); font: 11.5px var(--mono); }
.cell iframe { display: block; width: 100%; height: 12rem; border: 0; }
.empty { max-width: 34rem; margin: 3rem auto; color: var(--muted); }
.empty pre { padding: 1rem; border: 1px solid var(--rule); border-radius: 8px; background: var(--panel); color: var(--ink); font: 12.5px/1.6 var(--mono); }

/* Full screen: the story is the window, and a button in its corner brings the catalog back. */
body.full { grid-template-columns: minmax(0, 1fr); }
body.full aside, body.full .bar { display: none; }
body.full .stage { padding: 0; }
body.full .one { border: 0; border-radius: 0; box-shadow: none; }
body.full .grid { padding: 1rem; }
.exit { position: fixed; top: 0.75rem; right: 0.75rem; z-index: 10; display: none; align-items: center; gap: 0.5rem; height: 2.2rem; padding: 0 0.6rem 0 0.75rem; border: 1px solid rgb(255 255 255 / 0.18); border-radius: 999px; background: rgb(20 18 30 / 0.72); color: white; box-shadow: 0 6px 24px rgb(0 0 0 / 0.3); backdrop-filter: blur(10px); cursor: pointer; opacity: 0.7; transition: opacity 0.15s; }
.exit:hover, .exit:focus-visible { opacity: 1; }
.exit kbd { border-color: rgb(255 255 255 / 0.25); background: rgb(255 255 255 / 0.12); color: rgb(255 255 255 / 0.85); }
body.full .exit { display: inline-flex; }
</style>
</head>
<body>
<aside aria-label="Stories">
	<div class="brand">
		<span class="logo">${ICONS.book}</span>
		<span class="brand-text"><strong>Stories</strong><small>${escapeHtml(title)}</small></span>
		<button class="icon" id="fold" title="Hide the side (S)" aria-label="Hide the side">${ICONS.panel}</button>
	</div>
	<label class="search">${ICONS.search}<input type="search" id="find" placeholder="Find a story" aria-label="Find a story"><kbd>/</kbd></label>
	<nav id="list"></nav>
	<div class="keys"><span><kbd>↑↓</kbd> move</span><span><kbd>F</kbd> full screen</span><span><kbd>S</kbd> side</span></div>
</aside>
<main>
	<div class="bar" id="bar"></div>
	<div class="stage" id="stage"></div>
</main>
<button class="exit" id="exit" title="Leave full screen (Esc)">${ICONS.shrink}Exit full screen <kbd>Esc</kbd></button>
<script>
const STORIES = ${data};
const BASE = ${JSON.stringify(STORIES_PATH)};
const ICONS = ${JSON.stringify(ICONS)};
const $ = (tag, attrs = {}, ...children) => {
	const node = document.createElement(tag);
	for (const [key, value] of Object.entries(attrs)) key.startsWith("on") ? node.addEventListener(key.slice(2), value) : node.setAttribute(key, value);
	node.append(...children);
	return node;
};
const svg = (name) => {
	const span = document.createElement("span");
	span.innerHTML = ICONS[name];
	return span.firstChild;
};
// The two kinds of story, in the order the side lists them.
const KINDS = [
	{ kind: "draft", label: "Drafts", one: "Draft", hint: "pages in stories/", about: "A module in stories/: drafts of whole pages, beside one another" },
	{ kind: "component", label: "Components", one: "Component", hint: "inline <story>", about: "A <story> in a component's block" },
];
const kindOf = (story) => KINDS.find((kind) => kind.kind === story.kind) ?? KINDS[1];
const componentKey = (story) => story.file + "#" + story.component;
const groupOf = (key) => STORIES.filter((story) => componentKey(story) === key);
// What is shown: the hash is a story's id, or "side/" and a component's file#name for its stories
// side by side. Full screen and a folded side are kept for the tab, so a rebuild's reload keeps them.
function picked() {
	const hash = decodeURIComponent(location.hash.slice(1));
	if (hash.startsWith("side/") && groupOf(hash.slice(5)).length) return { side: groupOf(hash.slice(5)) };
	return { story: STORIES.find((story) => story.id === hash) ?? STORIES[0] };
}
const state = (name) => sessionStorage.getItem("rocx-stories-" + name) === "yes";
function set(name, on) {
	sessionStorage.setItem("rocx-stories-" + name, on ? "yes" : "no");
	document.body.classList.toggle(name, on);
	if (name === "folded") show();
	if (name === "full" && !on) document.getElementById("stage").focus();
}
function list() {
	const find = document.getElementById("find").value.trim().toLowerCase();
	const nav = document.getElementById("list");
	const now = picked();
	nav.replaceChildren();
	for (const kind of KINDS) {
		const shown = STORIES.filter((story) => story.kind === kind.kind && (!find || (story.file + " " + story.component + " " + story.name + " " + kind.one).toLowerCase().includes(find)));
		if (!shown.length) continue;
		const part = $("section", { class: "part", "data-kind": kind.kind, "aria-label": kind.label });
		part.append($("div", { class: "part-head", title: kind.about }, $("span", { class: "mark" }, svg(kind.kind)), $("span", { class: "part-name" }, $("strong", {}, kind.label), $("small", {}, kind.hint)), $("span", { class: "count" }, String(shown.length))));
		let group = null;
		let stories = null;
		for (const story of shown) {
			if (componentKey(story) !== group) {
				group = componentKey(story);
				const key = group;
				const many = groupOf(key).length;
				const sideOn = Boolean(now.side) && componentKey(now.side[0]) === key;
				// The component's name opens its stories side by side; with one story, that story.
				const href = "#" + (many > 1 ? "side/" + key : story.id);
				part.append($("a", { class: "component" + (sideOn ? " on" : ""), href, title: story.file + (many > 1 ? ": its stories side by side" : ": its story") }, svg(kind.kind), $("span", { class: "name" }, story.component), $("span", { class: "count" }, String(many))));
				stories = $("ul", { class: "stories" });
				part.append(stories);
			}
			stories.append($("li", {}, $("a", { href: "#" + story.id, class: now.story === story ? "on" : "" }, story.name)));
		}
		nav.append(part);
	}
	if (!nav.children.length) nav.append($("p", { class: "none" }, STORIES.length ? "No story matches." : "No stories yet."));
}
// The bar: what is open (its kind, the bar in that kind's colour; its component and name), where it
// is written, and what to do with it.
function bar(story, crumbs, where, tools) {
	const unfold = document.body.classList.contains("folded") ? [$("button", { class: "icon", title: "Show the side (S)", "aria-label": "Show the side", onclick: () => set("folded", false) }, svg("panel"))] : [];
	const full = $("button", { class: "tool", title: "Full screen (F)", onclick: () => set("full", true) }, svg("expand"), "Full screen");
	const kind = story && kindOf(story);
	const badge = kind ? [$("span", { class: "badge", title: kind.about }, svg(kind.kind), kind.one)] : [];
	const node = document.getElementById("bar");
	if (kind) node.dataset.kind = kind.kind;
	else delete node.dataset.kind;
	node.replaceChildren(...unfold, ...badge, $("div", { class: "crumbs" }, ...crumbs), where, $("span", { class: "spacer" }), ...tools, full);
}
// A frame's own keys: F and Esc work with the story focused too (it is a page of the same site).
function keysIn(frame) {
	frame.addEventListener("load", () => {
		try {
			frame.contentWindow.addEventListener("keydown", keys);
		} catch {}
	});
}
function show() {
	const stage = document.getElementById("stage");
	const now = picked();
	list();
	if (!STORIES.length) {
		bar(null, [$("strong", {}, "Stories")], $("span"), []);
		const empty = $("div", { class: "empty" }, $("p", {}, "No stories yet. Write one in a component's block, beside its definitions:"));
		empty.append($("pre", {}, 'Callout := [].{\\n\\tview = …\\n\\n\\t<story name="Tip">\\n\\t\\t<Callout kind="tip" title="A tip">…</Callout>\\n\\t</story>\\n}'));
		stage.replaceChildren(empty);
		return;
	}
	if (now.side) {
		const first = now.side[0];
		bar(first, [$("span", { class: "of" }, first.component), $("span", { class: "sep" }, "/"), $("strong", {}, "side by side")], $("span", { class: "where" }, first.file), []);
		const grid = $("div", { class: "grid" });
		for (const story of now.side) {
			const frame = $("iframe", { src: BASE + "/" + story.id, title: story.name });
			frame.addEventListener("load", () => fit(frame));
			keysIn(frame);
			grid.append($("section", { class: "cell" }, $("header", {}, $("a", { href: "#" + story.id }, story.name), $("span", { class: "line" }, ":" + story.line)), frame));
		}
		stage.replaceChildren(grid);
		return;
	}
	const story = now.story;
	const many = groupOf(componentKey(story)).length > 1;
	const of = many ? $("a", { class: "of", href: "#side/" + componentKey(story), title: "Its stories side by side" }, story.component) : $("span", { class: "of" }, story.component);
	bar(
		story,
		[of, $("span", { class: "sep" }, "/"), $("strong", {}, story.name)],
		$("a", { class: "where", href: "vscode://file/" + story.path + ":" + story.line, title: "Open it in the editor" }, story.file + ":" + story.line),
		[],
	);
	const frame = $("iframe", { src: BASE + "/" + story.id, title: story.component + " / " + story.name });
	keysIn(frame);
	stage.replaceChildren($("div", { class: "one" }, frame));
}
// Side by side, each frame is its cell's width, as a component is wherever it is put, and as tall
// as what it shows, up to a screen's height (it scrolls past that).
function fit(frame) {
	let tall = 0;
	try {
		tall = frame.contentDocument.documentElement.scrollHeight;
	} catch {}
	frame.style.height = Math.min(tall || 400, 900) + "px";
}
function keys(event) {
	const typing = event.target?.closest?.("input, textarea, select, [contenteditable]");
	if (event.key === "Escape" && document.body.classList.contains("full")) set("full", false);
	else if (typing || event.metaKey || event.ctrlKey || event.altKey) return;
	else if (event.key === "f") set("full", !document.body.classList.contains("full"));
	else if (event.key === "s") set("folded", !document.body.classList.contains("folded"));
	else if (event.key === "/") {
		if (document.body.classList.contains("folded")) set("folded", false);
		document.getElementById("find").focus();
	} else if (["ArrowDown", "ArrowUp", "j", "k"].includes(event.key) && picked().story) {
		const step = event.key === "ArrowDown" || event.key === "j" ? 1 : -1;
		const now = picked().story;
		location.hash = STORIES[(STORIES.indexOf(now) + step + STORIES.length) % STORIES.length].id;
	} else return;
	event.preventDefault();
}
document.getElementById("fold").addEventListener("click", () => set("folded", true));
document.getElementById("exit").addEventListener("click", () => set("full", false));
document.getElementById("find").addEventListener("input", list);
document.getElementById("find").addEventListener("keydown", (event) => {
	if (event.key === "Escape") event.target.blur();
	if (event.key === "Enter") document.querySelector("#list a")?.click();
});
document.getElementById("stage").tabIndex = -1;
addEventListener("keydown", keys);
addEventListener("hashchange", show);
document.body.classList.toggle("full", state("full"));
document.body.classList.toggle("folded", state("folded"));
show();
</script>
</body>
</html>`;
}
