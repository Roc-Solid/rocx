## `rocx build <dir> --static <out> [--base /path/] [--route <path>]… [--built <build>] [-- server
## options…]` (D-073): the app as static files, for a host with no server (GitHub Pages, a CDN, a
## benchmark's folder). rocx builds the app as for production (rocx build, the server from Roc's dev
## backend, the browser's wasm optimized for size), starts its server on a free port, and asks it
## for every page: `/`, each page whose path has no params, each `--route`, and every page those
## link to (`<a href>` on this site), each written as `<path>/index.html` with its URLs under
## `--base`; what a `--route` or a link answers that isn't a page (`/openapi.json`) is written at its
## path. A page carries the answers to the GETs it read while it rendered, so it shows them with no
## server. Then `404.html` (what a path nothing answers shows), the plugins' files, and the files
## pages load (`static/`, and `rocx/`: start.js, runtime.js, the wasm, the stylesheet). The copy is
## made beside `out` and put in its place at the end: a build that fails leaves the one before.
##
## `--built <build>` skips the build: `<build>/server` and `<build>/client/static` are the app's,
## built already (the docs site's build makes its own). What follows `--` goes to the server.
import pf.Child
import pf.Cmd
import pf.Events
import pf.File
import pf.Http
import pf.Stderr
import pf.Time
import Build
import Dev
import Fs
import Hosts
import Remap
import Routes
import Text
import Value

Static := [].{

	usage : Str
	usage = "usage: rocx build <dir> --static <out> [--base /path/] [--route <path>]… [--built <build>] [-- server options…]"

	## What `rocx build … --static` was asked: the app's directory, where the copy goes, the base it is
	## served under (`/` or `/docs/`), paths to ask for besides the pages, the build to use (none:
	## build one), and the server's own options. Paths are absolute.
	Asked : { dir : Str, out : Str, base : Str, routes : List(Str), built : [Some(Str), None], flags : List(Str) }

	## The words after `rocx build`, read, with paths from `cwd`; `Usage` says what is wrong.
	options : List(Str), Str -> Try(Asked, [Usage(Str)])
	options = |args, cwd| {
		var $own = []
		var $flags = []
		var $after = Bool.False
		for arg in args {
			if $after {
				$flags = $flags.append(arg)
			} else if arg == "--" {
				$after = Bool.True
			} else {
				$own = $own.append(arg)
			}
		}
		var $out = ""
		var $base = "/"
		var $routes = []
		var $built = None
		var $dirs = []
		var $i = 0
		while $i < $own.len() {
			arg = $own.get($i) ?? ""
			value = $own.get($i + 1) ?? ""
			if arg == "--static" or arg == "--base" or arg == "--route" or arg == "--built" {
				if value.is_empty() or value.starts_with("--") {
					return Err(Usage("rocx build ${arg}: give it a value\n${Static.usage}"))
				}
				if arg == "--static" {
					$out = value
				} else if arg == "--base" {
					$base = value
				} else if arg == "--route" {
					$routes = $routes.append(value)
				} else {
					$built = Some(Fs.resolve(cwd, [value]))
				}
				$i = $i + 2
			} else if arg == "--dev" {
				return Err(Usage("rocx build --static: a static copy is a production build; --dev is rocx dev's"))
			} else if arg.starts_with("-") {
				return Err(Usage(Static.usage))
			} else {
				$dirs = $dirs.append(arg)
				$i = $i + 1
			}
		}
		if $dirs.len() != 1 or $out.is_empty() {
			return Err(Usage("rocx build --static: one directory, the app's, and where its copy goes\n${Static.usage}"))
		}
		if !$base.starts_with("/") or !$base.ends_with("/") {
			return Err(Usage("rocx build --base: a base begins and ends with / (/ or /docs/): ${$base}"))
		}
		match $routes.find_first(|route| !route.starts_with("/") or route.starts_with("//")) {
			Ok(route) => return Err(Usage("rocx build --route: a path of this site, from its root (/feed.xml): ${route}"))
			Err(_) => {}
		}
		Ok({ dir: Fs.resolve(cwd, [$dirs.first() ?? "."]), out: Fs.resolve(cwd, [$out]), base: $base, routes: $routes, built: $built, flags: $flags })
	}

	## `rocx build <dir> --static <out> …` (the words after `build`), with the home of this rocx
	## (`rocx`; the app's root, `Hosts.root_of!`, builds it): exit 2 for arguments it can't take, 1
	## when the build or a page fails.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, rocx| {
		cwd = Fs.cwd!()
		asked = match Static.options(args, cwd) {
			Ok(read) => read
			Err(Usage(message)) => {
				_ = Stderr.line!(message)
				return Err(Exit(2))
			}
		}
		match Static.made!(asked, cwd, rocx) {
			Ok(said) => {
				for line in said {
					_ = Stderr.line!(line)
				}
				Ok({})
			}
			Err(Failed(message)) => {
				_ = Stderr.line!("rocx build --static: ${message}")
				Err(Exit(1))
			}
		}
	}

	## The copy made: what to say (the count, then notes).
	made! : Asked, Str, Str => Try(List(Str), [Failed(Str)])
	made! = |asked, cwd, rocx| {
		shown_dir = Static.shown(cwd, asked.dir)
		if !File.is_dir!(Fs.join([asked.dir, "routes"])) {
			return Err(Failed("${shown_dir} has no routes/: give the app's directory"))
		}
		dir = Fs.real!(asked.dir)
		if Static.holds(asked.out, [dir, cwd]) {
			return Err(Failed("${Static.shown(cwd, asked.out)} holds the app or this directory: the copy replaces what is there, so give a directory of its own (dist)"))
		}
		if File.is_dir!(asked.out) and !Fs.entries!(asked.out).is_empty() and !File.exists!(Fs.join([asked.out, "index.html"])) {
			return Err(Failed("${Static.shown(cwd, asked.out)} isn't empty and has no index.html: the copy replaces what is there, so give a directory of its own, or empty this one"))
		}
		routes = Fs.join([dir, "routes"])
		table = match Routes.route_table(Routes.find_route_files!(routes)) {
			Ok(found) => found
			Err(Problem(message)) => return Err(Failed(message))
		}
		if table.pages.is_empty() {
			return Err(Failed("${shown_dir} has no pages (routes/+page.rocx): there is nothing to write as static files"))
		}
		built_at = match asked.built {
			Some(given) => given
			None => {
				at = Fs.join([dir, "build", "static"])
				Static.build!(dir, at, Hosts.root_of!(dir, rocx))?
				at
			}
		}
		server = Fs.join([built_at, "server"])
		client_static = Fs.join([built_at, "client", "static"])
		if !File.exists!(server) or !File.exists!(Fs.join([client_static, "rocx", "app.wasm"])) {
			return Err(Failed("${Static.shown(cwd, built_at)} has no server, or no client/static/rocx/app.wasm: a build has both"))
		}
		app_static = Fs.join([dir, "static"])
		# The order the server is given them: the first that has a file answers it.
		served = [client_static].concat(if (File.is_dir!(app_static)) [app_static] else [])
		var $sources = []
		for file in Routes.routed_files(table) {
			$sources = $sources.append({ file, defs: Routes.definitions(Fs.read_or_empty!(Fs.join([routes, file]))) })
		}
		guarded = Static.own_middleware(table, $sources)
		stage = "${asked.out}.building"
		Fs.delete_all!(stage)
		started = Time.now_ms!({})
		job = { server, served, flags: asked.flags, log: Fs.join([built_at, "static-server.log"]), stage, base: asked.base, routes: asked.routes, pages: Static.plain_pages(table, guarded), guarded }
		copied = match Static.prerender!(job) {
			Ok(done) => done
			Err(Failed(why)) => {
				Fs.delete_all!(stage)
				return Err(Failed(why))
			}
		}
		# Files last, as the server answers a path with its file before its page; the first directory wins.
		for each in served.fold([], |reversed, each| reversed.prepend(each)) {
			match File.copy!(each, stage) {
				Ok({}) => {}
				Err(CantCopy(why)) => return Err(Failed(why))
			}
		}
		Fs.delete_all!(asked.out)
		match File.rename!(stage, asked.out) {
			Ok({}) => {}
			Err(CantRename(why)) => return Err(Failed(why))
		}
		counted = "rocx build --static: ${Static.count(copied.pages, "page")} and ${Static.count(copied.files, "file")} in ${Static.shown(cwd, asked.out)}${if (asked.base == "/") "" else ", for ${asked.base}"} (${Dev.seconds(Time.now_ms!({}) - started)} s)"
		Ok([counted].concat(copied.notes).concat(Static.notes(Routes.route_list(table, $sources), table, guarded, copied.written)))
	}

	## A path as `cwd` names it: relative if it is under `cwd` (`.` for `cwd` itself), else whole.
	shown : Str, Str -> Str
	shown = |cwd, path| {
		way = Fs.relative(cwd, path)
		if (way.is_empty()) "." else if (way.starts_with("..")) path else way
	}

	## Whether `out` is one of `kept`, or a directory above one: replacing it would delete it.
	holds : Str, List(Str) -> Bool
	holds = |out, kept| {
		at = Fs.normalize(out).drop_suffix("/")
		at.is_empty() or kept.any(|each| Static.within(Fs.normalize(each).drop_suffix("/"), at))
	}

	## Whether `path` is `at` or under it.
	within : Str, Str -> Bool
	within = |path, at| path == at or path.starts_with("${at}/")

	## `3 pages`, `1 file`.
	count : U64, Str -> Str
	count = |n, what| "${n.to_str()} ${what}${if (n == 1) "" else "s"}"

	# ---- Building ----

	## The app at `dir` built into `build`, as for production: rocx build (the browser's copy in
	## `build/client`, no stories), the server's host when it changed, the server from Roc's dev
	## backend (it only renders the pages, here; its build takes a fraction of LLVM's), and the
	## browser's wasm optimized for size, lambda sets specialized (as the docs site's is). `rocx` is the
	## app's root (`Hosts.root_of!`).
	build! : Str, Str, Str => Try({}, [Failed(Str)])
	build! = |dir, into, rocx| {
		client = Fs.join([into, "client"])
		main = Fs.join([dir, "main.roc"])
		if !File.exists!(main) {
			Dev.write_main!(dir, main, rocx)
		}
		match Build.build!([dir], { client: Some(client), cwd: Fs.cwd!(), dev: Bool.False, rocx }) {
			Ok(built) if built.ok => {
				said = built.said.keep_if(|line| !Dev.files_written(line))
				if !said.is_empty() {
					_ = Stderr.line!(Str.join_with(said, "\n"))
				}
			}
			Ok(built) => return Err(Failed("${Str.join_with(built.said, "\n")}\nrocx build failed"))
			Err(Problem(message)) => return Err(Failed("Error: ${message}\nrocx build failed"))
		}
		tools = Dev.tools!(rocx)?
		Hosts.server_host!(rocx, tools.target)?
		Static.roc_build!(tools, ["--target=${tools.target}", "--opt=dev", "--output=${Fs.join([into, "server"])}", main], "the server's build")?
		client_main = Fs.join([client, "main.roc"])
		if !File.exists!(client_main) {
			return Err(Failed("rocx build wrote no browser's copy (${client_main}): the app has no pages"))
		}
		Dev.web_host!(tools)?
		Static.roc_build!(tools, ["--target=wasm32", "--opt=size", "--specialize=yes", "--output=${Fs.join([client, "static", "rocx", "app.wasm"])}", client_main], "the browser's build")
	}

	## `roc build`, its reports pointed into the .rocx files; warnings alone are shown, not fatal.
	roc_build! : Dev.Tools, List(Str), Str => Try({}, [Failed(Str)])
	roc_build! = |tools, args, what| {
		ran = match Cmd.new(tools.roc).args(["build"].concat(args)).env("NO_COLOR", "1").output!() {
			Ok(done) => done
			Err(CantStart(why)) => return Err(Failed("${what}: ${why}"))
		}
		said = Remap.remap!(ran.stdout.concat(ran.stderr))
		if ran.code != 0 and ran.code != 2 {
			return Err(Failed("${Text.trim_end(said)}\n${what} failed"))
		}
		lines = Text.lines(said)
		if !lines.any(|line| line.starts_with("0 errors and 0 warnings found")) {
			rest = lines.keep_if(|line| !Text.trim(line).is_empty())
			if !rest.is_empty() {
				_ = Stderr.line!(Str.join_with(rest, "\n"))
			}
		}
		Ok({})
	}

	# ---- Asking the server ----

	## The routes of the pages behind a middleware of their own (`/members`), named in the page or
	## in the +server.roc beside it (D-079): it answers each request as it comes (who is asking?),
	## so the copy has none of them, and no link is followed to one.
	own_middleware : Routes.Table, List(Routes.Source) -> List(Str)
	own_middleware = |table, sources| table.pages.keep_if(|page| Routes.page_guarded(table, sources, page)).map(|page| page.path)

	## The paths of the pages whose route has no params (`/`, `/about`; not `/blog/[slug]`) and no
	## middleware of its own (`guarded`).
	plain_pages : Routes.Table, List(Str) -> List(Str)
	plain_pages = |table, guarded| table.pages.keep_if(|page| page.params.is_empty() and !guarded.contains(page.path)).map(|page| page.path)

	## The server, the directories it serves files from, its options and its log; where the copy
	## is made, its base, the `--route`s, the paths of the pages to ask for (`plain_pages`), and the
	## routes no link is followed to (`guarded`).
	Run : { server : Str, served : List(Str), flags : List(Str), log : Str, stage : Str, base : Str, routes : List(Str), pages : List(Str), guarded : List(Str) }

	Copied : { pages : U64, files : U64, written : List(Str), notes : List(Str) }

	## The server started on a free port, its output in its log, asked for everything (`copy!`),
	## and stopped, whatever the asking came to; when that is a failure, what the server said is
	## shown with it.
	prerender! : Run => Try(Copied, [Failed(Str)])
	prerender! = |job| {
		port = match Http.free_port!({}) {
			Ok(free) => free.to_str()
			Err(NoPort(why)) => return Err(Failed("no free port for the app's server: ${why}"))
		}
		statics = job.served.join_map(|each| ["--static", each])
		# --debug: the server lists the plugins' files (`/__rocx/plugin-files`), for the copy.
		child = match Cmd.new(job.server).args(["--port", port, "--debug"].concat(statics).concat(job.flags)).env("ROCX_LOG", "pretty").log(job.log).spawn!() {
			Ok(started) => started
			Err(CantStart(why)) => return Err(Failed("the app's server: ${why}"))
		}
		url = "http://127.0.0.1:${port}"
		copied = match Static.listening!(child, url) {
			Ok({}) => {
				asked = Static.copy!(url, job)
				Static.stop!(child)
				asked
			}
			Err(Ended(why)) => Err(Failed(why))
			Err(Failed(why)) => {
				Static.stop!(child)
				Err(Failed(why))
			}
		}
		match copied {
			Ok(done) => Ok(done)
			Err(Failed(why)) => {
				said = Text.lines(Fs.read_or_empty!(job.log)).keep_if(|line| !Text.trim(line).is_empty())
				Err(Failed(if (said.is_empty()) why else "${why}\nThe app's server said (${job.log}):\n${Str.join_with(said.drop_first(if (said.len() > 40) said.len() - 40 else 0), "\n")}"))
			}
		}
	}

	## Waits until the server answers (up to a minute): `Ended` when it ended first.
	listening! : Child, Str => Try({}, [Ended(Str), Failed(Str)])
	listening! = |child, url| {
		started = Time.now_ms!({})
		while Time.now_ms!({}) - started < 60_000 {
			match Http.get!("${url}/__rocx/plugin-files", []) {
				Ok(_) => return Ok({})
				Err(_) => {}
			}
			match Events.next!(50) {
				Exited(id, code) if id == child.id() => return Err(Ended("the app's server ended (exit ${code.to_str()}) before it listened"))
				Signal(_) => return Err(Failed("stopped"))
				_ => {}
			}
		}
		Err(Failed("the app's server didn't listen within a minute"))
	}

	## SIGTERM, then up to ten seconds for it to end, then SIGKILL.
	stop! : Child => {}
	stop! = |child| {
		Child.terminate!(child)
		started = Time.now_ms!({})
		while Time.now_ms!({}) - started < 10_000 {
			match Events.next!(100) {
				Exited(id, _) if id == child.id() => return {}
				_ => {}
			}
		}
		Child.kill!(child)
	}

	## What a browser asks for when it follows a link: a page where a path has a page and an
	## endpoint both.
	accept : Str
	accept = "accept: text/html,*/*;q=0.8"

	## Everything the server is asked for, written into `job.stage`: the plugins' files, then the
	## pages (and what `--route`s and links answer), then `404.html`. A page, a `--route` or a
	## plugin's file that doesn't answer 2xx fails the copy; a link that doesn't is a note.
	copy! : Str, Run => Try(Copied, [Failed(Str)])
	copy! = |url, job| {
		var $files = 0
		listed = Static.get!(url, "/__rocx/plugin-files", [])?
		files = match Value.parse(Str.from_utf8_lossy(listed.body)) {
			Ok(value) => Value.items(value).map(|each| Value.str(Value.field(each, "url")))
			Err(BadJson(why)) => return Err(Failed("the server's list of plugin files isn't JSON: ${why}"))
		}
		for file in files {
			answer = Static.get!(url, file, [])?
			if answer.status < 200 or answer.status >= 300 {
				return Err(Failed("GET ${file} (a plugin's file) answered ${answer.status.to_str()}"))
			}
			Static.write_bytes!(Fs.join([job.stage, Static.file_path(file)]), answer.body)?
			$files = $files + 1
		}
		var $queue = []
		for path in ["/"].concat(job.pages).concat(job.routes) {
			if !$queue.any(|queued| queued.path == path) {
				$queue = $queue.append({ path, linked_from: "" })
			}
		}
		var $pages = 0
		var $written = []
		var $notes = []
		var $i = 0
		while $i < $queue.len() {
			queued = $queue.get($i) ?? { path: "/", linked_from: "" }
			path = queued.path
			$i = $i + 1
			answer = Static.get!(url, path, [Static.accept])?
			if answer.status < 200 or answer.status >= 300 {
				if queued.linked_from.is_empty() {
					return Err(Failed("GET ${path} answered ${answer.status.to_str()}${if (job.routes.contains(path)) " (a --route)" else ""}"))
				}
				$notes = $notes.append("a link on ${queued.linked_from} to ${path} answered ${answer.status.to_str()}: not in the copy")
			} else if answer.content_type.starts_with("text/html") {
				html = Str.from_utf8_lossy(answer.body)
				file = if (Static.names_a_file(path)) Static.file_path(path) else Static.page_file(path)
				Static.write!(Fs.join([job.stage, file]), Static.under_base(html, job.base))?
				$pages = $pages + 1
				$written = $written.append(path)
				for link in Static.links(html) {
					if !$queue.any(|each| each.path == link) and !job.guarded.any(|route| Routes.matches(route, link)) {
						$queue = $queue.append({ path: link, linked_from: path })
					}
				}
			} else if !Static.names_a_file(path) and (path == "/" or path.ends_with("/")) {
				$notes = $notes.append("${path} answered ${answer.content_type}, not a page: a file needs a name, so it isn't in the copy")
			} else {
				Static.write_bytes!(Fs.join([job.stage, Static.file_path(path)]), answer.body)?
				$files = $files + 1
				$written = $written.append(path)
			}
		}
		# What a path nothing answers shows: static hosts serve 404.html there.
		missing = Static.get!(url, "/404", [Static.accept])?
		if missing.content_type.starts_with("text/html") {
			Static.write!(Fs.join([job.stage, "404.html"]), Static.under_base(Str.from_utf8_lossy(missing.body), job.base))?
		}
		Ok({ pages: $pages, files: $files, written: $written, notes: $notes })
	}

	get! : Str, Str, List(Str) => Try(Http.Answer, [Failed(Str)])
	get! = |url, path, headers|
		match Http.get!("${url}${path}", headers) {
			Ok(answer) => Ok(answer)
			Err(CantGet(why)) => Err(Failed(why))
		}

	write! : Str, Str => Try({}, [Failed(Str)])
	write! = |path, text|
		match File.write!(path, text) {
			Ok({}) => Ok({})
			Err(CantWrite(why)) => Err(Failed(why))
		}

	write_bytes! : Str, List(U8) => Try({}, [Failed(Str)])
	write_bytes! = |path, bytes|
		match File.write_bytes!(path, bytes) {
			Ok({}) => Ok({})
			Err(CantWrite(why)) => Err(Failed(why))
		}

	# ---- Pages as files ----

	## The file a page's path is written to: `/` is `index.html`, `/about` `about/index.html`.
	page_file : Str -> Str
	page_file = |path| {
		inner = Static.file_path(path).drop_suffix("/")
		if (inner.is_empty()) "index.html" else "${inner}/index.html"
	}

	## Whether a path names a file (its last part has a dot after its first character:
	## `/openapi.html`, `/sitemap.xml`), which the copy writes at its path, a page or not; a page at
	## any other path is its directory's index.html.
	names_a_file : Str -> Bool
	names_a_file = |path| {
		last = path.split_on("/").last() ?? ""
		last.to_utf8().drop_first(1).contains('.')
	}

	## A path as a file under the copy: without its leading `/`, `%XX` decoded (a static host
	## decodes the URL it is asked for before it looks for the file).
	file_path : Str -> Str
	file_path = |path| {
		bytes = path.drop_prefix("/").to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			byte = Text.at(bytes, $i)
			high = Static.hex_digit(Text.at(bytes, $i + 1)) ?? 16
			low = Static.hex_digit(Text.at(bytes, $i + 2)) ?? 16
			if byte == '%' and high < 16 and low < 16 {
				$out = $out.append(high * 16 + low)
				$i = $i + 3
			} else {
				$out = $out.append(byte)
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}

	hex_digit : U8 -> Try(U8, [NotHex])
	hex_digit = |byte|
		if byte >= '0' and byte <= '9' {
			Ok(byte - '0')
		} else if byte >= 'a' and byte <= 'f' {
			Ok(byte - 'a' + 10)
		} else if byte >= 'A' and byte <= 'F' {
			Ok(byte - 'A' + 10)
		} else {
			Err(NotHex)
		}

	## The page with its URLs under `base`: an `href`, `src` or `action` attribute (in double
	## quotes, after a space) whose URL begins with one `/` begins with `base` instead. As the
	## browser's runtime writes the ones it makes (`written`), and its start.js finds the rest
	## beside itself.
	under_base : Str, Str -> Str
	under_base = |html, base| {
		if base == "/" {
			return html
		}
		bytes = html.to_utf8()
		with_base = base.to_utf8()
		names = ["href=\"/".to_utf8(), "src=\"/".to_utf8(), "action=\"/".to_utf8()]
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			byte = Text.at(bytes, $i)
			$out = $out.append(byte)
			$i = $i + 1
			if byte == ' ' or byte == '\n' or byte == '\t' or byte == '\r' {
				match names.find_first(|name| Text.starts_with_at(bytes, name, $i)) {
					Ok(name) if Text.at(bytes, $i + name.len()) != '/' => {
						# The name and its quote, then the base for the `/`.
						$out = $out.concat(Text.slice(bytes, $i, $i + name.len() - 1)).concat(with_base)
						$i = $i + name.len()
					}
					_ => {}
				}
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The paths a page's links (`<a href="/…">`) lead to on this site, each once, in order: no
	## other site's, no fragment or query (a static file is one page whatever the query), none under
	## `/rocx/` or `/__rocx/` (the runtime's and the server's own).
	links : Str -> List(Str)
	links = |html| {
		bytes = html.to_utf8()
		var $found = []
		var $i = 0
		while $i < bytes.len() {
			match Text.index_of(bytes, "<a".to_utf8(), $i) {
				Err(NotFound) => {
					$i = bytes.len()
				}
				Ok(at) => {
					end = match Text.index_of_byte(bytes, '>', at) {
						Ok(found) => found
						Err(NotFound) => bytes.len()
					}
					$i = end
					after = Text.at(bytes, at + 2)
					if after == ' ' or after == '\n' or after == '\t' or after == '\r' {
						tag = Text.slice(bytes, at, end)
						match Static.href(tag) {
							Ok(link) if !$found.contains(link) => {
								$found = $found.append(link)
							}
							_ => {}
						}
					}
				}
			}
		}
		$found
	}

	## An `<a …>` tag's `href`, if it is a path on this site (see `links`).
	href : List(U8) -> Try(Str, [NotOurs])
	href = |tag| {
		var $at = 0
		var $start = 0
		while $start == 0 and $at < tag.len() {
			match Text.index_of(tag, "href=\"".to_utf8(), $at) {
				Ok(found) if found > 0 and Text.is_space_at(tag, found - 1) => {
					$start = found + 6
				}
				Ok(found) => {
					$at = found + 1
				}
				Err(NotFound) => {
					$at = tag.len()
				}
			}
		}
		if $start == 0 {
			return Err(NotOurs)
		}
		stop = match Text.index_of_byte(tag, '"', $start) {
			Ok(found) => found
			Err(NotFound) => return Err(NotOurs)
		}
		value = Text.cut(tag, $start, stop).replace_each("&amp;", "&")
		path = (value.split_on("#").first() ?? "").split_on("?").first() ?? ""
		if !path.starts_with("/") or path.starts_with("//") or path.starts_with("/rocx/") or path.starts_with("/__rocx/") {
			Err(NotOurs)
		} else {
			Ok(path)
		}
	}

	# ---- What a static host can't do ----

	## Notes on what the copy doesn't have: what only a server answers (a method that writes, a
	## stream, a channel, a handler of every method), the pages behind middleware of their own,
	## and each page with params none of whose paths was reached.
	notes : List(Routes.Row), Routes.Table, List(Str), List(Str) -> List(Str)
	notes = |rows, table, guarded, written| {
		served = rows.keep_if(|row| row.method != "GET" and row.path != "(anything else)").map(|row| "${row.method} ${row.path}")
		server_note = if (served.is_empty()) [] else ["not in the copy, as only a server answers them: ${Str.join_with(served, ", ")}"]
		unreached = table.pages.keep_if(|page| !page.params.is_empty() and !guarded.contains(page.path) and !written.any(|path| Routes.matches(page.path, path))).map(
			|page| "no page of ${page.path} was written: link to one from a page, or name it (--route ${Static.example_path(page.path)})",
		)
		guarded_note = if (guarded.is_empty()) [] else ["not in the copy, as their own middleware answers each request as it comes: ${Str.join_with(guarded, ", ")}"]
		server_note.concat(guarded_note).concat(unreached)
	}

	## A route's path with each param as `<name>` (`/blog/<slug>`), for a note.
	example_path : Str -> Str
	example_path = |path| Str.join_with(path.split_on("/").map(|part| if (part.starts_with("[") and part.ends_with("]")) "<${part.drop_prefix("[").drop_suffix("]")}>" else part), "/")
}

expect Static.page_file("/") == "index.html"
expect Static.page_file("/about") == "about/index.html"
expect Static.page_file("/blog/hello/") == "blog/hello/index.html"
expect Static.page_file("/notes/a%20b") == "notes/a b/index.html"
expect Static.file_path("/openapi.json") == "openapi.json"
expect Static.file_path("/100%") == "100%"
expect Static.names_a_file("/openapi.html") and Static.names_a_file("/blog/feed.xml")
expect !Static.names_a_file("/") and !Static.names_a_file("/about") and !Static.names_a_file("/.well-known") and !Static.names_a_file("/v1.2/")

expect Static.under_base("<a href=\"/syntax\">x</a> <img\nsrc=\"/logo.svg\"> <a href=\"//cdn/x\"> <form action=\"/go\">", "/docs/") == "<a href=\"/docs/syntax\">x</a> <img\nsrc=\"/docs/logo.svg\"> <a href=\"//cdn/x\"> <form action=\"/docs/go\">"
expect Static.under_base("<a href=\"/\">home</a> data-href=\"/x\"", "/b/") == "<a href=\"/b/\">home</a> data-href=\"/x\""
expect Static.under_base("<a href=\"/x\">", "/") == "<a href=\"/x\">"

expect Static.links("<a href=\"/about\">A</a><a class=\"x\" href=\"/blog/one?x=1#top\">B</a><a href=\"https://roc-lang.org\">R</a><a href=\"/about\">again</a><abbr href=\"/no\"></abbr><a href=\"//cdn/x\"></a><a\nhref=\"/q?a=1&amp;b=2\"></a><a href=\"/rocx/app.wasm\"></a><a data-href=\"/no\"></a>") == ["/about", "/blog/one", "/q"]

expect Static.holds("/work/site", ["/work/site/app", "/home"])
expect Static.holds("/work/app", ["/work/app"])
expect !Static.holds("/work/app/dist", ["/work/app", "/work"])
expect Static.holds("/", ["/x"])

expect Static.example_path("/blog/[slug]/[page]") == "/blog/<slug>/<page>"

expect {
	read = Static.options(["site", "--static", "dist", "--base", "/docs/", "--route", "/a.json", "--route", "/b", "--", "--context-file", "c.txt"], "/w")
	read == Ok({ dir: "/w/site", out: "/w/dist", base: "/docs/", routes: ["/a.json", "/b"], built: None, flags: ["--context-file", "c.txt"] })
}
expect Static.options(["site", "--static", "dist", "--base", "docs"], "/w").is_err()
expect Static.options(["site", "--static"], "/w").is_err()
expect Static.options(["a", "b", "--static", "dist"], "/w").is_err()
expect Static.options(["a", "--static", "dist", "--route", "x"], "/w").is_err()
expect Static.options(["a", "--static", "dist", "--dev"], "/w").is_err()
