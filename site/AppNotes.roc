import Generated/ExampleApps

## What the examples page says of each example app, in the order it shows them: a summary, and what
## the app shows that the others don't. The numbers beside them are measured (`ExampleApps`, from
## site/example-apps.json); this is the prose. An app in examples/ that isn't here is on the page
## too, marked as having no notes yet, which the site's test refuses.
AppNotes := [].{
	About : { name : Str, summary : Str, shows : List(Str) }

	all : List(About)
	all = [
		{
			name: "hello",
			summary: "The app Getting started makes: a page with a button that counts its clicks, and an endpoint. Its main.roc is the one rocx dev writes for an app that has none.",
			shows: ["A page and a signal", "An endpoint, GET /hello", "The smallest browser half there is: what every app starts from"],
		},
		{
			name: "tasks",
			summary: "A small team's task lists: lists, tasks with a due day and someone to do them, filters, and reordering. The one to read first: it does the usual things the plain way, and its comments say why each piece is where it is.",
			shows: ["File routing, a middleware, and Postgres with typed rows", "Forms that work without JavaScript, checked as they are typed", "Optimistic actions: a change shows at once and is undone if refused", "Drag and drop, and rows that glide to their places"],
		},
		{
			name: "echo",
			summary: "The smallest app on the server platform: one endpoint, POST /echo, which answers with the JSON it was sent, through a middleware that only passes it on. It has no browser half. It is there to measure the server itself.",
			shows: ["Everything a request goes through, and nothing more", "The server's benchmark, below"],
		},
		{
			name: "journal",
			summary: "A small publication in English and Polish: Markdown posts with typed frontmatter, compiled into the server, with a search that follows the typing and reactions kept in memory. No database.",
			shows: ["Markdown collections from content/, typed", "Two languages with the intl package, and feeds", "Kv for state that needs no database"],
		},
		{
			name: "board",
			summary: "A live kanban board a small team works on at once: each sees the others' changes as they happen, and who is where.",
			shows: ["Drag and drop with optimistic moves", "Channels: one stream per tab, changes published to everyone on the board", "Presence, and an edit lease kept in Kv"],
		},
		{
			name: "quiz",
			summary: "A live quiz for a room full of phones. The host puts a room on a big screen, everyone joins with its code, the quickest right answers score most, and the leaderboard turns after each question.",
			shows: ["An actor per room, with its own timers", "A channel to every phone", "Charts of how the room answered"],
		},
		{
			name: "uptime",
			summary: "An uptime monitor and its public status page: jobs check each service on time, incidents open and close themselves, subscribers are emailed, and the page follows it all live.",
			shows: ["Jobs and cron, email and OpenTelemetry metrics, as plugins", "The admin's tables for the app's Postgres", "Charts, and a channel for the live page"],
		},
		{
			name: "notes",
			summary: "Personal notes in Markdown that AI agents can use too: sign in by a mailed link, write with a live preview, tag, pin and search, and let an AI client read and write them over MCP.",
			shows: ["Sign-in by a mailed link, and a signed session cookie", "Personal access tokens, kept as hashes", "An MCP server, a JSON API and its OpenAPI page", "Postgres full-text search"],
		},
		{
			name: "plate",
			summary: "A food diary for a phone: the USDA's 7,500 foods seeded into Postgres, packets looked up by barcode in Open Food Facts, recipes that log like foods, targets worked out from a profile, and trends charted.",
			shows: ["A search that follows the typing, over Postgres full-text search", "Another service asked with Http.fetch!, and a stand-in for it in the tests", "Rules run on both sides: what an amount has, worked out as it is typed", "A phone-first layout, with tabs along the bottom"],
		},
	]

	## The notes for the app `name`, if it has any.
	about : Str -> Try(About, [NoNotes])
	about = |name| AppNotes.all.find_first(|each| each.name == name).map_err(|_| NoNotes)

	## The apps the page shows, in its order: those with notes first, then any without.
	shown : List(ExampleApps.Example)
	shown = {
		noted = AppNotes.all.keep_oks(|each| ExampleApps.all.find_first(|example| example.name == each.name))
		noted.concat(ExampleApps.all.drop_if(|example| AppNotes.about(example.name).is_ok()))
	}

	## The page's contents: what's at a glance, each app, and the server's numbers.
	toc : List({ id : Str, label : Str })
	toc =
		[{ id: "glance", label: "At a glance" }]
			.concat(AppNotes.shown.map(|example| { id: example.name, label: example.title }))
			.concat([{ id: "server", label: "The server, measured" }, { id: "measured", label: "How they're measured" }])
}

expect AppNotes.about("tasks").is_ok()
expect AppNotes.about("nowhere") == Err(NoNotes)
expect AppNotes.shown.len() == ExampleApps.all.len()
