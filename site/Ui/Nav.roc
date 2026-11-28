import ../Generated/Paths
import ../AppNotes

## The docs, in four parts, each with its own pages in the sidebar: rocx, what an app is written
## in; the platform, what it runs on; the ecosystem, the packages it can use; and the examples,
## whole apps made of all three. The front page (Roc Solid as a whole) is in none of them. The bar at the top goes from one part to another.
## A part's pages are in groups, each under its heading in the sidebar (a group named "" has none,
## as the ecosystem's overview); the pager goes through them all in order, from one group to the
## next. Each page's path is from Paths, which rocx writes from site/routes, so a page that isn't
## there doesn't compile.
Nav := [].{
	Page : { path : Str, label : Str, blurb : Str }
	Group : { name : Str, pages : List(Page) }
	Section : { name : Str, home : Str, groups : List(Group) }

	## rocx: the markup, pages and components, talking to the server, the tools.
	rocx_docs : Section
	rocx_docs = {
		name: "rocx",
		home: Paths.rocx,
		groups: [
			{
				name: "rocx",
				pages: [
					{ path: Paths.rocx, label: "Overview", blurb: "What rocx is, in one page" },
					{ path: Paths.showcase, label: "Showcase", blurb: "A game, a flock, sound and timers, run by Roc" },
					{ path: Paths.syntax, label: "Syntax", blurb: "Markup wherever an expression can stand" },
					{ path: Paths.routing, label: "Routing", blurb: "A page is a file: +page.rocx, +layout.rocx" },
					{ path: Paths.components, label: "Components", blurb: "Signals, and pages that hydrate" },
					{ path: Paths.calls, label: "Talking to the server", blurb: "Endpoints, channels, events" },
					{ path: Paths.safety, label: "Safety", blurb: "What can't reach the page, and why" },
					{ path: Paths.tooling, label: "Tooling", blurb: "Build, check, lint, and errors at your lines" },
				],
			},
		],
	}

	## The platform: the server, native, and the browser, wasm. What the server does with every
	## request first; then the state it keeps, in the database and in memory; then the rest.
	platform_docs : Section
	platform_docs = {
		name: "Platform",
		home: Paths.platform_,
		groups: [
			{
				name: "Overview",
				pages: [
					{ path: Paths.platform_, label: "Overview", blurb: "Two platforms, one app" },
					{ path: Paths.platform_server, label: "The server", blurb: "Native Roc in a Rust host" },
					{ path: Paths.platform_http, label: "HTTP", blurb: "Other servers, bodies, forwards, cookies" },
					{ path: Paths.platform_live, label: "Live", blurb: "Rooms, topics, and channels for pages" },
				],
			},
			{
				name: "State",
				pages: [
					{ path: Paths.platform_database, label: "Database", blurb: "Postgres or SQLite: queries, transactions, migrations" },
					{ path: Paths.platform_actors, label: "Actors", blurb: "State one message at a time, kept in the database" },
					{ path: Paths.platform_kv, label: "Kv", blurb: "Values in memory by key, with a time to live" },
				],
			},
			{
				name: "Other",
				pages: [
					{ path: Paths.platform_settings, label: "Settings", blurb: "Env, and what only a dev server does" },
					{ path: Paths.platform_crypto, label: "Crypto", blurb: "Random bytes, AES-GCM, P-256, signed links, sealed secrets" },
					{ path: Paths.platform_browser, label: "The browser", blurb: "Wasm, a Zig host, a runtime" },
					{ path: Paths.platform_reference, label: "Reference", blurb: "Every module and effect, from the source" },
				],
			},
		],
	}

	## The ecosystem: packages of plain Roc and components, for any app. The overview, then the
	## packages by where they work: in the page, on the server, and beside the app (tools, and
	## watching it run).
	ecosystem_docs : Section
	ecosystem_docs = {
		name: "Ecosystem",
		home: Paths.ecosystem,
		groups: [
			{
				name: "",
				pages: [
					{ path: Paths.ecosystem, label: "Overview", blurb: "What a package is, and using one" },
				],
			},
			{
				name: "Pages",
				pages: [
					{ path: Paths.ecosystem_charts, label: "Charts", blurb: "Seven kinds of chart that glide to their data, styled by CSS" },
					{ path: Paths.ecosystem_forms, label: "Forms", blurb: "A form's rules written once, checked as it is typed and at the endpoint" },
					{ path: Paths.ecosystem_markdown, label: "Markdown", blurb: "CommonMark in Roc, a <Markdown> component, and typed frontmatter" },
					{ path: Paths.ecosystem_intl, label: "Intl", blurb: "Numbers, dates and translated messages, as each locale writes them" },
					{ path: Paths.ecosystem_virtual, label: "Virtual lists", blurb: "Lists of any length that render only the rows that show" },
					{ path: Paths.ecosystem_video, label: "Video", blurb: "Videos made of your components, played in the page or rendered to MP4 and WebM" },
					{ path: Paths.ecosystem_qr, label: "QR codes", blurb: "QR codes made in plain Roc, drawn as SVG by a component that follows its text" },
					{ path: Paths.ecosystem_presence, label: "Presence", blurb: "Who is here, who is typing, and live cursors" },
					{ path: Paths.ecosystem_audio, label: "Audio", blurb: "Sound files from a handler, played by the plugin's script" },
					{ path: Paths.ecosystem_vibrate, label: "Vibrate", blurb: "The phone's vibration motor from a handler, in a browser and on Android" },
				],
			},
			{
				name: "Server",
				pages: [
					{ path: Paths.ecosystem_auth, label: "Auth", blurb: "Sign-in by a mailed link or at Google, GitHub and OpenID Connect providers, and sessions: a plugin" },
					{ path: Paths.ecosystem_stripe, label: "Stripe", blurb: "Payments and subscriptions through Stripe's Checkout and Customer Portal, its webhooks kept in step: a plugin" },
					{ path: Paths.ecosystem_ai, label: "AI", blurb: "Claude from the server: answers streamed to a page, typed answers, tools, and teams of agents: a plugin" },
					{ path: Paths.ecosystem_jobs, label: "Jobs and cron", blurb: "Work that runs later, and again, on a schedule too: a plugin" },
					{ path: Paths.ecosystem_email, label: "Email", blurb: "Email over SMTP, or a dev mailbox while you develop: a plugin" },
					{ path: Paths.ecosystem_push, label: "Push", blurb: "Web Push notifications: a button that subscribes, and jobs that send: a plugin" },
					{ path: Paths.ecosystem_storage, label: "Storage", blurb: "Files in S3, beside the server, or in memory" },
					{ path: Paths.ecosystem_guard, label: "Guard", blurb: "Rate limits, feature flags and request guards, as middleware" },
					{ path: Paths.ecosystem_crypto, label: "Crypto", blurb: "SHA-256, SHA-1, HMAC, HKDF, Base64, Base32, hex and UUIDs, in Roc" },
				],
			},
			{
				name: "Tools",
				pages: [
					{ path: Paths.ecosystem_admin, label: "Admin", blurb: "A Django-style admin for your database's tables" },
					{ path: Paths.ecosystem_testing, label: "Testing", blurb: "Find things in a page by role, name and label, from Roc and Node" },
					{ path: Paths.ecosystem_mcp, label: "MCP", blurb: "An app's tools, resources and prompts, for AI agents" },
					{ path: Paths.ecosystem_tools, label: "Tools", blurb: "What a tool is, made once for the AI package's models and an MCP server" },
				],
			},
			{
				name: "Monitoring",
				pages: [
					{ path: Paths.ecosystem_otel, label: "OpenTelemetry", blurb: "Request timings and the app's metrics over OTLP; logs for a collector" },
					{ path: Paths.ecosystem_posthog, label: "PostHog", blurb: "5xx answers, handled errors, failed jobs and browser errors, as PostHog issues" },
				],
			},
		],
	}

	## The examples: whole apps in the repository's examples/, an overview and a page for each, in
	## groups (`AppNotes`, which lists them): where to start, the apps, and the benchmarks.
	examples_docs : Section
	examples_docs = {
		name: "Examples",
		home: Paths.examples,
		groups: AppNotes.groups,
	}

	sections : List(Section)
	sections = [rocx_docs, platform_docs, ecosystem_docs, examples_docs]

	## A part's pages, every group's, in order.
	pages_of : Section -> List(Page)
	pages_of = |section| section.groups.join_map(|group| group.pages)

	## The part of the docs a path is in: the platform's, the ecosystem's and the examples' pages are
	## under their overviews' paths, and everything else (a page no part lists, a path no page has) is rocx's.
	section_of : Str -> Section
	section_of = |path| {
		under = |home| path == home or path.starts_with("${home}/")
		if under(Paths.platform_) {
			platform_docs
		} else if under(Paths.ecosystem) {
			ecosystem_docs
		} else if under(Paths.examples) {
			examples_docs
		} else {
			rocx_docs
		}
	}

	## Whether a path is a dev build's story (`/__rocx/stories/…`): the component, and nothing around it.
	is_story : Str -> Bool
	is_story = |path| path.starts_with("/__rocx/stories/")

	## Whether a path is in the front page's frame: the front page (Roc Solid's, in no part), or a story.
	is_landing : Str -> Bool
	is_landing = |path| path == Paths.root or Nav.is_story(path)

	## The part a path is in, as the bar at the top marks it: none on the front page.
	current_of : Str -> Str
	current_of = |path| if (Nav.is_landing(path)) "" else Nav.section_of(path).name

	## The pages before and after a path's, in its part, across its groups. A page it doesn't list (the
	## 404) has neither.
	neighbours : Str -> { previous : Try(Page, [OutOfBounds]), next : Try(Page, [OutOfBounds]) }
	neighbours = |path| {
		pages = Nav.pages_of(Nav.section_of(path))
		match pages.find_first_index(|page| page.path == path) {
			Ok(index) => { previous: if (index == 0) Err(OutOfBounds) else pages.get(index - 1), next: pages.get(index + 1) }
			Err(_) => { previous: Err(OutOfBounds), next: Err(OutOfBounds) }
		}
	}
}

expect Nav.section_of(Paths.platform_database).name == "Platform"
expect Nav.section_of("/platform/nowhere").name == "Platform"
expect Nav.section_of(Paths.ecosystem_charts).name == "Ecosystem"
expect Nav.section_of("/ecosystem/nowhere").name == "Ecosystem"
expect Nav.section_of(Paths.examples).name == "Examples"
expect Nav.section_of("/examples/tasks").name == "Examples"
expect Nav.section_of("/examplesque").name == "rocx"
expect Nav.section_of(Paths.syntax).name == "rocx"
expect Nav.section_of(Paths.rocx).name == "rocx"
expect Nav.section_of("/platformer").name == "rocx"
expect Nav.section_of("/ecosystems").name == "rocx"
expect Nav.is_landing(Paths.root) and Nav.is_landing("/__rocx/stories/x") and !Nav.is_landing(Paths.syntax)
expect Nav.current_of(Paths.platform_database) == "Platform" and Nav.current_of(Paths.root) == ""
expect Nav.neighbours(Paths.rocx).previous == Err(OutOfBounds)
expect Nav.neighbours("/nowhere").next == Err(OutOfBounds)
expect Nav.neighbours(Paths.platform_live).next.map_ok(|page| page.path) == Ok(Paths.platform_database)
expect Nav.neighbours(Paths.ecosystem).next.map_ok(|page| page.path) == Ok(Paths.ecosystem_charts)
expect Nav.pages_of(Nav.platform_docs).len() == 11
