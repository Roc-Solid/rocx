#!/usr/bin/env node
// Builds the docs site. The site is written in rocx and shows rocx on itself: every example is a
// real file under site/examples, shown beside the Roc rocx wrote for it and what it renders; the
// refusals are rocx's own messages, the compiler report is the compiler's, and the sizes and
// timings are measured here, on this build.
//
//   node site/build.mjs             everything, then each page rendered into site/dist (a static site)
//   node site/build.mjs --prepare   steps 1 and 2 only: what `roc check` needs
//   node site/build.mjs --dev       steps 1 to 4 from Roc's dev backend, no measuring: `just dev`'s
//
// `serve.mjs` builds with `dev`: everything from Roc's dev backend, and no measuring, so a save is
// rebuilt in a fraction of a second instead of seconds of LLVM.
//
// The steps, which `serve.mjs` runs too before it starts the server:
//   1. .rocx → .roc (rocx build): the pages (site/routes), their components (site/Ui, site/Demos)
//      and the program (site/Generated/App.roc), and the browser's copy of the site
//      (site/build/client), in which a server function is only its name, with its main.roc
//   2. site/Generated/Sources.roc: the sources, refusals and report the pages show
//   3. the browser's wasm: the same pages, on the web platform (its Zig host), built from the
//      browser's copy (site/build/client/main.roc) into site/build/client/static/rocx/app.wasm,
//      beside the start.js and runtime.js rocx build put there: a page loads all three from /rocx/
//   4. the server: site/main.roc, every page, endpoint and server function, natively, on the server
//      platform (its Rust host), one executable (site/build/server)
//   5. facts: what the wasm weighs, how long rendering a page takes in it; for the pages, in
//      site/build/context.txt, which the server is started with
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { build as rocxBuild } from "../bin/rocx.mjs";
import { definitions, findRouteFiles, pathsModule, routesTable, routeTable } from "../src/routes.mjs";
import { split as splitWasm } from "../src/split.mjs";
import { RocxError, rocString, transpile } from "../src/transpile.mjs";
import { Runtime } from "../web/runtime.js";
import { buildApp, buildHost, start, syncShared, zig } from "../server/build.mjs";

export const root = join(dirname(fileURLToPath(import.meta.url)), "..");
export const site = join(root, "site");
export const out = join(site, "build");
export const dist = join(site, "dist");
/** The browser's copy of the site (`rocx build --client`), which the browser's app is built from. */
export const client = join(out, "client");
const rocxBin = join(root, "bin", "rocx.mjs");

/** The pages, from site/routes (`/`, `/syntax`; `/blog/[slug]` would be one too). */
const pages = () => routeTable(findRouteFiles(join(site, "routes"))).pages;

/** The pages a static build writes: those with no params, and none behind middleware of its own,
 * which answers each request as it comes (`/members`: who is asking?). */
export const ROUTES = pages()
	.filter((page) => !page.params.length && !definitions(readFileSync(join(site, "routes", page.file), "utf8")).middleware)
	.map((page) => page.path);


export function roc() {
	// The fork rocx builds with, which `just setup` builds and links (the Justfile says why), as the
	// file it links to: a new pin is a new path. Else $ROC; never the `roc` on PATH, which may lack
	// the fork's fixes.
	const active = join(root, ".tools", "roc-active");
	if (existsSync(active)) return realpathSync(active);
	if (process.env.ROC) return process.env.ROC;
	throw new Error("no Roc compiler: run `just setup` (or set ROC)");
}

function run(command, args, { cwd = root } = {}) {
	const result = spawnSync(command, args, { cwd, encoding: "utf8" });
	if (result.error) throw result.error;
	const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
	if (result.status !== 0) throw new Error(`${basename(command)} ${args.join(" ")} failed:\n${output}`);
	return output;
}

function writeIfChanged(path, content) {
	// An unchanged file stays untouched, so a watcher doesn't see a change and build again.
	if (existsSync(path) && readFileSync(path, "utf8") === content) return;
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
}

const newer = (path, than) => existsSync(path) && than.every((other) => statSync(path).mtimeMs >= statSync(other).mtimeMs);

// ---- 2. What the pages show ----

/** Lines without the indentation they all share. */
function dedent(lines) {
	const indents = lines.filter((line) => line.trim()).map((line) => /^\t*/.exec(line)[0].length);
	const common = Math.min(...indents);
	return lines.map((line) => line.slice(common)).join("\n");
}

const snake = (name) => name.replace(/[A-Z]/g, (c, i) => (i ? "_" : "") + c.toLowerCase());

/** An example: the lines between `# example` and `# /example`, from both files, which match. */
function example(file) {
	const path = join(site, "examples", file);
	const rocx = readFileSync(path, "utf8").split("\n");
	const generated = readFileSync(path.replace(/\.rocx$/, ".roc"), "utf8").split("\n");
	const start = rocx.findIndex((line) => line.trim() === "# example");
	const end = rocx.findIndex((line) => line.trim() === "# /example");
	if (start < 0 || end < start) throw new Error(`${file}: mark the example with # example and # /example`);
	const module = basename(file, ".rocx");
	const call = /demo = \|\{\}\| view\((.*)\)$/m.exec(rocx.join("\n"));
	return {
		name: snake(module),
		file: `examples/${file}`,
		rocx: dedent(rocx.slice(start + 1, end)),
		roc: dedent(generated.slice(start + 1, end)),
		first: start + 2,
		call: `${module}.view(${call ? call[1] : ""})`,
	};
}

/** A whole file, shown as it is. */
function whole(name, path) {
	return { name, file: path, rocx: readFileSync(join(root, path), "utf8").replace(/\n+$/, ""), roc: "", first: 1, call: "" };
}

/** The lines of a file that `pattern` matches, as they are there: a definition, say. */
function lines(name, path, pattern) {
	const found = readFileSync(join(root, path), "utf8").split("\n").filter((line) => pattern.test(line));
	if (!found.length) throw new Error(`${path}: nothing matches ${pattern}`);
	return { name, file: path, rocx: dedent(found), roc: "", first: 1, call: "" };
}

/** Lines of a file that `pattern` matches, each without its indentation, "…" where lines were left out. */
function excerpt(name, path, pattern) {
	const all = readFileSync(join(root, path), "utf8").split("\n");
	const out = [];
	let last = -1;
	all.forEach((line, i) => {
		if (!pattern.test(line)) return;
		if (last >= 0 && i > last + 1) out.push("…");
		out.push(line.trim());
		last = i;
	});
	if (!out.length) throw new Error(`${path}: nothing matches ${pattern}`);
	return { name, file: path, rocx: out.join("\n"), roc: "", first: 1, call: "" };
}

/**
 * Lines of a file as they are there, indentation and all: each of `starts` is the next line that
 * starts with it (its indentation aside), in order; "…" stands where lines were left out.
 */
function pick(name, path, starts) {
	const all = readFileSync(join(root, path), "utf8").split("\n");
	const kept = [];
	let at = 0;
	for (const start of starts) {
		const found = all.findIndex((line, i) => i >= at && line.trimStart().startsWith(start));
		if (found < 0) throw new Error(`${path}: no line after ${at + 1} starts with ${JSON.stringify(start)}`);
		if (kept.length && found > at) kept.push(`${/^\t*/.exec(all[found])[0]}…`);
		kept.push(all[found]);
		at = found + 1;
	}
	return { name, file: path, rocx: dedent(kept), roc: "", first: 1, call: "" };
}

/**
 * Definitions of a file, whole, by name, each with its `##` comment and its annotation: from the
 * comment to the blank line after it (or the line that closes its block). A blank line between
 * them; each dedented. For the platform's samples (server/test/app/Samples.roc), compiled and run
 * by the server's tests.
 */
function defined(name, path, names) {
	const all = readFileSync(join(root, path), "utf8").split("\n");
	const parts = names.map((wanted) => {
		const at = all.findIndex((line) => new RegExp(`^\\s*${wanted.replace(/[!$]/g, "\\$&")}\\s*:(?!=)`).test(line));
		if (at < 0) throw new Error(`${path}: no definition of ${wanted}`);
		let start = at;
		while (start > 0 && all[start - 1].trimStart().startsWith("##")) start--;
		let end = at;
		while (end + 1 < all.length && all[end + 1].trim() && !/^}/.test(all[end + 1])) end++;
		return dedent(all.slice(start, end + 1));
	});
	return { name, file: path, rocx: parts.join("\n\n"), roc: "", first: 1, call: "" };
}

/** Picks from one file (`pick`'s), each dedented on its own, with a blank line between them. */
function picks(name, path, ...groups) {
	const parts = groups.map((starts) => pick(name, path, starts));
	return { ...parts[0], rocx: parts.map((part) => part.rocx).join("\n\n") };
}

/** The first `count` lines of a file, as they are there, and "…" after them. */
function first(name, path, count) {
	const all = readFileSync(join(root, path), "utf8").split("\n");
	return { name, file: path, rocx: [...all.slice(0, count), ...(all.length > count ? ["…"] : [])].join("\n"), roc: "", first: 1, call: "" };
}

/** This site's route files, each with the path it is or what it does. */
function routeTree() {
	const roles = { "+layout.rocx": "around every page", "+error.rocx": "where no page is" };
	const table = routeTable(findRouteFiles(join(site, "routes")));
	const paths = new Map([...table.pages.map((page) => [page.file, page.path]), ...table.servers.map((server) => [server.file, `${server.path}, its endpoints`])]);
	const files = findRouteFiles(join(site, "routes")).sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b));
	const width = Math.max(...files.map((file) => file.length)) + 2;
	const behind = (file) => {
		const { middleware } = definitions(readFileSync(join(site, "routes", file), "utf8"));
		return middleware ? `, behind ${middleware}` : "";
	};
	return { name: "route_tree", file: "site/routes", rocx: files.map((file) => `${file.padEnd(width)}# ${paths.get(file) ?? roles[file.split("/").pop()]}${behind(file)}`).join("\n"), roc: "", first: 1, call: "" };
}

/** What `rocx routes site` prints. */
function routeList() {
	return { name: "route_list", file: "rocx routes site", rocx: `$ rocx routes site\n${routesTable(site)}`, roc: "", first: 1, call: "" };
}

/** What rocx writes for the routes of the e2e test's app (with a param): its Paths. */
function fixturePaths() {
	const table = routeTable(findRouteFiles(join(root, "test", "e2e", "routes", "routes")));
	const text = pathsModule(table).split("\n").filter((line) => !line.startsWith("# rocx")).join("\n").trim();
	return { name: "route_fixture_paths", file: "Generated/Paths.roc", rocx: text, roc: "", first: 1, call: "" };
}

/** Markup rocx refuses, and why, in its own words. */
const REFUSED = [
	`<a onclick="go()">Go</a>`,
	`<b on:click="go()">Go</b>`,
	`<p style={styles}>Hi</p>`,
	`<a title=hi>Hi</a>`,
	`<br>`,
	`<ul><li>One</li></ol>`,
	`<p>1 < 2</p>`,
	`<p>&bogus;</p>`,
	`<DIV>Hi</DIV>`,
	`<input checked?="yes" />`,
	`<p style:color={c}>Hi</p>`,
	`<input on:input.files={f} />`,
];

function refusals() {
	return REFUSED.map((source) => {
		try {
			transpile(`x = ${source}`, "Page.rocx");
			throw new Error(`rocx accepted ${source}`);
		} catch (error) {
			if (!(error instanceof RocxError)) throw error;
			return { source, reason: error.reason, column: error.column - 4 };
		}
	});
}

/** The compiler's report on a real mistake, pointed into the .rocx file by `rocx check`. It takes
 * a compiler run, so it is kept, and made again only when what makes it changes. */
function checkReport() {
	const source = ["import pf.Html", "", "Posts := [].{", "\tview : List(Str) -> Html", "\tview = |posts|", '\t\t<p class="count">', "\t\t\tYou have {posts.len()} posts", "\t\t</p>", "}", ""].join("\n");
	const inputs = [source, roc(), ...["src/transpile.mjs", "src/remap.mjs", "bin/rocx.mjs", "web/platform/Html.roc"].map((path) => readFileSync(join(root, path), "utf8"))];
	const key = createHash("sha256").update(inputs.join("\0")).digest("hex");
	const kept = join(out, "check-report.json");
	if (existsSync(kept)) {
		const saved = JSON.parse(readFileSync(kept, "utf8"));
		if (saved.key === key) return saved;
	}
	const made = makeCheckReport(source);
	mkdirSync(out, { recursive: true });
	writeFileSync(kept, JSON.stringify({ key, ...made }));
	return made;
}

function makeCheckReport(source) {
	const dir = join(out, "check");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	// An app on the web platform, whose main! renders the posts: `roc check Posts.roc` checks it.
	writeFileSync(join(dir, "main.roc"), `app [main!] { pf: platform ${JSON.stringify(relative(dir, join(root, "web", "platform", "main.roc")))} }\n\nimport pf.Html\nimport Posts\n\nmain! : {} => Html\nmain! = |{}| Posts.view([])\n`);
	writeFileSync(join(dir, "Posts.rocx"), source);
	run("node", [rocxBin, "build", "."], { cwd: dir });
	const checked = spawnSync("node", [rocxBin, "check", "--", roc(), "check", "Posts.rocx".replace(".rocx", ".roc")], { cwd: dir, encoding: "utf8" });
	const report = `${checked.stdout}`.trim();
	return { source: readFileSync(join(dir, "Posts.rocx"), "utf8").trimEnd(), report: report || "(the compiler said nothing)" };
}

function sourcesModule() {
	const examples = readdirSync(join(site, "examples"))
		.filter((file) => file.endsWith(".rocx"))
		.sort()
		.map(example);
	const files = [
		whole("demo_counter", "site/Demos/Counter.rocx"),
		whole("ui_callout", "site/Ui/Callout.rocx"),
		routeTree(),
		first("route_page", "site/routes/showcase/+page.rocx", 23),
		first("route_page_generated", "site/Generated/ShowcasePage.roc", 23),
		pick("route_layout", "site/routes/+layout.rocx", ["import pf.Html", "import pf.Router", "import ../Facts", "import ../Ui/Nav", "import ../Generated/Paths", "## The document around", "## this part's pages", "## page's (its title", "## the facts the build", "view! = |{ meta, children, .. }| {", "path = Router.location!({}).path", "facts = Facts.facts!({})"]),
		pick("route_routes", "site/Generated/Routes.roc", [
			"Routes := [].{", "respond! = |request, context| {", "segments = ", "method = ", "wants_html = ",
			"if (request.path.starts_with(\"/rocx/call/\"))", "if (request.method == \"POST\")", "ServerFunctions.respond!(", "} else {", "Endpoint.not_allowed", "}",
			"} else if (segments == [\"api\", \"shout\"])", "params = {}", "if (method == \"POST\")", "Endpoint.respond!(Api.post_api_shout", "} else {", "Endpoint.not_allowed", "}",
			"} else if (segments == [\"calls\"])", "if (method == \"GET\")", "Routes.page(200)", "} else {", "Endpoint.not_allowed", "}",
			"} else {", "if (wants_html)", "Routes.page(404)", "} else {", "Routes.text(404,", "}", "}", "}",
		]),
		pick("route_main", "site/main.roc", ["import Generated/App", "import Middlewares", "", "# The count", "# The calls page", "import Demos/Count", "", "## Every request:", "## server was started with", "## jobs or schedules.", "program = App.program({", "context:", "middleware:", "crons:", "openapi:", "})"]),
		routeList(),
		pick("route_members", "site/Generated/Routes.roc", ["} else if (segments == [\"members\"])", "params = {}", "if (method == \"GET\" and wants_html)", "Middleware.run!(MembersPage.middleware", "} else if (method == \"GET\")", "Middleware.run!(MembersServer.middleware", "} else {", "Endpoint.not_allowed", "}"]),
		pick("middleware_type", "web/platform/Middleware.roc", ["Middleware(given, handed) ::", "## A middleware, from what it does.", "make :", "## `first`, then `second`", "then :", "## A request that would change", "## a form, an endpoint)", "## can make a browser", "## (`Origin`).", "same_origin :", "## Every answer with these headers too.", "headers :"]),
		whole("site_middlewares", "site/Middlewares.roc"),
		pick("members_page", "site/routes/members/+page.rocx", ["import pf.Html", "import pf.Endpoint", "import pf.Server", "import ../../Middlewares", "import ../../Generated/Api", "import ../../Generated/Paths", "", "## Members only", "middleware = Middlewares.member", "", "## Who the member is", "## handed on the name", "member! :", "member! =", "", "view! = |_| {", "member = member!({})", "<>", "<PageHero", "eyebrow=\"Members\"", "title={\"Welcome, ${member}\"}"]),
		whole("members_server", "site/routes/members/+server.roc"),
		whole("members_join_server", "site/routes/members/join/+server.roc"),
		pick("openapi_api", "site/Generated/Api.roc", ["## The OpenAPI document of these endpoints", "## each path and its methods", "## sent and answers", "## could be a tag", "openapi : Str", "openapi = {", "tags = [", "\"", "]", "OpenApi.document(", "OpenApi.path(\"/api/shout/{word}\"", "OpenApi.operation(\"get\"", "]),", "])", "}"]),
		pick("openapi_format", "web/platform/OpenApi.roc", ["## The schema of what an endpoint is sent", "body : Endpoint(", "where [arg.parser_for", "body = |_, tags| {", "Sent : arg", "described(Sent.parser_for(", "}", "## A format that reads nothing", "## as `Json` writes that shape", "Schema := [Default].{", "parse_str : Schema", "parse_str = ", "parse_u64 : Schema", "parse_u64 = "]),
		whole("endpoint_shout", "site/routes/api/shout/+server.roc"),
		whole("endpoint_shout_word", "site/routes/api/shout/[word]/+server.roc"),
		whole("endpoint_count", "site/routes/api/count/[to]/+server.roc"),
		pick("demo_count_update", "site/Demos/Count.rocx", ["start! = || {", "set_heard!([])", "set_state!(Listening)", "Endpoint.listen!(", "Api.events_api_count_to(", "Call.listen!,", "|event|", "match event {", "Event(counted) =>", "Ended =>", "Failed(problem) =>", "}", ")", "}"]),
		lines("endpoint_api", "site/Generated/Api.roc", /^\t(post_api_shout|get_api_shout_word) = /),
		lines("endpoint_api_browser", "site/build/client/Generated/Api.roc", /^\t(post_api_shout|get_api_shout_word) = /),
		whole("demo_shout", "site/Demos/Shout.rocx"),
		whole("demo_count", "site/Demos/Count.rocx"),
		pick("route_nav", "site/Ui/Nav.roc", ["import ../Generated/Paths", "rocx_docs : Section", "rocx_docs = {", "name: \"rocx\",", "home: Paths.rocx,", "pages: [", "{ path: Paths.rocx", "{ path: Paths.showcase", "{ path: Paths.syntax", "],"]),
		whole("route_error", "site/routes/+error.rocx"),
		whole("route_fixture_page", "test/e2e/routes/routes/blog/[slug]/+page.rocx"),
		fixturePaths(),
		pick("home_update", "site/Demos/Counter.rocx", ["view! = |{ start_value }| {", "(count!, set_count!) = create_signal!(start_value)", "<div class=\"counter\"", "<button type=\"button\" on:click={|| set_count!(count!() - 1)}", "<output>", "<button type=\"button\" on:click={|| set_count!(count!() + 1)}", "</div>", "}"]),
		excerpt("home_signals", "site/Demos/Echo.rocx", /^\techo! = |^\t\tsaid! =|<Answer said!/),
		whole("demo_todos", "site/Demos/Todos.rocx"),
		whole("demo_escape_lab", "site/Demos/EscapeLab.rocx"),
		whole("demo_snake", "site/Demos/Snake.rocx"),
		whole("demo_birds", "site/Demos/Birds.rocx"),
		whole("demo_timers", "site/Demos/Timers.rocx"),
		whole("demo_clock", "site/Demos/Clock.rocx"),
		picks("charts_use", "site/Demos/BarDemo.rocx", ["import charts.BarChart", "import charts.Format"], ["<BarChart data!="]),
		picks("charts_use_line", "site/Demos/LineDemo.rocx", ["import charts.Format", "import charts.LineChart"], ["<LineChart data!="]),
		picks("charts_use_donut", "site/Demos/DonutDemo.rocx", ["import charts.DonutChart", "import charts.Format"], ["<DonutChart data!="]),
		picks("charts_use_scatter", "site/Demos/ScatterDemo.rocx", ["import charts.Format", "import charts.ScatterChart"], ["<ScatterChart", "data!=", "label=", "format_x=", "format_y=", "/>"]),
		whole("demo_shuffle", "site/Demos/Shuffle.rocx"),
		whole("demo_bars", "site/Demos/BarDemo.rocx"),
		whole("demo_line", "site/Demos/LineDemo.rocx"),
		whole("demo_donut", "site/Demos/DonutDemo.rocx"),
		whole("demo_scatter", "site/Demos/ScatterDemo.rocx"),
		whole("ui_heading", "site/Ui/Heading.rocx"),
		whole("chart_bar", "packages/charts/components/BarChart.rocx"),
		whole("chart_line", "packages/charts/components/LineChart.rocx"),
		whole("chart_donut", "packages/charts/components/DonutChart.rocx"),
		whole("chart_scatter", "packages/charts/components/ScatterChart.rocx"),
		whole("demo_shelf", "site/Demos/Shelf.rocx"),
		whole("demo_bag", "site/Demos/Bag.rocx"),
		whole("shared", "site/Demos/Bag.rocx"),
		whole("demo_echo", "site/Demos/Echo.rocx"),
		lines("echo_server", "site/Demos/Echo.rocx", /^\techo!/),
		lines("echo_generated", "site/Demos/Echo.roc", /^\techo! = /),
		lines("echo_browser", "site/build/client/Demos/Echo.roc", /^\techo! = /),
		whole("server_functions", "site/Generated/ServerFunctions.roc"),
		pick("platform_program", "server/test/app/main.roc", ["program = {", "respond!,", "# The app's schema", "migrations: [", "jobs: [", "crons: [", "}"]),
		pick("platform_site_program", "site/main.roc", ["program = App.program({", "context:", "middleware:", "crons:", "openapi:", "})"]),
		pick("platform_notes", "server/test/app/main.roc", ["(\"GET\", \"/notes\") => {", "found : Try(", "found = Db.all!(", "match found {", "Ok(notes) =>", "Err(DbErr(why))", "Err(BadRow(why))", "}", "}"]),
		pick("platform_insert", "server/test/app/main.roc", ["(\"POST\", \"/notes\") =>", "match Db.run!(", "Ok(count) =>", "Err(DbErr(why))", "}"]),
		pick("platform_transaction", "server/test/app/main.roc", ["(\"POST\", \"/jobs/commit\") => {", "done = Db.transaction!(", "|{}| {", "_ = Db.run!(", "match Job.enqueue!(", "Ok({}) =>", "Err(JobErr(why))", "}", "},", ")", "match done {", "Ok(said) =>", "Err(DbErr(why))", "}", "}"]),
		whole("platform_migration", "server/test/app/migrations/0001_tables.sql"),
		pick("platform_migrations", "server/test/app/main.roc", ["import \"migrations/0001_tables.sql\" as tables : Str", "import \"migrations/0002_note_index.sql\"", "program = {", "# The app's schema", "migrations: ["]),
		pick("platform_rocpg", "server/examples/roc-pg/main.roc", ["planets! = |url| {", "db : Client.Client", "db = Client.connect_url!", "_ = db.execute!", "found : List(", "found = db.query!", "db.close!()", "Ok(Str.join_with", "}"]),
		pick("platform_job", "server/test/app/main.roc", ["## Writes what it was told to the job log.", "note_job : Job.Kind", "note_job = Job.define(", "\"note\",", "|{ run, said }|", "match Db.run!(", "Ok(_) => Ok({})", "Err(DbErr(why)) => Err(why)", "},", ")"]),
		pick("platform_enqueue", "server/test/app/main.roc", ["(\"POST\", \"/jobs/note\") =>", "match Job.enqueue!(", "Ok({}) =>", "Err(JobErr(why))", "}", "(\"POST\", \"/jobs/later\") =>", "match Job.enqueue!("]),
		pick("platform_mail_job", "server/test/app/main.roc", ["## Sends an email.", "mail_job : Job.Kind", "mail_job = Job.define(", "\"mail\",", "|{ to, run }|", "match Email.send!(", "Ok({}) => Ok({})", "Err(EmailErr(why)) => Err(why)", "},", ")"]),
		pick("components_form", "web/test/app/Form.rocx", ["view! = |{}| {", "submission = use_submission!(Form.join)", "<form class=\"join\"", "<input name=\"name\"", "<button type=\"submit\"", "</form>", "<Show when!={submission.result!()}>", "<Show when!={submission.error!()}>", "<button class=\"clear\""]),
		whole("routes_local", "test/e2e/app/routes/local/+page.rocx"),
		defined("platform_forecast", "server/test/app/Samples.roc", ["forecast!"]),
		defined("platform_preview", "server/test/app/Samples.roc", ["preview!"]),
		defined("platform_settings", "server/test/app/Samples.roc", ["origin!", "dev_sign_in!"]),
		defined("platform_tokens", "server/test/app/Samples.roc", ["token!", "digest"]),
		defined("platform_links", "server/test/app/Samples.roc", ["signed_link!", "link_member!", "link_key!", "app_secret!"]),
		defined("platform_sealed", "server/test/app/Samples.roc", ["seal!", "unseal!", "sealing_key!"]),
		defined("platform_avatar", "server/test/app/Samples.roc", ["save_avatar!", "avatar_size!", "take_avatar!"]),
		defined("platform_upload_link", "server/test/app/Samples.roc", ["upload_link!"]),
		defined("platform_parts", "server/test/app/Samples.roc", ["save_in_parts!"]),
		defined("platform_serve", "server/test/app/Samples.roc", ["serve_video!", "serve_whole!"]),
		defined("platform_digest", "server/test/app/Samples.roc", ["upload_digest"]),
		defined("platform_cdn", "server/test/app/Samples.roc", ["from_cdn"]),
		defined("platform_cookies", "server/test/app/Samples.roc", ["signed_in", "reviewing", "signed_out"]),
		defined("platform_job_options", "server/test/app/Samples.roc", ["reminder", "remind_tomorrow!", "forget_reminder!", "remind_sooner!"]),
		defined("platform_job_list", "server/test/app/Samples.roc", ["failed_reminders!"]),
		pick("platform_jobs_page", "server/test/app/main.roc", ["(_, \"/admin/jobs\") => Middleware.run!(admins_only"]),
		defined("platform_admins_only", "server/test/app/main.roc", ["admins_only"]),
		pick("platform_online", "server/test/app/main.roc", ["(\"GET\", \"/online\") =>", "# Who is here", "Server.events(", "Events.stream(", "|{ send!, .. }| {", "Live.join!(\"online\")", "var $open", "while $open {", "send!(Live.count!", "$open = Live.next!", "}", "Ok({})", "},", "),", ")"]),
		pick("platform_shouts", "server/test/app/main.roc", ["(\"GET\", \"/shouts\") =>", "Server.events(", "Events.stream(", "|{ send!, .. }| {", "Live.listen!(\"shouts\")", "send!(\"listening\")?", "var $open", "while $open {", "match Live.next!(15_000) {", "Heard({ message, .. }) =>", "Quiet =>", "Gone => {", "$open = Bool.False", "}", "}", "}", "Ok({})", "},", "),", ")", "(\"POST\", \"/shout\") => {", "Live.publish!(\"shouts\", Server.text_of(request))"]),
		pick("platform_counter", "server/test/app/main.roc", ["## A count, one per key", "counter : Actor.Kind", "counter = Actor.define(", "\"counter\",", "|_key| { count: 0 },", "|state, message|", "match message {", "Add(by) =>", "Get =>", "Boom =>", "},", ")"]),
		pick("platform_ask", "server/test/app/main.roc", ["(\"POST\", path) if path.starts_with(\"/actors/count/\") => {", "by : I64", "by = I64.from_str(", "answered_actor(Actor.ask!(counter,"]),
		pick("bag_reader", "site/Demos/Bag.rocx", ["## Who is reading", "## the bag with it", "reader! :", "reader! ="]),
		whole("test_session", "web/test/app/Profile.rocx"),
		whole("signals_echo", "site/Demos/Echo.rocx"),
		lines("signals_echo_server", "site/Demos/Echo.roc", /^\techo! = /),
		lines("signals_echo_browser", "site/build/client/Demos/Echo.roc", /^\techo! = /),
		pick("calls_component", "site/Demos/Echo.rocx", [
			"echo! : Str => Str", "echo! = server!", "messages : List(Str)", "messages = [", "view! : {} => Html", "view! = |{}| {", "(draft!, set_draft!)",
			"# A call per message", "answers! = create_memo!", "said! = create_memo!", "<form class=\"echo\"", "<For each!={messages}", "{|message!, _|",
			"<button", "type=\"button\"", "aria-pressed=", "on:click={|| set_draft!", ">", "{message!()}", "</button>", "}", "</For>",
			"<Errored fallback", "<output class=\"echo-answer failed\">", "{problem}", "</output>", "}>",
			"<Loading fallback", "<Answer said!", "</Loading>", "</Errored>", "</form>", "}",
		]),
		whole("signals_tally", "site/Demos/Tally.rocx"),
		pick("signals_store", "site/Demos/Picks.rocx", [
			"Store : {", "picks! :", "set_picks! :", "next! :", "set_next! :", "}",
			"picks_context : Context(Store)", "picks_context = create_context()",
			"store! : {} => Store", "store! = |{}| {", "(picks!, set_picks!)", "{ id: 1", "{ id: 2", "{ id: 3", "])",
			"(next!, set_next!)", "{ picks!: picks!", "}",
		]),
		pick("signals_tally_use", "site/Demos/Tally.rocx", ["view! = |{}| {", "{ picks!, set_picks!, next!, set_next! } = use_context!"]),
		whole("signals_profile", "web/test/app/Profile.rocx"),
		pick("signals_glance", "web/test/app/Profile.rocx", [
			"view! = |{}| {", "# Made first", "user! = create_memo!", "posts! = create_memo!", "(count!, set_count!)",
			"<Errored fallback", "<p class=\"page-problem\">", "The page failed", "</p>", "}>",
			"<Loading fallback", "<Heading text!", "<button class=\"count\"", "Clicked", "</button>",
			"<section class=\"posts\">", "<Errored fallback", "<p class=\"problem\">", "No posts", "</p>", "}>",
			"<ul>", "<For each!={posts!()}", "{|post!, _|", "</For>", "</ul>", "</Errored>", "</section>",
			"</Loading>", "</Errored>", "}",
		]),
		pick("signals_rename", "web/test/app/Profile.rocx", ["rename! = || {", "_ = Api.rename!", "refresh!(user!)", "}"]),
		whole("solid_friends", "site/snippets/solid-friends.tsx"),
		whole("rocx_friends", "site/snippets/rocx-friends.txt"),
		whole("echo_rendered", "site/snippets/echo-server.html"),
		whole("signals_picks", "site/Demos/Picks.rocx"),
		pick("signals_picks_control", "site/Demos/Picks.rocx", [
			"{ picks!, set_picks!, next!, set_next! } = use_context!(picks_context)",
			"<div class=\"picks-lists\">", "{# A row per id", "<ol class=\"keyed\"",
			"<For", "each!=", "keyed={|pick|", "fallback=", ">", "{|pick!, index!|", "</For>", "</ol>",
			"{# A row per place", "<ol class=\"unkeyed\"", "<For each!={picks!()} keyed={Bool.False}>", "{|pick!, index|", "</For>", "</ol>",
			"</div>", "<div class=\"picks-shows\">",
			"<Show", "when!=", "fallback=", ">", "<p class=\"many\">", "</Show>",
			"<Show when!={picks!().first()}>", "{|first!|", "</Show>", "</div>",
		]),
		excerpt("signals_answer", "site/Demos/Echo.rocx", /^\t\t\(draft!|^\t\tsaid! =|<Answer said|^answer/),
		whole("test_app", "web/test/app/main.roc"),
		pick("components_demos", "site/routes/components/+page.rocx", ["<PicksContext value=", "<Demo inspect=\"picks\"", "<div data-demo=\"picks\"", "</Demo>", "</PicksContext>", "<BagContext value=", "<Demo inspect=\"bag\"", "<div data-demo=\"shelf\"", "<div data-demo=\"bag\"", "</Demo>", "</BagContext>"]),
		whole("client_app", "site/build/client/main.roc"),
		whole("platform_header", "web/platform/main.roc"),
		pick("platform_requires", "web/platform/main.roc", ["platform \"\"", "requires {", "main! :", "}"]),
	];
	const record = (s) => `{ file: ${rocString(s.file)}, rocx: ${rocString(s.rocx)}, roc: ${rocString(s.roc)}, first: ${s.first}, call: ${rocString(s.call)} }`;
	const check = checkReport();
	return [
		"## Written by site/build.mjs: the sources, refusals and reports the pages show. Edit those",
		"## files (site/examples, site/Demos…), not this one.",
		"Sources := [].{",
		"\tSource : { file : Str, rocx : Str, roc : Str, first : U64, call : Str }",
		"",
		...[...examples, ...files].flatMap((s) => [`\t${s.name} : Source`, `\t${s.name} = ${record(s)}`, ""]),
		"\trefusals : List({ source : Str, reason : Str, column : U64 })",
		`\trefusals = [${refusals().map((r) => `{ source: ${rocString(r.source)}, reason: ${rocString(r.reason)}, column: ${r.column} }`).join(", ")}]`,
		"",
		"\tcheck_source : Str",
		`\tcheck_source = ${rocString(check.source)}`,
		"",
		"\tcheck_report : Str",
		`\tcheck_report = ${rocString(check.report)}`,
		"}",
		"",
	].join("\n");
}

// ---- 3. The wasm ----

function host() {
	const object = join(root, "web", "platform", "targets", "wasm32", "host.wasm");
	const sources = [join(root, "web", "host", "host.zig"), join(root, "web", "host", "roc_platform_abi.zig")];
	if (newer(object, sources)) return;
	mkdirSync(dirname(object), { recursive: true });
	run(zig(), ["build-obj", sources[0], "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", `-femit-bin=${object}`]);
}

/** How the browser's wasm is built: optimized for size, with lambda sets specialized. For this
 * site it is the smallest of the three, compressed, and about as fast as the others; `just site`
 * measures all three, and the browser platform's page shows them. */
export const CLIENT_OPT = ["--opt=size", "--specialize=yes"];

/** Split (`node site/build.mjs --split`, or ROCX_SPLIT=1): the browser's wasm cut into a main module
 * and a chunk per page (src/split.mjs). Its build has no lambda-set specialization, which puts every
 * closure into one function there is no cutting. */
export const SPLIT = process.argv.includes("--split") || process.env.ROCX_SPLIT === "1";
export const CLIENT_SPLIT_OPT = ["--opt=size", "--specialize=no"];

function wasm(app, output, opts) {
	run(roc(), ["build", "--target=wasm32", ...opts, `--output=${output}`, app]);
}

// ---- 4. Facts ----

const kb = (bytes) => `${(bytes / 1024).toFixed(1)} KB`;

const brotli = (bytes) => brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;

/** Microseconds per call of `act`: the median of five batches, after warming up (the first calls
 * run before the engine optimizes, and one batch can meet a busy machine). */
function time(count, act) {
	for (let i = 0; i < 200; i++) act(i);
	const batches = [];
	for (let batch = 0; batch < 5; batch++) {
		const started = performance.now();
		for (let i = 0; i < count / 5; i++) act(i);
		batches.push(((performance.now() - started) * 1000) / (count / 5));
	}
	return batches.sort((a, b) => a - b)[2];
}

/** The page `measureClient` renders: the front page. */
const MEASURED = "/";

/**
 * The page at `path` as the site's server answers it, and what the browser's build needs to render
 * it the same way (decision D): the server functions' answers it recorded, and what it has inside
 * each `<NoHydration>`.
 */
export async function nativePage(url, path, headers = {}) {
	const answered = await fetch(`${url}${path}`, { headers: { accept: "text/html", ...headers } });
	const html = await answered.text();
	const script = /<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(html);
	return { path, status: answered.status, html, answers: script ? JSON.parse(script[1]) : [], regions: Runtime.regionsOf(html) };
}

/** Sizes and timings of the browser's wasm, under `prefix`: rendering a page (`page`, as the
 * server answered it), as the server would, with the answers it recorded, runs every component and
 * every hole outside its `<NoHydration>`s once. */
async function measureClient(wasm, prefix, page, load = () => Runtime.load(wasm)) {
	const loading = performance.now();
	const runtime = await load();
	const compiled = performance.now() - loading;
	const render = () => runtime.renderToString({ path: page.path, answers: page.answers, regions: page.regions });
	if (render().html !== page.html) throw new Error(`the browser's build renders ${page.path} other than the server does`);
	return {
		[`${prefix}bytes`]: kb(wasm.length),
		[`${prefix}gzip`]: kb(gzipSync(wasm, { level: 9 }).length),
		[`${prefix}brotli`]: kb(brotli(wasm)),
		[`${prefix}compile_ms`]: compiled.toFixed(1),
		[`${prefix}render_us`]: time(200, render).toFixed(0),
	};
}

/** A split build's facts: that it is, and what the lightest and the heaviest page load first. */
function splitFacts() {
	const report = chunksOf();
	if (!report) return {};
	const loads = Object.values(report.firstLoad);
	return { split: "yes", split_chunks: String(Object.keys(report.sizes).length - 1), split_first_min: kb(Math.min(...loads)), split_first_max: kb(Math.max(...loads)) };
}

/** The build's facts; with `compare`, the client built other ways too, for the internals page. */
async function measure({ compare }) {
	const browser = readFileSync(appWasm);
	const runtime = readFileSync(join(root, "web", "runtime.js"));
	// The page the wasm renders, as the server answers it (started with the facts it had last).
	if (!existsSync(context)) writeFileSync(context, lastFacts());
	const running = await startServer();
	let page;
	try {
		page = await nativePage(running.url, MEASURED);
	} finally {
		await running.stop();
	}
	const facts = {
		...(await measureClient(browser, "client_", page, () => loadApp(appWasm))),
		...splitFacts(),
		runtime_bytes: kb(runtime.length),
		runtime_gzip: kb(gzipSync(runtime, { level: 9 }).length),
		server_bytes: kb(statSync(server).size),
		roc: run(roc(), ["version"]).trim().replace(/^Roc compiler version /, ""),
		node: process.version,
		built: new Date().toISOString().slice(0, 10),
	};
	// The comparison takes two more builds, so only `node site/build.mjs` makes it; a build that
	// doesn't keeps the last one it finds (marked as such on the page by its own date).
	const saved = join(out, "facts.txt");
	if (compare) {
		for (const [name, opts] of [["size", ["--opt=size"]], ["speed", ["--opt=speed"]]]) {
			const path = join(out, `app-${name}.wasm`);
			wasm(join(client, "main.roc"), path, opts);
			Object.assign(facts, await measureClient(readFileSync(path), `${name}_`, page));
		}
		facts.compared = facts.built;
	} else if (existsSync(saved)) {
		for (const line of readFileSync(saved, "utf8").split("\n")) {
			const [key, ...value] = line.split("=");
			if (/^(size_|speed_|compared$)/.test(key)) facts[key] = value.join("=");
		}
	}
	const text = Object.entries(facts)
		.map(([key, value]) => `${key}=${value}`)
		.join("\n");
	writeFileSync(saved, text);
	return text;
}

/** Steps 1 and 2: the Roc the compiler checks, and the browser's copy of the site, in which a
 * server function is only its name. */
export function prepare({ dev = false, split = false } = {}) {
	// rocx build, in this process: three more Node processes would cost a rebuild a third of a second.
	// A dev build has the stories too (the catalog at /__rocx/stories); `just site` and the tests don't.
	const said = [];
	const log = (line) => said.push(line);
	if (!rocxBuild(["site"], { client: relative(root, client), cwd: root, log, dev, split })) throw new Error(`rocx build failed:\n${said.join("\n")}`);
	// The server platform's copy of the modules both platforms have, for `roc check`.
	syncShared();
	// The sources the pages show, which quote what rocx build wrote, so they come after it; and the
	// browser's copy of the site gets them too, since rocx build copied the site before they were
	// written (on a fresh checkout, before there were any).
	const sources = sourcesModule();
	writeIfChanged(join(site, "Generated", "Sources.roc"), sources);
	writeIfChanged(join(client, "Generated", "Sources.roc"), sources);
}

/** The server's executable, and what it is started with. */
export const server = join(out, "server");
export const context = join(out, "context.txt");
/** What a page loads, besides the site's own files: rocx build's start.js and runtime.js, and the
 * browser's wasm beside them (served at /rocx/). */
export const clientStatic = join(client, "static");
export const appWasm = join(clientStatic, "rocx", "app.wasm");

/** The browser's app from its files, in Node: `app.wasm`, and for a split build (a chunks.json
 * beside it) every chunk a page loads, strictly (a call into `Unreached` throws). */
export function loadApp(path = appWasm, options = {}) {
	const dir = dirname(path);
	const listed = join(dir, "chunks.json");
	if (!existsSync(listed)) return Runtime.load(readFileSync(path), options);
	const { pages } = JSON.parse(readFileSync(listed, "utf8"));
	const preload = [...new Set(Object.values(pages).flat())];
	return Runtime.load(readFileSync(path), { ...options, chunk: (owner) => readFileSync(join(dir, `app.${owner}.wasm`)), preload, strict: true });
}

/** A split build's report (chunks.json beside app.wasm), or null. */
export function chunksOf(path = appWasm) {
	const listed = join(dirname(path), "chunks.json");
	return existsSync(listed) ? JSON.parse(readFileSync(listed, "utf8")) : null;
}

/** How the site's server is started: what it serves besides what Roc answers. */
export function serverFlags({ dev = false, databaseUrl } = {}) {
	return [
		"--static", join(site, "static"),
		"--static", clientStatic,
		"--context-file", context,
		...(databaseUrl ? ["--database-url", databaseUrl] : []),
		...(dev ? ["--dev"] : []),
	];
}

/** Starts the site's server (built) on a free port; resolves when it listens: its URL, what it
 * logged, and how to stop it. */
export function startServer(options = {}, extra = []) {
	return start(server, [...serverFlags(options), ...extra]);
}

/** The facts the last measured build saved, marked as a dev build's: its own wasm, from the dev
 * backend, is neither as small nor as fast as what was measured. */
function lastFacts() {
	const saved = join(out, "facts.txt");
	return `${existsSync(saved) ? `${readFileSync(saved, "utf8")}\n` : ""}dev=yes`;
}

/**
 * Steps 1 to 5; resolves to the facts the pages are given. With `dev`, everything comes from Roc's
 * dev backend, which builds the whole site in a fraction of a second, where LLVM takes seconds to
 * optimize (every time: its output isn't cached, and Roc hands it the whole program at once). The
 * pages' components then run about half as fast, which editing doesn't notice; the pages show the numbers
 * the last full build measured.
 */
export async function build({ log = console.error, compare = false, dev = false, split = SPLIT && !dev } = {}) {
	const started = performance.now();
	prepare({ dev, split });
	host();
	mkdirSync(out, { recursive: true });
	if (split) {
		// Built with its names (--debug), cut into app.wasm and the chunks beside it, the server's
		// Chunks written with each page's before the server is built.
		const named = join(out, "app-split.wasm");
		wasm(join(client, "main.roc"), named, [...CLIENT_SPLIT_OPT, "--debug"]);
		const report = splitWasm({ roc: roc(), app: join(client, "main.roc"), wasm: named, out: dirname(appWasm), opts: CLIENT_SPLIT_OPT, chunks: join(site, "Generated", "Chunks.roc") });
		log(`rocx site: split: app.wasm ${kb(report.sizes.app.brotli)} brotli, ${Object.keys(report.sizes).length - 1} chunks`);
	} else wasm(join(client, "main.roc"), appWasm, dev ? ["--opt=dev"] : CLIENT_OPT);
	buildHost();
	buildApp(join(site, "main.roc"), server, { opt: dev ? "dev" : (process.env.ROC_OPT ?? "speed") });
	const facts = dev ? lastFacts() : await measure({ compare });
	writeIfChanged(context, facts);
	log(`rocx site: built in ${((performance.now() - started) / 1000).toFixed(2)} s${dev ? " (dev backend; numbers from the last `just site`)" : ""}`);
	return facts;
}

/** The file a route is written to in dist/. */
export const pageFile = (route) => (route === "/" ? "index.html" : `${route.slice(1)}/index.html`);

/** Copies what pages load besides themselves into `dir`: the site's files, and start.js, runtime.js
 * and app.wasm, side by side in rocx/. */
export function assets(dir) {
	cpSync(join(site, "static"), dir, { recursive: true });
	cpSync(clientStatic, dir, { recursive: true });
}

/**
 * What the static site's demos ask for besides pages, answered by the server as the site is built
 * and written as files: the words the shout's buttons send (`site/Demos/Shout.rocx`), and the
 * endpoints' OpenAPI document and its page. A copy of the site as files answers these GETs, and
 * nothing else.
 */
export const STATIC_GETS = ["/api/shout/rocx", "/api/shout/hello", "/api/shout/static", "/openapi.json", "/openapi.html"];

/** A page as the server answered it, for a copy served under `base` (`/rocx/`): an attribute's URL
 * that begins with `/` (a link, a script, a stylesheet) begins with the base instead. */
export function underBase(html, base) {
	return base === "/" ? html : html.replace(/(\s(?:href|src|action)=")\/(?!\/)/g, `$1${base}`);
}

/**
 * Every page, as the site's server answers it, what the demos ask for (`STATIC_GETS`), and what
 * they load, into `dir`: a static site. With `base` (`/rocx/`), for a host that serves it under that
 * path (a GitHub Pages project site: `example.github.io/rocx/`).
 */
export async function prerender(dir, { base = "/" } = {}) {
	if (!base.startsWith("/") || !base.endsWith("/")) throw new Error(`a base begins and ends with /: ${base}`);
	const running = await startServer();
	try {
		rmSync(dir, { recursive: true, force: true });
		for (const route of [...ROUTES, "/404"]) {
			const path = join(dir, route === "/404" ? "404.html" : pageFile(route));
			mkdirSync(dirname(path), { recursive: true });
			const page = await fetch(`${running.url}${route}`, { headers: { accept: "text/html" } });
			writeFileSync(path, underBase(await page.text(), base));
		}
		for (const route of STATIC_GETS) {
			const answered = await fetch(`${running.url}${route}`);
			if (!answered.ok) throw new Error(`GET ${route}: ${answered.status} ${await answered.text()}`);
			const path = join(dir, route.slice(1));
			mkdirSync(dirname(path), { recursive: true });
			writeFileSync(path, await answered.text());
		}
	} finally {
		await running.stop();
	}
	assets(dir);
}

async function main() {
	const base = process.argv.find((arg) => arg.startsWith("--base="))?.slice("--base=".length) ?? "/";
	const facts = await build({ compare: true });
	await prerender(dist, { base });
	console.error(`rocx site: ${ROUTES.length} pages in ${relative(process.cwd(), dist)}${base === "/" ? "" : `, for ${base}`}`);
	console.error(facts);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	if (process.argv.includes("--prepare")) prepare({ split: SPLIT });
	else if (process.argv.includes("--dev")) await build({ dev: true });
	else await main();
}
