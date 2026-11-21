import ../Generated/Paths

## The docs, in three parts, each with its own pages in the sidebar: rocx, what an app is written
## in; the platform, what it runs on; and the ecosystem, the packages it can use. The front page
## (Roc Solid as a whole) is in none of them. The bar at the top goes from one part to another.
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
			{ path: Paths.components, label: "Components", blurb: "Signals, and islands that hydrate" },
			{ path: Paths.calls, label: "Talking to the server", blurb: "Server functions, endpoints, events" },
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
			{ path: Paths.platform_postgres, label: "Postgres", blurb: "Queries, transactions, migrations" },
			{ path: Paths.platform_storage, label: "Files in S3", blurb: "Uploads, parts, signed links, streaming" },
			{ path: Paths.platform_secrets, label: "Settings and crypto", blurb: "Env, signed links, sealed secrets" },
			{ path: Paths.platform_jobs, label: "Jobs, cron and email", blurb: "Work that runs later, and again" },
			{ path: Paths.platform_live, label: "Live and actors", blurb: "State that outlives a request" },
			{ path: Paths.platform_browser, label: "The browser", blurb: "Wasm, a Zig host, a runtime" },
		],
	}

	## The ecosystem: packages of plain Roc and components, for any app.
	ecosystem_docs : Section
	ecosystem_docs = {
		name: "Ecosystem",
		home: Paths.ecosystem,
		pages: [
			{ path: Paths.ecosystem, label: "Overview", blurb: "What a package is, and using one" },
			{ path: Paths.ecosystem_charts, label: "Charts", blurb: "Bar and line charts that glide to their data" },
		],
	}

	sections : List(Section)
	sections = [rocx_docs, platform_docs, ecosystem_docs]

	## The part of the docs a path is in: the platform's and the ecosystem's pages are under their
	## overviews' paths, and everything else (a page no part lists, a path no page has) is rocx's.
	section_of : Str -> Section
	section_of = |path| {
		under = |home| path == home or path.starts_with("${home}/")
		if (under(Paths.platform_)) platform_docs else if (under(Paths.ecosystem)) ecosystem_docs else rocx_docs
	}
}

expect Nav.section_of(Paths.platform_postgres).name == "Platform"
expect Nav.section_of("/platform/nowhere").name == "Platform"
expect Nav.section_of(Paths.ecosystem_charts).name == "Ecosystem"
expect Nav.section_of("/ecosystem/nowhere").name == "Ecosystem"
expect Nav.section_of(Paths.syntax).name == "rocx"
expect Nav.section_of(Paths.rocx).name == "rocx"
expect Nav.section_of("/platformer").name == "rocx"
expect Nav.section_of("/ecosystems").name == "rocx"
