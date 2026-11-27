## rocx's help (D-107): `rocx`, `rocx help` or `rocx --help`, the commands by what they're for; and
## `rocx help <command>` or `rocx <command> --help`, one command's options. Written to standard
## output, its headings bold at a terminal.
import pf.Env
import pf.Stdout
import Term
import Text

Help := [].{

	## The commands, in the order the overview lists them, each with its line there.
	Entry : { usage : Str, what : Str }

	sections : List({ title : Str, entries : List(Entry) })
	sections = [
		{
			title: "Start",
			entries: [
				{ usage: "new [name]", what: "a new app, asking which database (SQLite, Postgres or Turso)" },
				{ usage: "dev [dir]", what: "serve the app, rebuilt and reloaded as you save" },
			],
		},
		{
			title: "Ship",
			entries: [
				{ usage: "build [dir]", what: "the app to deploy: dist/server and dist/static" },
				{ usage: "build --image", what: "a container image of it: <name>.tar" },
				{ usage: "build --static", what: "every page as plain files, in dist/" },
			],
		},
		{
			title: "Check",
			entries: [
				{ usage: "check [dir]", what: "type-check the app, each problem at its .rocx line" },
				{ usage: "check --sql [dir]", what: "check its SQL on its own database engine" },
				{ usage: "test [dir]", what: "run its tests" },
				{ usage: "lint <dir>…", what: "refuse Html.source_text in hand-written Roc" },
				{ usage: "routes [dir]", what: "list its routes, their middleware and what each does" },
				{ usage: "fmt [--check] <path>…", what: "format .roc and .rocx files" },
			],
		},
		{
			title: "More",
			entries: [
				{ usage: "generate [dir]…", what: "write Generated/ and the browser's copy, and build nothing" },
				{ usage: "upgrade [version]", what: "move the app to another version of rocx" },
				{ usage: "agents [dir]", what: "rocx's rules for coding agents, in the app's AGENTS.md" },
				{ usage: "qr <text>", what: "a QR code in the terminal" },
				{ usage: "--version", what: "this rocx's version, and the Roc compiler it runs" },
			],
		},
	]

	## Whether `name` is a command the help has a page for.
	knows : Str -> Bool
	knows = |name| Help.page(name) != ""

	## One command's page: its usage lines, what it does, and its options; "" for a name that isn't one.
	page : Str -> Str
	page = |name|
		match name {
			"new" =>
				Str.join_with(
					[
						"rocx new [name] [--db sqlite|postgres|turso]",
						"",
						"A new app in the directory `name` (asked for at a terminal when not given), from rocx's",
						"template: pages, sign-in, its users' table, security headers and a README that says",
						"what to change first. It asks which database at a terminal; SQLite without one.",
						"",
						"  --db sqlite      a file beside the server, data/app.db (the default)",
						"  --db postgres    a Postgres server, at DATABASE_URL",
						"  --db turso       Turso's engine on a SQLite file (writes at the same time)",
					],
					"\n",
				)
			"dev" =>
				Str.join_with(
					[
						"rocx dev [dir] [--port 8080] [--android [--lan]] [-- server options…]",
						"",
						"The app in `dir` (here by default) built and served under --dev at http://localhost:8080,",
						"built again and its server restarted as you save; open pages reload. After each start",
						"its SQL is checked (rocx check --sql). An app without a main.roc gets one.",
						"",
						"  --port N         where it listens (PORT; 8080 by default)",
						"  --android        each build for the phone's dev client too",
						"  --lan            the server on this network too, for a phone on its Wi-Fi",
						"  -- …             what follows is given to the app's server (--database-url, --debug…)",
					],
					"\n",
				)
			"build" =>
				Str.join_with(
					[
						"rocx build [dir] [--out dist] [--target arm64mac|x64mac|arm64musl|x64musl]",
						"rocx build [dir] --image [--out <name>.tar] [--tag name:tag] [--target arm64musl|x64musl]",
						"rocx build [dir] --static [--out dist] [--base /path/] [--route <path>]… [-- server options…]",
						"",
						"The app in `dir` (here by default) built to deploy: its server optimized for speed, with",
						"the database engine its program names alone, and the browser's wasm optimized for size.",
						"",
						"  (no mode)        dist/server and dist/static: run dist/server --static dist/static",
						"                   behind a proxy that speaks TLS",
						"  --image          a container image, written by rocx (no Dockerfile, no Docker):",
						"                   <name>.tar, for docker load -i; its server runs on PORT 8080, with",
						"                   /app/data for a volume",
						"  --static         every page rendered to a file, for a static host (GitHub Pages)",
						"",
						"  --out PATH       where it goes (dist, or <name>.tar for --image)",
						"  --target T       for another machine; this one's by default (its Linux for --image)",
						"  --tag name:tag   the image's name (the directory's, :latest, by default)",
						"  --base /path/    where a static copy is served from (/ by default)",
						"  --route PATH     a path a static copy has though no link reaches it (repeatable)",
					],
					"\n",
				)
			"generate" =>
				Str.join_with(
					[
						"rocx generate [dir]… [--client <out>] [--dev]",
						"",
						"Writes what rocx makes from an app's sources, and builds nothing: its Generated/ modules",
						"(the routes, the program, the contract) and the browser's copy (build/client, or",
						"--client), as rocx dev and rocx build do first. For editors and scripts.",
						"",
						"  --client OUT     where the browser's copy goes (one app only)",
						"  --dev            the copy for rocx dev: the components' stories in it",
					],
					"\n",
				)
			"check" =>
				Str.join_with(
					[
						"rocx check [dir]",
						"rocx check --sql [dir] [--engine sqlite|turso] [--verbose] [-- server options…]",
						"rocx check -- <command>…",
						"",
						"The app in `dir` (here by default) checked from its sources: rocx generate, then the",
						"compiler on the server's program and the browser's, each problem at its .rocx line.",
						"Exit 1 on an error, 2 on warnings alone.",
						"",
						"  --sql            each statement prepared on a scratch database of the app's engine,",
						"                   built from its migrations: its parameters and columns against the",
						"                   records the app reads them into",
						"  --engine E       ask Turso about a SQLite app, or SQLite about a Turso app",
						"  -- command       run a command (roc check…) with its reports pointed into .rocx files",
					],
					"\n",
				)
			"test" =>
				Str.join_with(
					[
						"rocx test [dir]",
						"",
						"The app built from its sources as rocx check builds it, then its expects run by the",
						"compiler (roc test), what fails pointed into the .rocx files.",
					],
					"\n",
				)
			"lint" =>
				Str.join_with(
					[
						"rocx lint <dir>…",
						"",
						"Refuses Html.source_text in hand-written .roc files (only rocx may write it). Exit 1 if",
						"any has it.",
					],
					"\n",
				)
			"routes" =>
				Str.join_with(
					[
						"rocx routes [dir] [--server] [--client]",
						"",
						"The app's routes, each with its method and its middleware's chain, outermost first.",
						"",
						"  --server         only the endpoints",
						"  --client         only the pages (the error page too)",
					],
					"\n",
				)
			"fmt" =>
				Str.join_with(
					[
						"rocx fmt [--check] <path>…",
						"",
						"Formats each .rocx file (its markup kept as written) and each hand-written .roc file under",
						"the paths. --check only says which aren't formatted.",
					],
					"\n",
				)
			"upgrade" =>
				Str.join_with(
					[
						"rocx upgrade [version]",
						"",
						"Installs another version of rocx (the latest by default) and makes it the default; in an",
						"app (a .rocx-version here), moves the app onto it.",
					],
					"\n",
				)
			"agents" =>
				Str.join_with(
					[
						"rocx agents [dir] [--force]",
						"",
						"Writes rocx's rules for coding agents into the app's AGENTS.md (made if missing), as a",
						"block between two markers, and a CLAUDE.md that imports AGENTS.md when the app has none.",
						"Run it again after an upgrade: it rewrites the block and nothing outside it. The block",
						"points at .rocx/agents/guide.md, the guide for the rocx the app builds with. rocx check",
						"says when the block is from another rocx.",
						"",
						"  --force          replace a block that was edited since rocx wrote it",
					],
					"\n",
				)
			"qr" =>
				Str.join_with(
					[
						"rocx qr [--pbm] <text>",
						"",
						"`text` as a QR code in the terminal (or as a PBM image).",
					],
					"\n",
				)
			_ => ""
		}

	## The overview: what rocx is, the commands by section, and where to read more.
	overview : Bool -> Str
	overview = |styled| {
		widest = Help.sections.join_map(|section| section.entries).map(|entry| Text.length(entry.usage)).fold(0, |most, n| if (n > most) n else most)
		lines = Help.sections.join_map(
			|section|
				[Term.bold(styled, section.title)]
					.concat(section.entries.map(|entry| "  rocx ${Term.pad(entry.usage, widest + 2)}${Term.dim(styled, entry.what)}"))
					.concat([""]),
		)
		Str.join_with(
			["${Term.bold(styled, "rocx")}: Roc Solid's command line", "", "Usage: rocx <command> [options]", ""]
				.concat(lines)
				.concat(["rocx help <command> (or rocx <command> --help) says more of one."]),
			"\n",
		)
	}

	## Writes the overview, or `name`'s page (the overview for a name that isn't a command).
	show! : Str => {}
	show! = |name| {
		styled = Stdout.is_terminal!({}) and (Env.var!("NO_COLOR") ?? "").is_empty()
		text = if (Help.knows(name)) Help.page(name) else Help.overview(styled)
		_ = Stdout.line!(text)
		{}
	}
}

expect Help.knows("build")
expect !Help.knows("nope")
expect Help.overview(Bool.False).contains("  rocx build [dir]")
