import Generated/ExampleApps
import Generated/Paths

## What the docs say of each example app, in the order the sidebar lists them: its page, a line for
## the sidebar, a summary, what it shows that the others don't, and its screenshots. The numbers
## beside them are measured (`ExampleApps`, from site/example-apps.json, `just example-apps`), and
## so are the screenshots (site/static/shots/<app>/, `just example-shots`: a page shows those there
## are, and the site's test checks that each one named here was taken); this is the prose. An
## app in examples/ that isn't here is on the overview, marked as having no notes yet, which the
## site's test refuses.
AppNotes := [].{

	## A screenshot: its file under /shots/<app>/ (a .webp), what it shows (its alt text and
	## caption), and whether it is a phone's (narrow, so it's shown beside another).
	Shot : { file : Str, alt : Str, caption : Str, phone : Bool }

	## Where its page is in the sidebar: under Start (the first app to read), Apps, or Benchmarks
	## (apps made to be measured).
	Kind : [Start, App, Benchmark]

	About : { name : Str, kind : Kind, path : Str, blurb : Str, summary : Str, shows : List(Str), shots : List(Shot) }

	all : List(About)
	all = [
		{
			name: "hello",
			kind: Start,
			path: Paths.examples_hello,
			blurb: "A page, a counter and an endpoint",
			summary: "The app Getting started makes: a page with a button that counts its clicks, and an endpoint. Its main.roc is the one rocx dev writes for an app that has none.",
			shows: ["A page and a signal", "An endpoint, GET /hello", "The smallest browser half there is: what every app starts from"],
			shots: [],
		},
		{
			name: "tasks",
			kind: App,
			path: Paths.examples_tasks,
			blurb: "Task lists: the one to read first",
			summary: "A small team's task lists: lists, tasks with a due day and someone to do them, filters, and reordering. The one to read first: it does the usual things the plain way, and its comments say why each piece is where it is.",
			shows: ["File routing, a middleware, and a database with typed rows", "Forms that work without JavaScript, checked as they are typed", "Optimistic actions: a change shows at once and is undone if refused", "Drag and drop, rows that glide to their places, and a question before you leave unsaved changes"],
			shots: [
				{ file: "list", alt: "A task list with due badges, avatars, filters and the form that adds a task", caption: "A list, its filters, and the form under it", phone: Bool.False },
				{ file: "lists", alt: "The front page on a phone: each list as a card with how far along it is", caption: "The lists, on a phone", phone: Bool.True },
				{ file: "task", alt: "A task's page on a phone: every field in one form", caption: "A task, on a phone", phone: Bool.True },
			],
		},
		{
			name: "journal",
			kind: App,
			path: Paths.examples_journal,
			blurb: "Markdown posts in two languages",
			summary: "A small publication in English and Polish: Markdown posts with typed frontmatter, compiled into the server. The server renders the pages, and two small interactive parts run in the browser: a search that follows the typing, and reactions kept in memory. No database.",
			shows: ["A typed Markdown collection from content/, checked as the app builds", "Two languages with packages/intl, Atom feeds and a sitemap", "Pages the server renders alone (<NoHydration>), with two parts that hydrate", "Kv and packages/guard: reactions, a rate limit, security headers", "A typed JSON API with its OpenAPI page"],
			shots: [
				{ file: "home", alt: "The journal's front page: the latest posts with their dates and tags", caption: "The front page", phone: Bool.False },
				{ file: "post", alt: "A post on a phone, with its reactions under it", caption: "A post, on a phone", phone: Bool.True },
				{ file: "polish", alt: "The front page in Polish, on a phone", caption: "The same, in Polish", phone: Bool.True },
			],
		},
		{
			name: "board",
			kind: App,
			path: Paths.examples_board,
			blurb: "A live kanban board, for several at once",
			summary: "A live kanban board a small team works on at once: each sees the others' changes as they happen, and who is where.",
			shows: ["Drag and drop, with a move shown before the server has it", "A channel: each change published to everyone on the board", "Presence, and an edit lease on each card kept in Kv", "Ranks that keep the order when two people move cards at once"],
			shots: [
				{ file: "board", alt: "A kanban board with four columns of cards and the people on it", caption: "The board", phone: Bool.False },
				{ file: "card", alt: "A card open for editing, beside the board", caption: "A card, open", phone: Bool.False },
			],
		},
		{
			name: "quiz",
			kind: App,
			path: Paths.examples_quiz,
			blurb: "A live quiz for a room full of phones",
			summary: "A live quiz for a room full of phones. The host puts a room on a big screen, everyone joins with its code, the quickest right answers score most, and the leaderboard turns after each question.",
			shows: ["An actor per room, with its own timers", "A channel to every phone", "Charts of how the room answered"],
			shots: [
				{ file: "lobby", alt: "The big screen's lobby: the room's code, and who has joined", caption: "The big screen, waiting for the room", phone: Bool.False },
				{ file: "join", alt: "Joining a room on a phone: its code and a name", caption: "Joining, on a phone", phone: Bool.True },
			],
		},
		{
			name: "uptime",
			kind: App,
			path: Paths.examples_uptime,
			blurb: "An uptime monitor and its status page",
			summary: "An uptime monitor and its public status page: jobs check each service on time, incidents open and close themselves, subscribers are emailed, and the page follows it all live.",
			shows: ["Jobs, cron and email as plugins", "OpenTelemetry metrics from a middleware", "The admin's tables over the app's database, and its jobs page, behind a password and packages/auth's sessions", "Charts, and a channel for the live page"],
			shots: [
				{ file: "status", alt: "The status page: each service's state, its uptime and its last days", caption: "The status page", phone: Bool.False },
				{ file: "monitor", alt: "A monitor's page: its response time charted, and its incidents", caption: "A monitor", phone: Bool.False },
			],
		},
		{
			name: "notes",
			kind: App,
			path: Paths.examples_notes,
			blurb: "Notes in Markdown, for people and AI agents",
			summary: "Personal notes in Markdown that AI agents can use too: sign in by a mailed link, write with a live preview, tag, pin and search, and let an AI client read and write them over MCP.",
			shows: ["Sign-in by a mailed link, with packages/auth's plugin", "Personal access tokens, kept as hashes", "An MCP server whose tools are the JSON API's endpoints, and its OpenAPI page", "Full-text search, and Markdown with a live preview"],
			shots: [
				{ file: "notes", alt: "The notebook: notes with their tags, pinned ones first, and the tags down the side", caption: "The notebook", phone: Bool.False },
				{ file: "edit", alt: "A note being written, its Markdown beside its live preview", caption: "Writing, with a live preview", phone: Bool.False },
			],
		},
		{
			name: "pomodoro",
			kind: App,
			path: Paths.examples_pomodoro,
			blurb: "A focus timer, in a browser and on Android",
			summary: "A Pomodoro timer: 25 minutes to focus, then 5 to rest, a ring that empties as the time goes, and a count of today's sessions. The same page runs in a browser and, unchanged, as an Android phone's own views, where the end of a session plays a chime and buzzes the phone.",
			shows: ["One page on the web and on Android, with rocx dev --android", "A timer kept by a deadline, not by counting ticks", "A sound and a buzz from a timer, plugins with a phone half", "SVG and percentage widths, drawn natively on the phone"],
			shots: [
				{ file: "timer", alt: "The timer at 25:00 in a ring, the Focus and Break tabs above it, and today's count below", caption: "The timer", phone: Bool.False },
				{ file: "break", alt: "On a phone-sized browser: a break of 5 minutes after a focus session, the ring and buttons in green", caption: "A break, in a phone's browser", phone: Bool.True },
				{ file: "android", alt: "The same page on Android's emulator, drawn as native views: the ring, the time, the buttons and the day's bar", caption: "The same page, as Android views", phone: Bool.True },
			],
		},
		{
			name: "plate",
			kind: App,
			path: Paths.examples_plate,
			blurb: "A food diary for a phone",
			summary: "A food diary for a phone: the USDA's 7,500 foods seeded into its database, packets looked up by barcode in Open Food Facts, recipes that log like foods, targets worked out from a profile, and trends charted.",
			shows: ["A search that follows the typing, over full-text search", "Another service asked with Http.fetch!, and a stand-in for it in the tests", "Rules run on both sides: what an amount has, worked out as it is typed", "A phone-first layout, with tabs along the bottom", "A password only when one is set, with packages/auth's sessions (90 days)"],
			shots: [
				{ file: "diary", alt: "Today's diary on a phone: a ring of the energy eaten against the target, and the meals", caption: "Today, on a phone", phone: Bool.True },
				{ file: "food", alt: "A food's page on a phone: the amount, what it has, and its nutrition facts", caption: "A food, its amount worked out as it is typed", phone: Bool.True },
				{ file: "trends", alt: "The trends page: energy each day as bars, an average day, and weight", caption: "Trends", phone: Bool.False },
			],
		},
		{
			name: "echo",
			kind: Benchmark,
			path: Paths.examples_echo,
			blurb: "Two endpoints, to measure the server",
			summary: "The smallest app on the server platform: two endpoints, through a middleware that only passes a request on. POST /echo answers with the JSON string it was sent; POST /echo/json reads an order that nests into a record of its type and writes it back. It has no browser half. It is there to measure the server itself, and what reading and writing JSON adds.",
			shows: ["Everything a request goes through, and nothing more", "A body read into a typed record that nests, and written back", "The server's benchmark, on each endpoint"],
			shots: [],
		},
		{
			name: "sqlite-vs-turso",
			kind: Benchmark,
			path: Paths.examples_sqlite_vs_turso,
			blurb: "SQLite against Turso, timed in Roc",
			summary: "One app timing the same database work on SQLite and on Turso: writes alone and in a transaction, reads by key and by an index, sums, JSON, a recursive query, eight callers at once on rows of their own, on one row, and reading beside writing; a sale written to four tables in one transaction, with its job queued in it and without; then a million orders fetched one and a hundred at a time, and joined to their customers. Each is timed in Roc, in the server, around the Db calls it makes. Its results are on this page.",
			shows: ["The same SQL on two engines: --database-url picks one", "Turso's concurrent writes (MVCC): a transaction that loses to another runs again", "A job queued in the same transaction as its sale: the outbox pattern", "Eight actors as eight callers at once, and timing in Roc (Time.now_nanos!)", "A million rows, loaded by SQL from a count, fetched and joined"],
			shots: [],
		},
		{
			name: "checkboxes",
			kind: Benchmark,
			path: Paths.examples_checkboxes,
			blurb: "A million checkboxes, shared live",
			summary: "A million checkboxes that everyone with the page open shares: a box checked in one tab shows in every other within a moment, and the page holds only the rows that show.",
			shows: ["A virtual list (packages/virtual): <Repeat> and on:viewport", "State in the server's memory (Kv), with a compare-and-swap", "A channel that sends only the latest version of each chunk, and counts who is online", "A grid laid out by the list's width"],
			shots: [
				{ file: "grid", alt: "The grid: rows of checkboxes, some checked, each row's first box numbered, and the count of checked boxes and pages online above", caption: "The boxes", phone: Bool.False },
				{ file: "far", alt: "Half a million boxes down: the rows there, rendered as the grid scrolled to them", caption: "Half a million boxes down", phone: Bool.False },
			],
		},
	]

	## The notes for the app `name`, if it has any.
	about : Str -> Try(About, [NoNotes])
	about = |name| AppNotes.all.find_first(|each| each.name == name).map_err(|_| NoNotes)

	## The app `name`'s measured facts, if it was measured.
	facts : Str -> Try(ExampleApps.Example, [NotMeasured])
	facts = |name| ExampleApps.all.find_first(|example| example.name == name).map_err(|_| NotMeasured)

	## An app's title, as its README's heading has it (`Tasks`), or its directory's name.
	title : Str -> Str
	title = |name| AppNotes.facts(name).map_ok(|example| example.title) ?? name

	## The apps the overview shows, in its order: those with notes first, then any without.
	shown : List(ExampleApps.Example)
	shown = {
		noted = AppNotes.all.keep_oks(|each| AppNotes.facts(each.name))
		noted.concat(ExampleApps.all.drop_if(|example| AppNotes.about(example.name).is_ok()))
	}

	## The sidebar's groups: Start (the overview, then the first app to read), Apps, and Benchmarks,
	## each app's page in the group its `kind` names, in this list's order; Benchmarks ends with
	## js-framework-benchmark's page (its entries are in benchmarks/jsframework/, not examples/).
	groups : List({ name : Str, pages : List({ path : Str, label : Str, blurb : Str }) })
	groups = {
		of = |kind| AppNotes.all.keep_if(|each| each.kind == kind).map(|each| { path: each.path, label: AppNotes.title(each.name), blurb: each.blurb })
		[
			{ name: "Start", pages: [{ path: Paths.examples, label: "All the examples", blurb: "What each is, and what it weighs" }].concat(of(Start)) },
			{ name: "Apps", pages: of(App) },
			{ name: "Benchmarks", pages: of(Benchmark).append({ path: Paths.examples_js_framework_benchmark, label: "js-framework-benchmark", blurb: "Roc Solid beside Solid, React and others" }) },
		]
	}

	## An app's page's `meta`: its title, its summary, and what's on it.
	meta : Str -> { title : Str, description : Str, toc : List({ id : Str, label : Str }) }
	meta = |name| {
		found = AppNotes.about(name)
		shots = found.map_ok(|each| !each.shots.is_empty()) ?? Bool.False
		{
			title: "${AppNotes.title(name)} · Examples",
			description: found.map_ok(|each| each.summary) ?? "",
			toc: [{ id: "shows", label: "What it shows" }]
				.concat(if (shots) [{ id: "screens", label: "Screenshots" }] else [])
				.concat(if (name == "hello") [{ id: "source", label: "Its page" }] else [])
				.concat(if (name == "echo") [{ id: "bench", label: "The benchmark" }] else [])
				.concat(if (name == "sqlite-vs-turso") [{ id: "results", label: "The results" }, { id: "big", label: "A million rows" }] else [])
				.concat([{ id: "numbers", label: "What it's made of" }, { id: "run", label: "Run it" }]),
		}
	}
}

expect AppNotes.about("tasks").is_ok()
expect AppNotes.about("nowhere") == Err(NoNotes)
expect AppNotes.shown.len() == ExampleApps.all.len()
expect AppNotes.groups.join_map(|group| group.pages).len() == AppNotes.all.len() + 2
expect AppNotes.meta("echo").toc.any(|entry| entry.id == "bench")
expect !AppNotes.meta("tasks").toc.any(|entry| entry.id == "bench")
expect AppNotes.meta("sqlite-vs-turso").toc.any(|entry| entry.id == "results")
