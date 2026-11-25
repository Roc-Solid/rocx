## What the docs site's pages show of the repository's own files (`rocx site prepare`): the
## examples (site/examples, each beside the Roc rocx wrote for it), parts of the site, the packages,
## the platform's tests and the example apps, picked by name, by lines or by the start of each line
## (`specs`); the markup rocx refuses, in its own words; and the compiler's report on a real mistake,
## pointed into the .rocx file by `rocx check`. Written as site/Generated/Sources.roc.
import pf.Cmd
import pf.Env
import Fs
import Routes
import Text
import Transpile
import Value

SiteSources := [].{
	Source : { name : Str, file : Str, rocx : Str, roc : Str, first : U64, call : Str }

	## Which lines a `Lines` or an `Excerpt` keeps.
	Pattern : [ShoutApi, ShoutHandlers, GuardApi, FlagStoreApi, InboxExpects, GetDefinition, EchoDefinition, HomeSignals, SignalsAnswer, AppHeader]

	## One part a page shows, from a file under the repository (each a name, then the file):
	## - `Whole`: the file as it is;
	## - `Lines`: the lines a pattern keeps, as they are there (a definition, say);
	## - `Excerpt`: those lines, each without its indentation, "…" where lines were left out;
	## - `Header`: an app's header with only the entries named, "…" where others were;
	## - `Pick`: lines as they are there, each the next that starts with one of these (its
	##   indentation aside), "…" where lines were left out; `Picks`: groups of those, each dedented on
	##   its own, a blank line between them;
	## - `Defined`: definitions by name, each with its `##` comment and its annotation;
	## - `First`: the first lines, "…" after them;
	## - `Both`: the lines a pattern keeps in one file, then in another;
	## - `RouteTree`, `RouteList`, `FixturePaths`: this site's routes, `rocx routes site`, and the Paths
	##   rocx writes for the e2e test's routes.
	Spec : [
		Whole(Str, Str),
		Lines(Str, Str, Pattern),
		Excerpt(Str, Str, Pattern),
		Header(Str, Str, List(Str)),
		Pick(Str, Str, List(Str)),
		Picks(Str, Str, List(List(Str))),
		Defined(Str, Str, List(Str)),
		First(Str, Str, U64),
		Both(Str, Str, Pattern, Str, Pattern),
		RouteTree,
		RouteList,
		FixturePaths,
	]

	## What the pages show, in order (after the examples).
	specs : List(Spec)
	specs = [
		Whole("demo_counter", "site/Demos/Counter.rocx"),
		Whole("syntax_tour", "site/Demos/SyntaxTour.rocx"),
		Defined("platform_query", "examples/tasks/Store.roc", ["list!"]),
		Whole("start_page", "examples/hello/routes/+page.rocx"),
		Whole("start_server", "examples/hello/routes/hello/+server.roc"),
		Whole("ui_callout", "site/Ui/Callout.rocx"),
		RouteTree,
		First("route_page", "site/routes/showcase/+page.rocx", 23),
		First("route_page_generated", "site/Generated/ShowcasePage.roc", 23),
		Pick("route_layout", "site/routes/+layout.rocx", ["import pf.Html", "import pf.Router", "import pf.Store", "import ../Facts", "import ../Ui/Nav", "import ../Generated/Paths", "## The document around", "## this part's pages", "## page's (its title", "## the facts the build", "## site's design system", "## part of it a selection", "## part changes", "## the bar, the pager", "view! = |{ meta, children, .. }| {", "facts = Facts.facts!({})", "at = Store.of(", "# The front page is", "landing! = "]),
		Pick("route_routes", "site/Generated/Routes.roc", ["Routes := [].{", "respond! = |request, context| {", "segments = ", "method = ", "wants_html = ", "if (Endpoint.channel_asked(request) != \"\")", "Routes.channel!(segments, request, context)", "} else if (segments == [\"api\", \"facts\"])", "params = {}", "if (method == \"GET\")", "Endpoint.respond!(Handlers.get_api_facts", "} else {", "Endpoint.not_allowed", "}", "} else if (segments == [\"api\", \"shout\"])", "params = {}", "if (method == \"POST\")", "Endpoint.respond!(Handlers.post_api_shout", "} else {", "Endpoint.not_allowed", "}", "} else if (segments == [\"calls\"])", "if (method == \"GET\")", "Routes.page(200)", "} else {", "Endpoint.not_allowed", "}", "} else {", "if (wants_html)", "Routes.page(404)", "} else {", "Routes.text(404,", "}", "}", "}"]),
		Pick("route_main", "site/main.roc", ["import audio.AudioPlayer", "import Generated/App", "import Middlewares", "", "# The count", "# The calls page", "import Demos/Count", "", "## Every request:", "## server was started with", "## jobs or schedules; its one plugin", "## showcase's sounds.", "program = App.program({", "init!:", "middleware:", "openapi:", "plugins:", "})"]),
		RouteList,
		Pick("route_members", "site/Generated/Routes.roc", ["} else if (segments == [\"members\"])", "params = {}", "if (method == \"GET\" and wants_html)", "Middleware.run!(MembersServer.middleware", "} else if (method == \"GET\")", "Middleware.run!(MembersServer.middleware", "} else {", "Endpoint.not_allowed", "}"]),
		Pick("middleware_type", "web/platform/Middleware.roc", ["Middleware(given, handed) ::", "## A middleware, from what it does.", "make :", "## `first`, then `second`", "then :", "## A request that would change", "## an action) sent by", "## can make a browser", "## (`Origin`).", "same_origin :", "## Every answer with these headers too.", "headers :"]),
		Whole("site_middlewares", "site/Middlewares.roc"),
		Pick("members_page", "site/routes/members/+page.rocx", ["import pf.Html", "import pf.Endpoint", "import ../../Generated/Api", "import ../../Generated/Paths", "", "## Members only", "## that names no middleware", "## Who the member is", "## middleware, which read", "## the page, and the page", "member! :", "member! =", "", "view! = |_| {", "member = member!({})", "<>", "<PageHero", "eyebrow=\"Members\"", "title={\"Welcome, \${member}\"}"]),
		Whole("members_server", "site/routes/members/+server.roc"),
		Whole("members_join_server", "site/routes/members/join/+server.roc"),
		Pick("openapi_api", "site/Generated/Api.roc", ["## The OpenAPI document of these endpoints", "## each path and its methods", "## sent and answers", "## could be a tag", "openapi : Str", "openapi = {", "tags = [", "\"", "]", "OpenApi.document(", "OpenApi.path(\"/api/shout/{word}\"", "OpenApi.operation(\"get\"", "]),", "])", "}"]),
		Pick("openapi_format", "web/platform/OpenApi.roc", ["## The schema of what an endpoint is sent", "body : Endpoint(", "where [arg.parser_for", "body = |_, tags| {", "Sent : arg", "described(Sent.parser_for(", "}", "## A format that reads nothing", "## as `Json` writes that shape", "Schema := [Default].{", "parse_str : Schema", "parse_str = ", "parse_u64 : Schema", "parse_u64 = "]),
		Whole("endpoint_shout", "site/routes/api/shout/+server.roc"),
		Whole("endpoint_shout_word", "site/routes/api/shout/[word]/+server.roc"),
		Whole("endpoint_count", "site/routes/api/count/[to]/+server.roc"),
		Pick("demo_count_update", "site/Demos/Count.rocx", ["start! = || {", "set_heard!([])", "set_state!(Listening)", "Endpoint.listen!(", "Api.events_api_count_to(", "Call.listen!,", "|event|", "match event {", "Event(counted) =>", "Ended =>", "Failed(problem) =>", "}", ")", "}"]),
		Lines("endpoint_api", "site/Generated/Api.roc", ShoutApi),
		Lines("endpoint_handlers", "site/Generated/Handlers.roc", ShoutHandlers),
		Whole("demo_shout", "site/Demos/Shout.rocx"),
		Whole("demo_count", "site/Demos/Count.rocx"),
		Pick("route_nav", "site/Ui/Nav.roc", ["import ../Generated/Paths", "Page : {", "Group : {", "Section : {", "platform_docs : Section", "platform_docs = {", "name: \"Platform\",", "home: Paths.platform_,", "groups: [", "{", "name: \"Overview\",", "pages: [", "{ path: Paths.platform_,", "{ path: Paths.platform_server", "],", "},", "{", "name: \"State\",", "pages: [", "{ path: Paths.platform_database", "{ path: Paths.platform_actors", "{ path: Paths.platform_kv", "],", "},"]),
		Whole("route_error", "site/routes/+error.rocx"),
		Whole("route_fixture_page", "test/e2e/routes/routes/blog/[slug]/+page.rocx"),
		FixturePaths,
		Pick("home_update", "site/Demos/Counter.rocx", ["view! = |{ start_value }| {", "(count!, set_count!) = create_signal!(start_value)", "<div class=\"counter\"", "<button type=\"button\" on:click={|| set_count!(count!() - 1)}", "<output>", "<button type=\"button\" on:click={|| set_count!(count!() + 1)}", "</div>", "}"]),
		Excerpt("home_signals", "site/Demos/Echo.rocx", HomeSignals),
		Whole("demo_todos", "site/Demos/Todos.rocx"),
		Whole("demo_escape_lab", "site/Demos/EscapeLab.rocx"),
		Whole("demo_snake", "site/Demos/Snake.rocx"),
		Whole("demo_birds", "site/Demos/Birds.rocx"),
		Whole("demo_timers", "site/Demos/Timers.rocx"),
		Whole("demo_clock", "site/Demos/Clock.rocx"),
		Picks("charts_use", "site/Demos/BarDemo.rocx", [["import charts.BarChart", "import charts.Format"], ["{<BarChart data!="]]),
		Picks("charts_use_line", "site/Demos/LineDemo.rocx", [["import charts.Format", "import charts.LineChart"], ["{<LineChart data!="]]),
		Picks("charts_use_donut", "site/Demos/DonutDemo.rocx", [["import charts.DonutChart", "import charts.Format"], ["{<DonutChart data!="]]),
		Picks("charts_use_stacked", "site/Demos/StackDemo.rocx", [["import charts.Format", "import charts.StackedBarChart"], ["{<StackedBarChart data!="]]),
		Picks("charts_use_sparkline", "site/Demos/SparkDemo.rocx", [["import charts.Format", "import charts.Sparkline"], ["<Sparkline data!="]]),
		Picks("charts_use_heatmap", "site/Demos/HeatDemo.rocx", [["import charts.Format", "import charts.Heatmap"], ["<Heatmap data!="]]),
		Picks("virtual_use", "site/Demos/RowsDemo.rocx", [["import virtual.Rows", "import virtual.VirtualList"], ["<VirtualList count=", "{|row|", "</VirtualList>"]]),
		Picks("qr_use", "site/Demos/QrDemo.rocx", [["import qr.Qr", "import qr.QrCode"], ["<QrCode text="]]),
		Picks("charts_use_scatter", "site/Demos/ScatterDemo.rocx", [["import charts.Format", "import charts.ScatterChart"], ["<ScatterChart", "data!=", "label=", "format_x=", "format_y=", "/>"]]),
		Whole("demo_shuffle", "site/Demos/Shuffle.rocx"),
		Pick("charts_look", "site/Demos/Shuffle.rocx", ["/* A newspaper's: ink on cream, a serif, a dotted grid, no area, flat colours. */", "[data-look=\"paper\"] {", "background-color: #f4efe6;", "color: #1d1b18;", "font-family: Georgia, \"Iowan Old Style\", \"Times New Roman\", serif;", "--chart-font: Georgia, \"Iowan Old Style\", \"Times New Roman\", serif;", "--chart-color: #c8452c;", "--chart-active: #7f2716;", "--chart-grid: rgb(29 27 24 / 0.14);", "--chart-axis: #1d1b18;", "--chart-muted: #6b645a;", "--chart-surface: #f4efe6;", "--chart-radius: 0px;", "--chart-grid-dash: 1 3;", "--chart-line-width: 2;", "--chart-area: 0;", "--chart-dot: 5px;", "--chart-1: #c8452c;", "--chart-2: #1c63b8;", "--chart-3: #c98a0b;", "--chart-4: #8a4cb0;", "--chart-5: #2f8a43;", "--chart-heat-low: #f4efe6;", "--chart-heat-high: #1c63b8;", "--chart-up: #2f8a43;", "--chart-down: #c8452c;", "}"]),
		Whole("demo_bars", "site/Demos/BarDemo.rocx"),
		Whole("demo_line", "site/Demos/LineDemo.rocx"),
		Whole("demo_donut", "site/Demos/DonutDemo.rocx"),
		Whole("demo_scatter", "site/Demos/ScatterDemo.rocx"),
		Whole("demo_stacked", "site/Demos/StackDemo.rocx"),
		Whole("demo_sparkline", "site/Demos/SparkDemo.rocx"),
		Whole("demo_heatmap", "site/Demos/HeatDemo.rocx"),
		Whole("ui_heading", "site/Ui/Heading.rocx"),
		Whole("chart_bar", "packages/charts/components/BarChart.rocx"),
		Whole("chart_line", "packages/charts/components/LineChart.rocx"),
		Whole("chart_donut", "packages/charts/components/DonutChart.rocx"),
		Whole("chart_scatter", "packages/charts/components/ScatterChart.rocx"),
		Whole("chart_stacked", "packages/charts/components/StackedBarChart.rocx"),
		Whole("chart_sparkline", "packages/charts/components/Sparkline.rocx"),
		Whole("chart_heatmap", "packages/charts/components/Heatmap.rocx"),
		Header("admin_header", "site/main.roc", ["admin", "pf"]),
		Whole("admin_route", "site/Demos/AdminRoute.rocx"),
		Whole("admin_preview", "site/Demos/AdminPreview.rocx"),
		Defined("admin_ident", "packages/admin/Sql.roc", ["ident", "qualified", "contains"]),
		Defined("forms_schema", "site/Demos/FormsSignup.rocx", ["Passwords", "Account", "passwords", "form"]),
		Defined("forms_endpoint", "site/Demos/FormsSignup.rocx", ["post!"]),
		Defined("forms_demo", "site/Demos/FormsDemo.rocx", ["view!", "labels"]),
		Whole("forms_demo_file", "site/Demos/FormsDemo.rocx"),
		Whole("forms_live_form", "packages/forms/components/LiveForm.rocx"),
		Whole("forms_text_field", "packages/forms/components/TextField.rocx"),
		Whole("guard_middlewares", "packages/guard/example/Middlewares.roc"),
		Whole("guard_route", "packages/guard/example/routes/login/+server.roc"),
		Picks("guard_limits", "site/Demos/GuardLimits.rocx", [["## A login form's limit", "login : RateLimit", "login = "], ["## The same 5 a minute", "strict : RateLimit", "strict = "], ["## What each request is answered", "answers : ", "answers = ", "var $state", "var $said", "for second in seconds {", "{ decision, state } = ", "$state = state", "$said = ", "}", "$said", "}"]]),
		Whole("guard_playground", "site/Demos/GuardPlayground.rocx"),
		Picks("guard_flag", "site/Demos/GuardFlags.rocx", [["import guard.Flag", "import guard.Flags"], ["## On for ada, for anyone in staff", "## development, on for everyone.", "new_checkout : Flag", "new_checkout = ", ".in_env("]]),
		Whole("guard_overrides", "packages/guard/example/routes/admin/flags/+server.roc"),
		Whole("guard_visitor", "packages/guard/example/Visitor.rocx"),
		Whole("guard_layout", "packages/guard/example/routes/+layout.rocx"),
		Whole("guard_page", "packages/guard/example/routes/+page.rocx"),
		Whole("guard_checkout", "site/Demos/GuardCheckout.rocx"),
		Lines("guard_middleware_api", "packages/guard/Guard.roc", GuardApi),
		Lines("guard_flagstore_api", "packages/guard/FlagStore.roc", FlagStoreApi),
		Picks("intl_demo_use", "site/Demos/IntlDemo.rocx", [["import intl.Language", "import intl.Locales", "import intl.Catalog"], ["store = Language.store!(", "{ intl!, .. } = store", "<LanguageContext value={store}>", "<Language label=", "<div><dt><code>{\"number(", "</LanguageContext>"]]),
		Whole("intl_demo", "site/Demos/IntlDemo.rocx"),
		Defined("intl_files", "site/Demos/IntlSamples.rocx", ["files_catalog", "files"]),
		Defined("intl_typos", "site/Demos/IntlSamples.rocx", ["typos"]),
		Whole("intl_i18n", "packages/intl/example/I18n.rocx"),
		Defined("intl_best", "packages/intl/Locale.roc", ["best", "wanted"]),
		Whole("intl_layout", "packages/intl/example/routes/+layout.rocx"),
		Whole("intl_basket", "packages/intl/example/Basket.rocx"),
		Whole("intl_endpoint", "packages/intl/example/routes/locale/+server.roc"),
		Whole("intl_language", "packages/intl/components/Language.rocx"),
		Whole("markdown_walk", "site/Demos/MarkdownFiles/walk.md"),
		Picks("markdown_use", "site/Demos/MarkdownDemo.rocx", [["import markdown.Markdown", "import \"MarkdownFiles/walk.md\""], ["view = |{}| <Markdown"]]),
		Pick("markdown_toc", "site/Demos/MarkdownToc.rocx", ["doc = Md.parse(guide)", "<div class=\"guide\">", "<nav aria-label=", "<p class=\"time\">", "<ul>", "</nav>", "<Markdown doc={doc} />", "</div>"]),
		Whole("markdown_hooks_sample", "site/Demos/MarkdownFiles/hooks.md"),
		Pick("markdown_hooks", "site/Demos/MarkdownHooks.rocx", ["<Markdown", "source={sample}", "heading=", "code=", "link=", "/>"]),
		Whole("markdown_unsafe", "site/Demos/MarkdownFiles/unsafe.md"),
		Picks("markdown_safety", "site/Demos/MarkdownSafety.rocx", [["<Markdown source={unsafe} />"], ["<Markdown source={unsafe} raw={Drop} />"]]),
		Whole("markdown_heron", "site/Demos/MarkdownFiles/posts/heron.md"),
		Picks("markdown_posts", "site/Demos/MarkdownPosts.rocx", [["import markdown.Collection", "import markdown.Md", "import \"MarkdownFiles/posts/heron.md\"", "import \"MarkdownFiles/posts/winter.md\""], ["Post := {", "parser_for : _", "}"], ["all : List(", "all =", "match Collection.load(", "Ok(entries) => entries", "Err(failed) => crash", "}"]]),
		Whole("markdown_component", "packages/markdown/components/Markdown.rocx"),
		Whole("demo_markdown_demo", "site/Demos/MarkdownDemo.rocx"),
		Whole("demo_markdown_toc", "site/Demos/MarkdownToc.rocx"),
		Whole("demo_markdown_hooks", "site/Demos/MarkdownHooks.rocx"),
		Whole("demo_markdown_safety", "site/Demos/MarkdownSafety.rocx"),
		Whole("demo_markdown_posts", "site/Demos/MarkdownPosts.rocx"),
		Picks("mcp_server", "site/Demos/McpTemperatures.rocx", [["import mcp.Mcp", "import mcp.Prompt", "import mcp.Resource", "import mcp.Template", "import mcp.Tool"], ["server : Mcp.Server({})", "server = {", "name:", "version:", "title:", "instructions:", "tools: [", "Tool.typed(", "],", "resources:", "templates:", "prompts:", "}"], ["convert! :", "convert! =", "if celsius", "Err(", "} else {", "Ok(", "}"]]),
		Pick("mcp_test", "site/Demos/McpTemperatures.rocx", ["## What MCP takes", "expect Mcp.problems("]),
		Whole("mcp_http_sketch", "site/snippets/mcp-http.txt"),
		Whole("mcp_demo", "site/Demos/McpTemperatures.rocx"),
		Whole("mcp_http", "packages/mcp/server/McpHttp.roc"),
		Picks("presence_use", "site/Demos/PresenceDemo.rocx", [["import presence.AvatarStack", "import presence.Cursors", "import presence.LiveCursors", "import presence.TypingIndicator", "import presence.Presence", "import presence.Room", "import presence.Wire"], ["(members!, set_members!) = create_signal!(", "typing = Presence.create_typing!(", "cursors = Presence.create_cursors!("], ["<AvatarStack faces!="], ["<LiveCursors cursors!=", "<div class=\"note\"", "<p class=\"note-title\">", "<p class=\"line\">", "<p class=\"line short\">", "<p class=\"line\">", "<p class=\"line shorter\">", "</div>", "</LiveCursors>"], ["<TypingIndicator names!="]]),
		Pick("presence_stores", "site/Demos/PresenceDemo.rocx", ["did! = |step| {", "set_members!(", "set_seed!(", "if (!step.typed", "if !step.left", "(typing.stopped!)(", "(cursors.gone!)(", "}", "var $after", "for move in step.moves {", "_ = set_timeout!(", "$after = $after + 150", "}", "}", "act! = |action| "]),
		Whole("presence_route", "examples/board/routes/b/[board]/presence/+server.roc"),
		Pick("presence_join", "examples/board/routes/b/[board]/+page.rocx", ["# Who is here (packages/presence)", "# own), and the card", "# the tab is hidden", "here = Presence.join!(", "create_effect!(|| open!()", "<Document on:visibilitychange.visible="]),
		Picks("presence_grace", "packages/presence/Room.roc", [["Meta : { name : Str, status : Str }"], ["ann : Meta", "ann = "], ["start : Room(Meta)", "start = Room.empty("], ["# Leaving with grace", "expect {", "(room, _) = start.join(", "(left, changes) = room.leave(", "(early, before) = left.sweep(", "(_, after) = early.sweep(", "changes == []", "}"]]),
		Whole("presence_demo", "site/Demos/PresenceDemo.rocx"),
		Whole("presence_avatar_stack", "packages/presence/components/AvatarStack.rocx"),
		Whole("presence_typing_indicator", "packages/presence/components/TypingIndicator.rocx"),
		Whole("presence_live_cursors", "packages/presence/components/LiveCursors.rocx"),
		Whole("presence_stores_file", "packages/presence/components/Presence.rocx"),
		Whole("presence_server", "packages/presence/PresenceServer.roc"),
		Whole("auth_example_main", "packages/auth/example/main.roc"),
		Whole("auth_example_accounts", "packages/auth/example/Accounts.roc"),
		Whole("auth_example_middlewares", "packages/auth/example/Middlewares.roc"),
		Whole("auth_example_sign_in", "packages/auth/example/routes/sign-in/+server.roc"),
		Whole("auth_example_link", "packages/auth/example/routes/sign-in/link/+server.roc"),
		Whole("auth_example_link_page", "packages/auth/example/routes/sign-in/link/+page.rocx"),
		Whole("stripe_example_main", "packages/stripe/example/main.roc"),
		Whole("stripe_example_checkout", "packages/stripe/example/routes/billing/checkout/+server.roc"),
		Whole("stripe_example_done", "packages/stripe/example/routes/billing/done/+server.roc"),
		Whole("stripe_example_portal", "packages/stripe/example/routes/billing/portal/+server.roc"),
		Whole("stripe_example_billing", "packages/stripe/example/Billing.roc"),
		Defined("stripe_example_gates", "packages/stripe/example/Middlewares.roc", ["subscribers", "readers"]),
		Whole("push_example_main", "packages/push/example/main.roc"),
		Whole("push_example_page", "packages/push/example/routes/+page.rocx"),
		Whole("push_example_announce", "packages/push/example/routes/push/announce/+server.roc"),
		Defined("push_send", "packages/push/Push.roc", ["notify!", "broadcast!"]),
		Whole("push_button", "packages/push/components/PushButton.rocx"),
		Whole("push_compose", "site/Demos/PushCompose.rocx"),
		Header("audio_header", "site/main.roc", ["audio", "pf"]),
		Pick("audio_install", "site/main.roc", ["import audio.AudioPlayer", "program = App.program({", "plugins: [AudioPlayer.plugin({})],", "})"]),
		Whole("audio_module", "packages/audio/Audio.roc"),
		Whole("audio_player", "packages/audio/static/audio.js"),
		Header("vibrate_header", "examples/pomodoro/main.roc", ["vibrate", "pf"]),
		Pick("vibrate_install", "examples/pomodoro/main.roc", ["import vibrate.Vibrator", "program = App.program({", "plugins: [AudioPlayer.plugin({}), Vibrator.plugin({})],", "})"]),
		Whole("vibrate_module", "packages/vibrate/Vibrate.roc"),
		Whole("vibrate_script", "packages/vibrate/static/vibrate.js"),
		Pick("vibrate_use", "examples/pomodoro/routes/+page.rocx", ["import vibrate.Vibrate", "ended! = || {", "Audio.play!(", "Vibrate.pattern!(", "}"]),
		First("testing_inbox", "site/Demos/TestingInbox.rocx", 24),
		Lines("testing_inbox_expects", "site/Demos/TestingInbox.rocx", InboxExpects),
		Whole("testing_answers", "site/Demos/TestingAnswers.rocx"),
		Picks("testing_node_setup", "packages/testing/test/app.test.mjs", [["before(async () => {", "if (skip) return;", "dir = writeFixture(", "const built = await buildForTests(", "if (!skipDb) db = await testDatabase();", "app = await startServer(", "for (const engine of [\"chromium\", \"gecko\"]) browsers[engine] = await launchBrowser({ engine });", "});"], ["after(async () => {", "for (const browser of Object.values(browsers)) await browser?.close();", "await app?.stop();", "await db?.drop();", "if (dir) rmSync(", "});"]]),
		Pick("testing_node_page", "packages/testing/test/app.test.mjs", ["test(\"a page, found in by role", "const person = app.client();", "const page = await person.get(\"/\");", "assert.equal(page.status, 200);", "const { getByRole, getByLabelText, getByTestId } = page.dom;", "assert.equal(getByRole(\"heading\"", "assert.ok(getByRole(\"region\"", "assert.equal(getByTestId(\"count\")", "assert.equal(getByRole(\"status\"", "assert.equal(getByLabelText(\"New note\")", "assert.deepEqual(page.dom.getAllByRole(\"button\")", "const missing = await person.get(\"/nowhere\");", "assert.equal(missing.status, 404);", "assert.equal(missing.dom.getByRole(\"alert\")", "});"]),
		Pick("testing_node_form", "packages/testing/test/app.test.mjs", ["test(\"a form posted without the runtime", "const person = app.client();", "await person.get(\"/\");", "const posted = await person.post(\"/notes\"", "assert.equal(posted.status, 303);", "assert.equal(posted.location, \"/\"", "assert.deepEqual(person.flash, {", "assert.equal((await posted.follow()).status, 200);", "assert.equal(person.flash, null", "const sent = await person.submit(\"/notes\"", "assert.deepEqual([sent.status, sent.json()]", "});", "test(\"an endpoint the page reads, an endpoint", "const person = app.client();", "assert.equal(await person.read(\"/notes\"), 3);", "const ticks = await person.events(\"/api/ticks\");", "assert.deepEqual((await ticks.take(4))", "[\"message\", '{\"tick\":1}'],", "[\"message\", '{\"tick\":2}'],", "[\"message\", '{\"tick\":3}'],", "[\"end\", \"\"],", "]);", "});"]),
		Pick("testing_node_mail", "packages/testing/test/app.test.mjs", ["test(\"the dev mailbox", "const before = (await app.mail()).length;", "assert.equal((await app.client().json(\"/api/mail\"", "const mail = await app.waitForMail(", "assert.equal(mail.from,", "assert.deepEqual(links(mail),", "assert.ok(app.logs().some(", "});"]),
		Picks("testing_node_jobs", "packages/testing/test/app.test.mjs", [["const person = app.client();", "assert.equal((await person.json(\"/api/welcome\"", "const ran = await db.settleJobs();", "assert.deepEqual(ran.map(", "const welcome = await app.waitForMail(", "assert.deepEqual(links(welcome)"], ["const id = await db.enqueue(\"welcome\"", "assert.deepEqual((await db.settleJobs())"], ["// One that fails is tried again later", "// with `later`", "const failing = await db.enqueue(\"welcome\"", "const first = await db.settleJobs();", "assert.deepEqual(first.map(", "assert.match(first[0].last_error", "const spent = await db.settleJobs({ later: true });", "assert.deepEqual(spent.map(", "assert.deepEqual((await db.jobs({ kind: \"welcome\" }))"]]),
		Pick("testing_node_browser", "packages/testing/test/app.test.mjs", ["for (const engine of [\"chromium\", \"gecko\"]) {", "test(`in \${engine}", "const browser = browsers[engine];", "if (!browser) return t.skip(", "const tab = await browser.open(", "try {", "assert.deepEqual(tab.errors, []);", "assert.deepEqual(tab.console, []);", "assert.ok((await tab.requested())", "await (await tab.getByRole(\"button\", { name: \"Add one\" })).click();", "const count = await tab.findByText(\"2\");", "assert.deepEqual([count.tag, count.name]", "const field = await tab.getByLabelText(\"New note\");", "await field.fill(\"first\");", "await field.fill(\"second\");", "assert.equal(await field.value(), \"second\");", "assert.equal((await tab.findByText(\"3 notes\")).tag", "await assert.rejects(tab.findByRole(\"button\", { name: \"Delete\" }", "} finally {", "await tab.close();", "}", "const story = await browser.open(", "try {", "assert.equal((await story.getByRole(\"status\"", "await (await story.getByRole(\"button\"", "await story.findByText(\"11\");", "assert.deepEqual(story.errors, []);", "} finally {", "await story.close();", "}", "});", "}"]),
		Whole("demo_shelf", "site/Demos/Shelf.rocx"),
		Whole("demo_bag", "site/Demos/Bag.rocx"),
		Whole("shared", "site/Demos/Bag.rocx"),
		Whole("demo_echo", "site/Demos/Echo.rocx"),
		Both("way_endpoint", "site/routes/api/echo/[message]/+server.roc", GetDefinition, "site/Demos/Echo.rocx", EchoDefinition),
		Pick("platform_program", "server/test/app/main.roc", ["program = {", "init!:", "respond!,", "# The app's schema", "migrations: [", "# The actors' methods", "actors: [", "# The plugins", "# runs the rest.", "plugins:", "routes:", "}"]),
		Pick("email_plugin", "server/test/app/main.roc", ["# Email (packages/email)", "Email.plugin({}),"]),
		Pick("posthog_program", "packages/posthog/example/main.roc", ["program = App.program({", "init!:", "middleware:", "plugins:", "})"]),
		Pick("posthog_capture", "packages/posthog/example/routes/refund/+server.roc", ["get! = |_input| {", "PostHog.capture!(", "Ok(", "}"]),
		Pick("jobs_plugin", "test/e2e/app/main.roc", ["import jobs.Cron", "import jobs.Job", "import admin.JobsPage", "import Generated/App", "", "program = App.program({", "init!:", "middleware:", "# The jobs plugin", "# the jobs page", "plugins: [", "Job.plugin(", "JobsPage.plugin(", "],", "})"]),
		Pick("platform_site_program", "site/main.roc", ["program = App.program({", "init!:", "middleware:", "openapi:", "plugins:", "})"]),
		Pick("platform_notes", "server/test/app/main.roc", ["(\"GET\", \"/notes\") => {", "found : Try(", "found = Db.all!(", "match found {", "Ok(notes) =>", "Err(DbErr(why))", "Err(BadRow(why))", "}", "}"]),
		Pick("platform_insert", "server/test/app/main.roc", ["(\"POST\", \"/notes\") =>", "match Db.run!(", "Ok(count) =>", "Err(DbErr(why))", "}"]),
		Pick("platform_transaction", "server/test/app/main.roc", ["(\"POST\", \"/jobs/commit\") => {", "# One body", "# any error", "done = Db.transaction!(", "|{}| {", "_ = Db.run!(", "Job.enqueue!(", "Ok(\"queued\")", "},", ")", "match done {", "Ok(said) =>", "Err(DbErr(why))", "Err(JobErr(why))", "}", "}"]),
		Whole("platform_migration", "server/test/app/migrations/0001_tables.sql"),
		Pick("platform_migrations", "server/test/app/main.roc", ["import \"migrations/0001_tables.sql\" as tables : Str", "import \"migrations/0002_note_index.sql\"", "program = {", "# The app's schema", "migrations: ["]),
		Pick("platform_rocpg", "server/examples/roc-pg/main.roc", ["planets! = |url| {", "db : Client.Client", "db = Client.connect_url!", "_ = db.execute!", "found : List(", "found = db.query!", "db.close!()", "Ok(Str.join_with", "}"]),
		Pick("platform_job", "server/test/app/main.roc", ["## Writes what it was told to the job log.", "note_job : Job.Kind", "note_job = Job.define(", "\"note\",", "|_context, { run, said }|", "match Db.run!(", "Ok(_) => Ok({})", "Err(DbErr(why)) => Err(why)", "},", ")"]),
		Pick("platform_enqueue", "server/test/app/main.roc", ["(\"POST\", \"/jobs/note\") =>", "match Job.enqueue!(", "Ok({}) =>", "Err(JobErr(why))", "}", "(\"POST\", \"/jobs/later\") =>", "match Job.enqueue!("]),
		Pick("platform_mail_job", "server/test/app/main.roc", ["## Sends an email.", "mail_job : Job.Kind", "mail_job = Job.define(", "\"mail\",", "|_context, { to, run }|", "match Email.send!(", "Ok({}) => Ok({})", "Err(EmailErr(why)) => Err(why)", "},", ")"]),
		Pick("components_planner", "site/Demos/Planner.rocx", ["moves = use_submissions!(Api.post_api_planner_move({}))", "move! = use_action!(Api.post_api_planner_move({}))", "week = Api.get_api_planner({})", "plans! = create_memo!(", "|| {", "server = Endpoint.get!(week)", "moves.pending_inputs!().fold(server, PlannerDay.moved)", "},", ")", "{...moves.all!().keep_if(|sent| sent.error.is_ok()).map(|sent|", "<span>{Planner.why(sent.error)}</span>", "<button type=\"button\" on:click={|| moves.clear!(sent.id)}>Dismiss</button>"]),
		Pick("components_planner_day", "site/Demos/PlannerDay.rocx", ["<section class=\"day\"", "{...here!().map(|plan|", "<li class=\"plan\" key={plan.id}"]),
		Pick("components_form", "web/test/app/Form.rocx", ["view! = |{}| {", "submission = use_submission!(Form.join)", "<form class=\"join\"", "<input name=\"name\"", "<button type=\"submit\"", "</form>", "{match submission.result!()", "{match submission.error!()", "<button class=\"clear\""]),
		Whole("routes_local", "test/e2e/app/routes/local/+page.rocx"),
		Defined("platform_forecast", "server/test/app/Samples.roc", ["forecast!", "order!"]),
		Defined("platform_nested_transaction", "server/test/app/Samples.roc", ["award!", "place_order!"]),
		Defined("platform_preview", "server/test/app/Samples.roc", ["preview!"]),
		Defined("platform_lines", "server/test/app/Samples.roc", ["lines!"]),
		Defined("platform_partner", "server/test/app/Samples.roc", ["partner!"]),
		Defined("platform_settings", "server/test/app/Samples.roc", ["origin!", "signing_key!", "dev_sign_in!"]),
		Defined("platform_tokens", "server/test/app/Samples.roc", ["token!", "digest"]),
		Defined("platform_links", "server/test/app/Samples.roc", ["signed_link!", "link_member!", "link_key!", "app_secret!"]),
		Defined("platform_sealed", "server/test/app/Samples.roc", ["seal!", "unseal!", "sealing_key!"]),
		Defined("platform_es256", "server/test/app/Samples.roc", ["es256_token!"]),
		Defined("platform_files", "server/test/app/Samples.roc", ["files!"]),
		Defined("platform_avatar", "server/test/app/Samples.roc", ["save_avatar!", "avatar_size!", "take_avatar!"]),
		Defined("platform_upload_link", "server/test/app/Samples.roc", ["upload_link!"]),
		Defined("platform_parts", "server/test/app/Samples.roc", ["save_in_parts!"]),
		Defined("platform_serve", "server/test/app/Samples.roc", ["serve_video!", "serve_whole!"]),
		Defined("platform_digest", "server/test/app/Samples.roc", ["upload_digest"]),
		Defined("platform_cdn", "server/test/app/Samples.roc", ["from_cdn"]),
		Defined("platform_cookies", "server/test/app/Samples.roc", ["signed_in", "reviewing", "signed_out"]),
		Defined("platform_kv_limit", "server/test/app/Samples.roc", ["may_try!"]),
		Defined("platform_kv_once", "server/test/app/Samples.roc", ["begin_sign_in!", "finish_sign_in!"]),
		Defined("platform_job_options", "server/test/app/Samples.roc", ["reminder", "remind_tomorrow!", "forget_reminder!", "remind_sooner!"]),
		Defined("platform_job_list", "server/test/app/Samples.roc", ["failed_reminders!"]),
		Pick("platform_jobs_page", "server/test/app/main.roc", ["# The jobs page (packages/admin)", "JobsPage.plugin("]),
		Defined("platform_admins_only", "server/test/app/main.roc", ["admins_only"]),
		Pick("platform_online", "server/test/app/main.roc", ["(\"GET\", \"/online\") =>", "# Who is here", "Server.events(", "Events.stream(", "|{ send!, .. }| {", "Live.join!(\"online\")", "var $open", "while $open {", "send!(Live.count!", "$open = Live.next!", "}", "Ok({})", "},", "),", ")"]),
		Pick("platform_shouts", "server/test/app/main.roc", ["(\"GET\", \"/shouts\") =>", "Server.events(", "Events.stream(", "|{ send!, .. }| {", "Live.listen!(\"shouts\")", "send!(\"listening\")?", "var $open", "while $open {", "match Live.next!(15_000) {", "Heard({ message, .. }) =>", "Quiet =>", "Gone => {", "$open = Bool.False", "}", "}", "}", "Ok({})", "},", "),", ")", "(\"POST\", \"/shout\") => {", "Live.publish!(\"shouts\", Server.text_of(request))"]),
		Pick("platform_counter", "server/test/app/main.roc", ["## A count, one per key, that outlives requests and restarts: a kind (a type with `name` and", "## `initial`) and its methods.", "Counter := [].{", "name = |{}| \"counter\"", "initial = |_key| { count: 0 }", "", "## The type of its methods: the kind, the app's context (`--context-file`'s text), the key, the", "## count; then each one's input and reply.", "Method(input, reply) : Actor.Method(Counter, Str, Str, { count : I64 }, input, reply)", "", "## Adds `input` to the count: the count after.", "add : Counter.Method(I64, I64)", "add = Actor.method(\"add\", |{ state, input, .. }| { state: { count: state.count + input }, reply: state.count + input })", "", "## The count.", "get : Counter.Method({}, I64)", "get = Actor.method(\"get\", |{ state, .. }| { state, reply: state.count })", "}"]),
		Pick("platform_ask", "server/test/app/main.roc", ["(\"POST\", path) if path.starts_with(\"/actors/count/\") => {", "by : I64", "by = I64.from_str(", "answered_actor(Counter.add.ask!("]),
		Pick("platform_tell", "server/test/app/main.roc", ["(\"POST\", \"/actors/tell\") => {", "Counter.add.tell!(run,", "text(200, \"told\")", "}"]),
		Pick("platform_ticker", "server/test/app/main.roc", ["## Counts its own ticks: `start` sets a timer for itself, and each tick sets the next", "## (`me.after!`) until `stop` cancels the one waiting (`Actor.cancel!`).", "Ticker := [].{", "name = |{}| \"ticker\"", "initial = |_key| { ticks: 0, timer: 0, on: Bool.False }", "", "Method(input, reply) : Actor.Method(Ticker, Str, Str, { ticks : I64, timer : U64, on : Bool }, input, reply)", "", "start : Ticker.Method(U64, I64)", "start = Actor.method(\"start\", |{ me, state, input, .. }| { state: { ticks: state.ticks, timer: me.after!(input, Ticker.tick({}), input), on: Bool.True }, reply: state.ticks })", "", "## A tick sets the next: a method that names itself, so a function of `{}`.", "tick : {} -> Ticker.Method(U64, I64)", "tick = |{}|", "Actor.method(", "\"tick\",", "|{ me, state, input, .. }|", "if (state.on) {", "{ state: { ticks: state.ticks + 1, timer: me.after!(input, Ticker.tick({}), input), on: Bool.True }, reply: state.ticks + 1 }", "} else {", "{ state, reply: state.ticks }", "},", ")", "", "stop : Ticker.Method({}, I64)", "stop = Actor.method(", "\"stop\",", "|{ state, .. }| {", "Actor.cancel!(state.timer)", "{ state: { ticks: state.ticks, timer: 0, on: Bool.False }, reply: state.ticks }", "},", ")", "", "ticks : Ticker.Method({}, I64)", "ticks = Actor.method(\"ticks\", |{ state, .. }| { state, reply: state.ticks })", "}"]),
		Whole("channel_lobby", "site/routes/platform/live/lobby/+server.roc"),
		Pick("demo_lobby", "site/Demos/Lobby.rocx", ["lobby = Api.channel_platform_live_lobby({})", "create_effect!(", "|| {},", "|{}|", "Endpoint.subscribe!(", "lobby,", "|event|", "match event {", "Resync =>", "Message(wave) =>", "Refused(_, why) =>", "Ended(why) =>", "},", "),", ")", "{...[\"👋\", \"🎉\", \"🙌\"].map(|hand|", "<button key={hand} type=\"button\" class=\"wave\""]),
		Pick("bag_reader", "site/Demos/Bag.rocx", ["## Who is reading", "## The server renders", "## again.", "reader! :", "reader! ="]),
		Whole("endpoint_reader", "site/routes/api/reader/+server.roc"),
		Whole("endpoint_echo", "site/routes/api/echo/[message]/+server.roc"),
		Pick("members_read", "site/routes/members/+page.rocx", ["member! : {} => Str", "member! = |{}| Endpoint.get!"]),
		Whole("endpoint_members", "site/routes/members/+server.roc"),
		Whole("test_session", "web/test/app/Profile.rocx"),
		Whole("signals_echo", "site/Demos/Echo.rocx"),
		Pick("calls_component", "site/Demos/Echo.rocx", ["echo! : Str => Str", "echo! = |message| Endpoint.get!", "messages : List(Str)", "messages = [", "view! : {} => Html", "view! = |{}| {", "(draft!, set_draft!)", "# A GET per message", "answers! = create_memo!", "said! = create_memo!", "<form class=\"echo\"", "{...messages.map(|message|", "<button", "key={message}", "type=\"button\"", "aria-pressed=", "on:click={|| set_draft!", ">", "{message}", "</button>", ")}", "<Errored fallback", "<output class=\"echo-answer failed\">", "{problem}", "</output>", "}>", "<Loading fallback", "<Answer said!", "</Loading>", "</Errored>", "</form>", "}"]),
		Whole("signals_tally", "site/Demos/Tally.rocx"),
		Pick("signals_store", "site/Demos/Picks.rocx", ["Store : {", "picks! :", "set_picks! :", "next! :", "set_next! :", "}", "picks_context : Context(Store)", "picks_context = create_context()", "store! : {} => Store", "store! = |{}| {", "(picks!, set_picks!)", "{ id: 1", "{ id: 2", "{ id: 3", "])", "(next!, set_next!)", "{ picks!: picks!", "}"]),
		Pick("signals_tally_use", "site/Demos/Tally.rocx", ["view! = |{}| {", "{ picks!, set_picks!, next!, set_next! } = use_context!"]),
		Whole("signals_profile", "web/test/app/Profile.rocx"),
		Pick("signals_glance", "web/test/app/Profile.rocx", ["view! = |{}| {", "# Made first", "user! = create_memo!", "posts! = create_memo!", "(count!, set_count!)", "<Errored fallback", "<p class=\"page-problem\">", "The page failed", "</p>", "}>", "<Loading fallback", "<Heading text!", "<button class=\"count\"", "Clicked", "</button>", "<section class=\"posts\">", "<Errored fallback", "<p class=\"problem\">", "No posts", "</p>", "}>", "<ul>", "{...posts!().map(|post|", ")}", "</ul>", "</Errored>", "</section>", "</Loading>", "</Errored>", "}"]),
		Pick("signals_rename", "web/test/app/Profile.rocx", ["rename! = || {", "_ = Api.rename!", "refresh!(user!)", "}"]),
		Whole("solid_friends", "site/snippets/solid-friends.tsx"),
		Whole("echo_rendered", "site/snippets/echo-server.html"),
		Whole("signals_picks", "site/Demos/Picks.rocx"),
		Pick("signals_picks_control", "site/Demos/Picks.rocx", ["{ picks!, set_picks!, next!, set_next! } = use_context!(picks_context)", "<div class=\"picks-lists\">", "{# A row per id", "<ol class=\"keyed\"", "{...picks!().map_with_index(|pick, index| <li key={pick.id}>", "{if (picks!().is_empty())", "</ol>", "{# A row per place", "<ol class=\"unkeyed\"", "{...picks!().map_with_index(|pick, index| <li key={index}>", "</ol>", "</div>", "<div class=\"picks-shows\">", "{if picks!().len() > 3 {", "<p class=\"many\">", "} else {", "<p class=\"few\">", "}}", "{match picks!().first() {", "Ok(first) =>", "Err(_) =>", "}}", "</div>"]),
		Excerpt("signals_answer", "site/Demos/Echo.rocx", SignalsAnswer),
		Whole("test_app", "web/test/app/main.roc"),
		Pick("components_demos", "site/routes/components/+page.rocx", ["<PicksContext value=", "<Demo inspect=\"picks\"", "<div data-demo=\"picks\"", "</Demo>", "<Demo inspect=\"tally\"", "<div data-demo=\"tally\"", "</Demo>", "</PicksContext>", "<BagContext value=", "<Demo inspect=\"bag\"", "<div data-demo=\"shelf\"", "<div data-demo=\"bag\"", "</Demo>", "</BagContext>"]),
		Whole("client_app", "site/build/client/main.roc"),
		Whole("platform_header", "web/platform/main.roc"),
		Pick("platform_requires", "web/platform/main.roc", ["platform \"\"", "requires {", "main! :", "}"]),
	]

	## Markup rocx refuses: the pages show why, in its words.
	refused : List(Str)
	refused = [
		"<a onclick=\"go()\">Go</a>",
		"<b on:click=\"go()\">Go</b>",
		"<p style={styles}>Hi</p>",
		"<a title=hi>Hi</a>",
		"<br>",
		"<ul><li>One</li></ol>",
		"<p>1 < 2</p>",
		"<p>&bogus;</p>",
		"<DIV>Hi</DIV>",
		"<input checked?=\"yes\" />",
		"<p style:font_size={c}>Hi</p>",
		"<p on:click.files={f}>Hi</p>",
	]

	## Whether `line` is one a pattern keeps.
	matches : Pattern, Str -> Bool
	matches = |pattern, line|
		match pattern {
			# /^\t(post_api_shout|get_api_shout_word) [:=] /
			ShoutApi => ["\tpost_api_shout : ", "\tpost_api_shout = ", "\tget_api_shout_word : ", "\tget_api_shout_word = "].any(|start| line.starts_with(start))
			# /^\t(post_api_shout|get_api_shout_word) = /
			ShoutHandlers => line.starts_with("\tpost_api_shout = ") or line.starts_with("\tget_api_shout_word = ")
			# /^\t[A-Za-z_]+(\(c\))? : /
			GuardApi => {
				bytes = line.to_utf8()
				end = Text.run_end(bytes, 1, |b| Text.is_letter(b) or b == '_')
				Text.at(bytes, 0) == '\t' and end > 1 and (Text.rest(bytes, end).starts_with(" : ") or Text.rest(bytes, end).starts_with("(c) : "))
			}
			# /^\t[a-z_]+! : /
			FlagStoreApi => {
				bytes = line.to_utf8()
				end = Text.run_end(bytes, 1, |b| Text.is_lower(b) or b == '_')
				Text.at(bytes, 0) == '\t' and end > 1 and Text.rest(bytes, end).starts_with("! : ")
			}
			# /^(## Ada's inbox|inbox |expect )/
			InboxExpects => line.starts_with("## Ada's inbox") or line.starts_with("inbox ") or line.starts_with("expect ")
			# /^get! = /
			GetDefinition => line.starts_with("get! = ")
			# /^\techo! = /
			EchoDefinition => line.starts_with("\techo! = ")
			# /^\techo! = |^\t\tsaid! =|<Answer said!/
			HomeSignals => line.starts_with("\techo! = ") or line.starts_with("\t\tsaid! =") or line.contains("<Answer said!")
			# /^\t\t\(draft!|^\t\tsaid! =|<Answer said|^answer/
			SignalsAnswer => line.starts_with("\t\t(draft!") or line.starts_with("\t\tsaid! =") or line.contains("<Answer said") or line.starts_with("answer")
			# /^app \[program\] \{/
			AppHeader => line.starts_with("app [program] {")
		}

	## The pattern as the page's build names it, in a problem.
	pattern_name : Pattern -> Str
	pattern_name = |pattern|
		match pattern {
			ShoutApi => "the shout's API"
			ShoutHandlers => "the shout's handlers"
			GuardApi => "Guard's API"
			FlagStoreApi => "FlagStore's API"
			InboxExpects => "the inbox's expects"
			GetDefinition => "get! ="
			EchoDefinition => "echo! ="
			HomeSignals => "the echo's signals"
			SignalsAnswer => "the answer's signals"
			AppHeader => "app [program] {"
		}

	## How many tabs a line starts with.
	tabs : Str -> U64
	tabs = |line| Text.run_end(line.to_utf8(), 0, |b| b == '\t')

	## Lines without the indentation they all share.
	dedent : List(Str) -> Str
	dedent = |lines| {
		indents = lines.keep_if(|line| !Text.trim(line).is_empty()).map(SiteSources.tabs)
		common = indents.fold(if (indents.is_empty()) 0xFFFFFFFF else indents.first() ?? 0, |least, n| if (n < least) n else least)
		cut = |line| {
			bytes = line.to_utf8()
			Text.rest(bytes, if (bytes.len() < common) bytes.len() else common)
		}
		Str.join_with(lines.map(cut), "\n")
	}

	## `ExampleName` as `example_name`.
	snake : Str -> Str
	snake = |name| {
		bytes = name.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = Text.at(bytes, $i)
			if Text.is_upper(b) {
				$out = (if ($i > 0) $out.append('_') else $out).append(b + 32)
			} else {
				$out = $out.append(b)
			}
			$i = $i + 1
		}
		Str.from_utf8_lossy($out)
	}

	## The call a component's example makes (`/demo = \|\{\}\| view\((.*)\)$/m`): what is between
	## `view(` and the `)` its line ends with.
	view_call : Str -> Str
	view_call = |text| {
		marker = "demo = |{}| view("
		for line in Text.lines(text) {
			match line.split_first(marker) {
				Ok({ after, .. }) if after.ends_with(")") => return after.drop_suffix(")")
				_ => {}
			}
		}
		""
	}

	read! : Str, Str => Try(List(Str), [Problem(Str)])
	read! = |root, path|
		match Fs.read!(Fs.join([root, path])) {
			Ok(text) => Ok(Text.lines(text))
			Err(_) => Err(Problem("${path}: can't be read"))
		}

	## An example: the lines between `# example` and `# /example`, from both files, which match.
	example! : Str, Str => Try(Source, [Problem(Str)])
	example! = |root, file| {
		path = "site/examples/${file}"
		rocx = SiteSources.read!(root, path)?
		generated = SiteSources.read!(root, path.drop_suffix(".rocx").concat(".roc"))?
		start = rocx.find_first_index(|line| Text.trim(line) == "# example")
		end = rocx.find_first_index(|line| Text.trim(line) == "# /example")
		match (start, end) {
			(Ok(s), Ok(e)) if e >= s => {
				module_name = file.drop_suffix(".rocx")
				body = |lines| SiteSources.dedent(lines.sublist({ start: s + 1, len: e - (s + 1) }))
				Ok({ name: SiteSources.snake(module_name), file: "examples/${file}", rocx: body(rocx), roc: body(generated), first: s + 2, call: "${module_name}.view(${SiteSources.view_call(Str.join_with(rocx, "\n"))})" })
			}
			_ => Err(Problem("${file}: mark the example with # example and # /example"))
		}
	}

	shown : Str, Str, Str -> Source
	shown = |name, file, rocx| { name, file, rocx, roc: "", first: 1, call: "" }

	## A whole file, shown as it is.
	whole! : Str, Str, Str => Try(Source, [Problem(Str)])
	whole! = |root, name, path| {
		text = Str.join_with(SiteSources.read!(root, path)?, "\n")
		var $end = text.to_utf8().len()
		bytes = text.to_utf8()
		while $end > 0 and Text.at(bytes, $end - 1) == '\n' {
			$end = $end - 1
		}
		Ok(SiteSources.shown(name, path, Text.cut(bytes, 0, $end)))
	}

	## The lines of a file that `pattern` keeps, as they are there.
	lines! : Str, Str, Str, Pattern => Try(Source, [Problem(Str)])
	lines! = |root, name, path, pattern| {
		found = SiteSources.read!(root, path)?.keep_if(|line| SiteSources.matches(pattern, line))
		if found.is_empty() {
			return Err(Problem("${path}: nothing matches ${SiteSources.pattern_name(pattern)}"))
		}
		Ok(SiteSources.shown(name, path, SiteSources.dedent(found)))
	}

	## `text` split at each `, ` that a `name: ` follows (`/, (?=[a-z_]+: )/`).
	entries : Str -> List(Str)
	entries = |text| {
		bytes = text.to_utf8()
		var $parts = []
		var $from = 0
		var $i = 0
		while $i + 1 < bytes.len() {
			if Text.at(bytes, $i) == ',' and Text.at(bytes, $i + 1) == ' ' {
				end = Text.run_end(bytes, $i + 2, |b| Text.is_lower(b) or b == '_')
				if end > $i + 2 and Text.rest(bytes, end).starts_with(": ") {
					$parts = $parts.append(Text.cut(bytes, $from, $i))
					$from = $i + 2
				}
			}
			$i = $i + 1
		}
		$parts.append(Text.rest(bytes, $from))
	}

	## The app header of `path` (`app [program] { … }`) with only the entries named in `keep`, "…"
	## where others were left out: so a page can show the one package it is about, in the file that
	## names it.
	header! : Str, Str, Str, List(Str) => Try(Source, [Problem(Str)])
	header! = |root, name, path, keep| {
		line = SiteSources.lines!(root, name, path, AppHeader)?.rocx
		bytes = line.to_utf8()
		open = Text.index_of(bytes, "{ ".to_utf8(), 0) ?? bytes.len()
		inside = if (line.ends_with(" }") and open + 4 <= bytes.len()) Text.cut(bytes, open + 2, bytes.len() - 2) else ""
		listed = SiteSources.entries(inside)
		kept = listed.fold(
			[],
			|so_far, entry| {
				key = match entry.split_first(":") {
					Ok({ before, .. }) => before
					Err(_) => Str.from_utf8_lossy(entry.to_utf8().drop_last(1))
				}
				if keep.contains(key) {
					so_far.append(entry)
				} else {
					match so_far.last() {
						Ok("…") => so_far
						_ => so_far.append("…")
					}
				}
			},
		)
		missing = keep.keep_if(|wanted| !listed.any(|entry| entry.starts_with("${wanted}:")))
		if !missing.is_empty() {
			return Err(Problem("${path}: the header names no ${Str.join_with(missing, ", ")}"))
		}
		brace = Text.index_of_byte(bytes, '{', 0) ?? bytes.len()
		Ok(SiteSources.shown(name, path, "${Text.cut(bytes, 0, brace)}{ ${Str.join_with(kept, ", ")} }"))
	}

	## Lines of a file that `pattern` keeps, each without its indentation, "…" where lines were left out.
	excerpt! : Str, Str, Str, Pattern => Try(Source, [Problem(Str)])
	excerpt! = |root, name, path, pattern| {
		all = SiteSources.read!(root, path)?
		var $out = []
		var $last = 0
		var $any = Bool.False
		var $i = 0
		for line in all {
			if SiteSources.matches(pattern, line) {
				if $any and $i > $last + 1 {
					$out = $out.append("…")
				}
				$out = $out.append(Text.trim(line))
				$last = $i
				$any = Bool.True
			}
			$i = $i + 1
		}
		if $out.is_empty() {
			return Err(Problem("${path}: nothing matches ${SiteSources.pattern_name(pattern)}"))
		}
		Ok(SiteSources.shown(name, path, Str.join_with($out, "\n")))
	}

	## Lines of a file as they are there, indentation and all: each of `starts` is the next line that
	## starts with it (its indentation aside), in order; "…" stands where lines were left out.
	pick! : Str, Str, Str, List(Str) => Try(Source, [Problem(Str)])
	pick! = |root, name, path, starts| {
		all = SiteSources.read!(root, path)?
		var $kept = []
		var $at = 0
		for start in starts {
			found = match all.sublist({ start: $at, len: all.len() }).find_first_index(|line| Text.trim_start(line).starts_with(start)) {
				Ok(i) => $at + i
				Err(_) => return Err(Problem("${path}: no line after ${($at + 1).to_str()} starts with ${Value.json_string(start)}"))
			}
			line = all.get(found) ?? ""
			if !$kept.is_empty() and found > $at {
				$kept = $kept.append("${Str.from_utf8_lossy(line.to_utf8().take_first(SiteSources.tabs(line)))}…")
			}
			$kept = $kept.append(line)
			$at = found + 1
		}
		Ok(SiteSources.shown(name, path, SiteSources.dedent($kept)))
	}

	## Picks from one file (`pick!`'s), each dedented on its own, with a blank line between them.
	picks! : Str, Str, Str, List(List(Str)) => Try(Source, [Problem(Str)])
	picks! = |root, name, path, groups| {
		var $parts = []
		for starts in groups {
			$parts = $parts.append(SiteSources.pick!(root, name, path, starts)?.rocx)
		}
		Ok(SiteSources.shown(name, path, Str.join_with($parts, "\n\n")))
	}

	## Whether `line` annotates `wanted` (`/^\s*wanted\s*:(?!=)/`).
	annotates : Str, Str -> Bool
	annotates = |line, wanted| {
		rest = Text.trim_start(line)
		if !rest.starts_with(wanted) {
			return Bool.False
		}
		after = Text.trim_start(rest.drop_prefix(wanted))
		after.starts_with(":") and !after.starts_with(":=")
	}

	## Definitions of a file, whole, by name, each with its `##` comment and its annotation: from the
	## comment to the blank line after it (or the line that closes its block). A blank line between
	## them; each dedented.
	defined! : Str, Str, Str, List(Str) => Try(Source, [Problem(Str)])
	defined! = |root, name, path, names| {
		all = SiteSources.read!(root, path)?
		line_at = |i| all.get(i) ?? ""
		var $parts = []
		for wanted in names {
			at = match all.find_first_index(|line| SiteSources.annotates(line, wanted)) {
				Ok(i) => i
				Err(_) => return Err(Problem("${path}: no definition of ${wanted}"))
			}
			var $start = at
			while $start > 0 and Text.trim_start(line_at($start - 1)).starts_with("##") {
				$start = $start - 1
			}
			var $end = at
			while $end + 1 < all.len() and !Text.trim(line_at($end + 1)).is_empty() and !line_at($end + 1).starts_with("}") {
				$end = $end + 1
			}
			$parts = $parts.append(SiteSources.dedent(all.sublist({ start: $start, len: $end + 1 - $start })))
		}
		Ok(SiteSources.shown(name, path, Str.join_with($parts, "\n\n")))
	}

	## The first `count` lines of a file, as they are there, and "…" after them.
	first! : Str, Str, Str, U64 => Try(Source, [Problem(Str)])
	first! = |root, name, path, count| {
		all = SiteSources.read!(root, path)?
		more = if (all.len() > count) ["…"] else []
		Ok(SiteSources.shown(name, path, Str.join_with(all.take_first(count).concat(more), "\n")))
	}

	## This site's route files, each with the path it is or what it does.
	route_tree! : Str => Try(Source, [Problem(Str)])
	route_tree! = |root| {
		routes = Fs.join([root, "site", "routes"])
		files = Routes.find_route_files!(routes)
		table = Routes.route_table(files)?
		var $sources = []
		for file in files {
			$sources = $sources.append({ file, defs: Routes.definitions(Fs.read_or_empty!(Fs.join([routes, file]))) })
		}
		sources = $sources
		# A page's, as it runs (its own, or its +server.roc's: D-079); any other file's own.
		behind = |file|
			match table.pages.find_first(|page| page.file == file) {
				Ok(page) =>
					match Routes.page_guard(table, sources, page) {
						Some(guard) => ", behind ${guard.said}"
						None => ""
					}
				Err(_) =>
					match Routes.defs_of(sources, file).middleware {
						Some(middleware) if !middleware.is_empty() => ", behind ${middleware}"
						_ => ""
					}
			}
		paths = table.pages.map(|page| { file: page.file, path: page.path }).concat(table.servers.map(|server| { file: server.file, path: "${server.path}, its endpoints" }))
		depth = |file| file.split_on("/").len()
		sorted = files.sort_with(
			|a, b|
				if depth(a) < depth(b) {
					Before
				} else if depth(a) > depth(b) {
					After
				} else {
					Text.locale_order(a, b)
				},
		)
		width = sorted.fold(0, |widest, file| if (Text.length(file) > widest) Text.length(file) else widest) + 2
		role = |file|
			match file.split_on("/").last() ?? "" {
				"+layout.rocx" => "around every page"
				"+error.rocx" => "where no page is"
				_ => "undefined"
			}
		lines = sorted.map(
			|file| {
				what =
					match paths.keep_if(|each| each.file == file).last() {
						Ok(found) => found.path
						Err(_) => role(file)
					}
				"${Text.pad_end(file, width)}# ${what}${behind(file)}"
			},
		)
		Ok(SiteSources.shown("route_tree", "site/routes", Str.join_with(lines, "\n")))
	}

	## What `rocx routes site` prints.
	route_list! : Str => Try(Source, [Problem(Str)])
	route_list! = |root| {
		table = Routes.routes_table!(Fs.join([root, "site"]))?
		Ok(SiteSources.shown("route_list", "rocx routes site", "$ rocx routes site\n${table}"))
	}

	## What rocx writes for the routes of the e2e test's app (with a param): its Paths.
	fixture_paths! : Str => Try(Source, [Problem(Str)])
	fixture_paths! = |root| {
		table = Routes.route_table(Routes.find_route_files!(Fs.join([root, "test", "e2e", "routes", "routes"])))?
		kept = Text.lines(Routes.paths_module(table)).keep_if(|line| !line.starts_with("# rocx"))
		Ok(SiteSources.shown("route_fixture_paths", "Generated/Paths.roc", Text.trim(Str.join_with(kept, "\n"))))
	}

	## One part, from its spec.
	source! : Str, Spec => Try(Source, [Problem(Str)])
	source! = |root, spec|
		match spec {
			Whole(name, path) => SiteSources.whole!(root, name, path)
			Lines(name, path, pattern) => SiteSources.lines!(root, name, path, pattern)
			Excerpt(name, path, pattern) => SiteSources.excerpt!(root, name, path, pattern)
			Header(name, path, keep) => SiteSources.header!(root, name, path, keep)
			Pick(name, path, starts) => SiteSources.pick!(root, name, path, starts)
			Picks(name, path, groups) => SiteSources.picks!(root, name, path, groups)
			Defined(name, path, names) => SiteSources.defined!(root, name, path, names)
			First(name, path, count) => SiteSources.first!(root, name, path, count)
			Both(name, path, pattern, other, other_pattern) => {
				one = SiteSources.lines!(root, name, path, pattern)?
				two = SiteSources.lines!(root, name, other, other_pattern)?
				Ok({ ..one, rocx: "${one.rocx}\n\n${two.rocx}" })
			}
			RouteTree => SiteSources.route_tree!(root)
			RouteList => SiteSources.route_list!(root)
			FixturePaths => SiteSources.fixture_paths!(root)
		}

	## The markup rocx refuses, and why, in its own words (the column in the markup, not in `x = …`).
	refusals : {} -> Try(List({ source : Str, reason : Str, column : U64 }), [Problem(Str)])
	refusals = |{}| {
		var $found = []
		for markup in SiteSources.refused {
			match Transpile.transpile_module("x = ${markup}", "Page.rocx", Transpile.options_of(Object([]))) {
				Ok(_) => return Err(Problem("rocx accepted ${markup}"))
				Err(Rocx(e)) => {
					$found = $found.append({ source: markup, reason: e.reason, column: if (e.column > 4) e.column - 4 else 0 })
				}
				Err(Crash(message)) => return Err(Problem(message))
			}
		}
		Ok($found)
	}

	## A key for what the check's report is made from: FNV-1a, 64 bits, in hex.
	key_of : List(Str) -> Str
	key_of = |inputs| {
		start : U64
		start = 0xcbf29ce484222325
		prime : U64
		prime = 0x100000001b3
		hash = Str.join_with(inputs, "\u(0)").to_utf8().fold(start, |h, b| h.bitwise_xor(b.to_u64()).times_wrap(prime))
		Text.in_base(hash, 16)
	}

	## The compiler's report on a real mistake, pointed into the .rocx file by `rocx check`. It takes
	## a compiler run, so it is kept (site/build/check-report.json), and made again only when what
	## makes it changes. `rocx` is this program, `roc` the compiler.
	check_report! : Str, Str, Str => Try({ source : Str, report : Str }, [Problem(Str)])
	check_report! = |root, rocx, roc| {
		# The mistake: an attribute takes text, and `posts.len()` is a number (a hole shows either).
		source = Str.join_with(["import pf.Html", "", "Posts := [].{", "\tview : List(Str) -> Html", "\tview = |posts|", "\t\t<p class=\"count\" title={posts.len()}>", "\t\t\tYou have {posts.len()} posts", "\t\t</p>", "}", ""], "\n")
		read_root! = |path| Fs.read_or_empty!(Fs.join([root, path]))
		key = SiteSources.key_of([source, roc, read_root!("rocx-cli/Transpile.roc"), read_root!("rocx-cli/Remap.roc"), read_root!("rocx-cli/main.roc"), read_root!("web/platform/Html.roc")])
		kept = Fs.join([root, "site", "build", "check-report.json"])
		saved = Value.parse(Fs.read_or_empty!(kept)) ?? Null
		if Value.str(Value.field(saved, "key")) == key {
			return Ok({ source: Value.str(Value.field(saved, "source")), report: Value.str(Value.field(saved, "report")) })
		}
		dir = Fs.join([root, "site", "build", "check"])
		Fs.delete_all!(dir)
		Fs.make_dirs!(dir)
		# An app on the web platform, whose main! renders the posts: `roc check Posts.roc` checks it.
		web = Fs.relative(dir, Fs.join([root, "web", "platform", "main.roc"]))
		_ = Fs.write!(Fs.join([dir, "main.roc"]), "app [main!] { pf: platform ${Value.json_string(web)} }\n\nimport pf.Html\nimport Posts\n\nmain! : {} => Html\nmain! = |{}| Posts.view([])\n")
		_ = Fs.write!(Fs.join([dir, "Posts.rocx"]), source)
		built = match Cmd.new(rocx).args(["build", "."]).cwd(dir).merged!() {
			Ok(ran) => ran
			Err(CantStart(why)) => return Err(Problem(why))
		}
		if built.code != 0 {
			return Err(Problem("rocx build . failed:\n${built.output}"))
		}
		checked = match Cmd.new(rocx).args(["check", "--", roc, "check", "Posts.roc"]).cwd(dir).output!() {
			Ok(ran) => Text.trim(ran.stdout)
			Err(CantStart(why)) => return Err(Problem(why))
		}
		made = { source: Text.trim_end(Fs.read_or_empty!(Fs.join([dir, "Posts.rocx"]))), report: if (checked.is_empty()) "(the compiler said nothing)" else checked }
		_ = Fs.write!(kept, Value.encode(Object([{ key: "key", value: Text(key) }, { key: "source", value: Text(made.source) }, { key: "report", value: Text(made.report) }])))
		Ok(made)
	}

	## site/Generated/Sources.roc: the sources, refusals and report the pages show.
	module! : Str, Str, Str => Try(Str, [Problem(Str)])
	module! = |root, rocx, roc| {
		check = SiteSources.check_report!(root, rocx, roc)?
		var $sources = []
		for file in Fs.entries!(Fs.join([root, "site", "examples"])) {
			if file.ends_with(".rocx") {
				$sources = $sources.append(SiteSources.example!(root, file)?)
			}
		}
		for spec in SiteSources.specs {
			$sources = $sources.append(SiteSources.source!(root, spec)?)
		}
		q = Text.roc_string
		record = |s| "{ file: ${q(s.file)}, rocx: ${q(s.rocx)}, roc: ${q(s.roc)}, first: ${s.first.to_str()}, call: ${q(s.call)} }"
		refusal = |r| "{ source: ${q(r.source)}, reason: ${q(r.reason)}, column: ${r.column.to_str()} }"
		refused_found = SiteSources.refusals({})?
		lines =
			[
				"## Written by `rocx site prepare` (rocx-cli/SiteSources.roc): the sources, refusals and reports the",
				"## pages show. Edit those files (site/examples, site/Demos…), not this one.",
				"Sources := [].{",
				"\tSource : { file : Str, rocx : Str, roc : Str, first : U64, call : Str }",
				"",
			]
				.concat($sources.fold([], |all, s| all.concat(["\t${s.name} : Source", "\t${s.name} = ${record(s)}", ""])))
				.concat([
					"\trefusals : List({ source : Str, reason : Str, column : U64 })",
					"\trefusals = [${Str.join_with(refused_found.map(refusal), ", ")}]",
					"",
					"\tcheck_source : Str",
					"\tcheck_source = ${q(check.source)}",
					"",
					"\tcheck_report : Str",
					"\tcheck_report = ${q(check.report)}",
					"}",
					"",
				])
		Ok(Str.join_with(lines, "\n"))
	}
}

expect SiteSources.dedent(["\t\ta", "\t\t\tb", "", "\t\tc"]) == "a\n\tb\n\nc"
expect SiteSources.snake("EscapeLab") == "escape_lab"
expect SiteSources.view_call("x\ndemo = |{}| view({ n: 1 })\n") == "{ n: 1 }"
expect SiteSources.entries("pf: platform \"a\", admin: \"b, c\", x: \"y\"") == ["pf: platform \"a\"", "admin: \"b, c\"", "x: \"y\""]
expect SiteSources.matches(GuardApi, "\tmiddleware(c) : X")
expect SiteSources.matches(GuardApi, "\tRateLimit : X")
expect !SiteSources.matches(GuardApi, "\t\tx : X")
expect SiteSources.matches(FlagStoreApi, "\tset! : X")
