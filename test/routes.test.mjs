// File-based routing, without the compiler: which routes there are, what rocx writes for them.
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { build } from "../rocx-cli/rocx.mjs";
import { actorsIn, apiModule, appModule, clientMainModule, contractProblems, definitions, findRouteFiles, handlersModule, jobsIn, matches, migrationsIn, pathsModule, rootModule, routeList, routeModule, routesModule, routesTable, routeTable, tagNames, viewProblems } from "../rocx-cli/rocx.mjs";

const files = ["+layout.rocx", "+page.rocx", "+error.rocx", "blog/+layout.rocx", "blog/+page.rocx", "blog/[slug]/+page.rocx", "blog/[slug]/+server.rocx", "blog/new/+page.rocx", "getting-started/+page.rocx", "feed/+server.roc"];

test("routes: each page's path, params, name and layouts; the fixed tried before params", () => {
	const table = routeTable(files);
	assert.deepEqual(
		table.pages.map((page) => [page.path, page.name, page.module, page.layouts.map((layout) => layout.module)]),
		[
			["/blog/new", "blog_new", "BlogNewPage", ["RootLayout", "BlogLayout"]],
			["/blog", "blog", "BlogPage", ["RootLayout", "BlogLayout"]],
			["/getting-started", "getting_started", "GettingStartedPage", ["RootLayout"]],
			["/", "root", "RootPage", ["RootLayout"]],
			["/blog/[slug]", "blog_slug", "BlogSlugPage", ["RootLayout", "BlogLayout"]],
		],
	);
	assert.deepEqual(table.pages.at(-1).params, [{ name: "slug", at: 1 }]);
	assert.equal(table.error.module, "RootError");
	assert.throws(() => routeTable(["Blog/+page.rocx"]), /a directory is a path's part in lower case/);
	assert.deepEqual(routeTable(["if/+page.rocx", "platform/+page.rocx", "all/+page.rocx"]).pages.map((page) => page.name).sort(), ["all_", "if_", "platform_"], "a word Roc keeps (or Paths.all) gets a _");
	assert.throws(() => routeTable(["a-b/+page.rocx", "a_b/+page.rocx"]), /would both be/);
	assert.throws(() => routeTable(["blog/+error.rocx"]), /an error page is the app's/);
	assert.throws(() => routeTable(["feed/+server.roc", "feed/+server.rocx"]), /the same route: keep one/);
});

test("routes: what a route file defines; a path matched against a route", () => {
	assert.deepEqual(definitions("import pf.Html\n\nmeta = {}\n\nview! = |_| x"), { view: "view!", meta: true, methods: [], middleware: null, docs: {} });
	assert.deepEqual(definitions("view = |_| x"), { view: "view", meta: false, methods: [], middleware: null, docs: {} });
	assert.deepEqual(definitions("middleware = Guards.member\n\nget! = |_| Ok(1)\n\ndelete! = |_| Ok({})\n\nhelper = 1"), {
		view: null,
		meta: false,
		methods: ["get!", "delete!"],
		middleware: "Guards.member",
		docs: {},
		handlers: { "get!": { line: 3, unannotated: true }, "delete!": { line: 5, unannotated: true } },
		imports: [],
	});
	assert.ok(matches("/blog/[slug]", "/blog/rocx"));
	assert.ok(matches("/", "/"));
	assert.ok(!matches("/blog/[slug]", "/blog"));
	assert.ok(!matches("/blog/new", "/blog/old"));
});

test("routes: a route file's module keeps its lines: imports moved, the module's line on the blank one", () => {
	const code = "import pf.Html\nimport ../../Ui/Card\n\nview! = |_| x\n\n# rocx: generated from +page.rocx: edit that file\n";
	const module = routeModule(code, { name: "BlogPage", source: "/app/routes/blog/+page.rocx", generated: "/app/Generated/BlogPage.roc" });
	assert.deepEqual(module.split("\n").slice(0, 5), ["import pf.Html", "import ../Ui/Card", "BlogPage := [].{", "view! = |_| x", "}"]);
	assert.match(module, /# rocx: generated from \.\.\/routes\/blog\/\+page\.rocx: edit that file/);
	// No blank line after the imports, or no imports: the module's line at the start of the first
	// definition's, the lines kept; a file of imports alone has nothing to open.
	const at = { name: "X", source: "/a/routes/+page.rocx", generated: "/a/Generated/X.roc" };
	assert.deepEqual(routeModule("import pf.Html\nview! = |_| x\n", at).split("\n").slice(0, 3), ["import pf.Html", "X := [].{ view! = |_| x", "}"]);
	assert.deepEqual(routeModule("## GET /hello.\nget! = |_| Ok(1)\n", at).split("\n").slice(0, 3), ["## GET /hello.", "X := [].{ get! = |_| Ok(1)", "}"]);
	assert.deepEqual(routeModule("get! = |_| Ok(1)", at).split("\n").slice(0, 2), ["X := [].{ get! = |_| Ok(1)", "}"]);
	assert.throws(() => routeModule("import pf.Html", at), /defines its view, meta or methods after its imports/);
});

test("routes: a route file's own components are types beside its module, not in its block, where their view! would be the page's again", () => {
	const where = { name: "LocalPage", source: "/app/routes/local/+page.rocx", generated: "/app/Generated/LocalPage.roc" };
	const after = ["import pf.Html", "", "meta = { title: \"Local\" }", "", "view! = |_|", "\t<p>x</p>", "", "## A board.", "Board := [].{", "\tview! = |_| y", "}", "", "Tag := [].{", "\tview = |_| z", "}", ""];
	assert.deepEqual(routeModule(after.join("\n"), where).split("\n").slice(0, 15), ["import pf.Html", "LocalPage := [].{", "meta = { title: \"Local\" }", "", "view! = |_|", "\t<p>x</p>", "}", "## A board.", "Board := [].{", "\tview! = |_| y", "}", "", "Tag := [].{", "\tview = |_| z", "}"], "closed on the blank line before the first, its comment with it; lines kept");
	const before = ["import pf.Html", "", "Board := [].{", "\tview! = |_| y", "}", "", "view! = |_| x", ""];
	assert.deepEqual(routeModule(before.join("\n"), where).split("\n").slice(0, 8), ["import pf.Html", "", "Board := [].{", "\tview! = |_| y", "}", "LocalPage := [].{", "view! = |_| x", "}"], "opened on the blank line after them");
	const tight = ["import pf.Html", "", "view! = |_| x", "Board := [].{", "\tview! = |_| y", "}"];
	assert.equal(routeModule(tight.join("\n"), where).split("\n")[3], "} Board := [].{", "no blank line: closed at the start of the component's");
	const tightBefore = ["import pf.Html", "", "Board := [].{", "\tview! = |_| y", "}", "view! = |_| x"];
	assert.deepEqual(routeModule(tightBefore.join("\n"), where).split("\n").slice(4, 7), ["}", "LocalPage := [].{ view! = |_| x", "}"], "no blank line after them: opened at the start of the first definition's");
	assert.throws(() => routeModule(["import pf.Html", "", "meta = 1", "Board := [].{", "\tview! = |_| y", "}", "view! = |_| x"].join("\n"), where), /local\/\+page\.rocx:7: put the file's own components \(Board\) before its definitions or after them, not between/);
});

test("routes: a route file's own components see its definitions, each one it uses named on the component's line", () => {
	const where = { name: "LocalPage", source: "/app/routes/local/+page.rocx", generated: "/app/Generated/LocalPage.roc" };
	const source = [
		"import pf.Html",
		"",
		"Intro := [].{",
		"\tview = |_| <p>{greeting}</p>",
		"}",
		"",
		"meta = { title: \"Local\" }",
		"",
		"view! = |_| <Board />",
		"",
		"greeting = \"Hello\"",
		"shown : U64 -> Str",
		"shown = |count| count.to_str()",
		"beat! = |{}| {}",
		"count = 3",
		"label = \"x\"",
		"unused = 1",
		"",
		"## A board.",
		"Board := [].{",
		"\tview! = |_| {",
		"\t\tbeat!({})",
		"\t\tlabel = shown(count)",
		"\t\tsaid = \"unused ${Board.tally(LocalPage.greeting)}\" # and unused here",
		"\t\t<p>{label} {said}</p>",
		"\t}",
		"",
		"\ttally = |greeting| greeting",
		"}",
		"Tag := [].{ view = |{ text }| text }",
		"",
	];
	const lines = routeModule(source.join("\n"), where).split("\n");
	assert.equal(lines[2], "Intro := [].{ greeting = LocalPage.greeting", "a component before the page's definitions");
	assert.equal(lines[19], "Board := [].{ shown = LocalPage.shown beat! = LocalPage.beat! count = LocalPage.count", "after them: a function, an effect, a value; in the order the file defines them");
	assert.equal(lines[29], "Tag := [].{ view = |{ text }| text }", "one that uses none, as it was");
	assert.deepEqual(lines.slice(20, 29), source.slice(20, 29), "the component's other lines as they were");
	assert.equal(lines.length, source.length + 2, "line N is line N (and the marker after)");
	// Not a name it binds (Roc would say it is defined twice), nor one in a string or a comment, nor
	// one after a `.`; a component's own member is bound by it.
	const own = routeModule(["import pf.Html", "", "view! = |_| x", "", "helper = 1", "", "Card := [].{", "\tview = |{ n }| helper(n)", "\thelper = |n| n", "}"].join("\n"), where).split("\n");
	assert.equal(own[6], "Card := [].{", "its own helper: its own");
	const tight = routeModule(["import pf.Html", "", "view! = |_| x", "helper = 1", "Card := [].{", "\tview = |_| helper", "}"].join("\n"), where).split("\n");
	assert.equal(tight[4], "} Card := [].{ helper = LocalPage.helper", "closed at the start of the component's line, its names after the block's opening");
	const bound = routeModule(["import pf.Html", "", "view! = |_| x", "", "a = 1", "b = 2", "c = 3", "d = 4", "", "Card := [].{", "\tview = |{ n }| {", "\t\tf = |a| a + n", "\t\tfor b in [] {}", "\t\tmatch n { c => c }", "\t\td + f(1)", "\t}", "}"].join("\n"), where).split("\n");
	assert.equal(bound[9], "Card := [].{ d = LocalPage.d", "a lambda's parameter, a for's, a match arm's are its own");
});

test("routes: Routes answers a request: a page (Root's) for a browser's GET; an endpoint for its method; 405, 404", () => {
	const table = routeTable(files);
	const methods = { "blog/[slug]/+server.rocx": ["get!", "put!"], "feed/+server.roc": ["get!"] };
	const middleware = { "blog/new/+page.rocx": "Guards.writer", "blog/[slug]/+server.rocx": "Guards.member" };
	// The post's handlers' types, as their annotations give them; the feed's, none (a source made by hand).
	const typed = {
		"blog/[slug]/+server.rocx": {
			handlers: { "get!": { line: 6, body: "", answer: "Post.Full" }, "put!": { line: 9, body: "Post.Edit", answer: "{}" } },
			imports: ["import pf.Server", "import pf.Endpoint", "import ../../../Post", "import ../../../Guards"],
		},
	};
	const sources = new Map(files.map((file) => [file, { view: "view!", meta: file.endsWith("+page.rocx"), methods: methods[file] ?? [], middleware: middleware[file] ?? null, ...typed[file] }]));
	const routes = routesModule(table, { sources });
	assert.match(routes, /if \(segments == \["blog", "new"\]\) \{\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tMiddleware\.run!\(BlogNewPage\.middleware, request, context, \|_passed, _handed\| Routes\.page\(200\)\)/, "a page's middleware, before Root renders it");
	assert.match(routes, /else if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("blog"\)\) \{\n\t\t\tparams = \{ slug: segments\.get\(1\) \?\? "" \}/);
	// A page and endpoints at one path: a GET a browser sends is the page's.
	assert.match(routes, /if \(method == "GET" and wants_html\) \{\n\t\t\t\tRoutes\.page\(200\)\n\t\t\t\} else if \(method == "GET"\) \{\n\t\t\t\tMiddleware\.run!\(BlogSlugServer\.middleware, request, context, \|passed, handed\| Endpoint\.respond!\(Handlers\.get_blog_slug\(params\), passed, handed\)\)\n\t\t\t\} else if \(method == "PUT"\) \{\n\t\t\t\tMiddleware\.run!\(BlogSlugServer\.middleware, request, context, \|passed, handed\| Endpoint\.respond!\(Handlers\.put_blog_slug\(params\), passed, handed\)\)\n\t\t\t\} else \{\n\t\t\t\tEndpoint\.not_allowed\(request, \["GET", "PUT"\]\)/);
	assert.match(routes, /if \(segments == \["feed"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tEndpoint\.respond!\(Handlers\.get_feed\(params\), request, context\)/, "an endpoint with no page, and no middleware of its own");
	assert.match(routes, /if \(wants_html\) \{\n\t\t\t\tRoutes\.page\(404\)/);
	assert.match(routes, /^import pf\.Server\nimport pf\.Endpoint\nimport pf\.Middleware\nimport Handlers\nimport Root\n/m, "the platform's modules; each endpoint with its handler (Handlers); no Html: no page is rendered here");
	assert.doesNotMatch(routes, /^import Api$/m, "Api only for a channel's hooks");
	assert.match(routes, /^import BlogSlugServer$/m, "an endpoint's module, for its middleware");
	assert.doesNotMatch(routes, /^import FeedServer$/m);
	assert.deepEqual(
		routeList(table, sources).map((row) => Object.values(row).join(" ")),
		["GET / routes/+page.rocx ", "GET /blog routes/blog/+page.rocx ", "GET /blog/[slug] routes/blog/[slug]/+page.rocx ", "GET /blog/[slug] routes/blog/[slug]/+server.rocx Guards.member", "PUT /blog/[slug] routes/blog/[slug]/+server.rocx Guards.member", "GET /blog/new routes/blog/new/+page.rocx Guards.writer", "GET /feed routes/feed/+server.roc ", "GET /getting-started routes/getting-started/+page.rocx ", "* (anything else) routes/+error.rocx "],
	);
	const paths = pathsModule(table);
	assert.match(paths, /^import pf\.Server$/m);
	assert.match(paths, /\tblog_slug : \{ slug : Str \} -> Str\n\tblog_slug = \|params\| "\/blog\/\$\{Server\.encode_segment\(params\.slug\)\}"/);
	assert.match(paths, /\tgetting_started = "\/getting-started"/);
	assert.match(paths, /\tall = \["\/blog\/new", "\/blog", "\/getting-started", "\/"\]/);
	assert.doesNotMatch(paths, /feed/, "an endpoint isn't a page to link to");
	// Api, the contract (D-037): each endpoint's method, URL and types, the handler's annotation's;
	// the same in the browser's copy, but for the OpenAPI document. No route file.
	const api = apiModule(table, { sources });
	assert.match(api, /\t## PUT \/blog\/\[slug\], from routes\/blog\/\[slug\]\/\+server\.rocx\n\tput_blog_slug : \{ slug : Str \} -> Endpoint\(context, Post\.Edit, \{\}\)\n\tput_blog_slug = \|params\| Endpoint\.remote\("PUT", "\/blog\/\$\{Server\.encode_segment\(params\.slug\)\}"\)\n/, "its params, its body, its answer; any context");
	assert.match(api, /\tget_blog_slug : \{ slug : Str \} -> Endpoint\(context, \{\}, Post\.Full\)\n/, "a GET is sent nothing");
	assert.match(api, /\t## GET \/feed, from routes\/feed\/\+server\.roc\n\tget_feed = \|_params\| Endpoint\.remote\("GET", "\/feed"\)\n/, "a handler whose types rocx doesn't have: no annotation (rocx build refuses one)");
	assert.match(api, /^import pf\.Endpoint\nimport pf\.Server\nimport pf\.OpenApi\nimport \.\.\/Post\n\nApi := /m, "the module its types name, from Generated/; not Guards, which they don't; no route file");
	assert.doesNotMatch(api, /BlogSlugServer|FeedServer/, "nothing a handler does");
	const browser = apiModule(table, { sources, client: true });
	assert.match(browser, /^import pf\.Endpoint\nimport pf\.Server\nimport \.\.\/Post\n\n/m);
	assert.equal(browser.slice(browser.indexOf("Api := ")), api.slice(api.indexOf("Api := "), api.indexOf("\t## The OpenAPI document")) + "}\n\n# rocx: generated from the routes: rocx build writes it.\n", "the browser's copy: the same contract");
	// Handlers: each of Api's endpoints with its handler, the server's alone.
	const handlers = handlersModule(table, { sources });
	assert.match(handlers, /^import pf\.Endpoint\nimport Api\nimport BlogSlugServer\nimport FeedServer\n\nHandlers := /m);
	assert.match(handlers, /\tput_blog_slug = \|params\| Endpoint\.bind\(Api\.put_blog_slug\(params\), \|request, context, body\| BlogSlugServer\.put!\(\{ request: request, params: params, context: context, body: body \}\)\)\n/);
	assert.match(handlers, /\tget_feed = \|params\| Endpoint\.bind\(Api\.get_feed\(params\), \|request, context, \{\}\| FeedServer\.get!\(\{ request: request, params: params, context: context \}\)\)\n/);
});

test("routes: events! answers a GET that asks for events; beside a page and get!, each GET goes to what it accepts", () => {
	const table = routeTable(["+page.rocx", "live/+page.rocx", "live/+server.roc", "ticks/+server.roc"]);
	const methods = { "live/+server.roc": ["get!", "events!"], "ticks/+server.roc": ["events!"] };
	const sources = new Map(["+page.rocx", "live/+page.rocx", "live/+server.roc", "ticks/+server.roc"].map((file) => [file, { view: "view!", meta: false, methods: methods[file] ?? [], middleware: null }]));
	const routes = routesModule(table, { sources });
	assert.match(
		routes,
		/if \(method == "GET" and wants_html\) \{\n\t\t\t\tRoutes\.page\(200\)\n\t\t\t\} else if \(method == "GET" and wants_events\) \{\n\t\t\t\tEndpoint\.stream!\(Handlers\.events_live\(params\), request, context\)\n\t\t\t\} else if \(method == "GET"\) \{\n\t\t\t\tEndpoint\.respond!\(Handlers\.get_live\(params\), request, context\)\n\t\t\t\} else \{\n\t\t\t\tEndpoint\.not_allowed\(request, \["GET"\]\)/,
	);
	assert.match(routes, /if \(segments == \["ticks"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tEndpoint\.stream!\(Handlers\.events_ticks\(params\), request, context\)/, "alone, events! answers any GET");
	assert.match(routes, /\t\twants_events = \(Server\.header\(request, "accept"\) \?\? ""\)\.contains\("text\/event-stream"\)/);
	assert.doesNotMatch(routesModule(routeTable(["feed/+server.roc"]), { sources: new Map([["feed/+server.roc", { view: null, meta: false, methods: ["get!"], middleware: null }]]) }), /wants_events|wants_html/, "neither, where nothing reads them");
	assert.match(apiModule(table, { sources }), /\t## GET \/ticks, its events \(`Endpoint\.listen!`\), from routes\/ticks\/\+server\.roc\n\tevents_ticks = \|_params\| Endpoint\.remote\("GET", "\/ticks"\)/);
	assert.match(handlersModule(table, { sources }), /\tevents_ticks = \|params\| Endpoint\.bind\(Api\.events_ticks\(params\), \|request, context, \{\}\| TicksServer\.events!\(\{ request: request, params: params, context: context \}\)\)/);
	assert.deepEqual(routeList(table, sources).map((row) => `${row.method} ${row.path}`), ["GET /", "GET /live", "GET /live", "EVENTS /live", "EVENTS /ticks"]);
});

test("routes: what each method's comment says: the ## lines right above it, or, with one method, the file's", () => {
	const source = "import pf.Server\n\n## Who you are.\nmiddleware = Guards.member\n\n## What the post is.\n## In **markdown**.\nget! : {} => Try(Str, Refusal)\nget! = |_| Ok(\"\")\n\nput! = |_| Ok({})\n";
	assert.deepEqual(definitions(source).docs, { "get!": "What the post is.\nIn **markdown**." }, "a method with no comment right above it has none");
	assert.deepEqual(definitions("## GET /words: the words.\n\nget! = |_| Ok([])\n").docs, { "get!": "GET /words: the words." }, "one method: the file's comment, at its top");
	assert.deepEqual(definitions("import pf.Server\n\n## The member.\nmiddleware = Guards.member\n\nget! = |_| Ok(1)\n").docs, { "get!": "The member." }, "one method: the file's first comment");
});

test("routes: the names that could be tags: capitalized, outside comments and strings, not before a `.`", () => {
	const code = [
		"import pf.Server",
		"## Says Hello, in a Comment",
		'paint : Colour -> Try(Str, [BadRequest(Str), Gone]) # not Here',
		'paint = |colour| match colour { Red => Ok("Not \\"A\\" Tag") \n Rgb(r, _, _) => Err(Server.Unseen) }',
		"\\\\ A Multiline String",
	].join("\n");
	assert.deepEqual(tagNames([code, "x = [Red, Blue]"]), ["BadRequest", "Blue", "Colour", "Err", "Gone", "Ok", "Red", "Rgb", "Str", "Try", "Unseen"]);
});

test("routes: Api.openapi, the endpoints' OpenAPI document, which App.program serves if the app says", () => {
	const table = routeTable(["+page.rocx", "live/+page.rocx", "live/+server.roc", "blog/[slug]/+server.roc"]);
	const sources = new Map([
		["+page.rocx", { view: "view!", meta: false, methods: [], middleware: null, docs: {} }],
		["live/+page.rocx", { view: "view!", meta: false, methods: [], middleware: null, docs: {} }],
		["live/+server.roc", { view: null, meta: false, methods: ["get!", "events!"], middleware: null, docs: { "get!": "The count.", "events!": "Each tick, as it comes." } }],
		["blog/[slug]/+server.roc", { view: null, meta: false, methods: ["put!", "delete!"], middleware: null, docs: { "put!": 'The post, "edited": ${not code}.' } }],
	]);
	const api = apiModule(table, { sources, tags: ["Gone", "Red"], title: "blog" });
	assert.match(api, /^import pf\.OpenApi$/m);
	assert.match(api, /\topenapi : Str\n\topenapi = \{\n\t\ttags = \[\n\t\t\t"Gone", "Red",\n\t\t\]\n\t\tOpenApi\.document\("blog", \[/);
	assert.match(api, /\t\t\tOpenApi\.path\("\/live", \[\], \[\n\t\t\t\tOpenApi\.operation\("get", "The count\.\\n\\nEach tick, as it comes\.", "", \[OpenApi\.answer\(Api\.get_live\(\{\}\), tags\), OpenApi\.events\(Api\.events_live\(\{\}\), tags\)\]\),\n\t\t\t\]\),/, "get! and events! are one GET");
	assert.match(api, /\t\t\tOpenApi\.path\("\/blog\/\{slug\}", \["slug"\], \[\n\t\t\t\tOpenApi\.operation\("put", "The post, \\"edited\\": \\\$\{not code\}\.", OpenApi\.sent\(Api\.put_blog_slug\(\{ slug: "" \}\), tags\), \[OpenApi\.answer\(Api\.put_blog_slug\(\{ slug: "" \}\), tags\)\]\),\n\t\t\t\tOpenApi\.operation\("delete", "", "", \[OpenApi\.answer\(Api\.delete_blog_slug\(\{ slug: "" \}\), tags\)\]\),/);
	assert.doesNotMatch(apiModule(table, { sources, client: true }), /OpenApi|openapi/, "the browser's copy has no document");
	const routes = routesModule(table, { sources });
	assert.doesNotMatch(routes, /openapi/, "the router doesn't serve it: App.program does, if the app says")
	const app = appModule({ endpoints: true });
	assert.match(app, /^import Api$/m);
	assert.match(app, /\t\t\t\tchain = config\.middleware\.then\(OpenApi\.middleware\(config\.openapi, Api\.openapi\)\)\n\t\t\t\t# A plugin's route, or the app's\.\n\t\t\t\tServer\.clear_flash\(request, Middleware\.run!\(chain, request, \(config\.context\)\(started\), \|passed, context\| Plugin\.respond!\(config\.plugins, passed, context, \|routed, handed\| Routes\.respond!\(routed, handed\)\)\)\)/, "with endpoints: the app's middleware, then the document and its page, as the app says, then the routes");
	assert.doesNotMatch(appModule({}), /import Api|OpenApi\.middleware/, "no endpoints, no document");
	assert.match(appModule({}), /\t\t\t\tchain = config\.middleware\n/, "no endpoints: the app's middleware alone");
});

test("no server functions (D-023): Routes answers nothing at /rocx/call/, and imports no ServerFunctions", () => {
	const table = routeTable(files);
	const sources = new Map(files.map((file) => [file, { view: "view!", meta: false, methods: file.endsWith("+server.rocx") || file.endsWith("+server.roc") ? ["get!"] : [], middleware: null }]));
	const routes = routesModule(table, { sources });
	assert.doesNotMatch(routes, /ServerFunctions|rocx\/call/);
	assert.match(routes, /^import pf\.Endpoint$/m, "its endpoints use Endpoint");
	const pagesOnly = routesModule(routeTable(["+page.rocx"]), { sources: new Map([["+page.rocx", { view: "view!", meta: false, methods: [], middleware: null }]]) });
	assert.match(pagesOnly, /^\trespond! = \|request, _context\| \{$/m, "an app whose routes use no context names it _context, so the compiler doesn't warn");
});

// ---- Route files are components (`import pf.Html`, `view!`): Root, Routes' page answers, App ----

/** A page's, layout's or error page's definitions, as rocx build reads them. */
const component = (extra = {}) => ({ view: "view!", meta: false, methods: [], middleware: null, docs: {}, ...extra });

test("Root: the page at where it is, in its layouts, the root layout's <Errored> around the rest, the error page for 404 and 500", () => {
	const files = ["+layout.rocx", "+page.rocx", "+error.rocx", "blog/+layout.rocx", "blog/[slug]/+page.rocx", "blog/new/+page.rocx", "feed/+server.roc"];
	const table = routeTable(files);
	const sources = new Map(files.map((file) => [file, file.endsWith("+server.roc") ? { view: null, meta: false, methods: ["get!"], middleware: null, docs: {} } : component({ meta: file === "blog/[slug]/+page.rocx" || file === "+error.rocx" })]));
	const root = rootModule(table, { sources });
	assert.match(root, /^import pf\.Html\nimport pf\.Router\nimport pf\.Server\nimport pf\.Errored\nimport pf\.HttpStatusCode\nimport BlogLayout\nimport BlogNewPage\nimport BlogSlugPage\nimport RootError\nimport RootLayout\nimport RootPage\n\nRoot := \[\]\.\{$/m, "the component route files; no endpoint");
	assert.match(root, /\tview! = \|\{\}\| \{\n\t\tpath = Router\.location!\(\{\}\)\.path\n\t\tsegments = path\.split_on\("\/"\)\.keep_if\(\|segment\| !segment\.is_empty\(\)\)\.map\(Server\.decode_segment\)\n\t\tif \(segments == \["blog", "new"\]\) \{/, "matched as Routes matches, the fixed first");
	assert.match(
		root,
		/\} else if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("blog"\)\) \{\n\t\t\tparams = \{ slug: segments\.get\(1\) \?\? "" \}\n\t\t\tHtml\.component\(\|\| RootLayout\.view!\(\{ params: \|\| params, meta: \|\| BlogSlugPage\.meta, children: \[Root\.guarded!\(\[Html\.component\(\|\| BlogLayout\.view!\(\{ params: \|\| params, meta: \|\| BlogSlugPage\.meta, children: \[Html\.component\(\|\| BlogSlugPage\.view!\(\{ params: \|\| params \}\)\)\] \}\)\)\]\)\] \}\)\)\n/,
		"the root layout, then the <Errored>, then the layouts inside it and the page, each given the params and the page's meta",
	);
	assert.match(root, /\} else if \(segments == \[\]\) \{\n\t\t\tparams = \{\}\n\t\t\tHtml\.component\(\|\| RootLayout\.view!\(\{ params: \|\| params, meta: \|\| \{\}, children: \[Root\.guarded!\(\[Html\.component\(\|\| RootPage\.view!\(\{ params: \|\| params \}\)\)\]\)\] \}\)\)/, "a page with no meta: {}");
	assert.match(root, /\t\t\} else \{\n\t\t\tparams = \{\}\n\t\t\tHtml\.component\(\|\| RootLayout\.view!\(\{ params: \|\| params, meta: \|\| RootError\.meta, children: \[Root\.failed\(404, "nothing at \$\{path\}"\)\] \}\)\)\n\t\t\}/, "no page: the error page, in the root layout");
	assert.match(root, /\tguarded! = \|children\| Errored\.view!\(\{ fallback: \|problem, _retry\| Root\.failed\(Errored\.status_of\(problem\), problem\), children: children \}\)/, "its status the failure's: a refused read's 4xx, else 500");
	assert.match(root, /\tfailed = \|status, problem\| Html\.join\(\[Html\.component\(\|\| HttpStatusCode\.view!\(\{ code: status \}\)\), Html\.component\(\|\| RootError\.view!\(\{ status: \|\| status, problem: \|\| problem \}\)\)\]\)/);
	assert.doesNotMatch(root, /document|Styles/, "the root layout is the document");
	// No root layout, no error page: a default document, and a default error page.
	const bare = routeTable(["+page.rocx", "blog/+layout.rocx", "blog/+page.rocx"]);
	const bareSources = new Map(["+page.rocx", "blog/+layout.rocx", "blog/+page.rocx"].map((file) => [file, component()]));
	const plain = rootModule(bare, { sources: bareSources });
	assert.match(plain, /\t\t\tRoot\.document\(\[Root\.guarded!\(\[Html\.component\(\|\| BlogLayout\.view!\(\{ params: \|\| params, meta: \|\| \{\}, children: \[Html\.component\(\|\| BlogPage\.view!\(\{ params: \|\| params \}\)\)\] \}\)\)\]\)\]\)/);
	assert.match(plain, /\t\t\} else \{\n\t\t\tRoot\.document\(\[Root\.failed\(404, "nothing at \$\{path\}"\)\]\)\n\t\t\}/);
	assert.match(plain, /Html\.element\("main", \[\], \[Html\.element\("h1", \[\], \[Html\.text\(status\.to_str\(\)\)\]\), Html\.element\("p", \[\], \[Html\.text\(problem\)\]\)\]\)/);
	assert.match(plain, /\tdocument : List\(Html\) -> Html\n\tdocument = \|children\|\n\t\tHtml\.join\(\n\t\t\t\[\n\t\t\t\tHtml\.doctype\(\{\}\),\n\t\t\t\tHtml\.element\("html", \[Html\.attr\("lang", "en"\)\], \[\n\t\t\t\t\tHtml\.element\("head", \[\], \[Html\.void\("meta", \[Html\.attr\("charset", "utf-8"\)\]\), Html\.void\("meta", \[Html\.attr\("name", "viewport"\), Html\.attr\("content", "width=device-width, initial-scale=1"\)\]\), Styles\.style\]\),\n\t\t\t\t\tHtml\.element\("body", \[\], children\),/);
	assert.match(plain, /^import Styles$/m, "the app's stylesheet, in the default document's <head>");
});

test("Routes: a component page's GET is Root's page, after its route file's middleware; a path nothing has, Root's 404 for a browser", () => {
	const files = ["+layout.rocx", "+page.rocx", "+error.rocx", "members/+page.rocx", "blog/[slug]/+page.rocx", "blog/[slug]/+server.roc"];
	const table = routeTable(files);
	const sources = new Map(files.map((file) => [file, file.endsWith("+server.roc") ? { view: null, meta: false, methods: ["put!"], middleware: null, docs: {} } : component({ middleware: file === "members/+page.rocx" ? "Guards.member" : null })]));
	const routes = routesModule(table, { sources });
	assert.match(routes, /^import pf\.Server\nimport pf\.Endpoint\nimport pf\.Middleware\nimport Handlers\nimport Root\nimport MembersPage\n\nRoutes := /m, "no Html (no page is rendered here); a page's module only for its middleware");
	assert.match(routes, /\t\t\} else if \(segments == \["members"\]\) \{\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tMiddleware\.run!\(MembersPage\.middleware, request, context, \|_passed, _handed\| Routes\.page\(200\)\)\n/);
	assert.match(routes, /\} else if \(segments == \[\]\) \{\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tRoutes\.page\(200\)\n/, "no params read: Root reads them");
	assert.match(routes, /\} else if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("blog"\)\) \{\n\t\t\tparams = \{ slug: segments\.get\(1\) \?\? "" \}\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tRoutes\.page\(200\)\n\t\t\t\} else if \(method == "PUT"\) \{\n\t\t\t\tEndpoint\.respond!\(Handlers\.put_blog_slug\(params\), request, context\)/, "a page and an endpoint at one path");
	assert.match(routes, /\t\t\} else \{\n\t\t\tif \(wants_html\) \{\n\t\t\t\tRoutes\.page\(404\)\n\t\t\t\} else \{\n\t\t\t\tRoutes\.text\(404, "nothing at \$\{request\.path\}"\)\n\t\t\t\}\n\t\t\}/);
	assert.match(routes, /\tpage : U16 -> Server\.Response\n\tpage = \|status\| \{ status: status, headers: \[\], body: Page\(Root\.view!\) \}/);
	assert.doesNotMatch(routes, /Routes\.html|\thtml :|RootLayout|RootError/);
});

test("Routes.pattern: the route that answers a path, as its directory names it, for Server.Request's route", () => {
	const files = ["+page.rocx", "+error.rocx", "blog/+page.rocx", "blog/new/+page.rocx", "blog/[slug]/+page.rocx", "api/items/[id]/+server.roc"];
	const table = routeTable(files);
	const sources = new Map(files.map((file) => [file, file.endsWith("+server.roc") ? { view: null, meta: false, methods: ["get!"], middleware: null, docs: {} } : component()]));
	const routes = routesModule(table, { sources });
	const pattern = routes.slice(routes.indexOf("\tpattern = |path| {"), routes.indexOf("\ttext : U16"));
	assert.match(pattern, /\t\tif \(segments == \["blog", "new"\]\) \{\n\t\t\t"\/blog\/new"\n\t\t\} else if \(segments == \["blog"\]\) \{\n\t\t\t"\/blog"\n/, "fixed paths, in the order Routes.respond! tries them");
	assert.match(pattern, /\} else if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("blog"\)\) \{\n\t\t\t"\/blog\/\[slug\]"\n/, "a param's route, whatever the param");
	assert.match(pattern, /\} else if \(segments == \[\]\) \{\n\t\t\t"\/"\n/, "routes/ itself");
	assert.match(pattern, /"\/api\/items\/\[id\]"/, "an endpoint's route");
	assert.match(pattern, /\t\t\} else \{\n\t\t\t""\n\t\t\}\n\t\}/, "nothing answers: no route");
	assert.doesNotMatch(routes, /rocx\/call/, "no server functions, no call routes (D-023)");
	assert.match(routesModule(routeTable([]), { sources: new Map() }), /\tpattern = \|_path\| ""\n/, "no routes: none, and no unused variable");
});

test("route files' views: a page, a layout and the error page are components, which define view!", () => {
	const files = ["+layout.rocx", "+page.rocx", "+error.rocx", "old/+page.rocx"];
	const table = routeTable(files);
	const sources = new Map([
		["+layout.rocx", component({ view: "view" })],
		["+page.rocx", component()],
		["+error.rocx", component({ view: null })],
		["old/+page.rocx", component()],
	]);
	assert.deepEqual(viewProblems(table, sources), [
		"routes/+layout.rocx: a layout is a component, which defines view!: `view! = |{ meta, children, params }| …`",
		"routes/+error.rocx: an error page is a component, which defines view!: `view! = |{ status, problem }| …`",
	]);
	assert.deepEqual(viewProblems(table, new Map(files.map((file) => [file, component()]))), []);
});

test("App: the program, with the jobs the app's modules define (found by rocx build) and its migrations, in order", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-app-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		put("Jobs.roc", 'import jobs.Job\n\nJobs := [].{\n\twelcome : Job.Kind({ member : I64 })\n\twelcome = Job.define(\n\t\t"welcome",\n\t\t|_| Ok({}),\n\t)\n\n\tnightly = Job.define("nightly", |{}| Ok({}))\n\n\tonce = Job.define_with("once", { attempts: 1, timeout_ms: 60_000 }, |{}| Ok({}))\n}\n');
		put("Server/Mail.rocx", 'import jobs.Job\n\nMail := [].{\n\t# old = Job.define("old", |{}| Ok({}))\n\tsend = Job.define("mail", |{}| Ok({}))\n}\n');
		put("Server/Mail.roc", 'Mail := [].{\n\tsend = Job.define("mail", |{}| Ok({}))\n}\n\n# rocx: generated from Mail.rocx: edit that file\n');
		put("routes/members/+server.roc", 'import jobs.Job\n\nreminder = Job.define("reminder", |{}| Ok({}))\n\nget! = |_| Ok(1)\n');
		put("Generated/Copy.roc", 'Copy := [].{\n\tx = Job.define("welcome", |{}| Ok({}))\n}\n');
		put("build/client/Jobs.roc", 'Jobs := [].{\n\twelcome = Job.define("welcome", |{}| Ok({}))\n}\n');
		put("migrations/0010_later.sql", "select 2;");
		put("migrations/0002-first.sql", "select 1;");
		put("migrations/README.md", "not a migration");
		const table = routeTable(["members/+server.roc"]);
		const { jobs, problems } = jobsIn(dir, table);
		assert.deepEqual(problems, []);
		assert.deepEqual(
			jobs.map(({ name, define, module, file, line }) => [name, define, module, file, line]),
			[
				["welcome", "welcome", "Jobs", "Jobs.roc", 5],
				["nightly", "nightly", "Jobs", "Jobs.roc", 10],
				["once", "once", "Jobs", "Jobs.roc", 12],
				["mail", "send", "Server/Mail", "Server/Mail.rocx", 5],
				["reminder", "reminder", "Generated/MembersServer", "routes/members/+server.roc", 3],
			],
			"a route file's top is its module's block; Generated/, build/ and the .roc a .rocx file became are rocx's; Job.define_with's kinds too",
		);
		assert.deepEqual(migrationsIn(dir), ["0002-first.sql", "0010_later.sql"]);
		const app = appModule({ jobs, migrations: migrationsIn(dir), jobsPackage: "jobs" });
		assert.match(app, /^import pf\.Server\nimport pf\.Endpoint\nimport pf\.Middleware\nimport pf\.OpenApi\nimport pf\.Plugin\nimport jobs\.Job\nimport Routes\nimport \.\.\/Jobs as Jobs\nimport MembersServer\nimport \.\.\/Server\/Mail as ServerMail\nimport "\.\.\/migrations\/0002-first\.sql" as m0002_first : Str\nimport "\.\.\/migrations\/0010_later\.sql" as m0010_later : Str\n\nApp := \[\]\.\{$/m);
		assert.match(app, /\tConfig\(given, handed\) := \{\n\t\tcontext : Str -> given,\n\t\tmiddleware : Middleware\(given, handed\),\n\t\tdatabase : \[Postgres, Sqlite\(Str\), Turso\(Str\)\] \?\? Postgres,\n\t\topenapi : OpenApi\.Serving \?\? Off,\n\t\tplugins : List\(Plugin\.Value\(handed\)\) \?\? \[\],\n\t\}/, "the app's config: its database Postgres unless it says (D-045; Turso too, D-046); openapi is Off unless it says; no plugins unless it lists them");
		assert.match(app, /\tprogram : Config\(_, _\) -> _\n\tprogram = \|config\| \{\n\t\t# [^\n]*\n\t\trespond!: \|parsed, started\| \{\n\t\t\t# [^\n]*\n\t\t\trequest = \{ \.\.parsed, route: Plugin\.pattern\(config\.plugins, parsed\.method, parsed\.path\) \?\? Routes\.pattern\(parsed\.path\) \}\n\t\t\t# [^\n]*\n\t\t\t# [^\n]*\n\t\t\tif \(Endpoint\.channel_asked\(request\) == "close"\) \{\n\t\t\t\tRoutes\.closed!\(request\)\n\t\t\t\} else \{\n\t\t\t\t# [^\n]*\n\t\t\t\tchain = config\.middleware\n\t\t\t\t# A plugin's route, or the app's\.\n\t\t\t\tServer\.clear_flash\(request, Middleware\.run!\(chain, request, \(config\.context\)\(started\), \|passed, context\| Plugin\.respond!\(config\.plugins, passed, context, \|routed, handed\| Routes\.respond!\(routed, handed\)\)\)\)\n\t\t\t\}\n\t\t\},\n/, "the request as the host gives it (one record, its peer in it), with the route that answers it; a page view lets the flash go; a channel subscription's end, outside the middleware");
		assert.match(app, /\t\tdatabase: config\.database,\n\t\tmigrations: \[\{ name: "0002-first\.sql", sql: m0002_first \}, \{ name: "0010_later\.sql", sql: m0010_later \}\],\n\t\tactors: \[\],\n\t\tlogs: \{ format: Auto \},\n\t\tplugins: config\.plugins\.map\(Plugin\.running\),\n\t\troutes: Routes\.claims,\n\t\}/, "the platform's program: the migrations, no actors (the jobs are App.jobs', for the plugin); the log's format Auto (ROCX_LOG, or the terminal's guess), which the app may change with a record update");
		const none = appModule({});
		assert.match(app, /^\tjobs = \[Job\.handler\(Jobs\.welcome\), Job\.handler\(Jobs\.nightly\), Job\.handler\(Jobs\.once\), Job\.handler\(ServerMail\.send\), Job\.handler\(MembersServer\.reminder\)\]$/m, "App.jobs: the five, for the jobs plugin");
		assert.match(none, /\t\tmigrations: \[\],\n\t\tactors: \[\],/);
		assert.match(none, /\t\tlogs: \{ format: Auto \},\n\t\tplugins: config\.plugins\.map\(Plugin\.running\),\n\t\troutes: Routes\.claims,\n\t\}\n\}/, "App.program's log format is Auto; the platform gets the plugins and the app's routes, to check them at start");
		assert.doesNotMatch(none, /jobs\.Job|pf\.Actor|import "|\tjobs = /, "no jobs package named: no App.jobs");
		// A job outside its module's block, or inside a definition, can't be named; two with one name are refused.
		put("Loose.roc", 'import jobs.Job\n\nloose = Job.define("loose", |{}| Ok({}))\n\nLoose := [].{\n\tmake = |{}| {\n\t\tdeep = Job.define("deep", |{}| Ok({}))\n\t\tdeep\n\t}\n}\n');
		put("Again.roc", 'Again := [].{\n\tagain = Job.define("welcome", |{}| Ok({}))\n}\n');
		assert.deepEqual(jobsIn(dir, table).problems, [
			'Loose.roc:3: the job "loose" is defined outside its module\'s block: define it at the top of `Loose := [].{ … }`, as `\tloose = Job.define(…)`, so Generated/App can name it (`Loose.loose`)',
			'Loose.roc:7: the job "deep" is defined inside a definition: define it at the top of `Loose := [].{ … }`, as `\tdeep = Job.define(…)`, so Generated/App can name it (`Loose.deep`)',
			'Jobs.roc:5: there is a job called "welcome" already (Again.roc:2): the workers find a job by its name, so give each its own',
		]);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("App: the kinds of actor the app's modules define (found by rocx build), each Actor.handler, a function of {} called", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-actors-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		put("Carts.roc", 'import pf.Actor\n\nCarts := [].{\n\tcart : Actor.Kind({ items : List(Str) }, [Add(Str)], U64)\n\tcart = Actor.define({\n\t\tname: "cart",\n\t\tinitial: |_| { items: [] },\n\t\treceive!: |_, state, Add(item)| { state: { items: state.items.append(item) }, reply: 1 },\n\t})\n\n\tmirror = |{}|\n\t\tActor.define({ name: "mirror", initial: |_| {}, receive!: |_, state, _| { state, reply: 0 } })\n}\n');
		put("routes/rooms/+server.roc", 'import pf.Actor\n\nroom = Actor.define({ name: "room", initial: |_| 0, receive!: |_, n, _| { state: n, reply: n } })\n\nget! = |_| Ok(1)\n');
		put("Generated/Copy.roc", 'Copy := [].{\n\tx = Actor.define({ name: "cart", initial: |_| 0, receive!: |_, n, _| { state: n, reply: n } })\n}\n');
		put("Jobs.roc", 'import jobs.Job\n\nJobs := [].{\n\tdaily = Job.define("daily", |{}| Ok({}))\n}\n');
		const table = routeTable(["rooms/+server.roc"]);
		const { actors, problems } = actorsIn(dir, table);
		assert.deepEqual(problems, []);
		assert.deepEqual(
			actors.map(({ name, define, thunk, module, file, line }) => [name, define, thunk, module, file, line]),
			[
				["cart", "cart", false, "Carts", "Carts.roc", 5],
				["mirror", "mirror", true, "Carts", "Carts.roc", 11],
				["room", "room", false, "Generated/RoomsServer", "routes/rooms/+server.roc", 3],
			],
		);
		const { jobs } = jobsIn(dir, table);
		const app = appModule({ jobs, actors, jobsPackage: "jobs" });
		assert.match(app, /^import jobs\.Job\nimport pf\.Actor\nimport Routes\nimport \.\.\/Carts as Carts\nimport \.\.\/Jobs as Jobs\nimport RoomsServer\n/m, "each module once, jobs' and actors' alike");
		assert.match(app, /^\tjobs = \[Job\.handler\(Jobs\.daily\)\]$/m);
		assert.match(app, /\t\tmigrations: \[\],\n\t\tactors: \[Actor\.handler\(Carts\.cart\), Actor\.handler\(Carts\.mirror\(\{\}\)\), Actor\.handler\(RoomsServer\.room\)\],\n/);
		// Outside its module's block, its name not first, or two with one name: refused.
		put("Loose.roc", 'import pf.Actor\n\nloose = Actor.define({ name: "loose", initial: |_| 0, receive!: |_, n, _| { state: n, reply: n } })\n\nLoose := [].{\n\tunnamed = Actor.define({ initial: |_| 0, name: "unnamed", receive!: |_, n, _| { state: n, reply: n } })\n}\n');
		put("Again.roc", 'Again := [].{\n\tagain = Actor.define({ name: "cart", initial: |_| 0, receive!: |_, n, _| { state: n, reply: n } })\n}\n');
		assert.deepEqual(actorsIn(dir, table).problems, [
			'Loose.roc:3: the kind of actor "loose" is defined outside its module\'s block: define it at the top of `Loose := [].{ … }`, as `\tloose = Actor.define({ … })`, so Generated/App can name it (`Loose.loose`)',
			'Loose.roc:6: the kind of actor `unnamed` doesn\'t start with its name: define it as `unnamed = Actor.define({ name: "…", initial, receive! })`, so rocx build can list it',
			'Carts.roc:5: there is a kind of actor called "cart" already (Again.roc:2): the host finds an actor\'s kind by its name, and keeps its state under it, so give each its own',
		]);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client, for an app of component pages: the browser's main.roc and what a page loads; Root in both copies, App in the server's", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		// The jobs package names the server platform and has no browser.roc: the browser's half doesn't see it.
		put("packages/jobs/main.roc", 'package [Job, Cron] { pf: platform "../../server/platform/main.roc" }\n');
		put("app/main.roc", 'app [program] { charts: "../packages/charts/main.roc", jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }\n\nimport jobs.Job\nimport Generated/App\n\nprogram = App.program({ context: |s| s, middleware: M.none, plugins: [Job.plugin({ jobs: App.jobs })] })\n');
		put("app/routes/+page.rocx", "import pf.Html\n\nview! = |_| <p>Home</p>\n");
		put("app/Jobs.roc", 'import jobs.Job\n\nJobs := [].{\n\tdaily = Job.define("daily", |{}| Ok({}))\n}\n');
		const said = [];
		assert.equal(build([join(dir, "app")], { client: join(dir, "app", "build", "client"), cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		const out = join(dir, "app", "build", "client");
		const main = readFileSync(join(out, "main.roc"), "utf8");
		const web = join(dirname(new URL(import.meta.url).pathname), "..", "web", "platform", "main.roc");
		assert.match(main, /^app \[main!\] \{ charts: "\.\.\/\.\.\/\.\.\/packages\/charts\/main\.roc", pf: platform "(\.\.\/)+[^"]*web\/platform\/main\.roc" \}$/m, "the server's packages, and the web platform, from there");
		assert.ok(existsSync(join(out, /pf: platform "([^"]+)"/.exec(main)[1])) === existsSync(web), "rocx's own web platform");
		assert.match(main, /^import pf\.Html\nimport Generated\/Root\n\nmain! : \{\} => Html\nmain! = \|\{\}\| Root\.view!\(\{\}\)\n/m);
		assert.doesNotMatch(main, /answer!/, "the web platform requires main! alone: the browser answers no calls");
		assert.equal(main, clientMainModule({ web: /pf: platform "([^"]+)"/.exec(main)[1], packages: ['charts: "../../../packages/charts/main.roc"'], dir: "app" }));
		assert.equal(readFileSync(join(out, "static", "rocx", "start.js"), "utf8"), readFileSync(join(dirname(web), "..", "start.js"), "utf8"));
		assert.equal(readFileSync(join(out, "static", "rocx", "runtime.js"), "utf8"), readFileSync(join(dirname(web), "..", "runtime.js"), "utf8"));
		assert.equal(readFileSync(join(out, "Generated", "Root.roc"), "utf8"), readFileSync(join(dir, "app", "Generated", "Root.roc"), "utf8"), "Root: the same in both copies");
		assert.match(readFileSync(join(dir, "app", "Generated", "App.roc"), "utf8"), /^import jobs\.Job$[^]*^\tjobs = \[Job\.handler\(Jobs\.daily\)\]$/m, "App.jobs, for the jobs plugin, as the header names its package");
		assert.ok(!existsSync(join(dir, "app", "reference.roc")) && !existsSync(join(out, "reference.roc")), "no reference.roc: the browser's copy renders from the answers the server's page recorded");
		// Built again: what rocx wrote before goes (a page since removed), but the wasm built from it
		// stays as it was, served until its own build replaces it, so a running server's pages hydrate.
		const wasm = join(out, "static", "rocx", "app.wasm");
		writeFileSync(wasm, "the wasm built before");
		put("app/routes/old/+page.rocx", "import pf.Html\n\nview! = |_| <p>Old</p>\n");
		assert.equal(build([join(dir, "app")], { client: out, cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.ok(existsSync(join(out, "Generated", "OldPage.roc")), "the page's browser module, written");
		rmSync(join(dir, "app", "routes", "old"), { recursive: true });
		assert.equal(build([join(dir, "app")], { client: out, cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.equal(readFileSync(wasm, "utf8"), "the wasm built before", "app.wasm, untouched by a rebuild");
		assert.ok(!existsSync(join(out, "Generated", "OldPage.roc")), "what rocx wrote for a page that is gone, gone");
		assert.ok(existsSync(join(out, "static", "rocx", "start.js")) && existsSync(join(out, "main.roc")), "and the rest, written again");
		// A route file with the html package's Html is refused at its import: every page is a component.
		put("site/routes/+page.rocx", "import html.Html\n\nview = |_| <p>Home</p>\n");
		said.length = 0;
		assert.equal(build([join(dir, "site")], { client: join(dir, "site", "build", "client"), cwd: dir, log: (line) => said.push(line) }), false);
		assert.match(said.join("\n"), /site\/routes\/\+page\.rocx:1:8: import html\.Html: markup is components, written with the platform's Html, which the server renders and the browser hydrates: import pf\.Html/);
		assert.ok(!existsSync(join(dir, "site", "Generated", "Root.roc")) && !existsSync(join(dir, "site", "build", "client", "main.roc")));
		// One written with pf.Html, but `view` (pure): a page is a component, which defines view!.
		put("site/routes/+page.rocx", "import pf.Html\n\nview = |_| <p>Home</p>\n");
		said.length = 0;
		assert.equal(build([join(dir, "site")], { cwd: dir, log: (line) => said.push(line) }), false);
		assert.match(said.join("\n"), /site\/routes\/\+page\.rocx: a page is a component, which defines view!: `view! = \|\{ params \}\| …`/);
		// An app of endpoints alone: its program, with its jobs (Job.define_with's too) and migrations.
		put("api/routes/notes/+server.roc", "import pf.Server\nimport pf.Endpoint\n\nget! : { request : Server.Request, params : {}, context : c } => Try(U64, Endpoint.Refusal)\nget! = |_| Ok(1)\n");
		put("api/Jobs.roc", 'import jobs.Job\n\nJobs := [].{\n\tdaily = Job.define_with("daily", { attempts: 1, timeout_ms: 0 }, |{}| Ok({}))\n}\n');
		put("api/migrations/0001_notes.sql", "create table notes (id bigint);");
		// Jobs, and no jobs package in the header: refused, saying what to add.
		said.length = 0;
		assert.equal(build([join(dir, "api")], { cwd: dir, log: (line) => said.push(line) }), false);
		assert.match(said.join("\n"), /✗ api\/Jobs\.roc:4: the app defines jobs, and its header names no jobs package: add jobs: "…\/packages\/jobs\/main\.roc" to it, and Job\.plugin\(\{ jobs: App\.jobs \}\) to the app's plugins/);
		put("api/main.roc", 'app [program] { queue: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }\n');
		assert.equal(build([join(dir, "api")], { cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		const api = readFileSync(join(dir, "api", "Generated", "App.roc"), "utf8");
		assert.match(api, /^import queue\.Job$[^]*^\tjobs = \[Job\.handler\(Jobs\.daily\)\]$/m, "the jobs package by the name the header gives it");
		assert.match(api, /migrations: \[\{ name: "0001_notes\.sql", sql: m0001_notes \}\]/);
		assert.ok(!existsSync(join(dir, "api", "Generated", "Root.roc")));
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client: a route file's middleware, and the imports only it used, aren't in the browser's copy; the module's line goes after the last import kept", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-middleware-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		put("app/main.roc", 'app [program] { pf: platform "../server/platform/main.roc" }\n\nimport Generated/App\n');
		put("app/routes/+page.rocx", "import pf.Html\n\nview! = |_| <p>Home</p>\n");
		put(
			"app/routes/members/+page.rocx",
			[
				"import pf.Html",
				"import pf.Server",
				"import pf.Middleware",
				"import ../../Middlewares",
				"import ../../Db/Users",
				"import ../../Ui/Badge",
				"",
				"## Members only.",
				"middleware : Middleware({ started : Str }, { started : Str, member : Str })",
				"middleware = Middleware.make(",
				"\t|request, context, next!| if Users.known!(request) Middlewares.member(request, context, next!) else Server.refused(401, \"no\"),",
				")",
				"",
				"view! = |_| <p><Badge /> {Server.encode_segment(\"a b\")}</p>",
				"",
			].join("\n"),
		);
		// What only the middleware uses only the server has: the browser's copy leaves it out, so it warns of nothing.
		put("app/Middlewares.roc", "import pf.Env\n\nMiddlewares := [].{\n\tmember = |request, context, next!| next!(request, context)\n}\n");
		put("app/Db/Users.roc", "import pf.Db\n\nUsers := [].{\n\tknown! = |_| Bool.True\n}\n");
		const said = [];
		assert.equal(build([join(dir, "app")], { client: join(dir, "app", "build", "client"), cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.deepEqual(said.filter((line) => line.startsWith("⚠")), [], "nothing the browser's copy reaches is the server's alone");
		const server = readFileSync(join(dir, "app", "Generated", "MembersPage.roc"), "utf8");
		const browser = readFileSync(join(dir, "app", "build", "client", "Generated", "MembersPage.roc"), "utf8");
		assert.match(server, /^import \.\.\/Middlewares\n/m, "the server's copy keeps it all");
		assert.match(server, /^middleware = Middleware\.make\($/m);
		assert.doesNotMatch(browser, /middleware|Middlewares|Users/, "no middleware, and none of what only it used");
		assert.match(browser, /^import pf\.Server\n\n\n\nimport \.\.\/Ui\/Badge\nMembersPage := \[\]\.\{$/m, "the module's line after the last import kept, not on a line a dropped import left");
		assert.equal(browser.split("\n").length, server.split("\n").length, "lines stay lines");
		const at = (code) => code.split("\n").findIndex((line) => line.startsWith("view! = |_| Html.element(\"p\""));
		assert.ok(at(browser) > 0 && at(browser) === at(server), "the view on its line in both");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client: a module the browser's copy reaches that imports what only the server has (pf.Db) is a warning, at the import its author wrote; what the browser doesn't reach isn't", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-server-only-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		put("app/main.roc", 'app [program] { pf: platform "../server/platform/main.roc" }\n\nimport Generated/App\n');
		put("app/Notes.roc", 'import pf.Db\n\nNotes := [].{\n\ttitle = "Notes"\n}\n');
		put("app/Shelf.roc", "import Notes\n\nShelf := [].{\n\tname = Notes.title\n}\n");
		put("app/routes/+page.rocx", "import pf.Html\nimport ../Shelf\n\nview! = |_| <p>{Shelf.name}</p>\n");
		// Read only inside a <NoHydration>: the browser's copy leaves the import out, with what is inside.
		put("app/routes/quiet/+page.rocx", "import pf.Html\nimport ../../Notes\n\nview! = |_|\n\t<NoHydration>\n\t\t<p>{Notes.title}</p>\n\t</NoHydration>\n");
		// A page that imports it itself.
		put("app/routes/direct/+page.rocx", "import pf.Html\nimport pf.Db\n\nview! = |_| <p>{Db.name}</p>\n");
		// A module of components nothing imports: the browser never compiles it.
		put("app/Unused.rocx", "import pf.Html\nimport pf.Db\n\nUnused := [].{\n\tview = |_| <p>unused</p>\n}\n");
		const said = [];
		assert.equal(build([join(dir, "app")], { client: join(dir, "app", "build", "client"), cwd: dir, log: (line) => said.push(line) }), true, "a warning, not a failure: the browser's build says the rest");
		assert.deepEqual(said.filter((line) => line.startsWith("⚠")).sort(), [
			"⚠ app/routes/+page.rocx:2: the browser's copy imports ../Shelf, which imports Notes, which imports pf.Db, which only the server has, so the browser's build can't compile it. Use it in an endpoint (+server.roc) or middleware, which the browser's copy leaves out.",
			"⚠ app/routes/direct/+page.rocx:2: the browser's copy imports pf.Db, which only the server has, so the browser's build can't compile it. Use it in an endpoint (+server.roc) or middleware, which the browser's copy leaves out.",
		]);
		// Without --client, nothing to say.
		const quiet = [];
		build([join(dir, "app")], { cwd: dir, log: (line) => quiet.push(line) });
		assert.deepEqual(quiet.filter((line) => line.startsWith("⚠")), []);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client, for an app of endpoints alone: the browser's copy has no main.roc (the app's own is the server's program, left out), and the build says so", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-endpoints-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		const server = relative(join(dir, "app"), join(dirname(fileURLToPath(import.meta.url)), "..", "server", "platform", "main.roc"));
		put("app/main.roc", `app [program] { pf: platform "${server}" }\n\nimport Generated/App\n\nprogram = App.program({ context: |_| {}, middleware: M.none })\n`);
		put("app/tools/load.roc", `app [program] { pf: platform "../${server}" }\n\nprogram = {}\n`);
		put("app/routes/echo/+server.roc", "import pf.Server\nimport pf.Endpoint\n\npost! : { request : Server.Request, params : {}, context : c, body : {} } => Try(Str, Endpoint.Refusal)\npost! = |{ request }| Ok(Server.text_of(request))\n");
		put("app/Words.roc", "Words := [].{\n\tall = [\"echo\"]\n}\n");
		const said = [];
		const out = join(dir, "app", "build", "client");
		assert.equal(build([join(dir, "app")], { client: out, cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.ok(existsSync(join(dir, "app", "Generated", "App.roc")), "the server's program, as before");
		assert.ok(!existsSync(join(out, "main.roc")) && !existsSync(join(out, "tools", "load.roc")), "no app on the server platform in the browser's copy");
		assert.ok(existsSync(join(out, "Words.roc")) && existsSync(join(out, "Generated", "Api.roc")), "the rest of the copy, as before");
		assert.ok(!existsSync(join(out, "static")), "nothing a page loads");
		assert.ok(said.includes("rocx: app has no component pages and no app on the web platform, so its browser's copy (app/build/client) has no main.roc: the browser has nothing to build"), said.join("\n"));
		// Given a page, the browser's main.roc is written (and the server's still isn't copied).
		put("app/routes/+page.rocx", "import pf.Html\n\nview! = |_| <p>Home</p>\n");
		said.length = 0;
		assert.equal(build([join(dir, "app")], { client: out, cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.match(readFileSync(join(out, "main.roc"), "utf8"), /^app \[main!\] \{ pf: platform "[^"]*web\/platform\/main\.roc" \}$/m);
		assert.ok(!existsSync(join(out, "tools", "load.roc")) && existsSync(join(out, "static", "rocx", "start.js")));
		assert.ok(!said.some((line) => line.includes("nothing to build")), said.join("\n"));
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client: an app of components with no routes is checked from its own app on the web platform", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-components-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		const web = relative(join(dir, "app"), join(dirname(fileURLToPath(import.meta.url)), "..", "web", "platform", "main.roc"));
		put("app/widget_app.roc", `app [main!] { pf: platform "${web}" }\n\nimport pf.Html\nimport Widget\n\nmain! = |{}| Widget.view!({})\n`);
		put("app/Secret.roc", 'import pf.Env\n\nSecret := [].{\n\tkey = "k"\n}\n');
		put("app/Widget.rocx", "import pf.Html\nimport Secret\n\nWidget := [].{\n\tview! = |{}| <p>{Secret.key}</p>\n}\n");
		const said = [];
		assert.equal(build([join(dir, "app")], { client: join(dir, "out"), cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.deepEqual(said.filter((line) => line.startsWith("⚠")), [
			"⚠ app/Widget.rocx:2: the browser's copy imports Secret, which imports pf.Env, which only the server has, so the browser's build can't compile it. Use it in an endpoint (+server.roc) or middleware, which the browser's copy leaves out.",
		]);
		assert.ok(existsSync(join(dir, "out", "widget_app.roc")), "its own app on the web platform, kept: it is the browser's program");
		assert.ok(!said.some((line) => line.includes("nothing to build")), said.join("\n"));
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("routes: a directory may name a file (sitemap.xml, feed.xml): a dot between letters or digits, its names without it", () => {
	const files = ["sitemap.xml/+server.roc", "[lang]/feed.xml/+server.roc", "[lang]/+page.rocx"];
	const table = routeTable(files);
	const row = (path) => table.servers.find((server) => server.path === path);
	assert.deepEqual([row("/sitemap.xml").name, row("/sitemap.xml").module], ["sitemap_xml", "SitemapXmlServer"]);
	assert.deepEqual([row("/[lang]/feed.xml").name, row("/[lang]/feed.xml").module], ["lang_feed_xml", "LangFeedXmlServer"]);
	assert.ok(matches("/sitemap.xml", "/sitemap.xml"));
	assert.ok(!matches("/sitemap.xml", "/sitemapxxml"));
	assert.ok(matches("/[lang]/feed.xml", "/en/feed.xml"));
	const sources = new Map(files.map((file) => [file, file.endsWith("+page.rocx") ? { view: "view!", meta: false, methods: [], middleware: null, docs: {} } : { view: null, meta: false, methods: ["get!"], middleware: null, docs: {}, handlers: { "get!": { line: 4, body: "", answer: "Str" } }, imports: [] }]));
	const routes = routesModule(table, { sources });
	assert.match(routes, /if \(segments == \["sitemap\.xml"\]\) \{/);
	assert.match(routes, /Endpoint\.respond!\(Handlers\.get_lang_feed_xml\(params\), request, context\)/);
	// The contract's names, and the handlers' modules, without the dots; its URLs with them (D-037).
	const api = apiModule(table, { sources });
	assert.match(api, /\t## GET \/sitemap\.xml, from routes\/sitemap\.xml\/\+server\.roc\n\tget_sitemap_xml : \{\} -> Endpoint\(context, \{\}, Str\)\n\tget_sitemap_xml = \|_params\| Endpoint\.remote\("GET", "\/sitemap\.xml"\)\n/);
	assert.match(api, /\tget_lang_feed_xml : \{ lang : Str \} -> Endpoint\(context, \{\}, Str\)\n\tget_lang_feed_xml = \|params\| Endpoint\.remote\("GET", "\/\$\{Server\.encode_segment\(params\.lang\)\}\/feed\.xml"\)\n/);
	assert.match(api, /OpenApi\.path\("\/sitemap\.xml", \[\], \[/);
	const handlers = handlersModule(table, { sources });
	assert.match(handlers, /^import LangFeedXmlServer\nimport SitemapXmlServer$/m);
	assert.match(handlers, /\tget_sitemap_xml = \|params\| Endpoint\.bind\(Api\.get_sitemap_xml\(params\), \|request, context, \{\}\| SitemapXmlServer\.get!\(/);
	// A dot that isn't between two letters or digits would make a name Roc can't read.
	for (const part of ["feed.", "a..b", "a.-b", "a-.b"]) assert.throws(() => routeTable([`${part}/+page.rocx`]), /a directory is a path's part in lower case/, part);
	assert.throws(() => routeTable(["feed.xml/+server.roc", "feed-xml/+server.roc"]), /would both be/);
});

test("routes: .well-known is routed, and no other directory starting with a dot; respond! answers every method nothing else at its path does", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-routes-"));
	try {
		for (const file of [".well-known/oauth-authorization-server/+server.roc", ".hidden/+page.rocx", "mcp/+server.roc", "+page.rocx"]) {
			mkdirSync(dirname(join(dir, file)), { recursive: true });
			writeFileSync(join(dir, file), "");
		}
		assert.deepEqual(findRouteFiles(dir), ["+page.rocx", ".well-known/oauth-authorization-server/+server.roc", "mcp/+server.roc"]);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
	assert.throws(() => routeTable([".hidden/+page.rocx"]), /a directory is a path's part in lower case/);
	const files = [".well-known/oauth-authorization-server/+server.roc", "mcp/+server.roc", "mounted/+page.rocx", "mounted/+server.roc"];
	const table = routeTable(files);
	const known = table.servers.find((server) => server.file.startsWith(".well-known"));
	assert.deepEqual([known.path, known.name, known.module], ["/.well-known/oauth-authorization-server", "well_known_oauth_authorization_server", "WellKnownOauthAuthorizationServerServer"]);

	assert.deepEqual(definitions("import pf.Server\n\nmiddleware = Guards.bearer\n\nrespond! = |{ request, .. }| Server.redirect(\"/\")\n"), { view: null, meta: false, methods: [], middleware: "Guards.bearer", docs: {}, respond: true });
	const sources = new Map([
		[files[0], { view: null, meta: false, methods: ["get!"], middleware: null, docs: {} }],
		[files[1], { view: null, meta: false, methods: ["post!"], middleware: "Guards.bearer", docs: {}, respond: true }],
		[files[2], { view: "view!", meta: false, methods: [], middleware: null, docs: {} }],
		[files[3], { view: null, meta: false, methods: [], middleware: null, docs: {}, respond: true }],
	]);
	const routes = routesModule(table, { sources });
	assert.match(routes, /if \(segments == \["\.well-known", "oauth-authorization-server"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET"\) \{\n\t\t\t\tEndpoint\.respond!\(Handlers\.get_well_known_oauth_authorization_server\(params\), request, context\)/);
	assert.match(
		routes,
		/if \(segments == \["mcp"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "POST"\) \{\n[^\n]*Handlers\.post_mcp[^\n]*\n\t\t\t\} else \{\n\t\t\t\tMiddleware\.run!\(McpServer\.middleware, request, context, \|passed, handed\| McpServer\.respond!\(\{ request: passed, params: params, context: handed \}\)\)\n\t\t\t\}/,
		"post! for a POST; every other method, respond!, behind the file's middleware",
	);
	assert.match(
		routes,
		/if \(segments == \["mounted"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET" and wants_html\) \{\n\t\t\t\tRoutes\.page\(200\)\n\t\t\t\} else \{\n\t\t\t\tMountedServer\.respond!\(\{ request: request, params: params, context: context \}\)\n\t\t\t\}/,
		"beside a page, a browser's GET is the page's, and anything else respond!'s",
	);
	assert.match(routes, /^import McpServer\nimport MountedServer$/m, "a file with respond! is imported; a page, only for its middleware");
	assert.deepEqual(
		routeList(table, sources).map((row) => `${row.method} ${row.path} ${row.middleware ?? "-"}`),
		["GET /.well-known/oauth-authorization-server -", "POST /mcp Guards.bearer", "* /mcp Guards.bearer", "GET /mounted -", "* /mounted -"],
	);
	assert.doesNotMatch(apiModule(table, { sources }), /respond/, "respond! isn't an endpoint in Api");
	// Beside a component page (Root renders it), a browser's GET is Root's page; anything else respond!'s.
	const live = routeTable(["live/+page.rocx", "live/+server.roc"]);
	const liveSources = new Map([
		["live/+page.rocx", component()],
		["live/+server.roc", { view: null, meta: false, methods: [], middleware: null, docs: {}, respond: true }],
	]);
	assert.match(
		routesModule(live, { sources: liveSources }),
		/if \(segments == \["live"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET" and wants_html\) \{\n\t\t\t\tRoutes\.page\(200\)\n\t\t\t\} else \{\n\t\t\t\tLiveServer\.respond!\(\{ request: request, params: params, context: context \}\)\n\t\t\t\}/,
	);
});

test("channels: a +server.roc's channel! is Api's channel_<path> (CHANNEL, its URL; the browser's copy that alone); Routes answers the host's asks about it behind the file's middleware, with its hooks, and App its end outside it; a path a channel alone is at answers no HTTP", () => {
	const room = [
		"import pf.Server",
		"import pf.Endpoint",
		"import pf.Channel",
		"",
		"middleware = Members.signed_in",
		"",
		"## Who is in the room.",
		"channel! : { request : Server.Request, params : { room : Str }, context : Str } => Try(Channel(Str, Str, Str), Endpoint.Refusal)",
		"channel! = |{ context, .. }| Ok(Channel.allow(context))",
		"",
		"receive! = |{ said, .. }| Ok({})",
		"on_open! = |{ who, .. }| [who]",
		"on_close! = |_| {}",
		"",
	].join("\n");
	assert.deepEqual(definitions(room).channel, { hooks: ["receive!", "on_open!", "on_close!"] });
	assert.deepEqual(definitions(room).handlers, { "channel!": { line: 9, body: "", answer: "Channel(Str, Str, Str)" } }, "its types, from its annotation: what Api's copy is");
	assert.deepEqual(definitions(room).methods, [], "a channel is no HTTP method");
	assert.deepEqual(definitions("get! = |_| Ok(1)\n").channel, undefined);
	assert.deepEqual(definitions("on_open! = |_| []\n").hooks, ["on_open!"], "a hook with no channel, for rocx build to refuse");
	const table = routeTable(["+page.rocx", "rooms/[room]/+server.roc", "news/+server.roc", "news/+page.rocx"]);
	const sources = new Map([
		["+page.rocx", { view: "view!", meta: false, methods: [], middleware: null, docs: {} }],
		["rooms/[room]/+server.roc", { view: null, meta: false, methods: [], middleware: "Members.signed_in", docs: {}, channel: { hooks: ["receive!", "on_open!", "on_close!"] }, handlers: definitions(room).handlers, imports: definitions(room).imports }],
		["news/+server.roc", { view: null, meta: false, methods: ["get!"], middleware: null, docs: {}, channel: { hooks: [] } }],
		["news/+page.rocx", { view: "view!", meta: false, methods: [], middleware: null, docs: {} }],
	]);
	const api = apiModule(table, { sources, title: "app" });
	assert.match(api, /\t## The channel at \/rooms\/\[room\], from routes\/rooms\/\[room\]\/\+server\.roc \(`Endpoint\.subscribe!`, `Endpoint\.publish!`\)\n\tchannel_rooms_room : \{ room : Str \} -> Endpoint\(context, \{\}, Channel\(Str, Str, Str\)\)\n\tchannel_rooms_room = \|params\| Endpoint\.remote\("CHANNEL", "\/rooms\/\$\{Server\.encode_segment\(params\.room\)\}"\)\n/, "its Channel(who, message, said), from channel!'s annotation");
	assert.match(api, /^import pf\.Channel$/m, "the module its type names");
	assert.match(api, /\tchannel_news = \|_params\| Endpoint\.remote\("CHANNEL", "\/news"\)/);
	assert.match(handlersModule(table, { sources }), /\tchannel_rooms_room = \|params\| Endpoint\.bind\(Api\.channel_rooms_room\(params\), \|request, context, \{\}\| RoomsRoomServer\.channel!\(\{ request: request, params: params, context: context \}\)\)\n/);
	assert.doesNotMatch(api, /OpenApi\.path\("\/rooms/, "a channel isn't in the OpenAPI document");
	const browser = apiModule(table, { sources, client: true });
	assert.match(browser, /\tchannel_rooms_room = \|params\| Endpoint\.remote\("CHANNEL", "\/rooms\/\$\{Server\.encode_segment\(params\.room\)\}"\)\n/);
	assert.match(browser, /\tchannel_news = \|_params\| Endpoint\.remote\("CHANNEL", "\/news"\)\n/);
	assert.doesNotMatch(browser, /RoomsRoomServer|on_open|receive/, "the browser's copy: its method, URL and types alone");
	assert.match(browser, /\tchannel_rooms_room : \{ room : Str \} -> Endpoint\(context, \{\}, Channel\(Str, Str, Str\)\)\n/);
	const routes = routesModule(table, { sources });
	assert.match(routes, /^import RoomsRoomServer$/m, "the module whose hooks it calls");
	assert.match(routes, /^import Api\nimport Handlers$/m, "Handlers for each channel's check, Api for what its hooks are given");
	assert.match(routes, /\t\tif \(Endpoint\.channel_asked\(request\) != ""\) \{\n\t\t\tRoutes\.channel!\(segments, request, context\)\n\t\t\} else if /, "the host's asks first, whatever the path");
	assert.match(
		routes,
		/\tchannel! = \|segments, request, context\| \{\n\t\tif \(segments == \["news"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tEndpoint\.channel!\(Handlers\.channel_news\(params\), request, context, \{ opened!: \|_who, _tab\| \[\], received!: \|_who, _tab, _said\| Err\(Status\(404, "\/news takes nothing pages say: its route has no receive!"\)\), closes: Bool\.False \}\)\n\t\t\} else if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("rooms"\)\) \{\n\t\t\tparams = \{ room: segments\.get\(1\) \?\? "" \}\n\t\t\tMiddleware\.run!\(RoomsRoomServer\.middleware, request, context, \|passed, handed\| Endpoint\.channel!\(Handlers\.channel_rooms_room\(params\), passed, handed, \{ opened!: \|who, tab\| RoomsRoomServer\.on_open!\(\{ params: params, who: who, tab: tab, channel: Api\.channel_rooms_room\(params\) \}\), received!: Endpoint\.receiving\(Api\.channel_rooms_room\(params\), \|who, tab, said\| RoomsRoomServer\.receive!\(\{ params: params, who: who, tab: tab, said: said, channel: Api\.channel_rooms_room\(params\) \}\)\), closes: Bool\.True \}\)\)\n\t\t\} else \{\n\t\t\tRoutes\.text\(404, "no channel at \$\{request\.path\}"\)\n\t\t\}\n\t\}/,
		"each behind its file's middleware, the hooks it has, defaults for the others",
	);
	assert.match(
		routes,
		/\tclosed! = \|request\| \{\n\t\tsegments = [^\n]*\n\t\tif \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("rooms"\)\) \{\n\t\t\tparams = \{ room: segments\.get\(1\) \?\? "" \}\n\t\t\tEndpoint\.closed!\(Api\.channel_rooms_room\(params\), request, \|who, tab, why\| RoomsRoomServer\.on_close!\(\{ params: params, who: who, tab: tab, why: why, channel: Api\.channel_rooms_room\(params\) \}\)\)\n\t\t\} else \{\n\t\t\tServer\.response\(204, \[\], ""\)\n\t\t\}\n\t\}/,
		"on_close!, for the channels that have it, outside any middleware",
	);
	assert.doesNotMatch(routes, /if \(segments\.len\(\) == 2 and segments\.get\(0\) == Ok\("rooms"\)\) \{\n\t\t\tparams = \{ room: segments\.get\(1\) \?\? "" \}\n\t\t\tif \(method/, "a path a channel alone is at answers no HTTP request: nothing is there");
	assert.match(routes, /if \(segments == \["news"\]\) \{\n\t\t\tparams = \{\}\n\t\t\tif \(method == "GET" and wants_html\)/, "a channel beside a page and an endpoint leaves them as they were");
	const none = routesModule(routeTable(["+page.rocx"]), { sources: new Map([["+page.rocx", { view: "view!", meta: false, methods: [], middleware: null }]]) });
	assert.match(none, /\t\tif \(Endpoint\.channel_asked\(request\) != ""\) \{\n\t\t\tRoutes\.text\(404, "no channel at \$\{request\.path\}"\)\n\t\t\} else /, "with no channels, every ask is a 404");
	assert.doesNotMatch(none, /\tchannel! = /, "and no channel! to ask");
	assert.match(none, /\tclosed! = \|_request\| Server\.response\(204, \[\], ""\)\n/);
	assert.deepEqual(
		routeList(table, sources).filter((row) => row.method === "CHANNEL"),
		[
			{ method: "CHANNEL", path: "/news", file: "routes/news/+server.roc", middleware: null },
			{ method: "CHANNEL", path: "/rooms/[room]", file: "routes/rooms/[room]/+server.roc", middleware: "Members.signed_in" },
		],
	);
	// rocx build: a +server.roc with a channel alone is fine; a hook with no channel isn't.
	const dir = mkdtempSync(join(tmpdir(), "rocx-channels-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	try {
		put("app/main.roc", 'app [program] { pf: platform "../server/platform/main.roc" }\n\nimport Generated/App\n');
		put("app/routes/+page.rocx", "import pf.Html\n\nview! = |_| <p>Home</p>\n");
		put("app/routes/rooms/[room]/+server.roc", room.replace("middleware = Members.signed_in\n\n", ""));
		const said = [];
		assert.equal(build([join(dir, "app")], { client: join(dir, "app", "build", "client"), cwd: dir, log: (line) => said.push(line) }), true, said.join("\n"));
		assert.match(readFileSync(join(dir, "app", "build", "client", "Generated", "Api.roc"), "utf8"), /channel_rooms_room = \|params\| Endpoint\.remote\("CHANNEL"/);
		put("app/routes/lobby/+server.roc", "import pf.Channel\n\non_open! = |_| []\n");
		said.length = 0;
		assert.equal(build([join(dir, "app")], { cwd: dir, log: (line) => said.push(line) }), false);
		assert.match(said.join("\n"), /routes\/lobby\/\+server\.roc: on_open! is a channel's hook, and it defines no channel: define channel!, its check/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("the contract (D-037): Api's types are copied from each handler's annotation, with the imports they name, from Generated/; a handler rocx can't read is refused", () => {
	const board = [
		"import pf.Server",
		"import pf.Endpoint",
		"import pf.Events",
		"import pf.Channel",
		"import ../../../Board exposing [Card]",
		"import ../../../Store",
		"import shop.Cart as C",
		"import ../../../Guards",
		"",
		"middleware = Guards.member",
		"",
		"## The board.",
		"get! : { request : Server.Request, params : { board : Str }, context : Guards.Member }",
		"\t=> Try(List(Board.Column), Endpoint.Refusal)",
		"get! = |{ params, .. }| Store.columns!(params.board)",
		"",
		"post! : {",
		"\trequest : Server.Request,",
		"\tparams : { board : Str },",
		"\tcontext : Guards.Member,",
		"\tbody : { card : Card, totals : List(C.Total) },",
		"} => Try(Str, Endpoint.Refusal)",
		"post! = |_| Ok(\"\")",
		"",
		"events! : { request : Server.Request, params : { board : Str }, context : c } => Try(Events({ at : U64 }), Endpoint.Refusal)",
		"events! = |_| Ok(Events.from_list([], 0))",
		"",
		"channel! : { request : Server.Request, params : { board : Str }, context : c } => Try(Channel(Str, Board.News, []), Endpoint.Refusal)",
		"channel! = |_| Ok(Channel.allow(\"x\"))",
		"",
	].join("\n");
	const defs = definitions(board);
	assert.deepEqual(defs.handlers, {
		"get!": { line: 15, body: "", answer: "List(Board.Column)" },
		"post!": { line: 23, body: "{ card : Card, totals : List(C.Total) }", answer: "Str" },
		"events!": { line: 26, body: "", answer: "Events({ at : U64 })" },
		"channel!": { line: 29, body: "", answer: "Channel(Str, Board.News, [])" },
	}, "an annotation over several lines too; the line each is defined at");
	assert.deepEqual(defs.imports.length, 8);
	const table = routeTable(["b/[board]/+server.roc"]);
	const sources = new Map([["b/[board]/+server.roc", defs]]);
	const api = apiModule(table, { sources });
	assert.match(api, /^import pf\.Endpoint\nimport pf\.Server\nimport pf\.OpenApi\nimport pf\.Channel\nimport pf\.Events\nimport shop\.Cart as C\nimport \.\.\/Board exposing \[Card\]\n\nApi := /m, "the packages' modules, then the app's, as Generated/ names them: what the types name (Card exposed, C an alias), not Store or Guards");
	assert.match(api, /\tget_b_board : \{ board : Str \} -> Endpoint\(context, \{\}, List\(Board\.Column\)\)\n/);
	assert.match(api, /\tpost_b_board : \{ board : Str \} -> Endpoint\(context, \{ card : Card, totals : List\(C\.Total\) \}, Str\)\n/);
	assert.match(api, /\tevents_b_board : \{ board : Str \} -> Endpoint\(context, \{\}, Events\(\{ at : U64 \}\)\)\n/);
	assert.match(api, /\tchannel_b_board : \{ board : Str \} -> Endpoint\(context, \{\}, Channel\(Str, Board\.News, \[\]\)\)\n/);
	assert.doesNotMatch(api, /Guards|BBoardServer/, "the context stays any: only the handler cares");
	assert.deepEqual(contractProblems(table, sources), []);
	// What rocx build refuses, each at its handler's line.
	const refused = (source, file = "notes/+server.roc") => contractProblems(routeTable([file]), new Map([[file, definitions(source)]]));
	assert.deepEqual(refused("import pf.Server\n\n## Notes.\nget! = |_| Ok([])\n"), [
		"routes/notes/+server.roc:4: get! has no type annotation, and rocx build copies its types into Generated/Api, the app's contract (D-037): annotate it, as get! : { request : Server.Request, params : {}, context : c } => Try(…, Endpoint.Refusal)",
	]);
	assert.deepEqual(refused("channel! = |_| Ok(Channel.allow(1))\n", "rooms/[room]/+server.roc"), [
		"routes/rooms/[room]/+server.roc:1: channel! has no type annotation, and rocx build copies its types into Generated/Api, the app's contract (D-037): annotate it, as channel! : { request : Server.Request, params : { room : Str }, context : c } => Try(Channel(who, message, said), Endpoint.Refusal)",
	]);
	assert.match(refused("post! : Handler\npost! = |_| Ok(1)\n")[0], /^routes\/notes\/\+server\.roc:2: rocx build can't read post!'s types for Generated\/Api: its annotation should be a record of what it is given, then => and a Try of its answer/);
	assert.match(refused("get! : { request : Server.Request, params : {}, context : c } => Try(a, Endpoint.Refusal) where [a.X]\nget! = |_| Ok(1)\n")[0], /a where clause\?/);
	assert.deepEqual(refused("put! : { request : Server.Request, params : {}, context : c } => Try({}, Endpoint.Refusal)\nput! = |_| Ok({})\n"), [
		"routes/notes/+server.roc:2: put! is sent a body (PUT): its annotation's record needs body : … ({} for none), as put! : { request : Server.Request, params : {}, context : c, body : … } => Try(…, Endpoint.Refusal)",
	]);
	// One module that two route files import differently (one exposing a name): imported once.
	const merged = routeTable(["a/+server.roc", "b/c/+server.roc"]);
	const mergedSources = new Map([
		["a/+server.roc", definitions("import ../../Board exposing [Card]\n\nget! : { request : Server.Request, params : {}, context : c } => Try(Card, Endpoint.Refusal)\nget! = |_| Ok(1)\n")],
		["b/c/+server.roc", definitions("import ../../../Board\n\nget! : { request : Server.Request, params : {}, context : c } => Try(Board.Column, Endpoint.Refusal)\nget! = |_| Ok(1)\n")],
	]);
	assert.deepEqual(contractProblems(merged, mergedSources), []);
	assert.match(apiModule(merged, { sources: mergedSources }), /^import pf\.OpenApi\nimport \.\.\/Board exposing \[Card\]\n\nApi := /m, "once, with what either exposes");
	// Two route files whose types name different modules by one name: Api can't import both.
	const two = routeTable(["a/+server.roc", "b/+server.roc"]);
	const clash = contractProblems(two, new Map([
		["a/+server.roc", definitions("import ../../Store\n\nget! : { request : Server.Request, params : {}, context : c } => Try(Store.Item, Endpoint.Refusal)\nget! = |_| Ok(1)\n")],
		["b/+server.roc", definitions("import shop.Store\n\nget! : { request : Server.Request, params : {}, context : c } => Try(Store.Item, Endpoint.Refusal)\nget! = |_| Ok(1)\n")],
	]));
	assert.deepEqual(clash, [
		"routes/b/+server.roc:4: its get! names Store (shop.Store, as Generated/ has it), and routes/a/+server.roc's get! names another Store (../Store): Generated/Api imports the modules both name, so give one of them another name (import … as …)",
	]);
});

test("rocx build (D-037): refuses an unannotated handler; a type's module that imports Api is a cycle, said at that import; the browser's copy reaching pf.Db through Api's types is an error at the route", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-contract-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	const said = [];
	const built = (options = {}) => {
		said.length = 0;
		return build([join(dir, "app")], { cwd: dir, log: (line) => said.push(line), ...options });
	};
	try {
		put("app/main.roc", 'app [program] { pf: platform "../server/platform/main.roc" }\n\nimport Generated/App\n');
		put("app/routes/+page.rocx", "import pf.Html\n\nview! = |_| <p>Home</p>\n");
		put("app/routes/hello/+server.roc", "## GET /hello.\nget! = |_| Ok(\"hi\")\n");
		assert.equal(built(), false);
		assert.deepEqual(said.filter((line) => line.startsWith("✗")), [
			"✗ app/routes/hello/+server.roc:2: get! has no type annotation, and rocx build copies its types into Generated/Api, the app's contract (D-037): annotate it, as get! : { request : Server.Request, params : {}, context : c } => Try(…, Endpoint.Refusal)",
		]);
		put("app/routes/hello/+server.roc", "import pf.Server\nimport pf.Endpoint\nimport ../../News\n\n## GET /hello.\nget! : { request : Server.Request, params : {}, context : c } => Try(News.Said, Endpoint.Refusal)\nget! = |_| Ok({ text: \"hi\" })\n");
		// News defines the answer's type and imports Api, through Feed: Api imports News, so a cycle.
		put("app/News.roc", "import Feed\n\nNews := [].{\n\tSaid : { text : Str }\n}\n");
		put("app/Feed.roc", "import pf.Endpoint\nimport Generated/Api\n\nFeed := [].{\n\thello = Api.get_hello({})\n}\n");
		assert.equal(built(), false);
		assert.deepEqual(said.filter((line) => line.startsWith("✗")), [
			"✗ app/Feed.roc:2: News.roc imports Feed, which imports Generated/Api, and Generated/Api imports News.roc for routes/hello/+server.roc's get!, whose type News.Said names News.Said: a cycle, which Roc refuses. Move News.Said into a module of its own that doesn't import Generated/Api, and name it from there",
		]);
		// The type in a module of its own: no cycle. Feed, which the routes may import, may import Api.
		put("app/News.roc", "News := [].{\n\tSaid : { text : Str }\n}\n");
		// The page reads the endpoint: the browser's copy reaches Api, and what its types name.
		put("app/routes/+page.rocx", "import pf.Html\nimport pf.Endpoint\nimport ../Generated/Api\n\nview! = |_| <p>{Endpoint.get!(Api.get_hello({})).text}</p>\n");
		assert.equal(built({ client: join(dir, "app", "build", "client") }), true, said.join("\n"));
		assert.match(readFileSync(join(dir, "app", "Generated", "Api.roc"), "utf8"), /^import \.\.\/News\n[^]*\tget_hello : \{\} -> Endpoint\(context, \{\}, News\.Said\)\n/m);
		assert.match(readFileSync(join(dir, "app", "build", "client", "Generated", "Api.roc"), "utf8"), /\tget_hello : \{\} -> Endpoint\(context, \{\}, News\.Said\)\n/, "the browser's copy: the same types");
		assert.ok(existsSync(join(dir, "app", "Generated", "Handlers.roc")) && readFileSync(join(dir, "app", "build", "client", ".rocx-client"), "utf8").includes("\napp: ../..\n"), "Handlers, for the server; the copy says where its app is, for rocx check");
		// A type whose module imports pf.Db: the browser's copy of Api can't compile it.
		put("app/News.roc", "import pf.Db\n\nNews := [].{\n\tSaid : { text : Str }\n}\n");
		assert.equal(built({ client: join(dir, "app", "build", "client") }), false);
		assert.deepEqual(said.filter((line) => line.startsWith("✗") || line.startsWith("⚠")), [
			"✗ app/routes/hello/+server.roc:7: get!'s type News.Said names News, a module that imports pf.Db, which only the server has. The browser's copy of Generated/Api, the app's contract (D-037), imports the modules a route's types name, so the browser's build can't compile it: move the type into a module that doesn't import pf.Db, and name it from there",
		]);
		assert.equal(built(), true, "without --client, nothing to say: the server's copy compiles");
		// A type the route file defines itself: Api, which imports no route file, can't name it.
		put("app/routes/hello/+server.roc", "import pf.Server\nimport pf.Endpoint\n\nGreeting : { text : Str }\n\n## GET /hello.\nget! : { request : Server.Request, params : {}, context : c } => Try(List(Greeting), Endpoint.Refusal)\nget! = |_| Ok([{ text: \"hi\" }])\n");
		assert.equal(built(), false);
		assert.deepEqual(said.filter((line) => line.startsWith("✗")), [
			"✗ app/routes/hello/+server.roc:8: get!'s type names Greeting, which this route file defines, and Generated/Api, the app's contract (D-037), imports no route file: move Greeting into a module of its own (Greeting.roc beside routes/) and import it here",
		]);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
