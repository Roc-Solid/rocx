// File-based routing, as SvelteKit has it: under an app's `routes/`, a `+page.rocx` is a page at
// the path its directory names (`routes/blog/[slug]/+page.rocx` is `/blog/:slug`), each
// `+layout.rocx` above it wraps it, `+server.rocx` answers HTTP methods there (`get!`, `post!`,
// `put!`, `patch!`, `delete!`: endpoints; `events!`: a stream of events; `respond!`: every method
// the others don't, with a `Server.Response` of its own), and `+error.rocx` is what a path nothing
// has shows. A route file names its `middleware`, which runs around it. Directories that start with
// a dot are skipped, but for `.well-known` (`routes/.well-known/openid-configuration/+server.roc`).
//
// A route file is bare: imports, a blank line, then its definitions (`meta`, `view`). Roc names a
// module after its file, and `+page` isn't a name, so rocx writes each as a module of its own under
// `Generated/` (`ShowcasePage.roc`), putting the module's line on that blank line, so line N there
// is still line N of the route file. Then `Generated/Routes.roc` matches a request's path to its
// page, and `Generated/Paths.roc` has a path for every page, a function of its params if it has
// any, so a link to a page that isn't there doesn't compile; and `Generated/Api.roc` has each
// endpoint, a function of its params, called directly on the server and over HTTP in the browser,
// and their OpenAPI document (`Api.openapi`), which `GET /openapi.json` answers with if the app says
// (`App.program`'s `openapi`: `OpenApi.Serving`, `Off` unless it does). The app's server
// functions (`server!`) are routes too: `Generated/ServerFunctions.roc` answers
// `POST /rocx/call/<module>.<name>` with each, behind the middleware of the route file that defines
// it. They stay out of the OpenAPI document: they are the app's own calls, named after its modules,
// not an API.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { MARKER, rocString } from "./transpile.mjs";
import { STORIES_PATH } from "./stories.mjs";

/** A route file's name. */
export const ROUTE_FILE = /^\+(page|layout|error|server)\.(rocx|roc)$/;

/** The methods a `+server.rocx` may answer, as it names them; `events!` is a stream of events
 * (server-sent events), for a GET that accepts them (`text/event-stream`). */
export const METHODS = ["get!", "post!", "put!", "patch!", "delete!", "events!"];

/** The HTTP method a handler answers (`events!` answers a GET). */
const verbOf = (method) => (method === "events!" ? "GET" : method.replace("!", "").toUpperCase());

/** The one directory starting with a dot that is routed (RFC 8615): `/.well-known/…`. */
const WELL_KNOWN = ".well-known";

/** Where rocx writes the modules for an app's routes. */
export const GENERATED = "Generated";

/** Names a route's definitions can't have: Roc's keywords, and `all` (Paths has every path as it).
 * A route that would be named one is named with `_` after it: `/platform` is `Paths.platform_`. */
const KEYWORDS = new Set(["all", "and", "app", "as", "break", "crash", "dbg", "else", "expect", "exposes", "exposing", "for", "hosted", "if", "import", "in", "is", "match", "module", "not", "or", "package", "packages", "platform", "provides", "requires", "return", "targets", "then", "var", "when", "where", "while"]);

/** Whether a route's `.roc` is one rocx wrote (beside its `.rocx`, before routes were modules), not a route. */
const written = (path) =>
	path.endsWith(".roc") && (existsSync(`${path}x`) || readFileSync(path, "utf8").trimEnd().split("\n").pop().startsWith(MARKER));

/** Whether `routes` has the route files (`+page.rocx`; `+server.roc`, plain Roc), and their paths relative to it. */
export function findRouteFiles(routes) {
	if (!existsSync(routes) || !statSync(routes).isDirectory()) return [];
	const found = [];
	const walk = (dir) => {
		for (const entry of readdirSync(dir).sort()) {
			if (entry.startsWith(".") && entry !== WELL_KNOWN) continue;
			const path = join(dir, entry);
			if (statSync(path).isDirectory()) walk(path);
			else if (ROUTE_FILE.test(entry) && !written(path)) found.push(relative(routes, path).split(sep).join("/"));
		}
	};
	walk(routes);
	return found;
}

const pascal = (word) => word.replace(/(^|[_-])([a-z0-9])/g, (_, __, c) => c.toUpperCase());

/**
 * The routes, from their files' paths under `routes/` (`blog/[slug]/+page.rocx`): each page's path
 * (`/blog/[slug]`), params, name (`blog_slug`, for Paths) and module (`BlogSlugPage`), and the
 * layouts above it, outermost first; and the error page, if there is one. Throws what is wrong.
 */
export function routeTable(paths) {
	const entries = paths.map((path) => {
		const parts = path.split("/");
		const kind = ROUTE_FILE.exec(parts.pop())[1];
		if (paths.some((other) => other !== path && other.replace(/\.roc$/, ".rocx") === path)) throw new Error(`routes/${path} and routes/${path}x are the same route: keep one`);
		for (const part of parts) {
			if (!/^(\[[a-z][a-z0-9_]*\]|[a-z0-9][a-z0-9_-]*)$/.test(part) && part !== WELL_KNOWN) {
				throw new Error(`routes/${path}: a directory is a path's part in lower case (\`blog\`, \`getting-started\`) or a param (\`[slug]\`): not \`${part}\``);
			}
		}
		const words = parts.map((part) => part.replace(/^\[|\]$/g, "").replace(/^\./, ""));
		const stem = words.length ? words.map(pascal).join("") : "Root";
		const name = words.length ? words.join("_").replace(/-/g, "_") : "root";
		return { file: path, kind, parts, module: `${stem}${pascal(kind)}`, name: KEYWORDS.has(name) ? `${name}_` : name };
	});
	const modules = new Map();
	for (const entry of entries) {
		const other = modules.get(entry.module);
		if (other) throw new Error(`routes/${entry.file} and routes/${other.file} would both be ${entry.module}: rename one of their directories`);
		modules.set(entry.module, entry);
	}
	const errors = entries.filter((entry) => entry.kind === "error");
	if (errors.some((entry) => entry.parts.length)) throw new Error(`routes/${errors.find((entry) => entry.parts.length).file}: an error page is the app's, in routes/ itself, for now`);
	const layouts = entries.filter((entry) => entry.kind === "layout");
	const above = (parts) => layouts.filter((layout) => layout.parts.length <= parts.length && layout.parts.every((part, i) => part === parts[i]));
	const routed = (entry) => ({
		...entry,
		path: `/${entry.parts.join("/")}`,
		params: entry.parts.flatMap((part, i) => (part.startsWith("[") ? [{ name: part.slice(1, -1), at: i }] : [])),
		layouts: above(entry.parts),
	});
	const pages = entries.filter((entry) => entry.kind === "page").map(routed);
	const servers = entries.filter((entry) => entry.kind === "server").map(routed);
	const names = new Map();
	for (const page of pages) {
		const other = names.get(page.name);
		if (other) throw new Error(`routes/${page.file} and routes/${other.file} would both be Paths.${page.name}: rename one of their directories`);
		names.set(page.name, page);
	}
	// The more of a path is fixed, the sooner it is tried: `/blog/new` before `/blog/[slug]`.
	const fixed = (page) => page.parts.length - page.params.length;
	const order = (a, b) => a.params.length - b.params.length || fixed(b) - fixed(a) || a.path.localeCompare(b.path);
	pages.sort(order);
	servers.sort(order);
	// Every path something answers: its page, its endpoints, or both.
	const answered = new Map();
	for (const entry of [...pages, ...servers]) {
		const at = answered.get(entry.path) ?? { path: entry.path, parts: entry.parts, params: entry.params, name: entry.name };
		at[entry.kind] = entry;
		answered.set(entry.path, at);
	}
	return { pages, servers, layouts, error: errors[0] ? { ...errors[0], layouts: above([]) } : null, paths: [...answered.values()].sort(order) };
}

/** The definitions a route file has, among `view`, `view!`, `meta`, `middleware` and the methods,
 * at the top of the file; what its middleware is, as written (for `rocx routes`); and what each
 * method's comment says (for its OpenAPI operation). `respond: true` if it defines `respond!`. */
export function definitions(source) {
	const defined = (name) => new RegExp(`^${name.replace("!", "\\!")}\\s*=`, "m").test(source);
	const middleware = /^middleware\s*=\s*(.+)$/m.exec(source)?.[1].trim() ?? null;
	const methods = METHODS.filter(defined);
	const lines = source.split("\n");
	// A method's comment is the `##` lines right above it (its annotation, or it); a file with one
	// method may have its comment at the top instead, above the blank line the module's line goes on.
	const comment = (end) => {
		let start = end;
		while (start > 0 && lines[start - 1].startsWith("##")) start--;
		return lines.slice(start, end).map((line) => line.replace(/^##\s?/, "")).join("\n").trim();
	};
	const first = lines.findIndex((line) => line.startsWith("##"));
	const docs = {};
	for (const method of methods) {
		const at = lines.findIndex((line) => new RegExp(`^${method.replace("!", "\\!")}\\s*[:=]`).test(line));
		const doc = comment(at) || (methods.length === 1 && first >= 0 ? comment(lines.findIndex((line, i) => i > first && !line.startsWith("##"))) : "");
		if (doc) docs[method] = doc;
	}
	return { view: defined("view!") ? "view!" : defined("view") ? "view" : null, meta: defined("meta"), methods, middleware, docs, ...(defined("respond!") ? { respond: true } : {}) };
}

/**
 * Every name in Roc code that could be a tag (`Red`, `BadRequest`): a capitalized word outside
 * comments and strings, but not a module's or a type's before a `.` (`Server.`). The OpenAPI
 * document tries each as a tag of each tag union it describes, which says what its tags are only
 * when asked for one; a name that isn't a tag is only a name it tries.
 */
export function tagNames(codes) {
	const names = new Set();
	for (const code of codes) {
		for (const line of code.split("\n")) {
			const trimmed = line.trimStart();
			if (trimmed.startsWith("\\\\") || trimmed.startsWith("import ")) continue;
			let bare = "";
			let quoted = false;
			for (let i = 0; i < line.length; i++) {
				const c = line[i];
				if (quoted) {
					if (c === "\\") i++;
					else if (c === '"') quoted = false;
				} else if (c === '"') {
					quoted = true;
					bare += " ";
				} else if (c === "#") break;
				else bare += c;
			}
			for (const [name] of bare.matchAll(/\b[A-Z][A-Za-z0-9_]*\b(?!\.)/g)) names.add(name);
		}
	}
	return [...names].sort();
}

/**
 * A route file's Roc (what rocx wrote for it, without its last line), as the module `name` at
 * `generated`: its relative imports made relative to there, the module's line on the blank line
 * after them, and a `}` after the rest.
 */
export function routeModule(code, { name, source, generated }) {
	const lines = code.replace(/\n*# rocx: generated from[^\n]*\n?$/, "").split("\n");
	// The module's line goes on the first blank line after the last import: the browser's copy may
	// have blank lines between imports, where it dropped those only the server used.
	let blank = -1;
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i].trim();
		if (line.startsWith("import ")) {
			// A path relative to the route file, made relative to the module rocx writes.
			const imported = /^import\s+((?:\.{1,2}\/)*(?:[A-Za-z0-9_]+\/)*[A-Z][A-Za-z0-9]*)(.*)$/.exec(line);
			if (imported && !/^[a-z_][a-z0-9_]*\./.test(imported[1])) {
				const moved = relative(dirname(generated), resolve(dirname(source), imported[1])).split(sep).join("/");
				lines[i] = `import ${moved}${imported[2]}`;
			}
			blank = -1;
		} else if (line === "") {
			if (blank < 0) blank = i;
		} else if (!line.startsWith("#")) break;
	}
	if (blank < 0) throw new Error(`${source}: leave a blank line after the imports, before the definitions: rocx puts the module's line there`);
	// The file's own components (`Board := [].{ view! = … }`, at its top level) are types beside the
	// module, not in its block, where their `view!` would be the page's again: the module's block is
	// the file's definitions between them, opened on the blank line before the first and closed
	// (`}`) on the one after the last, or at the start of the next component's line.
	const own = (i) => /^[A-Z][A-Za-z0-9_]*(\([^)\n]*\))?[ \t]*:=/.test(lines[i]);
	const topLevel = (i) => /^[^\s#})\]]/.test(lines[i]);
	let first = -1;
	let last = -1;
	const owned = new Set();
	for (let i = blank + 1; i < lines.length; i++) {
		if (own(i)) owned.add(i);
		else if (topLevel(i)) {
			if (first < 0) first = i;
			else if ([...owned].some((at) => at > first && at < i)) {
				const between = lines[[...owned].find((at) => at > first && at < i)].split(/[ \t(:]/)[0];
				throw new Error(`${source}:${i + 1}: put the file's own components (${between}) before its definitions or after them, not between: the page's module is the lines between them`);
			}
			last = i;
		}
	}
	const from = relative(dirname(generated), source).split(sep).join("/");
	const ending = `${MARKER} ${from}: edit that file, not this one. Line N here is line N there.\n`;
	if (!owned.size) {
		lines[blank] = `${name} := [].{`;
		return `${lines.join("\n").replace(/\n*$/, "")}\n}\n\n${ending}`;
	}
	if (first < 0) throw new Error(`${source}: a route file defines its view, meta or methods, beside its own components`);
	// A component's comment goes with it, outside the module.
	const commentStart = (at) => {
		while (at > 0 && lines[at - 1].startsWith("#")) at--;
		return at;
	};
	let opening = blank;
	if ([...owned].some((at) => at < first)) {
		opening = -1;
		for (let i = commentStart(first) - 1; i > blank && opening < 0; i--) if (lines[i].trim() === "") opening = i;
		if (opening < 0 || [...owned].some((at) => at > opening && at < first)) throw new Error(`${source}:${first + 1}: leave a blank line after the file's own components, before its definitions: rocx puts the module's line there`);
	}
	lines[opening] = `${name} := [].{`;
	const after = [...owned].filter((at) => at > last).sort((a, b) => a - b)[0];
	if (after === undefined) return `${lines.join("\n").replace(/\n*$/, "")}\n}\n\n${ending}`;
	const start = commentStart(after);
	let closing = -1;
	for (let i = start - 1; i > last && closing < 0; i--) if (lines[i].trim() === "") closing = i;
	if (closing >= 0) lines[closing] = "}";
	else lines[start] = `} ${lines[start]}`;
	return `${lines.join("\n").replace(/\n*$/, "")}\n\n${ending}`;
}

/** Every route file a table has. */
const routedEntries = (table) => [...table.pages, ...table.servers, ...table.layouts, ...(table.error ? [table.error] : [])];

/** An endpoint's name in Api: its method and its path's (`post_blog`, `get_blog_slug`). */
const apiName = (method, at) => `${method.replace("!", "")}_${at.name}`;

/** The URL of a path, its params put in (`"/blog/${Server.encode_segment(params.slug)}"`, as Roc). */
const urlOf = (at) =>
	JSON.stringify(`/${at.parts.map((part) => (part.startsWith("[") ? `\${Server.encode_segment(params.${part.slice(1, -1)})}` : part)).join("/")}`);

/** A path as OpenAPI writes it, its params in braces (`/blog/{slug}`). */
const openApiPath = (at) => `/${at.parts.map((part) => (part.startsWith("[") ? `{${part.slice(1, -1)}}` : part)).join("/")}`;


/** Where a server function's calls go: `POST /rocx/call/Demos/Echo.echo`, its input as JSON. */
export const CALL_PATH = "/rocx/call/";

/** The module `rocx build` writes the server functions' routes in (`Generated/ServerFunctions.roc`). */
export const SERVER_FUNCTIONS = "ServerFunctions";

/**
 * `Generated/ServerFunctions.roc`: the answer to a call of each server function (`functions`: `{
 * module, name, call, route }`, `route` the route file that defines it, with whether it names
 * `middleware`, or null), as `Routes.respond!` gives it every POST to `/rocx/call/<name>`: its input
 * read, its body run, its answer as JSON (`Server.serve!`), behind its route file's middleware if
 * it is defined in one (the app's default ran before, as for every request); 404 for a name none
 * has. `client`: the browser's copy, which has none (the browser answers no calls).
 */
export function serverFunctionsModule(functions, { client = false, dir = "." } = {}) {
	const alias = (f) => (f.route ? f.route.module : f.module.split("/").join(""));
	const named = (f) => `${f.module}.${f.call}`;
	const listed = client ? [] : [...functions].sort((a, b) => (named(a) < named(b) ? -1 : named(a) > named(b) ? 1 : 0));
	const imports = [...new Map(listed.map((f) => [alias(f), f.route ? `import ${f.route.module}` : `import ../${f.module} as ${alias(f)}`])).entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([, line]) => line);
	const guarded = listed.some((f) => f.route?.middleware);
	const served = (f, request, context) => `Server.serve!(called, ${request}, ${context}, ${alias(f)}.${f.name})`;
	const answer = (f) => (f.route?.middleware ? `Middleware.run!(${f.route.module}.middleware, request, context, |passed, handed| ${served(f, "passed", "handed")})` : served(f, "request", "context"));
	const missing = 'Server.refused(404, "no server function is called ${called}")';
	const body = listed.length
		? [
				"\trespond! = |called, request, context|",
				...listed.map((f, i) => `\t\t${i ? "} else " : ""}if (called == ${JSON.stringify(named(f))}) {\n\t\t\t${answer(f)}`),
				`\t\t} else {\n\t\t\t${missing}\n\t\t}`,
			]
		: [`\trespond! = |called, _request, _context| ${missing}`];
	return [
		client
			? `## The browser's copy of ${dir}/${GENERATED}/${SERVER_FUNCTIONS}.roc: it answers no calls, and imports`
			: `## Every server function (\`server!\`) under ${dir}, as the server answers its calls:`,
		client
			? "## no server function. Written by rocx build --client."
			: "## `Routes.respond!` gives it every `POST /rocx/call/<name>`. Written by rocx build: edit the functions.",
		"import pf.Server",
		...(guarded ? ["import pf.Middleware"] : []),
		...imports,
		"",
		`${SERVER_FUNCTIONS} := [].{`,
		"\t## The answer to a call of the server function `called` (`POST /rocx/call/Demos/Echo.echo`, its",
		"\t## input the request's body, as JSON), given what the app's middleware handed on (`context`):",
		"\t## 200 and its answer, as JSON; 400 for input it can't read; 404 for a name no function has. A",
		"\t## function a route file defines runs behind that file's middleware too.",
		...body,
		"}",
		"",
		`${MARKER} the server functions under ${dir}: rocx build writes it.`,
		"",
	].join("\n");
}

/**
 * The server functions under the app `dir` (`name = server!(…)` in a .rocx file, or in a route
 * file), as `rocx routes` lists them: each's name (`Demos/Echo.echo`), its file (relative to `dir`)
 * and its route file's middleware, if a route file that names one defines it. `table` and `sources`
 * are the routes'.
 */
export function serverFunctionsIn(dir, table, sources) {
	const routes = new Map(routedEntries(table).map((entry) => [`routes/${entry.file}`, entry]));
	const found = [];
	const walk = (at) => {
		for (const entry of readdirSync(at).sort()) {
			if ((entry.startsWith(".") && entry !== WELL_KNOWN) || /^(build|dist|Generated|node_modules)$/.test(entry)) continue;
			const path = join(at, entry);
			if (statSync(path).isDirectory()) walk(path);
			else {
				const file = relative(dir, path).split(sep).join("/");
				const route = routes.get(file);
				if (!file.endsWith(".rocx") && !route) continue;
				const module = route ? `${GENERATED}/${route.module}` : file.replace(/\.rocx$/, "");
				for (const [, name] of readFileSync(path, "utf8").matchAll(/^[ \t]*([a-z_][A-Za-z0-9_]*!?)[ \t]*=[ \t]*server!\(/gm)) {
					found.push({ name: `${module}.${name.replace(/!$/, "")}`, file, middleware: route ? (sources.get(route.file)?.middleware ?? null) : null });
				}
			}
		}
	};
	if (existsSync(dir)) walk(dir);
	return found.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

/** What a path's segments are checked against, as Roc (`segments == ["blog"]`, or its length and fixed parts). */
const matchedBy = (at) =>
	at.params.length
		? [`segments.len() == ${at.parts.length}`, ...at.parts.flatMap((part, i) => (part.startsWith("[") ? [] : [`segments.get(${i}) == Ok(${JSON.stringify(part)})`]))].join(" and ")
		: `segments == [${at.parts.map((part) => JSON.stringify(part)).join(", ")}]`;

/** A path's params, read from its segments, as Roc (`{ slug: segments.get(1) ?? "" }`, or `{}`). */
const paramsOf = (at) => (at.params.length ? `{ ${at.params.map((param) => `${param.name}: segments.get(${param.at}) ?? ""`).join(", ")} }` : "{}");

/** The module rocx writes the app's component pages in, for both the server and the browser. */
export const ROOT = "Root";

/** Whether the app has pages (a page, or its error page): `Root` renders them. */
export function hasPages(table) {
	return table.pages.length > 0 || Boolean(table.error);
}

/**
 * What is wrong with an app's route files' views: every page, layout and error page is a component,
 * which defines `view!`, with what it is given. Each a line.
 */
export function viewProblems(table, sources) {
	const takes = { page: "view! = |{ params }| …", layout: "view! = |{ meta, children, params }| …", error: "view! = |{ status, problem }| …" };
	return [...table.pages, ...table.layouts, ...(table.error ? [table.error] : [])]
		.filter((entry) => sources.get(entry.file).view !== "view!")
		.map((entry) => `routes/${entry.file}: ${entry.kind === "error" ? "an error page" : `a ${entry.kind}`} is a component, which defines view!: \`${takes[entry.kind]}\``);
}

/**
 * `Generated/Routes.roc`: the answer to a request. A path's page for a GET a browser sends (one
 * that accepts HTML): `Root`'s, a page the host renders (`Routes.page`), after the route file's
 * middleware; its endpoint for the method otherwise (`Api`); 405, with what it answers, for a
 * method it doesn't; and, where nothing is, the error page for a browser (404, `Root`'s), in an
 * app with pages, or text.
 */
export function routesModule(table, { sources, stories = null }) {
	// A file's middleware, if it names one, around what answers for it.
	const guarded = (entry, answer) =>
		sources.get(entry.file).middleware ? `Middleware.run!(${entry.module}.middleware, request, context, |passed, handed| ${answer("passed", "handed")})` : answer("request", "context");
	// A page is `Root`'s (Generated/Root.roc): the answer is a page the host renders, the same for
	// every path, which finds its route where it renders, as the browser does.
	const pages = hasPages(table);
	const page = (entry) => (sources.get(entry.file).middleware ? `Middleware.run!(${entry.module}.middleware, request, context, |_passed, _handed| Routes.page(200))` : "Routes.page(200)");
	const endpoint = (at, method) =>
		guarded(at.server, (request, context) => `Endpoint.${method === "events!" ? "stream!" : "respond!"}(Api.${apiName(method, at)}(params), ${request}, ${context})`);
	const branch = (at) => {
		const condition = matchedBy(at);
		const params = paramsOf(at);
		const methods = at.server ? sources.get(at.server.file).methods : [];
		const allowed = [...new Set([...(at.page ? ["GET"] : []), ...methods.map(verbOf)])];
		// `respond!`: every method nothing else here answers, with its own answer, instead of a 405.
		const respond = at.server && sources.get(at.server.file).respond;
		const arms = [];
		// What answers a GET: the page, for a browser; the events, for a page that listens to them;
		// `get!`. Each but the last answers only the GETs that accept what it answers (the last too,
		// before `respond!`).
		const gets = [
			...(at.page ? [["wants_html", page(at.page)]] : []),
			...(methods.includes("events!") ? [["wants_events", endpoint(at, "events!")]] : []),
			...(methods.includes("get!") ? [[null, endpoint(at, "get!")]] : []),
		];
		gets.forEach(([accepts, then], i) => arms.push([accepts && (i < gets.length - 1 || respond) ? `method == "GET" and ${accepts}` : `method == "GET"`, then]));
		for (const method of methods.filter((method) => verbOf(method) !== "GET")) arms.push([`method == ${JSON.stringify(verbOf(method))}`, endpoint(at, method)]);
		const responded = (request, context) => `${at.server.module}.respond!({ request: ${request}, params: params, context: ${context} })`;
		arms.push([null, respond ? guarded(at.server, responded) : `Endpoint.not_allowed(request, [${allowed.map((method) => JSON.stringify(method)).join(", ")}])`]);
		// A path `respond!` alone answers has one arm, and nothing to choose.
		const dispatch = arms.map(([test, then], i) => (test ? `${i ? " else " : ""}if (${test}) {\n\t\t\t\t${then}\n\t\t\t}` : i ? ` else {\n\t\t\t\t${then}\n\t\t\t}` : then)).join("");
		// A page reads its params where it renders (`Root`): with nothing else here, none.
		const reads = methods.length || respond;
		return [`if (${condition}) {`, ...(reads ? [`\t\t\tparams = ${params}`] : []), `\t\t\t${dispatch}`, "\t\t}"].join("\n");
	};
	const missing = pages ? `if (wants_html) {\n\t\t\tRoutes.page(404)\n\t\t} else {\n\t\t\tRoutes.text(404, "nothing at \${request.path}")\n\t\t}` : `Routes.text(404, "nothing at \${request.path}")`;
	// A page's module only for its middleware (`Root` renders it); an endpoint's, only for its
	// middleware or its `respond!` (`Api` has its handlers).
	const modules = [...table.pages.filter((entry) => sources.get(entry.file).middleware), ...table.servers.filter((entry) => sources.get(entry.file).middleware || sources.get(entry.file).respond)]
		.map((entry) => entry.module)
		.sort();
	// A call of a server function: `Generated/ServerFunctions`, with POST only. No route file can be
	// at its path either (it begins with `/rocx/call/`, which only rocx answers).
	const calls = [
		`if (request.path.starts_with(${JSON.stringify(CALL_PATH)})) {`,
		'\t\t\tif (request.method == "POST") {',
		`\t\t\t\tServerFunctions.respond!(Server.decode_segment(request.path.drop_prefix(${JSON.stringify(CALL_PATH)})), request, context)`,
		"\t\t\t} else {",
		'\t\t\t\tEndpoint.not_allowed(request, ["POST"])',
		"\t\t\t}",
		"\t\t}",
	].join("\n");
	// A dev build's stories (`stories`, from rocx build --dev): the catalog, and each story, the app's
	// page, which `Root` renders (as it renders a page), so the browser hydrates it.
	const storied = stories !== null;
	const storyBranch = [
		`if (request.path == ${JSON.stringify(STORIES_PATH)} or request.path.starts_with(${JSON.stringify(`${STORIES_PATH}/`)})) {`,
		`\t\t\tRoutes.story(request.path.drop_prefix(${JSON.stringify(STORIES_PATH)}).drop_prefix("/"), request)`,
		"\t\t}",
	].join("\n");
	const storyFunction = storied
		? [
				"\t## A dev build's stories (`<story>` in a component's block; rocx build --dev): the catalog at",
				`\t## ${STORIES_PATH}, and each story at ${STORIES_PATH}/<id>, in the root layout (\`Root\`).`,
				"\tstory = |id, request| {",
				'\t\tif (id == "") {',
				'\t\t\tServer.response(200, [{ name: "content-type", value: "text/html; charset=utf-8" }], Stories.catalog)',
				...stories.flatMap((story) => [`\t\t} else if (id == ${JSON.stringify(story.id)}) {`, "\t\t\tRoutes.page(200)"]),
				"\t\t} else {",
				'\t\t\tRoutes.text(404, "no story at ${request.path}")',
				"\t\t}",
				"\t}",
				"",
			]
		: [];
	// Last: no route can be at /__rocx/stories (a directory doesn't begin with `_`).
	const branches = [calls, ...table.paths.map(branch), ...(storied ? [storyBranch] : [])];
	return [
		"## Written by rocx build from the app's routes/: a page for each +page.rocx, in the +layout.rocx",
		"## files above it; the endpoints each +server.rocx has; the app's server functions",
		"## (`ServerFunctions`); and +error.rocx where nothing is. Edit those files, not this one.",
		"import pf.Server",
		"import pf.Endpoint",
		...([...routedEntries(table)].some((entry) => sources.get(entry.file).middleware) ? ["import pf.Middleware"] : []),
		...(table.servers.length ? ["import Api"] : []),
		...(pages ? [`import ${ROOT}`] : []),
		"import ServerFunctions",
		...modules.map((module) => `import ${module}`),
		...(storied ? ["import Stories"] : []),
		"",
		"Routes := [].{",
		"\t## The answer to `request` (a `Server.Request`): a page, in its layouts, for a browser's GET; an",
		"\t## endpoint's answer for its method; a server function's, for a POST to `/rocx/call/<name>`; the",
		"\t## error page (404) where nothing is. A file that names its `middleware` has it run around its",
		"\t## page, endpoints and server functions. `context` is what the app's middleware handed on: each",
		"\t## page, layout, endpoint and server function is given it (or what its own middleware hands on).",
		"\trespond! = |request, context| {",
		'\t\tsegments = request.path.split_on("/").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)',
		'\t\tmethod = if (request.method == "HEAD") "GET" else request.method',
		...(branches.some((branch) => branch.includes("wants_html")) || missing.includes("wants_html") ? ['\t\twants_html = (Server.header(request, "accept") ?? "").contains("text/html")'] : []),
		...(branches.some((branch) => branch.includes("wants_events")) ? ['\t\twants_events = (Server.header(request, "accept") ?? "").contains("text/event-stream")'] : []),
		branches.length ? `\t\t${branches.join(" else ")} else {\n\t\t\t${missing.replace(/\n/g, "\n\t")}\n\t\t}` : `\t\t${missing}`,
		"\t}",
		"",
		...(pages
			? [
					"\t## The app's page (`Root`), which the host renders for the request, every hole run once, as a",
					"\t## document for the browser to hydrate: the page at the request's path, in its layouts, or the",
					"\t## error page.",
					"\tpage : U16 -> Server.Response",
					`\tpage = |status| { status: status, headers: [], body: Page(${ROOT}.view!) }`,
					"",
				]
			: []),
		...storyFunction,
		"\ttext : U16, Str -> Server.Response",
		'\ttext = |status, body| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)',
		"}",
		"",
		`${MARKER} the routes: rocx build writes it.`,
		"",
	].join("\n");
}

/**
 * The server's `Api.openapi`: the OpenAPI document of the endpoints. rocx writes each path, its
 * params and its methods, with what their comments say; `OpenApi` has the compiler write the
 * schemas of what each is sent and answers, from their types (an endpoint's, as `Api` has it), and
 * `tags` are the names it tries as a tag union's. A path's `get!` and `events!` are one GET, which
 * answers with what the request accepts.
 */
function openApiDocument(table, { sources, tags, title }) {
	const operation = (verb, doc, body, contents) =>
		`OpenApi.operation(${rocString(verb)}, ${rocString(doc)}, ${body}, [${contents.join(", ")}])`;
	// A path `respond!` alone answers has no endpoints to describe.
	const paths = table.paths
		.filter((at) => at.server && sources.get(at.server.file).methods.length)
		.map((at) => {
			const { methods, docs = {} } = sources.get(at.server.file);
			// Any params will do: an endpoint's types don't depend on them.
			const params = at.params.length ? `{ ${at.params.map((param) => `${param.name}: ""`).join(", ")} }` : "{}";
			const call = (method) => `Api.${apiName(method, at.server)}(${params})`;
			const gets = methods.filter((method) => verbOf(method) === "GET");
			const operations = [
				...(gets.length
					? [operation("get", gets.map((method) => docs[method]).filter(Boolean).join("\n\n"), '""', gets.map((method) => `OpenApi.${method === "events!" ? "events" : "answer"}(${call(method)}, tags)`))]
					: []),
				...methods
					.filter((method) => verbOf(method) !== "GET")
					.map((method) => {
						const takes = ["POST", "PUT", "PATCH"].includes(verbOf(method));
						return operation(verbOf(method).toLowerCase(), docs[method] ?? "", takes ? `OpenApi.body(${call(method)}, tags)` : '""', [`OpenApi.answer(${call(method)}, tags)`]);
					}),
			];
			return [`\t\t\tOpenApi.path(${rocString(openApiPath(at))}, [${at.params.map((param) => rocString(param.name)).join(", ")}], [`, ...operations.map((each) => `\t\t\t\t${each},`), "\t\t\t]),"];
		});
	// The names, a line of about a hundred characters each.
	const lines = [];
	for (const name of tags.map(rocString)) {
		if (!lines.length || lines.at(-1).length + name.length > 100) lines.push(name);
		else lines[lines.length - 1] += `, ${name}`;
	}
	return [
		"\t## The OpenAPI document of these endpoints, which the server answers `GET /openapi.json` with if",
		"\t## the app says (`App.program`'s `openapi`):",
		"\t## each path and its methods, with what their comments say, and the JSON Schemas of what each is",
		"\t## sent and answers, from their types (`OpenApi`). `tags` is every name in the app's code that",
		"\t## could be a tag: a tag union's schema has the ones that are its.",
		"\topenapi : Str",
		"\topenapi = {",
		lines.length ? `\t\ttags = [\n${lines.map((line) => `\t\t\t${line},`).join("\n")}\n\t\t]` : "\t\ttags = []",
		`\t\tOpenApi.document(${rocString(title)}, [`,
		...paths.flat(),
		"\t\t])",
		"\t}",
	];
}

/**
 * `Generated/Api.roc`: each endpoint, a function of its params (`{}` with none). On the server
 * (`client` false) it runs the route's handler; in the browser's copy it is its method and URL,
 * and nothing it does. Its types are the handler's, checked where the app calls it: the same code
 * is built for the server, against the handler. The server's has their OpenAPI document too
 * (`openapi`), its title `title`, its tag unions' tags among `tags` (`tagNames`). `Endpoint`,
 * `Server` and `OpenApi` are the platform's (`pf`: both platforms have them).
 */
export function apiModule(table, { sources, client = false, tags = [], title = "app" }) {
	const endpoints = table.servers.flatMap((server) =>
		sources.get(server.file).methods.map((method) => {
			const verb = verbOf(method);
			const takes = ["POST", "PUT", "PATCH"].includes(verb);
			const handler = `|request, context, ${takes ? "body" : "{}"}| ${server.module}.${method}({ request: request, params: params, context: context${takes ? ", body: body" : ""} })`;
			const made = client ? `Endpoint.remote(${JSON.stringify(verb)}, ${urlOf(server)})` : `Endpoint.local(${JSON.stringify(verb)}, ${urlOf(server)}, ${handler})`;
			// The browser's copy of an endpoint with no params doesn't use them.
			const takes_params = client && !server.params.length ? "_params" : "params";
			const what = method === "events!" ? `${verb} ${server.path}, its events (\`Endpoint.listen!\`)` : `${verb} ${server.path}`;
			return [`\t## ${what}, from routes/${server.file}`, `\t${apiName(method, server)} = |${takes_params}| ${made}`, ""];
		}),
	);
	return [
		"## Written by rocx build from the app's routes/: each endpoint a +server.rocx has, as a function",
		client
			? "## of its params. This is the browser's copy: an endpoint is its method and URL (`Endpoint.send!`)."
			: "## of its params: `Endpoint.run!` runs it on the server, `Endpoint.send!` from a component. Edit the routes.",
		"import pf.Endpoint",
		"import pf.Server",
		...(client ? [] : ["import pf.OpenApi", ...[...new Set(table.servers.map((server) => server.module))].sort().map((module) => `import ${module}`)]),
		"",
		"Api := [].{",
		...endpoints.flat(),
		...(client ? [] : openApiDocument(table, { sources, tags, title })),
		"}",
		"",
		`${MARKER} the routes: rocx build writes it.`,
		"",
	].join("\n");
}

/** `Generated/Paths.roc`: a path for every page, a function of its params if it has any (the
 * platform's `Server.encode_segment` makes each param a segment). */
export function pathsModule(table) {
	const definition = (page) => {
		if (!page.params.length) return [`\t## ${page.path}, from routes/${page.file}`, `\t${page.name} : Str`, `\t${page.name} = ${JSON.stringify(page.path)}`];
		const type = `{ ${page.params.map((param) => `${param.name} : Str`).join(", ")} }`;
		return [`\t## ${page.path}, from routes/${page.file}`, `\t${page.name} : ${type} -> Str`, `\t${page.name} = |params| ${urlOf(page)}`];
	};
	const statics = table.pages.filter((page) => !page.params.length).map((page) => JSON.stringify(page.path));
	const anyParams = table.pages.some((page) => page.params.length);
	return [
		"## Written by rocx build from the app's routes/: a path for every page, so a link to a page that",
		"## isn't there doesn't compile. Edit the routes, not this file.",
		...(anyParams ? ["import pf.Server", ""] : []),
		"Paths := [].{",
		...[...table.pages].sort((a, b) => a.path.localeCompare(b.path)).flatMap((page) => [...definition(page), ""]),
		"\t## Every page with no params: what a static build writes.",
		"\tall : List(Str)",
		`\tall = [${statics.join(", ")}]`,
		"}",
		"",
		`${MARKER} the routes: rocx build writes it.`,
		"",
	].join("\n");
}

/**
 * `Generated/Root.roc`, for both the server and the browser: the app's page, which the host renders
 * for a request and the browser hydrates. Its `view!` reads where the page is (`Router.location!`),
 * matches its segments as `Routes` does, and renders that path's component page (`{ params }`) in
 * the layouts above it (`{ meta, children, params }`: the page's `meta`), the root layout being the
 * document (or, with none, a default one). Inside the root layout, around the rest, an `<Errored>`:
 * a failure nothing else catches is the error page (`{ status, problem }`) with
 * `<HttpStatusCode code={500}/>`. A failure in the root layout itself is the server's 500. A path
 * no page has is the error page with `<HttpStatusCode code={404}/>`. The default document's <head>
 * has the app's stylesheet (Generated/Styles).
 */
export function rootModule(table, { sources, stories = [] }) {
	const pages = table.pages;
	const root = table.layouts.find((layout) => !layout.parts.length) ?? null;
	const meta = (entry) => (entry && sources.get(entry.file).meta ? `${entry.module}.meta` : "{}");
	const layout = (entry, metaOf, children) => `Html.component(|| ${entry.module}.view!({ params: params, meta: ${metaOf}, children: [${children}] }))`;
	// The document: the root layout, or a default one, around `inside`.
	const documented = (metaOf, inside) => (root ? layout(root, metaOf, inside) : `${ROOT}.document([${inside}])`);
	const branch = (page) => {
		const inner = page.layouts.filter((each) => each !== root).reduceRight((html, each) => layout(each, meta(page), html), `Html.component(|| ${page.module}.view!({ params: params }))`);
		return [`if (${matchedBy(page)}) {`, `\t\t\tparams = ${paramsOf(page)}`, `\t\t\t${documented(meta(page), `${ROOT}.guarded!([${inner}])`)}`, "\t\t}"].join("\n");
	};
	const missing = [...(root ? ["\t\t\tparams = {}"] : []), `\t\t\t${documented(meta(table.error), `${ROOT}.failed(404, "nothing at \${path}")`)}`].join("\n");
	// A dev build's stories (rocx build --dev): each at /__rocx/stories/<id>, in the root layout with
	// the front page's meta, run where it is rendered, as a page is.
	const told = stories;
	const front = pages.find((page) => page.path === "/") ?? table.error;
	const storied = told.length
		? [
				`if (path.starts_with(${JSON.stringify(`${STORIES_PATH}/`)})) {`,
				`\t\t\tid = path.drop_prefix(${JSON.stringify(`${STORIES_PATH}/`)})`,
				...(root ? ["\t\t\tparams = {}"] : []),
				...told.map((story, i) => `\t\t\t${i ? "} else " : ""}if (id == ${JSON.stringify(story.id)}) {\n\t\t\t\t${documented(meta(front), `${ROOT}.guarded!([Html.component(|| ${story.alias}.${story.def}({}))])`)}`),
				`\t\t\t} else {\n\t\t\t\t${documented(meta(front), `${ROOT}.failed(404, "no story at \${path}")`)}\n\t\t\t}`,
				"\t\t}",
			].join("\n")
		: null;
	const branches = [...(storied ? [storied] : []), ...pages.map(branch)];
	const storyModules = [...new Map(told.map((story) => [story.module, story.alias])).entries()].sort();
	const error = table.error
		? `Html.component(|| ${table.error.module}.view!({ status: status, problem: problem }))`
		: 'Html.element("main", [], [Html.element("h1", [], [Html.text(status.to_str())]), Html.element("p", [], [Html.text(problem)])])';
	const modules = [...new Set([...pages.flatMap((page) => [...page.layouts, page]), ...(table.error ? [table.error] : []), ...(root ? [root] : [])].map((entry) => entry.module))].sort();
	return [
		"## Written by rocx build from the app's routes/: the app's page, for the server, which renders it for",
		"## a request, and for the browser, which hydrates it: the page at where it is, in the +layout.rocx",
		"## files above it, or +error.rocx where no page is, or where a page failed. Edit those files, not this one.",
		"import pf.Html",
		"import pf.Router",
		...(pages.length ? ["import pf.Server"] : []),
		"import pf.Errored",
		"import pf.HttpStatusCode",
		...modules.map((module) => `import ${module}`),
		...storyModules.map(([module, alias]) => `import ../${module} as ${alias}`),
		...(!root ? ["import Styles"] : []),
		"",
		`${ROOT} := [].{`,
		"\t## The page at where it is (`Router.location!`: the request's path on the server; in the browser,",
		"\t## the page's, without the base): its route's page, given its params, in its layouts, the error",
		"\t## page (500) for a failure nothing else catches; the error page (404) where no page is.",
		"\tview! : {} => Html",
		"\tview! = |{}| {",
		"\t\tpath = Router.location!({}).path",
		...(pages.length ? ['\t\tsegments = path.split_on("/").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)'] : []),
		branches.length ? `\t\t${branches.join(" else ")} else {\n${missing}\n\t\t}` : missing.replace(/^\t/gm, ""),
		"\t}",
		"",
		"\t## What is inside the root layout: when it fails and nothing in it catches that, the error page.",
		"\tguarded! : List(Html) => Html",
		`\tguarded! = |children| Errored.view!({ fallback: |problem, _retry| ${ROOT}.failed(500, problem), children: children })`,
		"",
		"\t## The error page for `status` (404: no page is here; 500: the page failed), which the server",
		"\t## answers with (`<HttpStatusCode>`), and why.",
		"\tfailed : U16, Str -> Html",
		`\tfailed = |status, problem| Html.join([Html.component(|| HttpStatusCode.view!({ code: status })), ${error}])`,
		...(root
			? []
			: [
					"",
					"\t## The document, for an app with no root layout (routes/+layout.rocx).",
					"\tdocument : List(Html) -> Html",
					"\tdocument = |children|",
					"\t\tHtml.join(",
					"\t\t\t[",
					"\t\t\t\tHtml.doctype({}),",
					'\t\t\t\tHtml.element("html", [Html.attr("lang", "en")], [',
					`\t\t\t\t\tHtml.element("head", [], [Html.void("meta", [Html.attr("charset", "utf-8")]), Html.void("meta", [Html.attr("name", "viewport"), Html.attr("content", "width=device-width, initial-scale=1")]), Styles.style]),`,
					'\t\t\t\t\tHtml.element("body", [], children),',
					"\t\t\t\t]),",
					"\t\t\t],",
					"\t\t)",
				]),
		"}",
		"",
		`${MARKER} the routes: rocx build writes it.`,
		"",
	].join("\n");
}

/** A job's definition in a module (`welcome = Job.define("welcome", …)`, or
 * `Job.define_with("welcome", { attempts, timeout_ms }, …)`): its indentation, its name in the module,
 * and the job's name. */
const JOB_DEFINITION = /^([ \t]*)([a-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*Job\.define(?:_with)?\(\s*"([^"]+)"/gm;

/**
 * The jobs the app under `dir` defines (`Job.define`, `Job.define_with`), for `Generated/App`'s `program.jobs`: each
 * `{ name, define, module, file, line }`, `module` the one `App` imports (`Jobs`; a route file's,
 * `Generated/MembersServer`), by file and line. Every .roc and .rocx file but rocx's (Generated/,
 * build/, dist/; a .roc it wrote for a .rocx file) is read, outside directories starting with a dot
 * (but `.well-known`). A job is defined inside its module's
 * block, at its top (`Jobs := [].{` then `\twelcome = Job.define(…)`), so that App can name it
 * (`Jobs.welcome`); and no two jobs have one name, which is how the workers find a job. `problems`
 * says what isn't so, a line each.
 */
export function jobsIn(dir, table) {
	const routes = new Map(routedEntries(table).map((entry) => [`routes/${entry.file}`, entry]));
	const jobs = [];
	const problems = [];
	const walk = (at) => {
		for (const entry of readdirSync(at).sort()) {
			if ((entry.startsWith(".") && entry !== WELL_KNOWN) || /^(build|dist|Generated|node_modules)$/.test(entry)) continue;
			const path = join(at, entry);
			if (statSync(path).isDirectory()) {
				walk(path);
				continue;
			}
			if (!/\.rocx?$/.test(entry)) continue;
			const source = readFileSync(path, "utf8");
			if (entry.endsWith(".roc") && (existsSync(`${path}x`) || source.trimEnd().split("\n").pop().startsWith(MARKER))) continue;
			const file = relative(dir, path).split(sep).join("/");
			const route = routes.get(file);
			for (const match of source.matchAll(JOB_DEFINITION)) {
				const [, indent, define, name] = match;
				const line = source.slice(0, match.index).split("\n").length;
				// A route file's definitions are its module's: rocx puts them in its block.
				const module = route ? `${GENERATED}/${route.module}` : file.replace(/\.rocx?$/, "");
				const type = module.split("/").pop();
				if (indent !== (route ? "" : "\t")) {
					problems.push(`${file}:${line}: the job "${name}" is defined ${indent ? "inside a definition" : "outside its module's block"}: define it at the top of \`${type} := [].{ … }\`, as \`${route ? "" : "\t"}${define} = Job.define(…)\`, so Generated/App can name it (\`${type}.${define}\`)`);
				} else jobs.push({ name, define, module, file, line, route: route?.module ?? null });
			}
		}
	};
	if (existsSync(dir)) walk(dir);
	const named = new Map();
	for (const job of jobs) {
		const other = named.get(job.name);
		if (other) problems.push(`${job.file}:${job.line}: there is a job called "${job.name}" already (${other.file}:${other.line}): the workers find a job by its name, so give each its own`);
		else named.set(job.name, job);
	}
	return { jobs, problems };
}

/** The app's migrations, `migrations/*.sql` under `dir`, in the order of their names. */
export function migrationsIn(dir) {
	const at = join(dir, "migrations");
	if (!existsSync(at) || !statSync(at).isDirectory()) return [];
	return readdirSync(at)
		.filter((name) => name.endsWith(".sql") && statSync(join(at, name)).isFile())
		.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

/** The module rocx writes the app's program in (`Generated/App.roc`), for its main.roc. */
export const APP = "App";

/**
 * `Generated/App.roc`, the server's: `App.program({ context, middleware, crons })`, the platform's
 * `program` from what only the author can say: every request answered by `Routes.respond!`, behind
 * `middleware`, which is given `context(started)` (`started`: what the server was started with,
 * `--context-file`), a page view letting a plain form's flash go (`Server.clear_flash`); the jobs found (`jobsIn`), each `Job.handler(Module.name)`; the migrations
 * (`migrationsIn`: names), embedded, in order; and `crons` as given.
 */
export function appModule({ jobs = [], migrations = [], endpoints = false } = {}) {
	const alias = (job) => (job.route ? job.route : job.module.split("/").join(""));
	const imports = [...new Map(jobs.map((job) => [alias(job), job.route ? `import ${job.route}` : `import ../${job.module} as ${alias(job)}`])).entries()].sort(([a], [b]) => (a < b ? -1 : 1)).map(([, line]) => line);
	const names = new Set();
	const embedded = migrations.map((name) => {
		const base = `m${name.replace(/\.sql$/, "").toLowerCase().replace(/[^a-z0-9_]+/g, "_")}`;
		let as = base;
		for (let i = 2; names.has(as); i++) as = `${base}_${i}`;
		names.add(as);
		return { name, as };
	});
	return [
		"## Written by rocx build: the app's `program`, for its main.roc, which says what only it can",
		"## (`program = App.program({ context, middleware, crons })`, and `openapi` if it serves its",
		"## endpoints' OpenAPI document). Every request is answered by the routes (`Routes.respond!`),",
		"## behind the app's middleware; the jobs are the ones its modules define (`Job.define`); the",
		"## migrations, migrations/*.sql, in the order of their names.",
		"import pf.Server",
		"import pf.Middleware",
		"import pf.OpenApi",
		...(jobs.length ? ["import pf.Job"] : []),
		...(endpoints ? ["import Api"] : []),
		"import Routes",
		...imports,
		...embedded.map(({ name, as }) => `import ${rocString(`../migrations/${name}`)} as ${as} : Str`),
		"",
		`${APP} := [].{`,
		"\t## What only the app can say: `context`, what its middleware is given from what the server was",
		"\t## started with (`--context-file`: `|started| …`); `middleware`, which runs around every",
		"\t## request; `crons`, the jobs on a schedule (`Cron.every`); and `openapi`, whether it serves its",
		"\t## endpoints' OpenAPI document, and a page to read it in (`OpenApi.Serving`): `Off` unless it",
		"\t## says.",
		"\tConfig(given, handed) := {",
		"\t\tcontext : Str -> given,",
		"\t\tmiddleware : Middleware(given, handed),",
		"\t\tcrons : List({ name : Str, schedule : Str, job : Str, input : Str }),",
		"\t\topenapi : OpenApi.Serving ?? Off,",
		"\t}",
		"",
		"\t## The platform's program, from what the app says (`Config`).",
		"\tprogram : Config(_, _) -> _",
		"\tprogram = |config| {",
		"\t\trespond!: |method, target, headers, body, started| {",
		"\t\t\trequest = Server.from_http(method, target, headers, body)",
		"\t\t\t# A page a browser asks for lets a plain form's flash go (`Server.flash!`): it has read it, or never will.",
		...(endpoints
			? [
					"\t\t\t# Behind the app's middleware: the endpoints' OpenAPI document and its page, as the app says",
					"\t\t\t# (`OpenApi.respond`), then the routes.",
					"\t\t\tanswer! = |passed, context|",
					"\t\t\t\tmatch OpenApi.respond(passed, config.openapi, Api.openapi) {",
					"\t\t\t\t\tOk(served) => served",
					"\t\t\t\t\tErr(NotHere) => Routes.respond!(passed, context)",
					"\t\t\t\t}",
				]
			: ["\t\t\tanswer! = |passed, context| Routes.respond!(passed, context)"]),
		"\t\t\tServer.clear_flash(request, Middleware.run!(config.middleware, request, (config.context)(started), answer!))",
		"\t\t},",
		`\t\tmigrations: [${embedded.map(({ name, as }) => `{ name: ${rocString(name)}, sql: ${as} }`).join(", ")}],`,
		`\t\tjobs: [${jobs.map((job) => `Job.handler(${alias(job)}.${job.define})`).join(", ")}],`,
		"\t\tcrons: config.crons,",
		"\t}",
		"}",
		"",
		`${MARKER} the app: rocx build writes it.`,
		"",
	].join("\n");
}

/**
 * The browser's app (`rocx build --client <out>`, `<out>/main.roc`): the app's page
 * (`Generated/Root`), which the browser hydrates (web/start.js), on the web platform (`web`, its
 * path from there), with the packages the server's app names besides its platform (`packages`:
 * `name: "path"`, from there).
 */
export function clientMainModule({ web, packages = [], dir = "." }) {
	return [
		`## The browser's app, written by rocx build --client from ${dir}: the app's page (\`Generated/Root\`),`,
		"## which the browser hydrates (web/start.js), on the web platform. Don't edit it.",
		`app [main!] { ${[...packages, `pf: platform ${JSON.stringify(web)}`].join(", ")} }`,
		"",
		"import pf.Html",
		`import ${GENERATED}/${ROOT}`,
		"",
		"main! : {} => Html",
		`main! = |{}| ${ROOT}.view!({})`,
		"",
		`${MARKER} the routes: rocx build --client writes it.`,
		"",
	].join("\n");
}

/**
 * Every route, as `rocx routes` prints it, by path: each method a path answers, the file that answers
 * it (relative to the app), and the middleware that file names (the app's default runs before it,
 * for every request); each server function in `functions` (`serverFunctionsIn`), a POST to
 * `/rocx/call/<name>`; and, with endpoints, their OpenAPI document (no file: rocx writes it).
 */
export function routeList(table, sources, functions = []) {
	const rows = [];
	// By path, so a directory's routes are together, as its files are.
	for (const at of [...table.paths].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) {
		if (at.page) rows.push({ method: "GET", path: at.path, file: `routes/${at.page.file}`, middleware: sources.get(at.page.file).middleware });
		for (const method of at.server ? sources.get(at.server.file).methods : []) {
			rows.push({ method: method === "events!" ? "EVENTS" : verbOf(method), path: at.path, file: `routes/${at.server.file}`, middleware: sources.get(at.server.file).middleware });
		}
		// `respond!`: whatever else comes.
		if (at.server && sources.get(at.server.file).respond) rows.push({ method: "*", path: at.path, file: `routes/${at.server.file}`, middleware: sources.get(at.server.file).middleware });
	}
	// The server functions (`serverFunctionsIn`), each a POST to its own path, in their place by path.
	for (const f of functions) {
		const row = { method: "POST", path: `${CALL_PATH}${f.name}`, file: f.file, middleware: f.middleware };
		const at = rows.findIndex((other) => other.path > row.path);
		rows.splice(at < 0 ? rows.length : at, 0, row);
	}
	if (table.error) rows.push({ method: "*", path: "(anything else)", file: `routes/${table.error.file}`, middleware: null });
	return rows;
}

/** `rocx routes`: the routes of the app in `dir` (its `routes/`, and its server functions), a line each, in columns. */
export function routesTable(dir) {
	const routes = join(dir, "routes");
	const table = routeTable(findRouteFiles(routes));
	const sources = new Map(routedEntries(table).map((entry) => [entry.file, definitions(readFileSync(join(routes, ...entry.file.split("/")), "utf8"))]));
	const rows = routeList(table, sources, serverFunctionsIn(dir, table, sources)).map((row) => [row.method, row.path, row.file, row.middleware ?? "-"]);
	const header = ["METHOD", "PATH", "FILE", "MIDDLEWARE (after the app's default)"];
	const widths = header.map((title, i) => Math.max(title.length, ...rows.map((row) => row[i].length)));
	return [header, ...rows].map((row) => row.map((cell, i) => (i === row.length - 1 ? cell : cell.padEnd(widths[i]))).join("  ")).join("\n");
}

/** Whether `path` (`/blog/rocx`) is the path of a page whose route is `route` (`/blog/[slug]`). */
export function matches(route, path) {
	const want = route.split("/").filter(Boolean);
	const have = path.split("/").filter(Boolean);
	return want.length === have.length && want.every((part, i) => part.startsWith("[") || part === have[i]);
}
