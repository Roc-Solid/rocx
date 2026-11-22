import ../Generated/Paths
import ../AppNotes

## The docs, in four parts, each with its own pages in the sidebar: rocx, what an app is written
## in; the platform, what it runs on; the ecosystem, the packages it can use; and the examples,
## whole apps made of all three. The front page (Roc Solid as a whole) is in none of them. The bar at the top goes from one part to another.
## Each page's path is from Paths, which rocx writes from site/routes, so a page that isn't there
## doesn't compile.
Nav := [].{
	Page : { path : Str, label : Str, blurb : Str }
	Section : { name : Str, home : Str, pages : List(Page) }

	## rocx: the markup, pages and components, talking to the server, the tools.
	rocx_docs : Section
	rocx_docs = {
		name: "rocx",
		home: Paths.rocx,
		pages: [
			{ path: Paths.rocx, label: "Overview", blurb: "What rocx is, in one page" },
			{ path: Paths.showcase, label: "Showcase", blurb: "A game, a flock and charts, run by Roc" },
			{ path: Paths.syntax, label: "Syntax", blurb: "Markup wherever an expression can stand" },
			{ path: Paths.routing, label: "Routing", blurb: "A page is a file: +page.rocx, +layout.rocx" },
			{ path: Paths.components, label: "Components", blurb: "Signals, and pages that hydrate" },
			{ path: Paths.calls, label: "Talking to the server", blurb: "Endpoints, channels, events" },
			{ path: Paths.safety, label: "Safety", blurb: "What can't reach the page, and why" },
			{ path: Paths.tooling, label: "Tooling", blurb: "Build, check, lint, and errors at your lines" },
		],
	}

	## The platform: the server, native, and the browser, wasm.
	platform_docs : Section
	platform_docs = {
		name: "Platform",
		home: Paths.platform_,
		pages: [
			{ path: Paths.platform_, label: "Overview", blurb: "Two platforms, one app" },
			{ path: Paths.platform_server, label: "The server", blurb: "Native Roc in a Rust host" },
			{ path: Paths.platform_http, label: "HTTP", blurb: "Other servers, bodies, forwards, cookies" },
			{ path: Paths.platform_database, label: "Database", blurb: "Postgres or SQLite: queries, transactions, migrations" },
			{ path: Paths.platform_secrets, label: "Settings and crypto", blurb: "Env, signed links, sealed secrets" },
			{ path: Paths.platform_live, label: "Live and actors", blurb: "State that outlives a request" },
			{ path: Paths.platform_browser, label: "The browser", blurb: "Wasm, a Zig host, a runtime" },
			{ path: Paths.platform_reference, label: "Reference", blurb: "Every module and effect, from the source" },
		],
	}

	## The ecosystem: packages of plain Roc and components, for any app.
	ecosystem_docs : Section
	ecosystem_docs = {
		name: "Ecosystem",
		home: Paths.ecosystem,
		pages: [
			{ path: Paths.ecosystem, label: "Overview", blurb: "What a package is, and using one" },
			{ path: Paths.ecosystem_charts, label: "Charts", blurb: "Seven kinds of chart that glide to their data, styled by CSS" },
			{ path: Paths.ecosystem_admin, label: "Admin", blurb: "A Django-style admin for your Postgres tables" },
			{ path: Paths.ecosystem_crypto, label: "Crypto", blurb: "SHA-256, HMAC, HKDF, Base64 and hex, in Roc" },
			{ path: Paths.ecosystem_s3, label: "Files in S3", blurb: "Uploads, parts, signed links, streaming" },
			{ path: Paths.ecosystem_email, label: "Email", blurb: "Email over SMTP, or a dev mailbox while you develop: a plugin" },
			{ path: Paths.ecosystem_forms, label: "Forms", blurb: "A form's rules written once, checked as it is typed and at the endpoint" },
			{ path: Paths.ecosystem_guard, label: "Guard", blurb: "Rate limits, feature flags and request guards, as middleware" },
			{ path: Paths.ecosystem_intl, label: "Intl", blurb: "Numbers, dates and translated messages, as each locale writes them" },
			{ path: Paths.ecosystem_jobs, label: "Jobs and cron", blurb: "Work that runs later, and again, on a schedule too: a plugin" },
			{ path: Paths.ecosystem_markdown, label: "Markdown", blurb: "CommonMark in Roc, a <Markdown> component, and typed frontmatter" },
			{ path: Paths.ecosystem_mcp, label: "MCP", blurb: "An app's tools, resources and prompts, for AI agents" },
			{ path: Paths.ecosystem_otel, label: "OpenTelemetry", blurb: "Request timings and the app's metrics over OTLP; logs for a collector" },
			{ path: Paths.ecosystem_posthog, label: "PostHog", blurb: "5xx answers, handled errors, failed jobs and browser errors, as PostHog issues" },
			{ path: Paths.ecosystem_presence, label: "Presence", blurb: "Who is here, who is typing, and live cursors" },
			{ path: Paths.ecosystem_push, label: "Push", blurb: "Web Push notifications: a button that subscribes, and jobs that send" },
			{ path: Paths.ecosystem_testing, label: "Testing", blurb: "Find things in a page by role, name and label, from Roc and Node" },
		],
	}

	## The examples: whole apps in the repository's examples/, an overview and a page for each
	## (`AppNotes`, which lists them).
	examples_docs : Section
	examples_docs = {
		name: "Examples",
		home: Paths.examples,
		pages: AppNotes.pages,
	}

	sections : List(Section)
	sections = [rocx_docs, platform_docs, ecosystem_docs, examples_docs]

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
