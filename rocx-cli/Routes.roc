## File-based routing, as SvelteKit has it: under an app's `routes/`, a
## `+page.rocx` is a page at the path its directory names (`routes/blog/[slug]/+page.rocx` is
## `/blog/:slug`), each `+layout.rocx` above it wraps it, `+server.rocx` answers HTTP methods there
## (`get!`, `post!`, `put!`, `patch!`, `delete!`: endpoints; `events!`: a stream of events;
## `respond!`: every method the others don't, with a `Server.Response` of its own; `channel!`: a
## channel, which pages subscribe to over the tab's one stream, `/rocx/live`, with its hooks
## `receive!`, `on_open!` and `on_close!`), and `+error.rocx` is what a path nothing has shows. A
## route file names its `middleware`, which runs around it. A directory may have dots after its
## first character, for a file's name (`routes/sitemap.xml/+server.roc` answers `/sitemap.xml`; its
## names are `SitemapXmlServer` and `sitemap_xml`). Directories that start with a dot are skipped,
## but for `.well-known` (`routes/.well-known/openid-configuration/+server.roc`).
##
## A route file is bare: imports, then its definitions (`meta`, `view`). Roc names a module after
## its file, and `+page` isn't a name, so rocx writes each as a module of its own under `Generated/`
## (`ShowcasePage.roc`), putting the module's line on the blank line between them (or at the start
## of the first definition's line), so line N there is still line N of the route file. Then `Generated/Routes.roc` matches a request's path to its
## page, `Generated/Paths.roc` has a path for every page, `Generated/Api.roc` is the app's contract
## (each endpoint and channel, a function of its params, its method, URL and types copied from its
## handler's annotation, and their OpenAPI document, `Api.openapi`), and `Generated/Handlers.roc`
## binds each to its handler, for the router and `Endpoint.run!` (D-037). (A record field can't be
## called `module` in Roc: these records call a route's module `mod`.)
import Value
import Text
import Fs
import Transpile

Routes := [].{

	## A route's param: its name, and which of the path's parts it is.
	Param : { name : Str, at : U64 }

	## An import Api makes for a route's type (`contract_imports`).
	ContractImport : { target : Str, alias : Str, renamed : Bool, exposed : List(Str), file : Str, method : Str, at : U64, type : Str }

	## A route file, from its path under `routes/`: its kind (`page`, `layout`, `error`, `server`),
	## its directories, its module (`BlogSlugPage`) and its name (`blog_slug`, for Paths).
	Layout : { file : Str, kind : Str, parts : List(Str), module_name : Str, name : Str }

	## A page's, an endpoint's or the error page's route file, with its path (`/blog/[slug]`), its
	## params and the layouts above it, outermost first. (The error page has no path or params.)
	Entry : { file : Str, kind : Str, parts : List(Str), module_name : Str, name : Str, path : Str, params : List(Param), layouts : List(Layout) }

	## A path something answers: its page, its endpoints, or both.
	At : { path : Str, parts : List(Str), params : List(Param), name : Str, page : [Some(Entry), None], server : [Some(Entry), None] }

	## The routes: the pages and endpoints in the order they are tried, the layouts, the error
	## page, every path something answers, and the route files' paths they were made from.
	Table : { pages : List(Entry), servers : List(Entry), layouts : List(Layout), error : [Some(Entry), None], paths : List(At), files : List(Str) }

	## What a route file defines (`definitions`). `channel`: its channel's hooks, if it defines
	## `channel!`; `hooks`: the hooks it defines when it defines no channel (for rocx build to refuse);
	## `handlers`: the types of each method and of its channel, from their annotations (for Api, the
	## contract); `imported`: its import lines, for the modules those types name.
	Defs : { view : [Some(Str), None], meta : Bool, methods : List(Str), middleware : [Some(Str), None], docs : List({ key : Str, value : Str }), respond : Bool, channel : [Some(List(Str)), None], hooks : List(Str), handlers : List(Handler), imported : List(Str) }

	## A method's or a channel's types, from its annotation (`get! : { request : Server.Request,
	## params : {}, context : c } => Try(Str, Endpoint.Refusal)`): what it is sent (`body`'s type; `""`
	## when its record has none) and what it answers (its `Try`'s first). `line`: its definition's
	## (from 1). Without an annotation, or one rocx can't read (`Unreadable`, why), it has none; one
	## that names a type the route file defines (`Defined`, those types) has none Api can name.
	Handler : { method : Str, line : U64, types : [Typed({ body : Str, answer : Str }), Unreadable(Str), Unannotated, Defined(List(Str))] }

	## Each route file's definitions, by its path under `routes/`.
	Source : { file : Str, defs : Defs }

	## A story with its id, as Stories makes them.
	Placed : { file : Str, module_path : Str, component : Str, name : Str, def : Str, line : U64, id : Str, alias : Str }

	## A job or a kind of actor an app's module defines (`jobs_in!`, `actors_in!`).
	Found : { define : Str, name : Str, module_path : Str, file : Str, line : U64, route : [Some(Str), None], thunk : Bool }

	## A line of `rocx routes`.
	Row : { method : Str, path : Str, file : Str, middleware : [Some(Str), None] }

	## The last lines of every generated file start with this.
	marker : Str
	marker = "# rocx: generated from"

	## Where a dev build's catalog of stories is.
	stories_path : Str
	stories_path = "/__rocx/stories"

	## The methods a `+server.rocx` may answer, as it names them.
	method_names : List(Str)
	method_names = ["get!", "post!", "put!", "patch!", "delete!", "events!"]

	## A channel, which a `+server.roc` defines beside its methods.
	channel_name : Str
	channel_name = "channel!"

	## A channel's hooks, each optional.
	channel_hooks : List(Str)
	channel_hooks = ["receive!", "on_open!", "on_close!"]

	## The one directory starting with a dot that is routed (RFC 8615).
	well_known : Str
	well_known = ".well-known"

	## Where rocx writes the modules for an app's routes.
	generated_dir : Str
	generated_dir = "Generated"

	## The module rocx writes the app's component pages in.
	root_name : Str
	root_name = "Root"

	## The module rocx writes the app's program in.
	app_name : Str
	app_name = "App"

	## Names a route's definitions can't have: Roc's keywords, and `all`.
	keywords : List(Str)
	keywords = ["all", "and", "app", "as", "break", "crash", "dbg", "else", "expect", "exposes", "exposing", "for", "hosted", "if", "import", "in", "is", "match", "module", "not", "or", "package", "packages", "platform", "provides", "requires", "return", "targets", "then", "var", "when", "where", "while"]

	# ---- small things ----

	## A route file's kind, from its name (`+page.rocx`: `page`).
	route_kind : Str -> Try(Str, [NotRoute])
	route_kind = |entry_name| {
		found = ["page", "layout", "error", "server"].find_first(|kind| entry_name == "+${kind}.rocx" or entry_name == "+${kind}.roc")
		match found {
			Ok(kind) => Ok(kind)
			Err(_) => Err(NotRoute)
		}
	}

	## Whether a file's name is a route file's (`+page.rocx`, `+server.roc`, …).
	is_route_file : Str -> Bool
	is_route_file = |entry_name|
		match Routes.route_kind(entry_name) {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		}

	## The HTTP method a handler answers (`events!` answers a GET).
	verb_of : Str -> Str
	verb_of = |method| if (method == "events!") "GET" else Text.upper(method.replace_first("!", ""))

	## Whether some text is there and not empty (JavaScript's truthiness of a string or null).
	filled : [Some(Str), None] -> Bool
	filled = |maybe|
		match maybe {
			Some(text) => !text.is_empty()
			None => Bool.False
		}

	## The text, or `""`.
	or_empty : [Some(Str), None] -> Str
	or_empty = |maybe|
		match maybe {
			Some(text) => text
			None => ""
		}

	## A file's definitions, from the sources.
	defs_of : List(Source), Str -> Defs
	defs_of = |sources, file|
		match sources.find_first(|source| source.file == file) {
			Ok(source) => source.defs
			Err(_) => { view: None, meta: Bool.False, methods: [], middleware: None, docs: [], respond: Bool.False, channel: None, hooks: [], handlers: [], imported: [] }
		}

	## Whether the file names a middleware.
	guards : List(Source), Str -> Bool
	guards = |sources, file| Routes.filled(Routes.defs_of(sources, file).middleware)

	## Whether the file defines a channel.
	has_channel : List(Source), Str -> Bool
	has_channel = |sources, file|
		match Routes.defs_of(sources, file).channel {
			Some(_) => Bool.True
			None => Bool.False
		}

	## The hooks of the file's channel (none without one).
	hooks_of : List(Source), Str -> List(Str)
	hooks_of = |sources, file|
		match Routes.defs_of(sources, file).channel {
			Some(hooks) => hooks
			None => []
		}

	## The last line of a file's text, its trailing whitespace gone.
	last_line : Str -> Str
	last_line = |text| {
		trimmed = Text.trim_end(text)
		match trimmed.split_last("\n") {
			Ok(halves) => halves.after
			Err(_) => trimmed
		}
	}

	## Whether a route's `.roc` is one rocx wrote (beside its `.rocx`, or ending with the marker).
	written! : Str => Bool
	written! = |path|
		path.ends_with(".roc") and (Fs.exists!("${path}x") or Routes.last_line(Fs.read_or_empty!(path)).starts_with(Routes.marker))

	lower_or_digit : U8 -> Bool
	lower_or_digit = |b| Text.is_lower(b) or Text.is_digit(b)

	up : U8 -> U8
	up = |b| if (Text.is_lower(b)) b - 32 else b

	## `blog-post` → `BlogPost`, `getting_started` → `GettingStarted`, `feed.xml` → `FeedXml`.
	pascal : Str -> Str
	pascal = |word| {
		bytes = word.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if $i == 0 and Routes.lower_or_digit(c) {
				$out = $out.append(Routes.up(c))
				$i = $i + 1
			} else if (c == '_' or c == '-' or c == '.') and $i + 1 < bytes.len() and Routes.lower_or_digit(Text.at(bytes, $i + 1)) {
				$out = $out.append(Routes.up(Text.at(bytes, $i + 1)))
				$i = $i + 2
			} else {
				$out = $out.append(c)
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}

	## Whether a directory is a path's part: lower case (`blog`, `getting-started`, `feed.xml`: a dot
	## after the first character, for a file's name) or a param (`[slug]`).
	is_path_part : Str -> Bool
	is_path_part = |part| {
		bytes = part.to_utf8()
		n = bytes.len()
		if n >= 3 and Text.at(bytes, 0) == '[' and Text.at(bytes, n - 1) == ']' {
			inner = Text.slice(bytes, 1, n - 1)
			Text.is_lower(Text.at(inner, 0)) and inner.all(|b| Text.is_lower(b) or Text.is_digit(b) or b == '_')
		} else {
			# A dot only between two letters or digits (`feed.xml`), so the names made from it are Roc's.
			dotted = bytes.map_with_index(|b, i| { b, i }).keep_if(|each| each.b == '.').all(|each| each.i > 0 and each.i + 1 < n and Routes.lower_or_digit(Text.at(bytes, each.i - 1)) and Routes.lower_or_digit(Text.at(bytes, each.i + 1)))
			n > 0 and Routes.lower_or_digit(Text.at(bytes, 0)) and dotted and bytes.all(|b| Text.is_lower(b) or Text.is_digit(b) or b == '_' or b == '-' or b == '.')
		}
	}

	## A directory as a word of a route's names: a param's brackets and a leading dot gone.
	word_of : Str -> Str
	word_of = |part| {
		opened = if (part.starts_with("[")) part.drop_prefix("[") else part
		closed = if (opened.ends_with("]")) opened.drop_suffix("]") else opened
		if (closed.starts_with(".")) closed.drop_prefix(".") else closed
	}

	## A `.roc` route file's path as its `.rocx`.
	as_rocx : Str -> Str
	as_rocx = |path| if (path.ends_with(".roc")) path.drop_suffix(".roc").concat(".rocx") else path

	## The order routes are tried in: fewer params first, then more fixed parts, then by path.
	route_order : U64, U64, Str, U64, U64, Str -> [Before, Same, After]
	route_order = |a_params, a_parts, a_path, b_params, b_parts, b_path| {
		a_fixed = a_parts - a_params
		b_fixed = b_parts - b_params
		if a_params < b_params {
			Before
		} else if a_params > b_params {
			After
		} else if b_fixed < a_fixed {
			Before
		} else if b_fixed > a_fixed {
			After
		} else {
			Text.locale_order(a_path, b_path)
		}
	}

	## The layouts above some parts: those whose parts begin them.
	above : List(Layout), List(Str) -> List(Layout)
	above = |layouts, parts| layouts.keep_if(|layout| layout.parts.len() <= parts.len() and parts.take_first(layout.parts.len()) == layout.parts)

	## Every route file a table has, as JavaScript's `routedEntries` lists them: the pages, the
	## endpoints, the layouts and the error page.
	entries : Table -> List(Layout)
	entries = |table| {
		plain = |entry| { file: entry.file, kind: entry.kind, parts: entry.parts, module_name: entry.module_name, name: entry.name }
		errors =
			match table.error {
				Some(error) => [plain(error)]
				None => []
			}
		table.pages.map(plain).concat(table.servers.map(plain)).concat(table.layouts).concat(errors)
	}

	## Every route file a table has.
	routed_files : Table -> List(Str)
	routed_files = |table| {
		errors =
			match table.error {
				Some(error) => [error.file]
				None => []
			}
		table.pages.map(|entry| entry.file).concat(table.servers.map(|entry| entry.file)).concat(table.layouts.map(|layout| layout.file)).concat(errors)
	}

	## Every route file a table has, with its module.
	routed_modules : Table -> List({ file : Str, module_name : Str })
	routed_modules = |table| {
		pick = |entry| { file: entry.file, module_name: entry.module_name }
		errors =
			match table.error {
				Some(error) => [pick(error)]
				None => []
			}
		table.pages.map(pick).concat(table.servers.map(pick)).concat(table.layouts.map(|layout| { file: layout.file, module_name: layout.module_name })).concat(errors)
	}

	# ---- finding the routes ----

	## The route files under `routes` (`+page.rocx`; `+server.roc`, plain Roc), their paths
	## relative to it, each directory's entries in order; none if it isn't a directory.
	find_route_files! : Str => List(Str)
	find_route_files! = |dir| if (Fs.is_dir!(dir)) Routes.walk_routes!(dir, "", []) else []

	walk_routes! : Str, Str, List(Str) => List(Str)
	walk_routes! = |dir, prefix, found| {
		var $found = found
		for entry in Fs.entries!(dir) {
			if !(entry.starts_with(".") and entry != Routes.well_known) {
				path = Fs.join([dir, entry])
				relative = if (prefix.is_empty()) entry else "${prefix}/${entry}"
				if Fs.is_dir!(path) {
					$found = Routes.walk_routes!(path, relative, $found)
				} else if Routes.is_route_file(entry) and !Routes.written!(path) {
					$found = $found.append(relative)
				}
			}
		}
		$found
	}

	## The routes, from their files' paths under `routes/`. `Problem` says what is wrong.
	route_table : List(Str) -> Try(Table, [Problem(Str)])
	route_table = |paths| {
		var $made = []
		for path in paths {
			pieces = path.split_on("/")
			parts = pieces.drop_last(1)
			kind_found = Routes.route_kind(pieces.last() ?? "")
			if kind_found == Err(NotRoute) {
				return Err(Problem("Cannot read properties of null (reading '1')"))
			}
			kind = kind_found ?? ""
			if paths.any(|other| other != path and Routes.as_rocx(other) == path) {
				return Err(Problem("routes/${path} and routes/${path}x are the same route: keep one"))
			}
			match parts.find_first(|part| !(Routes.is_path_part(part) or part == Routes.well_known)) {
				Ok(part) => return Err(Problem("routes/${path}: a directory is a path's part in lower case (`blog`, `getting-started`, `feed.xml`) or a param (`[slug]`): not `${part}`"))
				Err(_) => {}
			}
			words = parts.map(Routes.word_of)
			stem = if (words.is_empty()) "Root" else Str.join_with(words.map(Routes.pascal), "")
			named = if (words.is_empty()) "root" else Str.join_with(words, "_").replace_each("-", "_").replace_each(".", "_")
			$made = $made.append({ file: path, kind, parts, module_name: "${stem}${Routes.pascal(kind)}", name: if (Routes.keywords.contains(named)) "${named}_" else named })
		}
		made = $made
		var $seen = []
		for entry in made {
			match $seen.find_first(|other| other.module_name == entry.module_name) {
				Ok(other) => return Err(Problem("routes/${entry.file} and routes/${other.file} would both be ${entry.module_name}: rename one of their directories"))
				Err(_) => {
					$seen = $seen.append(entry)
				}
			}
		}
		errors = made.keep_if(|entry| entry.kind == "error")
		match errors.find_first(|entry| !entry.parts.is_empty()) {
			Ok(misplaced) => return Err(Problem("routes/${misplaced.file}: an error page is the app's, in routes/ itself, for now"))
			Err(_) => {}
		}
		layouts = made.keep_if(|entry| entry.kind == "layout")
		routed = |entry| {
			params = entry.parts.map_with_index(|part, i| { part, i }).keep_if(|each| each.part.starts_with("[")).map(|each| { name: each.part.drop_prefix("[").drop_suffix("]"), at: each.i })
			{ file: entry.file, kind: entry.kind, parts: entry.parts, module_name: entry.module_name, name: entry.name, path: "/${Str.join_with(entry.parts, "/")}", params, layouts: Routes.above(layouts, entry.parts) }
		}
		unsorted_pages = made.keep_if(|entry| entry.kind == "page").map(routed)
		unsorted_servers = made.keep_if(|entry| entry.kind == "server").map(routed)
		var $names = []
		for page in unsorted_pages {
			match $names.find_first(|other| other.name == page.name) {
				Ok(other) => return Err(Problem("routes/${page.file} and routes/${other.file} would both be Paths.${page.name}: rename one of their directories"))
				Err(_) => {
					$names = $names.append(page)
				}
			}
		}
		by_route = |a, b| Routes.route_order(a.params.len(), a.parts.len(), a.path, b.params.len(), b.parts.len(), b.path)
		pages = unsorted_pages.sort_with(by_route)
		servers = unsorted_servers.sort_with(by_route)
		var $answered = []
		for entry in pages.concat(servers) {
			match $answered.find_first_index(|at| at.path == entry.path) {
				Ok(i) => {
					$answered = $answered.update(i, |at| if (entry.kind == "page") { ..at, page: Some(entry) } else { ..at, server: Some(entry) }) ?? $answered
				}
				Err(_) => {
					$answered = $answered.append({ path: entry.path, parts: entry.parts, params: entry.params, name: entry.name, page: if (entry.kind == "page") Some(entry) else None, server: if (entry.kind == "page") None else Some(entry) })
				}
			}
		}
		error =
			match errors.first() {
				Ok(entry) => Some({ file: entry.file, kind: entry.kind, parts: entry.parts, module_name: entry.module_name, name: entry.name, path: "", params: [], layouts: Routes.above(layouts, []) })
				Err(_) => None
			}
		Ok({ pages, servers, layouts, error, paths: $answered.sort_with(by_route), files: paths })
	}

	# ---- what a route file defines ----

	## Where the line after the one `pos` is on starts (after a `\n` or `\r`).
	next_line_start : List(U8), U64 -> Try(U64, [NoMore])
	next_line_start = |bytes, pos| {
		var $i = pos
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\n' or c == '\r' {
				return Ok($i + 1)
			}
			$i = $i + 1
		}
		Err(NoMore)
	}

	## Whether some line starts with `name`, then whitespace (any, newlines too), then `=`:
	## JavaScript's `new RegExp(`^${name}\\s*=`, "m")`.
	defines : List(U8), Str -> Bool
	defines = |bytes, name| {
		want = name.to_utf8()
		var $start = 0
		var $more = Bool.True
		while $more {
			if Text.starts_with_at(bytes, want, $start) {
				after = Text.skip_space(bytes, $start + want.len())
				if after < bytes.len() and Text.at(bytes, after) == '=' {
					return Bool.True
				}
			}
			match Routes.next_line_start(bytes, $start) {
				Ok(next) => {
					$start = next
				}
				Err(_) => {
					$more = Bool.False
				}
			}
		}
		Bool.False
	}

	## What `middleware = …` says, as `/^middleware\s*=\s*(.+)$/m` finds it, trimmed.
	middleware_of : List(U8) -> [Some(Str), None]
	middleware_of = |bytes| {
		word = "middleware".to_utf8()
		ends_line = |c| c == '\n' or c == '\r'
		var $start = 0
		var $more = Bool.True
		while $more {
			if Text.starts_with_at(bytes, word, $start) {
				equals = Text.skip_space(bytes, $start + word.len())
				if equals < bytes.len() and Text.at(bytes, equals) == '=' {
					from = equals + 1
					spaced = Text.skip_space(bytes, from)
					# The value starts at the last place in the whitespace (or after it) that isn't a line's end.
					var $k = spaced
					var $found = spaced < bytes.len()
					while !$found and $k > from {
						$k = $k - 1
						if !ends_line(Text.at(bytes, $k)) {
							$found = Bool.True
						}
					}
					if $found {
						var $end = $k
						while $end < bytes.len() and !ends_line(Text.at(bytes, $end)) {
							$end = $end + 1
						}
						return Some(Text.trim(Text.cut(bytes, $k, $end)))
					}
				}
			}
			match Routes.next_line_start(bytes, $start) {
				Ok(next) => {
					$start = next
				}
				Err(_) => {
					$more = Bool.False
				}
			}
		}
		None
	}

	## A doc comment's line without its `##` (and one space after it).
	undoc : Str -> Str
	undoc = |line| {
		bytes = line.to_utf8()
		if (line.starts_with("##")) Text.rest(bytes, 2 + Text.space_at(bytes, 2)) else line
	}

	## The `##` lines right above line `end`, as one text, trimmed.
	comment_above : List(Str), U64 -> Str
	comment_above = |lines, end| {
		var $start = end
		while $start > 0 and (lines.get($start - 1) ?? "").starts_with("##") {
			$start = $start - 1
		}
		Text.trim(Str.join_with(lines.sublist({ start: $start, len: end - $start }).map(Routes.undoc), "\n"))
	}

	## Whether a line starts with `name`, then whitespace, then `:` or `=`.
	line_defines : Str, Str -> Bool
	line_defines = |line, name| {
		bytes = line.to_utf8()
		if line.starts_with(name) {
			after = Text.skip_space(bytes, name.to_utf8().len())
			c = Text.at(bytes, after)
			after < bytes.len() and (c == ':' or c == '=')
		} else {
			Bool.False
		}
	}

	## The definitions a route file has, among `view`, `view!`, `meta`, `middleware`, the methods and
	## a channel's, at the top of the file; what its middleware is, as written; and what each
	## method's comment says.
	definitions : Str -> Defs
	definitions = |source| {
		bytes = source.to_utf8()
		defined = |name| Routes.defines(bytes, name)
		methods = Routes.method_names.keep_if(defined)
		lines = source.split_on("\n")
		first = lines.find_first_index(|line| line.starts_with("##"))
		docs = methods.fold(
			[],
			|so_far, method| {
				above_it =
					match lines.find_first_index(|line| Routes.line_defines(line, method)) {
						Ok(at) => Routes.comment_above(lines, at)
						Err(_) => ""
					}
				doc =
					if !above_it.is_empty() {
						above_it
					} else if methods.len() == 1 {
						match first {
							Ok(top) =>
								match lines.map_with_index(|line, i| { line, i }).find_first(|each| each.i > top and !each.line.starts_with("##")) {
									Ok(after) => Routes.comment_above(lines, after.i)
									Err(_) => ""
								}
							Err(_) => ""
						}
					} else {
						""
					}
				if (doc.is_empty()) so_far else so_far.append({ key: method, value: doc })
			},
		)
		hooks = Routes.channel_hooks.keep_if(defined)
		channel = defined(Routes.channel_name)
		typed = methods.concat(if (channel) [Routes.channel_name] else [])
		{
			view: if (defined("view!")) Some("view!") else if (defined("view")) Some("view") else None,
			meta: defined("meta"),
			methods,
			middleware: Routes.middleware_of(bytes),
			docs,
			respond: defined("respond!"),
			channel: if (channel) Some(hooks) else None,
			hooks: if (channel) [] else hooks,
			handlers: typed.map(|method| Routes.handler_of(lines, method)),
			imported: lines.map(Text.trim).keep_if(|line| line.starts_with("import ")),
		}
	}

	## A method's types, from its annotation in a route file's `lines`: `method : …`, at the start of
	## a line, and the lines after it that are indented.
	handler_of : List(Str), Str -> Handler
	handler_of = |lines, method| {
		defined_at = lines.find_first_index(|line| Routes.line_defines(line, method) and !Routes.annotates(line, method)) ?? 0
		match lines.find_first_index(|line| Routes.annotates(line, method)) {
			Err(_) => { method, line: defined_at + 1, types: Unannotated }
			Ok(at) => {
				first = Text.trim((lines.get(at) ?? "").drop_prefix(method)).drop_prefix(":")
				# The lines after it while a bracket is open (`} => Try(…)` closes a record at the start
				# of its line), or while they are indented.
				var $taken = [first]
				var $depth = Routes.depth_of(first)
				var $next = at + 1
				var $going = Bool.True
				while $going and $next < lines.len() {
					line = lines.get($next) ?? ""
					if $depth > 0 or line.starts_with("\t") or line.starts_with(" ") {
						$taken = $taken.append(Text.trim(line))
						$depth = $depth + Routes.depth_of(line)
						$next = $next + 1
					} else {
						$going = Bool.False
					}
				}
				annotation = Text.trim(Str.join_with($taken.keep_if(|part| !part.is_empty()), " "))
				types =
					match Routes.signature(annotation) {
						Ok(found) => {
							own = Routes.types_defined(lines)
							named = Routes.type_names("${found.body} ${found.answer}").keep_if(|name| own.contains(name))
							if (named.is_empty()) Typed(found) else Defined(named)
						}
						Err(Unreadable(why)) => Unreadable(why)
					}
				{ method, line: defined_at + 1, types }
			}
		}
	}

	## The types a route file defines at its top level (`Thing : { name : Str }`, `Pair(a) : (a, a)`).
	types_defined : List(Str) -> List(Str)
	types_defined = |lines|
		lines.keep_oks(
			|line| {
				bytes = line.to_utf8()
				if bytes.is_empty() or !Text.is_upper(Text.at(bytes, 0)) {
					return Err(NotAType)
				}
				end = Text.run_end(bytes, 0, Text.is_word)
				after_args =
					if Text.at(bytes, end) == '(' {
						match Routes.closing_at(bytes, end) {
							Ok(close) => close + 1
							Err(Unclosed) => return Err(NotAType)
						}
					} else {
						end
					}
				if (Text.at(bytes, Text.skip_space(bytes, after_args)) == ':') Ok(Text.cut(bytes, 0, end)) else Err(NotAType)
			},
		)

	## How many more brackets a line opens than it closes (negative: closes more).
	depth_of : Str -> I64
	depth_of = |line|
		line.to_utf8().fold(
			0,
			|depth, c|
				if c == '{' or c == '(' or c == '[' {
					depth + 1
				} else if c == '}' or c == ')' or c == ']' {
					depth - 1
				} else {
					depth
				},
		)

	## Whether a line annotates `name`: `name`, then whitespace, then `:` (and not `:=`).
	annotates : Str, Str -> Bool
	annotates = |line, name| {
		bytes = line.to_utf8()
		if line.starts_with(name) {
			after = Text.skip_space(bytes, name.to_utf8().len())
			after < bytes.len() and Text.at(bytes, after) == ':' and Text.at(bytes, after + 1) != '='
		} else {
			Bool.False
		}
	}

	## Where the bracket that opens at `open` (`{`, `(` or `[`) closes, past the ones inside it.
	closing_at : List(U8), U64 -> Try(U64, [Unclosed])
	closing_at = |bytes, open| {
		var $depth = 0
		var $i = open
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '{' or c == '(' or c == '[' {
				$depth = $depth + 1
			} else if c == '}' or c == ')' or c == ']' {
				$depth = $depth - 1
				if $depth == 0 {
					return Ok($i)
				}
			}
			$i = $i + 1
		}
		Err(Unclosed)
	}

	## Text split at its commas outside brackets, each part trimmed; empty ones (a trailing comma's) gone.
	top_level_parts : Str -> List(Str)
	top_level_parts = |text| {
		bytes = text.to_utf8()
		var $parts = []
		var $depth = 0
		var $start = 0
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '{' or c == '(' or c == '[' {
				$depth = $depth + 1
			} else if (c == '}' or c == ')' or c == ']') and $depth > 0 {
				$depth = $depth - 1
			} else if c == ',' and $depth == 0 {
				$parts = $parts.append(Text.cut(bytes, $start, $i))
				$start = $i + 1
			}
			$i = $i + 1
		}
		$parts.append(Text.rest(bytes, $start)).map(Text.trim).keep_if(|part| !part.is_empty())
	}

	## A handler's types, from its annotation (what follows its `:`): `{ request : …, params : …,
	## context : …, body : B } => Try(A, …)` is `{ body: "B", answer: "A" }` (`body` is `""` when
	## the record has none).
	signature : Str -> Try({ body : Str, answer : Str }, [Unreadable(Str)])
	signature = |annotation| {
		shape = "its annotation should be a record of what it is given, then => and a Try of its answer: { request : Server.Request, params : …, context : …, body : … } => Try(…, Endpoint.Refusal)"
		bytes = annotation.to_utf8()
		if Text.at(bytes, 0) != '{' {
			return Err(Unreadable(shape))
		}
		close =
			match Routes.closing_at(bytes, 0) {
				Ok(at) => at
				Err(Unclosed) => return Err(Unreadable(shape))
			}
		fields = Routes.top_level_parts(Text.cut(bytes, 1, close))
		body =
			match fields.find_first(|field| field.starts_with("body") and Text.trim(field.drop_prefix("body")).starts_with(":")) {
				Ok(field) => Text.trim(Text.trim(field.drop_prefix("body")).drop_prefix(":"))
				Err(_) => ""
			}
		arrow = Text.trim(Text.rest(bytes, close + 1))
		if !(arrow.starts_with("=>") or arrow.starts_with("->")) {
			return Err(Unreadable(shape))
		}
		answered = Text.trim(arrow.drop_prefix("=>").drop_prefix("->"))
		if !answered.starts_with("Try(") {
			return Err(Unreadable(shape))
		}
		answer_bytes = answered.to_utf8()
		ends =
			match Routes.closing_at(answer_bytes, 3) {
				Ok(at) => at
				Err(Unclosed) => return Err(Unreadable(shape))
			}
		if !Text.trim(Text.rest(answer_bytes, ends + 1)).is_empty() {
			return Err(Unreadable("its annotation has more after its Try(…) than rocx reads (a where clause?): ${shape}"))
		}
		parts = Routes.top_level_parts(Text.cut(answer_bytes, 4, ends))
		if parts.len() == 2 {
			Ok({ body, answer: parts.first() ?? "" })
		} else {
			Err(Unreadable(shape))
		}
	}

	# ---- the names that could be tags ----

	## Every name in Roc code that could be a tag (`Red`, `BadRequest`): a capitalized word outside
	## comments and strings, but not a module's or a type's before a `.`; sorted.
	tag_names : List(Str) -> List(Str)
	tag_names = |codes| {
		var $names = []
		for code in codes {
			for line in code.split_on("\n") {
				trimmed = Text.trim_start(line)
				if !(trimmed.starts_with("\\\\") or trimmed.starts_with("import ")) {
					bytes = line.to_utf8()
					var $bare = []
					var $quoted = Bool.False
					var $i = 0
					var $going = Bool.True
					while $going and $i < bytes.len() {
						c = Text.at(bytes, $i)
						if $quoted {
							if c == '\\' {
								$i = $i + 1
							} else if c == '"' {
								$quoted = Bool.False
							}
						} else if c == '"' {
							$quoted = Bool.True
							$bare = $bare.append(' ')
						} else if c == '#' {
							$going = Bool.False
						} else {
							$bare = $bare.append(c)
						}
						$i = $i + 1
					}
					bare = $bare
					var $j = 0
					while $j < bare.len() {
						c = Text.at(bare, $j)
						if Text.is_upper(c) and ($j == 0 or !Text.is_word(Text.at(bare, $j - 1))) {
							end = Text.run_end(bare, $j + 1, Text.is_word)
							if Text.at(bare, end) != '.' or end >= bare.len() {
								found = Text.cut(bare, $j, end)
								if !$names.contains(found) {
									$names = $names.append(found)
								}
							}
							$j = end
						} else {
							$j = $j + 1
						}
					}
				}
			}
		}
		Text.sorted($names)
	}

	# ---- a route file's module ----

	## What `import …` names, if it names a module by path (`../Ui/Card`): `^import\s+((?:\.{1,2}\/)*
	## (?:[A-Za-z0-9_]+\/)*[A-Z][A-Za-z0-9]*)(.*)$`, with its backtracking.
	import_target : Str -> Try({ target : Str, rest : Str }, [NoMatch])
	import_target = |line| {
		bytes = line.to_utf8()
		if !line.starts_with("import") {
			return Err(NoMatch)
		}
		start = Text.skip_space(bytes, 6)
		if start == 6 {
			return Err(NoMatch)
		}
		# Where each repetition of `(\.{1,2}\/)` ends, then each of `([A-Za-z0-9_]+\/)`.
		var $dots = [start]
		var $p = start
		var $going = Bool.True
		while $going {
			if Text.starts_with_at(bytes, "../".to_utf8(), $p) {
				$p = $p + 3
				$dots = $dots.prepend($p)
			} else if Text.starts_with_at(bytes, "./".to_utf8(), $p) {
				$p = $p + 2
				$dots = $dots.prepend($p)
			} else {
				$going = Bool.False
			}
		}
		for dot_end in $dots {
			var $dirs = [dot_end]
			var $q = dot_end
			var $more = Bool.True
			while $more {
				word_end = Text.run_end(bytes, $q, Text.is_word)
				if word_end > $q and Text.at(bytes, word_end) == '/' {
					$q = word_end + 1
					$dirs = $dirs.prepend($q)
				} else {
					$more = Bool.False
				}
			}
			for dir_end in $dirs {
				if Text.is_upper(Text.at(bytes, dir_end)) {
					name_end = Text.run_end(bytes, dir_end + 1, Text.is_alnum)
					return Ok({ target: Text.cut(bytes, start, name_end), rest: Text.rest(bytes, name_end) })
				}
			}
		}
		Err(NoMatch)
	}

	## `code` with its last line, the marker's (and the blank lines before it), gone:
	## `.replace(/\n*# rocx: generated from[^\n]*\n?$/, "")`.
	without_marker : Str -> Str
	without_marker = |code| {
		bytes = code.to_utf8()
		body_end = if (code.ends_with("\n")) bytes.len() - 1 else bytes.len()
		last_start = Text.line_start(bytes, body_end)
		last = Text.slice(bytes, last_start, body_end)
		match Text.index_of(last, Routes.marker.to_utf8(), 0) {
			Ok(k) => {
				var $start = last_start + k
				if k == 0 {
					while $start > 0 and Text.at(bytes, $start - 1) == '\n' {
						$start = $start - 1
					}
				}
				Text.cut(bytes, 0, $start)
			}
			Err(_) => code
		}
	}

	## Text without the newlines at its end.
	without_trailing_newlines : Str -> Str
	without_trailing_newlines = |text| {
		bytes = text.to_utf8()
		var $end = bytes.len()
		while $end > 0 and Text.at(bytes, $end - 1) == '\n' {
			$end = $end - 1
		}
		Text.cut(bytes, 0, $end)
	}

	## A route file's Roc (what rocx wrote for it), as the module `name` at `generated`: its
	## relative imports made relative to there, the module's line on the blank line after them (at
	## the start of the first definition's line, when there is none), and a `}` after the rest. Its
	## paths are absolute (else taken from `/`).
	route_module : Str, { name : Str, source : Str, generated : Str } -> Try(Str, [Problem(Str)])
	route_module = |code, place| Routes.route_module_in("/", code, place)

	## `route_module`, with relative paths taken from `cwd`.
	route_module_in : Str, Str, { name : Str, source : Str, generated : Str } -> Try(Str, [Problem(Str)])
	route_module_in = |cwd, code, place| {
		source = place.source
		generated = Fs.resolve(cwd, [place.generated])
		var $lines = Routes.without_marker(code).split_on("\n")
		var $blank = 0
		var $has_blank = Bool.False
		var $i = 0
		var $scanning = Bool.True
		while $scanning and $i < $lines.len() {
			line = Text.trim($lines.get($i) ?? "")
			if line.starts_with("import ") {
				match Routes.import_target(line) {
					Ok(imported) =>
						if !Routes.package_name(imported.target) {
							moved = Fs.relative(Fs.dirname(generated), Fs.resolve(cwd, [Fs.dirname(source), imported.target]))
							$lines = $lines.set($i, "import ${moved}${imported.rest}") ?? $lines
						}
					Err(_) => {}
				}
				$has_blank = Bool.False
			} else if line.is_empty() {
				if !$has_blank {
					$blank = $i
					$has_blank = Bool.True
				}
			} else if !line.starts_with("#") {
				$scanning = Bool.False
			}
			if $scanning {
				$i = $i + 1
			}
		}
		# No blank line after the imports (or none at all): the module's line goes at the start of the
		# first definition's, so line N is still line N. A file of imports alone has nothing to open.
		if !$has_blank and $i >= $lines.len() {
			return Err(Problem("${source}: a route file defines its view, meta or methods after its imports"))
		}
		inline = !$has_blank
		blank = if (inline) $i else $blank
		# Where the definitions start: the line after the blank one, or the first definition's.
		body_from = if (inline) blank else blank + 1
		lines = $lines
		line_at = |i| lines.get(i) ?? ""
		own = |i| Routes.is_component_line(line_at(i))
		top_level = |i| {
			bytes = line_at(i).to_utf8()
			c = Text.at(bytes, 0)
			!bytes.is_empty() and Text.space_at(bytes, 0) == 0 and c != '#' and c != '}' and c != ')' and c != ']'
		}
		var $first = 0
		var $has_first = Bool.False
		var $last = 0
		var $owned = []
		var $k = body_from
		while $k < lines.len() {
			if own($k) {
				$owned = $owned.append($k)
			} else if top_level($k) {
				if !$has_first {
					$first = $k
					$has_first = Bool.True
				} else {
					first_now = $first
					k_now = $k
					match $owned.find_first(|at| at > first_now and at < k_now) {
						Ok(between) => {
							named = Routes.first_word(line_at(between))
							return Err(Problem("${source}:${(k_now + 1).to_str()}: put the file's own components (${named}) before its definitions or after them, not between: the page's module is the lines between them"))
						}
						Err(_) => {}
					}
				}
				$last = $k
			}
			$k = $k + 1
		}
		owned0 = $owned
		first = $first
		last = $last
		# The file's own definitions (the page module's), which its components see: each component's
		# line names those it uses as its own (`Asked := [].{ answered = HostCodePage.answered`), so
		# line N here is still line N there.
		var $page_names = []
		var $p = first
		while $has_first and $p <= last {
			if top_level($p) and !own($p) {
				match Routes.defined_name(line_at($p)) {
					Some(name) => {
						if !$page_names.contains(name) {
							$page_names = $page_names.append(name)
						}
					}
					None => {}
				}
			}
			$p = $p + 1
		}
		page_names = $page_names
		var $aliased = lines
		if !page_names.is_empty() {
			for at in owned0 {
				# The component's lines: to its closing `}`, or to what comes next at the top level.
				var $end = at + 1
				var $closed = Bool.False
				while !$closed and $end < lines.len() and !own($end) and !top_level($end) {
					if line_at($end).starts_with("}") {
						$closed = Bool.True
					}
					$end = $end + 1
				}
				body = Str.join_with(lines.sublist({ start: at, len: $end - at }), "\n")
				$aliased = $aliased.set(at, Routes.with_aliases(line_at(at), body, page_names, place.name)) ?? $aliased
			}
		}
		aliased = $aliased
		owned = owned0
		from = Fs.relative(Fs.dirname(generated), Fs.resolve(cwd, [source]))
		ending = "${Routes.marker} ${from}: edit that file, not this one. Line N here is line N there.\n"
		opening_line = "${place.name} := [].{"
		# The module's line on the line `at`: alone on a blank one, or before a definition on its own.
		open_at = |at, before|
			if before {
				aliased.set(at, "${opening_line} ${line_at(at)}") ?? aliased
			} else {
				aliased.set(at, opening_line) ?? aliased
			}
		if owned.is_empty() {
			done = open_at(blank, inline)
			return Ok("${Routes.without_trailing_newlines(Str.join_with(done, "\n"))}\n}\n\n${ending}")
		}
		if !$has_first {
			return Err(Problem("${source}: a route file defines its view, meta or methods, beside its own components"))
		}
		comment_start = |at| {
			var $at = at
			while $at > 0 and line_at($at - 1).starts_with("#") {
				$at = $at - 1
			}
			$at
		}
		var $opening = blank
		var $opening_inline = inline
		if owned.any(|at| at < first) {
			# On the blank line after the components, or else at the start of the first definition's.
			var $found = Bool.False
			var $j = comment_start(first)
			while !$found and $j > body_from {
				$j = $j - 1
				if Text.trim(line_at($j)).is_empty() {
					$opening = $j
					$found = Bool.True
				}
			}
			opening_now = $opening
			if !$found or owned.any(|at| at > opening_now and at < first) {
				$opening = first
				$opening_inline = Bool.True
			} else {
				$opening_inline = Bool.False
			}
		}
		opened = open_at($opening, $opening_inline)
		after = owned.keep_if(|at| at > last).sort_with(|a, b| if (a < b) Before else if (a > b) After else Same)
		match after.first() {
			Err(_) => Ok("${Routes.without_trailing_newlines(Str.join_with(opened, "\n"))}\n}\n\n${ending}")
			Ok(next) => {
				start = comment_start(next)
				var $closing = 0
				var $closes = Bool.False
				var $j = start
				while !$closes and $j > last + 1 {
					$j = $j - 1
					if Text.trim(opened.get($j) ?? "").is_empty() {
						$closing = $j
						$closes = Bool.True
					}
				}
				closed =
					if $closes {
						opened.set($closing, "}") ?? opened
					} else {
						opened.set(start, "} ${opened.get(start) ?? ""}") ?? opened
					}
				Ok("${Routes.without_trailing_newlines(Str.join_with(closed, "\n"))}\n\n${ending}")
			}
		}
	}

	## Whether an import's target names a package's module (`pf.`): `^[a-z_][a-z0-9_]*\.`.
	package_name : Str -> Bool
	package_name = |target| {
		bytes = target.to_utf8()
		c = Text.at(bytes, 0)
		if Text.is_lower(c) or c == '_' {
			end = Text.run_end(bytes, 1, |b| Text.is_lower(b) or Text.is_digit(b) or b == '_')
			Text.at(bytes, end) == '.' and end < bytes.len()
		} else {
			Bool.False
		}
	}

	## Whether a line defines a type of the file's own (`Board := [].{`, `Pair(a) :=`).
	is_component_line : Str -> Bool
	is_component_line = |line| {
		bytes = line.to_utf8()
		if !Text.is_upper(Text.at(bytes, 0)) {
			return Bool.False
		}
		name_end = Text.run_end(bytes, 1, Text.is_word)
		after_args =
			if Text.at(bytes, name_end) == '(' {
				match Text.index_of_byte(bytes, ')', name_end) {
					Ok(close) =>
						if (Text.slice(bytes, name_end, close).contains('\n')) name_end else close + 1
					Err(_) => name_end
				}
			} else {
				name_end
			}
		at = Text.run_end(bytes, after_args, |b| b == ' ' or b == '\t')
		Text.starts_with_at(bytes, ":=".to_utf8(), at)
	}

	## The name a line defines or annotates, from its start (`helper = …`, `beat! : …`):
	## `^[a-z_][A-Za-z0-9_]*!?\s*(=|:)`, not `==` or `=>`.
	defined_name : Str -> [Some(Str), None]
	defined_name = |line| {
		bytes = line.to_utf8()
		c = Text.at(bytes, 0)
		if !(Text.is_lower(c) or c == '_') {
			return None
		}
		word_end = Text.run_end(bytes, 1, Text.is_word)
		end = if (Text.at(bytes, word_end) == '!') word_end + 1 else word_end
		after = Text.run_end(bytes, end, |b| b == ' ' or b == '\t')
		d = Text.at(bytes, after)
		next = Text.at(bytes, after + 1)
		if d == ':' or (d == '=' and next != '=' and next != '>') {
			Some(Text.cut(bytes, 0, end))
		} else {
			None
		}
	}

	## A component's line (`Asked := [].{`) with the file's definitions its lines use (`body`, the
	## line first) named as its own, after its `.{`: ` answered = HostCodePage.answered`. Not those it
	## binds itself, as a definition, a lambda's parameter, a `for`'s or a match arm's pattern: the
	## file's name would be one Roc says is defined twice.
	with_aliases : Str, Str, List(Str), Str -> Str
	with_aliases = |line, body, page_names, module_name| {
		bytes = line.to_utf8()
		code = Transpile.code_only(bytes)
		match Text.index_of(code, ":=".to_utf8(), 0) {
			Err(_) => line
			Ok(declared) =>
				match Text.index_of(code, ".{".to_utf8(), declared) {
					Err(_) => line
					Ok(opens) => {
						names = Routes.names_in(Transpile.code_only(body.to_utf8()))
						wanted = page_names.keep_if(|name| names.used.contains(name) and !names.bound.contains(name))
						if wanted.is_empty() {
							line
						} else {
							aliases = Str.join_with(wanted.map(|name| " ${name} = ${module_name}.${name}"), "")
							"${Text.cut(bytes, 0, opens + 2)}${aliases}${Text.rest(bytes, opens + 2)}"
						}
					}
				}
		}
	}

	## The lower-case names in some code (Transpile.code_only's), a line at a time: those it binds
	## (before a definition's `=`, a lambda's parameters between its bars, after `for`, before a match
	## arm's `=>`) and those it uses (any other, but a field's or a module's member after a `.`, and a
	## record's field or an annotation's name before a `:`).
	names_in : List(U8) -> { used : List(Str), bound : List(Str) }
	names_in = |code| {
		var $used = []
		var $bound = []
		for text in Str.from_utf8_lossy(code).split_on("\n") {
			line = text.to_utf8()
			# Where the line's definition's `=` is (not `==`, `!=`, `<=`, `>=`, `:=` or `=>`), and its
			# arm's `=>`: 0 when it has none.
			var $eq = 0
			var $arrow = 0
			var $k = 0
			while $k < line.len() {
				if Text.at(line, $k) == '=' {
					before = if ($k == 0) ' ' else Text.at(line, $k - 1)
					after = Text.at(line, $k + 1)
					if after == '>' {
						if $arrow == 0 {
							$arrow = $k
						}
					} else if $eq == 0 and after != '=' and before != '=' and before != '!' and before != '<' and before != '>' and before != ':' {
						$eq = $k
					}
				}
				$k = $k + 1
			}
			eq = $eq
			arrow = $arrow
			var $bars = 0
			var $i = 0
			while $i < line.len() {
				c = Text.at(line, $i)
				previous = if ($i == 0) ' ' else Text.at(line, $i - 1)
				if c == '|' {
					$bars = $bars + 1
					$i = $i + 1
				} else if (Text.is_lower(c) or c == '_') and !Text.is_word(previous) and previous != '.' and previous != '$' {
					word_end = Text.run_end(line, $i + 1, Text.is_word)
					end = if (Text.at(line, word_end) == '!') word_end + 1 else word_end
					name = Text.cut(line, $i, end)
					var $back = $i
					while $back > 0 and Text.at(line, $back - 1) == ' ' {
						$back = $back - 1
					}
					after_for = $back >= 3 and Text.cut(line, $back - 3, $back) == "for" and ($back == 3 or !Text.is_word(Text.at(line, $back - 4)))
					binds = $i < eq or $i < arrow or $bars % 2 == 1 or after_for
					next = Text.at(line, Text.run_end(line, end, |b| b == ' ' or b == '\t'))
					if binds {
						if !$bound.contains(name) {
							$bound = $bound.append(name)
						}
					} else if next != ':' and !$used.contains(name) {
						$used = $used.append(name)
					}
					$i = end
				} else if Text.is_word(c) {
					$i = Text.run_end(line, $i + 1, Text.is_word)
				} else {
					$i = $i + 1
				}
			}
		}
		{ used: $used, bound: $bound }
	}

	## A line's first word: up to a space, a tab, `(` or `:`.
	first_word : Str -> Str
	first_word = |line| {
		bytes = line.to_utf8()
		Text.cut(bytes, 0, Text.run_end(bytes, 0, |b| b != ' ' and b != '\t' and b != '(' and b != ':'))
	}

	# ---- what the routes are written as ----

	## An endpoint's name in Api: its method and its path's (`post_blog`, `get_blog_slug`).
	api_name : Str, Str -> Str
	api_name = |method, name| "${method.replace_first("!", "")}_${name}"

	## The URL of a path, its params put in, as a Roc string literal.
	url_of : List(Str) -> Str
	url_of = |parts| Text.json_string("/${Str.join_with(parts.map(|part| if (part.starts_with("[")) "\${Server.encode_segment(params.${part.drop_prefix("[").drop_suffix("]")})}" else part), "/")}")

	## A path as OpenAPI writes it, its params in braces (`/blog/{slug}`).
	open_api_path : List(Str) -> Str
	open_api_path = |parts| "/${Str.join_with(parts.map(|part| if (part.starts_with("[")) "{${part.drop_prefix("[").drop_suffix("]")}}" else part), "/")}"

	## What a path's segments are checked against, as Roc.
	matched_by : List(Str), List(Param) -> Str
	matched_by = |parts, params|
		if params.is_empty() {
			"segments == [${Str.join_with(parts.map(Text.json_string), ", ")}]"
		} else {
			fixed = parts.map_with_index(|part, i| { part, i }).keep_if(|each| !each.part.starts_with("[")).map(|each| "segments.get(${each.i.to_str()}) == Ok(${Text.json_string(each.part)})")
			Str.join_with(["segments.len() == ${parts.len().to_str()}"].concat(fixed), " and ")
		}

	## A path's params, read from its segments, as Roc.
	params_of : List(Param) -> Str
	params_of = |params| if (params.is_empty()) "{}" else "{ ${Str.join_with(params.map(|param| "${param.name}: segments.get(${param.at.to_str()}) ?? \"\""), ", ")} }"

	## Whether the app has pages (a page, or its error page).
	has_pages : Table -> Bool
	has_pages = |table|
		!table.pages.is_empty()
			or (
				match table.error {
					Some(_) => Bool.True
					None => Bool.False
				}
			)

	## What is wrong with an app's route files' views, a line each.
	view_problems : Table, List(Source) -> List(Str)
	view_problems = |table, sources| {
		errors =
			match table.error {
				Some(error) => [{ file: error.file, kind: error.kind }]
				None => []
			}
		checked = table.pages.map(|entry| { file: entry.file, kind: entry.kind }).concat(table.layouts.map(|layout| { file: layout.file, kind: layout.kind })).concat(errors)
		checked
			.keep_if(|entry| Routes.defs_of(sources, entry.file).view != Some("view!"))
			.map(
				|entry| {
					takes = if (entry.kind == "page") "view! = |{ params }| …" else if (entry.kind == "layout") "view! = |{ meta, children, params }| …" else "view! = |{ status, problem }| …"
					what = if (entry.kind == "error") "an error page" else "a ${entry.kind}"
					"routes/${entry.file}: ${what} is a component, which defines view!: `${takes}`"
				},
			)
	}

	## Whether `word` is in `text` as a word of its own (`\bword\b`).
	has_word : Str, Str -> Bool
	has_word = |text, word| {
		bytes = text.to_utf8()
		want = word.to_utf8()
		var $from = 0
		var $more = Bool.True
		while $more {
			match Text.index_of(bytes, want, $from) {
				Ok(at) => {
					before = at == 0 or !Text.is_word(Text.at(bytes, at - 1))
					end = at + want.len()
					after = end >= bytes.len() or !Text.is_word(Text.at(bytes, end))
					if before and after {
						return Bool.True
					}
					$from = at + 1
				}
				Err(_) => {
					$more = Bool.False
				}
			}
		}
		Bool.False
	}

	## `Routes.pattern`'s lines.
	pattern_body : Table, Bool -> List(Str)
	pattern_body = |table, storied| {
		arms = table.paths.map(|at| { condition: Routes.matched_by(at.parts, at.params), route: Text.json_string(at.path) }).concat(if (storied) [{ condition: "path == ${Text.json_string(Routes.stories_path)} or path.starts_with(${Text.json_string("${Routes.stories_path}/")})", route: Text.json_string(Routes.stories_path) }] else [])
		if arms.is_empty() {
			["\tpattern = |_path| \"\""]
		} else {
			chain = Str.join_with(arms.map_with_index(|arm, i| "${if (i > 0) " else " else ""}if (${arm.condition}) {\n\t\t\t${arm.route}\n\t\t}"), "")
			["\tpattern = |path| {"]
				.concat(if (table.paths.is_empty()) [] else ["\t\tsegments = path.split_on(\"/\").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)"])
				.concat(["\t\t${chain} else {\n\t\t\t\"\"\n\t\t}", "\t}"])
		}
	}

	## The routes a path answers with, around `answer`: behind the file's middleware if it names one.
	guarded : List(Source), Entry, (Str, Str -> Str) -> Str
	guarded = |sources, entry, answer|
		if Routes.guards(sources, entry.file) {
			"Middleware.run!(${entry.module_name}.middleware, request, context, |passed, handed| ${answer("passed", "handed")})"
		} else {
			answer("request", "context")
		}

	## The server entry of a path (one is there when this is called).
	server_of : At -> Entry
	server_of = |at|
		match at.server {
			Some(entry) => entry
			None => { file: "", kind: "server", parts: [], module_name: "", name: "", path: "", params: [], layouts: [] }
		}

	## `Generated/Routes.roc`: the answer to a request.
	routes_module : Table, List(Source), [Some(List(Placed)), None] -> Str
	routes_module = |table, sources, stories| {
		pages = Routes.has_pages(table)
		page_answer = |entry| if (Routes.guards(sources, entry.file)) "Middleware.run!(${entry.module_name}.middleware, request, context, |_passed, _handed| Routes.page(200))" else "Routes.page(200)"
		endpoint = |at, method| Routes.guarded(sources, Routes.server_of(at), |request, context| "Endpoint.${if (method == "events!") "stream!" else "respond!"}(Handlers.${Routes.api_name(method, at.name)}(params), ${request}, ${context})")
		branch = |at| {
			condition = Routes.matched_by(at.parts, at.params)
			params = Routes.params_of(at.params)
			server_defs =
				match at.server {
					Some(server) => Some(Routes.defs_of(sources, server.file))
					None => None
				}
			methods =
				match server_defs {
					Some(defs) => defs.methods
					None => []
				}
			page_get =
				match at.page {
					Some(_) => ["GET"]
					None => []
				}
			allowed = Text.unique(page_get.concat(methods.map(Routes.verb_of)))
			respond =
				match server_defs {
					Some(defs) => defs.respond
					None => Bool.False
				}
			gets =
				(
					match at.page {
						Some(page) => [{ accepts: "wants_html", then: page_answer(page) }]
						None => []
					}
				)
					.concat(if (methods.contains("events!")) [{ accepts: "wants_events", then: endpoint(at, "events!") }] else [])
					.concat(if (methods.contains("get!")) [{ accepts: "", then: endpoint(at, "get!") }] else [])
			get_arms = gets.map_with_index(|get, i| { test: if (!get.accepts.is_empty() and (i + 1 < gets.len() or respond)) "method == \"GET\" and ${get.accepts}" else "method == \"GET\"", then: get.then })
			other_arms = methods.keep_if(|method| Routes.verb_of(method) != "GET").map(|method| { test: "method == ${Text.json_string(Routes.verb_of(method))}", then: endpoint(at, method) })
			server = Routes.server_of(at)
			last_arm =
				if respond {
					Routes.guarded(sources, server, |request, context| "${server.module_name}.respond!({ request: ${request}, params: params, context: ${context} })")
				} else {
					"Endpoint.not_allowed(request, [${Str.join_with(allowed.map(Text.json_string), ", ")}])"
				}
			arms = get_arms.concat(other_arms).append({ test: "", then: last_arm })
			dispatch = Str.join_with(
				arms.map_with_index(
					|arm, i|
						if !arm.test.is_empty() {
							"${if (i > 0) " else " else ""}if (${arm.test}) {\n\t\t\t\t${arm.then}\n\t\t\t}"
						} else if i > 0 {
							" else {\n\t\t\t\t${arm.then}\n\t\t\t}"
						} else {
							arm.then
						},
				),
				"",
			)
			reads = !methods.is_empty() or respond
			Str.join_with(["if (${condition}) {"].concat(if (reads) ["\t\t\tparams = ${params}"] else []).concat(["\t\t\t${dispatch}", "\t\t}"]), "\n")
		}
		missing = if (pages) "if (wants_html) {\n\t\t\tRoutes.page(404)\n\t\t} else {\n\t\t\tRoutes.text(404, \"nothing at \${request.path}\")\n\t\t}" else "Routes.text(404, \"nothing at \${request.path}\")"
		modules = Text.sorted(
			table.pages
				.keep_if(|entry| Routes.guards(sources, entry.file))
				.concat(table.servers.keep_if(|entry| Routes.guards(sources, entry.file) or Routes.defs_of(sources, entry.file).respond or !Routes.hooks_of(sources, entry.file).is_empty()))
				.map(|entry| entry.module_name),
		)
		channels = table.paths.keep_if(
			|at|
				match at.server {
					Some(server) => Routes.has_channel(sources, server.file)
					None => Bool.False
				},
		)
		hooked = |at, hook| Routes.hooks_of(sources, Routes.server_of(at).file).contains(hook)
		channel_arm = |at| {
			server = Routes.server_of(at)
			channel = "Api.${Routes.api_name(Routes.channel_name, at.name)}(params)"
			opened = if (hooked(at, "on_open!")) "|who, tab| ${server.module_name}.on_open!({ params: params, who: who, tab: tab, channel: ${channel} })" else "|_who, _tab| []"
			received =
				if hooked(at, "receive!") {
					"Endpoint.receiving(${channel}, |who, tab, said| ${server.module_name}.receive!({ params: params, who: who, tab: tab, said: said, channel: ${channel} }))"
				} else {
					"|_who, _tab, _said| Err(Status(404, ${Text.roc_string("${at.path} takes nothing pages say: its route has no receive!")}))"
				}
			closes = if (hooked(at, "on_close!")) "Bool.True" else "Bool.False"
			answer = |request, context| "Endpoint.channel!(Handlers.${Routes.api_name(Routes.channel_name, at.name)}(params), ${request}, ${context}, { opened!: ${opened}, received!: ${received}, closes: ${closes} })"
			Str.join_with(["if (${Routes.matched_by(at.parts, at.params)}) {", "\t\t\tparams = ${Routes.params_of(at.params)}", "\t\t\t${Routes.guarded(sources, server, answer)}", "\t\t}"], "\n")
		}
		no_channel = "Routes.text(404, \"no channel at \${request.path}\")"
		channel_function =
			if channels.is_empty() {
				[]
			} else {
				[
					"\t## A channel's subscription, as the host asks about it (`/rocx/live`; `x-rocx-channel` says",
					"\t## what): its check, behind its route file's middleware, then its hooks. 404 where no channel is.",
					"\tchannel! = |segments, request, context| {",
					"\t\t${Str.join_with(channels.map(channel_arm), " else ")} else {\n\t\t\t${no_channel}\n\t\t}",
					"\t}",
					"",
				]
			}
		closing = channels.keep_if(|at| hooked(at, "on_close!"))
		closed_arm = |at| {
			server = Routes.server_of(at)
			channel = "Api.${Routes.api_name(Routes.channel_name, at.name)}(params)"
			Str.join_with(
				[
					"if (${Routes.matched_by(at.parts, at.params)}) {",
					"\t\t\tparams = ${Routes.params_of(at.params)}",
					"\t\t\tEndpoint.closed!(${channel}, request, |who, tab, why| ${server.module_name}.on_close!({ params: params, who: who, tab: tab, why: why, channel: ${channel} }))",
					"\t\t}",
				],
				"\n",
			)
		}
		closed_function =
			if closing.is_empty() {
				["\tclosed! = |_request| Server.response(204, [], \"\")"]
			} else {
				[
					"\tclosed! = |request| {",
					"\t\tsegments = request.path.split_on(\"/\").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)",
					"\t\t${Str.join_with(closing.map(closed_arm), " else ")} else {\n\t\t\tServer.response(204, [], \"\")\n\t\t}",
					"\t}",
				]
			}
		storied =
			match stories {
				Some(_) => Bool.True
				None => Bool.False
			}
		told =
			match stories {
				Some(list) => list
				None => []
			}
		story_branch = Str.join_with(
			[
				"if (request.path == ${Text.json_string(Routes.stories_path)} or request.path.starts_with(${Text.json_string("${Routes.stories_path}/")})) {",
				"\t\t\tRoutes.story(request.path.drop_prefix(${Text.json_string(Routes.stories_path)}).drop_prefix(\"/\"), request)",
				"\t\t}",
			],
			"\n",
		)
		story_function =
			if storied {
				[
					"\t## A dev build's stories (`<story>` in a component's block; rocx build --dev): the catalog at",
					"\t## ${Routes.stories_path}, and each story at ${Routes.stories_path}/<id>, in the root layout (`Root`).",
					"\tstory = |id, request| {",
					"\t\tif (id == \"\") {",
					"\t\t\tServer.response(200, [{ name: \"content-type\", value: \"text/html; charset=utf-8\" }], Stories.catalog)",
				]
					.concat(told.join_map(|story| ["\t\t} else if (id == ${Text.json_string(story.id)}) {", "\t\t\tRoutes.page(200)"]))
					.concat([
						"\t\t} else {",
						"\t\t\tRoutes.text(404, \"no story at \${request.path}\")",
						"\t\t}",
						"\t}",
						"",
					])
			} else {
				[]
			}
		asked = Str.join_with(["if (Endpoint.channel_asked(request) != \"\") {", "\t\t\t${if (channels.is_empty()) no_channel else "Routes.channel!(segments, request, context)"}", "\t\t}"], "\n")
		answers = |at|
			match at.page {
				Some(_) => Bool.True
				None =>
					match at.server {
						Some(server) => {
							defs = Routes.defs_of(sources, server.file)
							!defs.methods.is_empty() or defs.respond
						}
						None => Bool.False
					}
			}
		branches = [asked].concat(table.paths.keep_if(answers).map(branch)).concat(if (storied) [story_branch] else [])
		uses_middleware = Routes.routed_files(table).any(|file| Routes.guards(sources, file))
		context_name = if (branches.any(|each| Routes.has_word(each, "context"))) "context" else "_context"
		chained = if (branches.is_empty()) "\t\t${missing}" else "\t\t${Str.join_with(branches, " else ")} else {\n\t\t\t${missing.replace_each("\n", "\n\t")}\n\t\t}"
		wants_html = branches.any(|each| each.contains("wants_html")) or missing.contains("wants_html")
		wants_events = branches.any(|each| each.contains("wants_events"))
		# Api for the channels' hooks (each is given its channel), Handlers for what answers.
		named = |prefix| branches.concat(channel_function).concat(closed_function).any(|each| each.contains(prefix))
		lines =
			[
				"## Written by rocx build from the app's routes/: a page for each +page.rocx, in the +layout.rocx",
				"## files above it; the endpoints and channels each +server.rocx has; and +error.rocx where nothing",
				"## is. Edit those files, not this one.",
				"import pf.Server",
			]
				.concat(if (branches.any(|each| each.contains("Endpoint."))) ["import pf.Endpoint"] else [])
				.concat(if (uses_middleware) ["import pf.Middleware"] else [])
				.concat(if (named("Api.")) ["import Api"] else [])
				.concat(if (named("Handlers.")) ["import Handlers"] else [])
				.concat(if (pages) ["import ${Routes.root_name}"] else [])
				.concat(modules.map(|module_name| "import ${module_name}"))
				.concat(if (storied) ["import Stories"] else [])
				.concat([
					"",
					"Routes := [].{",
					"\t## The answer to `request` (a `Server.Request`): a page, in its layouts, for a browser's GET; an",
					"\t## endpoint's answer for its method; a channel's, for the host's asks about its subscriptions",
					"\t## (`channel!`); the error page (404) where nothing is. A file that names its `middleware` has it",
					"\t## run around its page, endpoints and channel. `context` is what the app's middleware handed on:",
					"\t## each page, layout, endpoint and channel is given it (or what its own middleware hands on).",
					"\trespond! = |request, ${context_name}| {",
					"\t\tsegments = request.path.split_on(\"/\").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)",
					"\t\tmethod = if (request.method == \"HEAD\") \"GET\" else request.method",
				])
				.concat(if (wants_html) ["\t\twants_html = (Server.header(request, \"accept\") ?? \"\").contains(\"text/html\")"] else [])
				.concat(if (wants_events) ["\t\twants_events = (Server.header(request, \"accept\") ?? \"\").contains(\"text/event-stream\")"] else [])
				.concat([chained, "\t}", ""])
				.concat(
					if pages {
						[
							"\t## The app's page (`Root`), which the host renders for the request, every hole run once, as a",
							"\t## document for the browser to hydrate: the page at the request's path, in its layouts, or the",
							"\t## error page.",
							"\tpage : U16 -> Server.Response",
							"\tpage = |status| { status: status, headers: [], body: Page(${Routes.root_name}.view!) }",
							"",
						]
					} else {
						[]
					},
				)
				.concat(story_function)
				.concat([
					"\t## The route that answers `path`, as its route file's directory names it (`/blog/[slug]`): what",
					"\t## `Server.Request`'s `route` is; a dev build's stories, their path; `\"\"` where nothing is.",
					"\tpattern : Str -> Str",
				])
				.concat(Routes.pattern_body(table, storied))
				.concat([""])
				.concat(Routes.claims_lines(table, sources))
				.concat([""])
				.concat(channel_function)
				.concat([
					"\t## A channel's subscription has ended, as the host tells it (`x-rocx-channel: close`): its route's",
					"\t## `on_close!`, outside the middleware (`App` answers it so). 204 where there is none.",
				])
				.concat(closed_function)
				.concat([
					"",
					"\ttext : U16, Str -> Server.Response",
					"\ttext = |status, body| Server.response(status, [{ name: \"content-type\", value: \"text/plain; charset=utf-8\" }], body)",
					"}",
					"",
					"${Routes.marker} the routes: rocx build writes it.",
					"",
				])
		Str.join_with(lines, "\n")
	}

	## The server's `Api.openapi`: the OpenAPI document of the endpoints.
	open_api_document : Table, List(Source), List(Str), Str -> List(Str)
	open_api_document = |table, sources, tags, title| {
		operation = |verb, doc, body, contents| "OpenApi.operation(${Text.roc_string(verb)}, ${Text.roc_string(doc)}, ${body}, [${Str.join_with(contents, ", ")}])"
		documented = table.paths.keep_if(
			|at|
				match at.server {
					Some(server) => !Routes.defs_of(sources, server.file).methods.is_empty()
					None => Bool.False
				},
		)
		paths = documented.map(
			|at| {
				server = Routes.server_of(at)
				defs = Routes.defs_of(sources, server.file)
				methods = defs.methods
				doc_of = |method|
					match defs.docs.find_first(|doc| doc.key == method) {
						Ok(doc) => doc.value
						Err(_) => ""
					}
				params = if (at.params.is_empty()) "{}" else "{ ${Str.join_with(at.params.map(|param| "${param.name}: \"\""), ", ")} }"
				call = |method| "Api.${Routes.api_name(method, server.name)}(${params})"
				gets = methods.keep_if(|method| Routes.verb_of(method) == "GET")
				get_operation =
					if gets.is_empty() {
						[]
					} else {
						[operation("get", Str.join_with(gets.map(doc_of).keep_if(|doc| !doc.is_empty()), "\n\n"), "\"\"", gets.map(|method| "OpenApi.${if (method == "events!") "events" else "answer"}(${call(method)}, tags)"))]
					}
				others = methods.keep_if(|method| Routes.verb_of(method) != "GET").map(
					|method| {
						verb = Routes.verb_of(method)
						takes = verb == "POST" or verb == "PUT" or verb == "PATCH"
						operation(Text.lower(verb), doc_of(method), if (takes) "OpenApi.body(${call(method)}, tags)" else "\"\"", ["OpenApi.answer(${call(method)}, tags)"])
					},
				)
				["\t\t\tOpenApi.path(${Text.roc_string(Routes.open_api_path(at.parts))}, [${Str.join_with(at.params.map(|param| Text.roc_string(param.name)), ", ")}], ["]
					.concat(get_operation.concat(others).map(|each| "\t\t\t\t${each},"))
					.append("\t\t\t]),")
			},
		)
		tag_lines = tags.map(Text.roc_string).fold(
			[],
			|so_far, name|
				match so_far.last() {
					Ok(last) if Text.length(last) + Text.length(name) <= 100 => so_far.drop_last(1).append("${last}, ${name}")
					_ => so_far.append(name)
				},
		)
		[
			"\t## The OpenAPI document of these endpoints, which the server answers `GET /openapi.json` with if",
			"\t## the app says (`App.program`'s `openapi`):",
			"\t## each path and its methods, with what their comments say, and the JSON Schemas of what each is",
			"\t## sent and answers, from their types (`OpenApi`). `tags` is every name in the app's code that",
			"\t## could be a tag: a tag union's schema has the ones that are its.",
			"\topenapi : Str",
			"\topenapi = {",
			if (tag_lines.is_empty()) "\t\ttags = []" else "\t\ttags = [\n${Str.join_with(tag_lines.map(|line| "\t\t\t${line},"), "\n")}\n\t\t]",
			"\t\tOpenApi.document(${Text.roc_string(title)}, [",
		]
			.concat(paths.join_map(|each| each))
			.concat(["\t\t])", "\t}"])
	}

	## The handler a route file's `method` has, if it has one (a source made by hand may not).
	handler_in : List(Source), Str, Str -> [Some(Handler), None]
	handler_in = |sources, file, method|
		match Routes.defs_of(sources, file).handlers.find_first(|handler| handler.method == method) {
			Ok(handler) => Some(handler)
			Err(_) => None
		}

	## The method's verb in Api: its HTTP method's, or `CHANNEL`.
	contract_verb : Str -> Str
	contract_verb = |method| if (method == Routes.channel_name) "CHANNEL" else Routes.verb_of(method)

	## Whether a verb's requests have a body (the handler's `body`).
	takes_body : Str -> Bool
	takes_body = |verb| verb == "POST" or verb == "PUT" or verb == "PATCH"

	## What an endpoint is sent and what it answers, as Api's types: its handler's `body` (`{}` for a
	## method without one) and its answer. None for a handler rocx can't read the types of.
	contract_types : List(Source), Entry, Str -> [Some({ arg : Str, answer : Str }), None]
	contract_types = |sources, server, method|
		match Routes.handler_in(sources, server.file, method) {
			Some(handler) =>
				match handler.types {
					Typed(types) => Some({ arg: if (Routes.takes_body(Routes.contract_verb(method)) and !types.body.is_empty()) types.body else "{}", answer: types.answer })
					_ => None
				}
			None => None
		}

	## The record of a route's params, as a type: `{ board : Str, card : Str }`, or `{}`.
	params_type : List(Param) -> Str
	params_type = |params| if (params.is_empty()) "{}" else "{ ${Str.join_with(params.map(|param| "${param.name} : Str"), ", ")} }"

	## An endpoint's or a channel's lines in Api: its comment, its type (from its handler's: its
	## params to an endpoint of any context, the handler's body and its answer) and its contract,
	## its method and URL. The browser's copy is the same.
	contract_lines : List(Source), Entry, Str -> List(Str)
	contract_lines = |sources, server, method| {
		verb = Routes.contract_verb(method)
		name = Routes.api_name(method, server.name)
		comment =
			if method == Routes.channel_name {
				"The channel at ${server.path}, from routes/${server.file} (`Endpoint.subscribe!`, `Endpoint.publish!`)"
			} else if method == "events!" {
				"${verb} ${server.path}, its events (`Endpoint.listen!`), from routes/${server.file}"
			} else {
				"${verb} ${server.path}, from routes/${server.file}"
			}
		annotation =
			match Routes.contract_types(sources, server, method) {
				Some(types) => ["\t${name} : ${Routes.params_type(server.params)} -> Endpoint(context, ${types.arg}, ${types.answer})"]
				None => []
			}
		takes_params = if (server.params.is_empty()) "_params" else "params"
		["\t## ${comment}"].concat(annotation).concat(["\t${name} = |${takes_params}| Endpoint.remote(${Text.json_string(verb)}, ${Routes.url_of(server.parts)})", ""])
	}

	## A route file's methods with endpoints in Api, then its channel (`channel!`), if it has one.
	contracted : List(Source), Entry -> List(Str)
	contracted = |sources, server| Routes.defs_of(sources, server.file).methods.concat(if (Routes.has_channel(sources, server.file)) [Routes.channel_name] else [])

	## An import line's parts: what it names (`../../Board`, `pf.Channel`), the name the file calls it
	## by (its last part, or what follows `as`), and what it exposes (`exposing [Card, Column]`).
	import_parts : Str -> { target : Str, alias : Str, exposed : List(Str) }
	import_parts = |line| {
		bytes = line.to_utf8()
		start = Text.skip_space(bytes, 6)
		end = Text.run_end(bytes, start, |b| b != ' ' and b != '\t')
		target = Text.cut(bytes, start, end)
		rest = Text.rest(bytes, end)
		last = (target.split_on("/").last() ?? target).split_on(".").last() ?? target
		alias =
			match rest.split_first(" as ") {
				Ok({ after, .. }) => {
					named = Text.trim_start(after).to_utf8()
					Text.cut(named, 0, Text.run_end(named, 0, Text.is_word))
				}
				Err(_) => last
			}
		exposed =
			match rest.split_first("exposing") {
				Ok({ after, .. }) => {
					inside = Text.trim(after).drop_prefix("[").split_on("]").first() ?? ""
					inside.split_on(",").map(Text.trim).keep_if(|each| !each.is_empty())
				}
				Err(_) => []
			}
		{ target, alias, exposed }
	}

	## The capitalized names a type's text has, but after a `.`: a module's (`Board` in
	## `Board.Data`), a type's (`Channel`, `Str`); each once.
	type_names : Str -> List(Str)
	type_names = |text| {
		bytes = text.to_utf8()
		var $names = []
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if Text.is_word(c) {
				end = Text.run_end(bytes, $i, Text.is_word)
				if Text.is_upper(c) and ($i == 0 or Text.at(bytes, $i - 1) != '.') {
					$names = $names.append(Text.cut(bytes, $i, end))
				}
				$i = end
			} else {
				$i = $i + 1
			}
		}
		Text.unique($names)
	}

	## What a route file's import names, as a module under Generated/ names it: a module of the app's
	## by its path from there (`../../../Board` in `routes/b/[board]/+server.roc` is `../Board`), a
	## package's as it is (`pf.Channel`).
	target_from_generated : Str, Str -> Str
	target_from_generated = |file, target|
		if Routes.package_name(target) {
			target
		} else {
			Fs.relative("/app/${Routes.generated_dir}", Fs.resolve("/", [Fs.dirname("/app/routes/${file}"), target]))
		}

	## An import's line, from what it names, the name it gives it if it gives one, and what it
	## exposes.
	import_written : Str, [Some(Str), None], List(Str) -> Str
	import_written = |target, alias, exposed| {
		named =
			match alias {
				Some(name) => " as ${name}"
				None => ""
			}
		"import ${target}${named}${if (exposed.is_empty()) "" else " exposing [${Str.join_with(exposed, ", ")}]"}"
	}

	## What Api imports for its types: each route file's import of a module its contract's types
	## name (`import ../Board` for `Board.Data`): what it names as Generated/ names it (`target`),
	## the name it gives it (`alias`; `renamed` when `as` gives it) and what it exposes, with the
	## route file, its method, the method's line and the type that needs it; for each import that
	## many times.
	contract_imports : Table, List(Source) -> List(ContractImport)
	contract_imports = |table, sources|
		table.servers.join_map(
			|server| {
				defs = Routes.defs_of(sources, server.file)
				Routes.contracted(sources, server).join_map(
					|method|
						match Routes.contract_types(sources, server, method) {
							None => []
							Some(types) => {
								at =
									match Routes.handler_in(sources, server.file, method) {
										Some(handler) => handler.line
										None => 0
									}
								[types.arg, types.answer].join_map(
									|type| {
										names = Routes.type_names(type)
										defs.imported.keep_if(
											|line| {
												parts = Routes.import_parts(line)
												names.contains(parts.alias) or parts.exposed.any(|each| names.contains(each))
											},
										)
											.map(
												|line| {
													parts = Routes.import_parts(line)
													{ target: Routes.target_from_generated(server.file, parts.target), alias: parts.alias, renamed: line.contains(" as "), exposed: parts.exposed, file: server.file, method, at, type }
												},
											)
									},
								)
							}
						},
				)
			},
		)

	## Api's import lines, from `contract_imports`: each module once, by the name the first route
	## file gives it, with what any of them expose; a package's modules (`pf.Channel`) first.
	contract_import_lines : List(ContractImport) -> List(Str)
	contract_import_lines = |uses| {
		named_modules = Text.unique(uses.map(|each| each.target))
		lines = named_modules.map(
			|target| {
				all = uses.keep_if(|each| each.target == target)
				first = all.first() ?? { target, alias: "", renamed: Bool.False, exposed: [], file: "", method: "", at: 0, type: "" }
				Routes.import_written(target, if (first.renamed) Some(first.alias) else None, Text.unique(all.join_map(|each| each.exposed)))
			},
		)
		sorted = Text.sorted(lines)
		sorted.keep_if(|line| Routes.package_name(line.drop_prefix("import "))).concat(sorted.keep_if(|line| !Routes.package_name(line.drop_prefix("import "))))
	}

	## Two route files whose types name different modules by one name (`import ../Store` and `import
	## shop.Store`), or one module by two: Api, which imports what both name, can't have both.
	contract_clashes : Table, List(Source) -> List(Str)
	contract_clashes = |table, sources| {
		var $seen = []
		var $problems = []
		for each in Routes.contract_imports(table, sources) {
			match $seen.find_first(|before| (before.alias == each.alias) != (before.target == each.target)) {
				Ok(before) => {
					problem =
						if before.alias == each.alias {
							"routes/${each.file}:${each.at.to_str()}: its ${each.method} names ${each.alias} (${each.target}, as Generated/ has it), and routes/${before.file}'s ${before.method} names another ${each.alias} (${before.target}): Generated/Api imports the modules both name, so give one of them another name (import … as …)"
						} else {
							"routes/${each.file}:${each.at.to_str()}: its ${each.method} names ${each.target} as ${each.alias}, and routes/${before.file}'s ${before.method} names it as ${before.alias}: Generated/Api imports the module once, so give it one name in both"
						}
					if !$problems.contains(problem) {
						$problems = $problems.append(problem)
					}
				}
				Err(_) => {
					$seen = $seen.append(each)
				}
			}
		}
		$problems
	}

	## What keeps rocx build from writing the contract: a method or channel with no annotation, or
	## one it can't read; one sent a body whose record has none; two modules Api would import by one
	## name. Each says where (`routes/…:line: …`).
	contract_problems : Table, List(Source) -> List(Str)
	contract_problems = |table, sources| {
		problems = table.servers.join_map(
			|server|
				Routes.contracted(sources, server).join_map(
					|method| {
						verb = Routes.contract_verb(method)
						takes = Routes.takes_body(verb)
						answer = if (method == Routes.channel_name) "Channel(who, message, said)" else if (method == "events!") "Events(…)" else "…"
						wanted = "${method} : { request : Server.Request, params : ${Routes.params_type(server.params)}, context : c${if (takes) ", body : …" else ""} } => Try(${answer}, Endpoint.Refusal)"
						match Routes.handler_in(sources, server.file, method) {
							None => []
							Some(handler) => {
								at = "routes/${server.file}:${handler.line.to_str()}"
								match handler.types {
									Unannotated => ["${at}: ${method} has no type annotation, and rocx build copies its types into Generated/Api, the app's contract (D-037): annotate it, as ${wanted}"]
									Unreadable(why) => ["${at}: rocx build can't read ${method}'s types for Generated/Api: ${why}"]
									Defined(named) => {
										these = Str.join_with(named, ", ")
										["${at}: ${method}'s type names ${these}, which this route file defines, and Generated/Api, the app's contract (D-037), imports no route file: move ${these} into a module of its own (${named.first() ?? these}.roc beside routes/) and import it here"]
									}
									Typed(types) => if (takes and types.body.is_empty()) ["${at}: ${method} is sent a body (${verb}): its annotation's record needs body : … ({} for none), as ${wanted}"] else []
								}
							}
						}
					},
				),
		)
		problems.concat(Routes.contract_clashes(table, sources))
	}

	## `Generated/Api.roc`: the app's contract. Each endpoint, a function of its params, with its
	## method, its URL and the types its handler's annotation gives (`Endpoint.remote`); each channel
	## too. It imports what those types name, and no route file, so any module of the app's may
	## import it (D-037); the server's has the OpenAPI document too, and the browser's is the same
	## contract. The handlers are `Generated/Handlers.roc`'s.
	api_module : Table, List(Source), { client : Bool, tags : List(Str), title : Str } -> Str
	api_module = |table, sources, options| {
		client = options.client
		endpoints = table.servers.join_map(|server| Routes.defs_of(sources, server.file).methods.join_map(|method| Routes.contract_lines(sources, server, method)))
		channels = table.servers.keep_if(|server| Routes.has_channel(sources, server.file)).join_map(|server| Routes.contract_lines(sources, server, Routes.channel_name))
		known = ["import pf.Endpoint", "import pf.Server", "import pf.OpenApi"]
		typed = Routes.contract_import_lines(Routes.contract_imports(table, sources)).keep_if(|line| !known.contains(line))
		lines =
			[
				"## Written by rocx build from the app's routes/: the app's contract. Each endpoint a +server.roc has,",
				"## as a function of its params: its method, its URL and the types its handler's annotation gives,",
				if (client) "## and nothing it does. This is the browser's copy (`Endpoint.send!`, `Endpoint.get!`)." else "## and nothing it does, so any module may import it (`Endpoint.publish!`, `Endpoint.get!`). The",
				if (client) "## Edit the routes." else "## handlers are Generated/Handlers'. Edit the routes.",
				"import pf.Endpoint",
				"import pf.Server",
			]
				.concat(if (client) [] else ["import pf.OpenApi"])
				.concat(typed)
				.concat(["", "Api := [].{"])
				.concat(endpoints)
				.concat(channels)
				.concat(if (client) [] else Routes.open_api_document(table, sources, options.tags, options.title))
				.concat(["}", "", "${Routes.marker} the routes: rocx build writes it.", ""])
		Str.join_with(lines, "\n")
	}

	## `Generated/Handlers.roc`, the server's alone: each endpoint and channel of Api with its
	## handler (`Endpoint.bind`), which the router answers with and `Endpoint.run!` runs. It imports
	## every route file with one, so a module a route file imports can't import it: main.roc can, and
	## a plugin, or a module only they import.
	handlers_module : Table, List(Source) -> Str
	handlers_module = |table, sources| {
		bound = |server, method| {
			verb = Routes.contract_verb(method)
			takes = Routes.takes_body(verb)
			name = Routes.api_name(method, server.name)
			handler = "|request, context, ${if (takes) "body" else "{}"}| ${server.module_name}.${method}({ request: request, params: params, context: context${if (takes) ", body: body" else ""} })"
			what = if (method == Routes.channel_name) "The channel at ${server.path}" else if (method == "events!") "${verb} ${server.path}, its events" else "${verb} ${server.path}"
			["\t## ${what}, from routes/${server.file}", "\t${name} = |params| Endpoint.bind(Api.${name}(params), ${handler})", ""]
		}
		bound_endpoints = table.servers.join_map(|server| Routes.defs_of(sources, server.file).methods.join_map(|method| bound(server, method)))
		channels = table.servers.keep_if(|server| Routes.has_channel(sources, server.file)).join_map(|server| bound(server, Routes.channel_name))
		modules = Text.sorted(Text.unique(table.servers.keep_if(|server| !Routes.contracted(sources, server).is_empty()).map(|server| server.module_name)))
		lines =
			[
				"## Written by rocx build from the app's routes/: each endpoint and channel of Api with its handler,",
				"## for the server alone: the router answers with them, and `Endpoint.run!` runs one (skipping its",
				"## middleware). It imports every route file, so a module they import can't import it: main.roc",
				"## can, a plugin can. Edit the routes.",
				"import pf.Endpoint",
				"import Api",
			]
				.concat(modules.map(|module_name| "import ${module_name}"))
				.concat(["", "Handlers := [].{"])
				.concat(bound_endpoints)
				.concat(channels)
				.concat(["}", "", "${Routes.marker} the routes: rocx build writes it.", ""])
		Str.join_with(lines, "\n")
	}

	## `Generated/Paths.roc`: a path for every page, a function of its params if it has any.
	paths_module : Table -> Str
	paths_module = |table| {
		definition = |page|
			if page.params.is_empty() {
				["\t## ${page.path}, from routes/${page.file}", "\t${page.name} : Str", "\t${page.name} = ${Text.json_string(page.path)}"]
			} else {
				shape = "{ ${Str.join_with(page.params.map(|param| "${param.name} : Str"), ", ")} }"
				["\t## ${page.path}, from routes/${page.file}", "\t${page.name} : ${shape} -> Str", "\t${page.name} = |params| ${Routes.url_of(page.parts)}"]
			}
		statics = table.pages.keep_if(|page| page.params.is_empty()).map(|page| Text.json_string(page.path))
		any_params = table.pages.any(|page| !page.params.is_empty())
		lines =
			[
				"## Written by rocx build from the app's routes/: a path for every page, so a link to a page that",
				"## isn't there doesn't compile. Edit the routes, not this file.",
			]
				.concat(if (any_params) ["import pf.Server", ""] else [])
				.concat(["Paths := [].{"])
				.concat(table.pages.sort_with(|a, b| Text.locale_order(a.path, b.path)).join_map(|page| definition(page).append("")))
				.concat([
					"\t## Every page with no params: what a static build writes.",
					"\tall : List(Str)",
					"\tall = [${Str.join_with(statics, ", ")}]",
					"}",
					"",
					"${Routes.marker} the routes: rocx build writes it.",
					"",
				])
		Str.join_with(lines, "\n")
	}

	## `Generated/Root.roc`, for both the server and the browser: the app's page.
	root_module : Table, List(Source), List(Placed) -> Str
	root_module = |table, sources, stories| {
		pages = table.pages
		root = table.layouts.find_first(|layout| layout.parts.is_empty())
		has_root =
			match root {
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
		meta = |maybe|
			match maybe {
				Some(entry) => if (Routes.defs_of(sources, entry.file).meta) "${entry.module_name}.meta" else "{}"
				None => "{}"
			}
		# A route's view is a component, given getters for its value props (D-039).
		layout = |mod_name, meta_of, children| "Html.component(|| ${mod_name}.view!({ params: || params, meta: || ${meta_of}, children: [${children}] }))"
		documented = |meta_of, inside|
			match root {
				Ok(found) => layout(found.module_name, meta_of, inside)
				Err(_) => "${Routes.root_name}.document([${inside}])"
			}
		root_file =
			match root {
				Ok(found) => found.file
				Err(_) => ""
			}
		branch = |page| {
			inner = page.layouts.keep_if(|each| each.file != root_file).fold_rev("Html.component(|| ${page.module_name}.view!({ params: || params }))", |each, html| layout(each.module_name, meta(Some(page)), html))
			Str.join_with(["if (${Routes.matched_by(page.parts, page.params)}) {", "\t\t\tparams = ${Routes.params_of(page.params)}", "\t\t\t${documented(meta(Some(page)), "${Routes.root_name}.guarded!([${inner}])")}", "\t\t}"], "\n")
		}
		missing = Str.join_with((if (has_root) ["\t\t\tparams = {}"] else []).append("\t\t\t${documented(meta(table.error), "${Routes.root_name}.failed(404, \"nothing at \${path}\")")}"), "\n")
		front =
			match pages.find_first(|page| page.path == "/") {
				Ok(page) => Some(page)
				Err(_) => table.error
			}
		storied =
			if stories.is_empty() {
				[]
			} else {
				[
					Str.join_with(
						[
							"if (path.starts_with(${Text.json_string("${Routes.stories_path}/")})) {",
							"\t\t\tid = path.drop_prefix(${Text.json_string("${Routes.stories_path}/")})",
						]
							.concat(if (has_root) ["\t\t\tparams = {}"] else [])
							.concat(stories.map_with_index(|story, i| "\t\t\t${if (i > 0) "} else " else ""}if (id == ${Text.json_string(story.id)}) {\n\t\t\t\t${documented(meta(front), "${Routes.root_name}.guarded!([Html.component(|| ${story.alias}.${story.def}({}))])")}"))
							.concat(["\t\t\t} else {\n\t\t\t\t${documented(meta(front), "${Routes.root_name}.failed(404, \"no story at \${path}\")")}\n\t\t\t}", "\t\t}"]),
						"\n",
					),
				]
			}
		branches = storied.concat(pages.map(branch))
		story_modules =
			stories
				.fold(
					[],
					|so_far, story|
						match so_far.find_first_index(|each| each.module_path == story.module_path) {
							Ok(i) => so_far.update(i, |each| { ..each, alias: story.alias }) ?? so_far
							Err(_) => so_far.append({ module_path: story.module_path, alias: story.alias })
						},
				)
				.sort_with(|a, b| Text.order("${a.module_path},${a.alias}", "${b.module_path},${b.alias}"))
		error =
			match table.error {
				Some(entry) => "Html.component(|| ${entry.module_name}.view!({ status: || status, problem: || problem }))"
				None => "Html.element(\"main\", [], [Html.element(\"h1\", [], [Html.text(status.to_str())]), Html.element(\"p\", [], [Html.text(problem)])])"
			}
		error_modules =
			match table.error {
				Some(entry) => [entry.module_name]
				None => []
			}
		root_modules =
			match root {
				Ok(found) => [found.module_name]
				Err(_) => []
			}
		modules = Text.sorted(Text.unique(pages.join_map(|page| page.layouts.map(|each| each.module_name).append(page.module_name)).concat(error_modules).concat(root_modules)))
		view_body = if (branches.is_empty()) Routes.without_first_tabs(missing) else "\t\t${Str.join_with(branches, " else ")} else {\n${missing}\n\t\t}"
		lines =
			[
				"## Written by rocx build from the app's routes/: the app's page, for the server, which renders it for",
				"## a request, and for the browser, which hydrates it: the page at where it is, in the +layout.rocx",
				"## files above it, or +error.rocx where no page is, or where a page failed. Edit those files, not this one.",
				"import pf.Html",
				"import pf.Router",
			]
				.concat(if (pages.is_empty()) [] else ["import pf.Server"])
				.concat(["import pf.Errored", "import pf.HttpStatusCode"])
				.concat(modules.map(|module_name| "import ${module_name}"))
				.concat(story_modules.map(|each| "import ../${each.module_path} as ${each.alias}"))
				.concat(if (has_root) [] else ["import Styles"])
				.concat([
					"",
					"${Routes.root_name} := [].{",
					"\t## The page at where it is (`Router.location!`: the request's path on the server; in the browser,",
					"\t## the page's, without the base): its route's page, given its params, in its layouts, the error",
					"\t## page for a failure nothing else catches (a read its endpoint refused with a 4xx, that status;",
					"\t## else 500); the error page (404) where no page is.",
					"\tview! : {} => Html",
					"\tview! = |{}| {",
					"\t\tpath = Router.location!({}).path",
				])
				.concat(if (pages.is_empty()) [] else ["\t\tsegments = path.split_on(\"/\").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)"])
				.concat([
					view_body,
					"\t}",
					"",
					"\t## What is inside the root layout: when it fails and nothing in it catches that, the error page,",
					"\t## its status the failure's (`Errored.status_of`: a refused read's 4xx, 404 for data that isn't there).",
					"\tguarded! : List(Html) => Html",
					"\tguarded! = |children| Errored.view!({ fallback: |problem, _retry| ${Routes.root_name}.failed(Errored.status_of(problem), problem), children: children })",
					"",
					"\t## The error page for `status` (404: no page is here, or its data isn't; 500: the page failed),",
					"\t## which the server answers with (`<HttpStatusCode>`), and why.",
					"\tfailed : U16, Str -> Html",
					"\tfailed = |status, problem| Html.join([Html.component(|| HttpStatusCode.view!({ code: status })), ${error}])",
				])
				.concat(
					if has_root {
						[]
					} else {
						[
							"",
							"\t## The document, for an app with no root layout (routes/+layout.rocx).",
							"\tdocument : List(Html) -> Html",
							"\tdocument = |children|",
							"\t\tHtml.join(",
							"\t\t\t[",
							"\t\t\t\tHtml.doctype({}),",
							"\t\t\t\tHtml.element(\"html\", [Html.attr(\"lang\", \"en\")], [",
							"\t\t\t\t\tHtml.element(\"head\", [], [Html.void(\"meta\", [Html.attr(\"charset\", \"utf-8\")]), Html.void(\"meta\", [Html.attr(\"name\", \"viewport\"), Html.attr(\"content\", \"width=device-width, initial-scale=1\")]), Styles.style]),",
							"\t\t\t\t\tHtml.element(\"body\", [], children),",
							"\t\t\t\t]),",
							"\t\t\t],",
							"\t\t)",
						]
					},
				)
				.concat(["}", "", "${Routes.marker} the routes: rocx build writes it.", ""])
		Str.join_with(lines, "\n")
	}

	## Each line without one tab at its start (`.replace(/^\t/gm, "")`).
	without_first_tabs : Str -> Str
	without_first_tabs = |text| Str.join_with(text.split_on("\n").map(|line| if (line.starts_with("\t")) line.drop_prefix("\t") else line), "\n")

	# ---- jobs, actors, migrations ----

	## Where each line starts that a match may begin at, from `from` on (after `\n` or `\r`).
	line_starts_from : List(U8), U64 -> List(U64)
	line_starts_from = |bytes, from| {
		var $starts = if (from == 0) [0] else []
		var $i = if (from == 0) 0 else from - 1
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if (c == '\n' or c == '\r') and $i + 1 >= from {
				$starts = $starts.append($i + 1)
			}
			$i = $i + 1
		}
		$starts
	}

	## A definition's head at `start`: its indentation, its name, and where `=` and the spaces after it end.
	definition_head : List(U8), U64 -> Try({ indent : Str, define : Str, after : U64 }, [NoMatch])
	definition_head = |bytes, start| {
		indent_end = Text.run_end(bytes, start, |b| b == ' ' or b == '\t')
		c = Text.at(bytes, indent_end)
		if !(Text.is_lower(c) or c == '_') or indent_end >= bytes.len() {
			return Err(NoMatch)
		}
		name_end = Text.run_end(bytes, indent_end + 1, Text.is_word)
		equals = Text.run_end(bytes, name_end, |b| b == ' ' or b == '\t')
		if Text.at(bytes, equals) != '=' or equals >= bytes.len() {
			return Err(NoMatch)
		}
		Ok({ indent: Text.cut(bytes, start, indent_end), define: Text.cut(bytes, indent_end, name_end), after: Text.run_end(bytes, equals + 1, |b| b == ' ' or b == '\t') })
	}

	## A quoted name at `at` (`"…"`, at least a character, to the next quote): it, and where it ends.
	quoted_at : List(U8), U64 -> Try({ text : Str, end : U64 }, [NoMatch])
	quoted_at = |bytes, at| {
		if Text.at(bytes, at) != '"' or at >= bytes.len() {
			return Err(NoMatch)
		}
		match Text.index_of_byte(bytes, '"', at + 1) {
			Ok(close) if close > at + 1 => Ok({ text: Text.cut(bytes, at + 1, close), end: close + 1 })
			_ => Err(NoMatch)
		}
	}

	## A job's definition at `start`: `^([ \t]*)([a-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*Job\.define(?:_with)?\(\s*"([^"]+)"`.
	job_at : List(U8), U64 -> Try({ indent : Str, define : Str, name : [Some(Str), None], thunk : Bool, end : U64 }, [NoMatch])
	job_at = |bytes, start| {
		head = Routes.definition_head(bytes, start)?
		call = "Job.define".to_utf8()
		if !Text.starts_with_at(bytes, call, head.after) {
			return Err(NoMatch)
		}
		after_call = head.after + call.len()
		opened =
			if Text.starts_with_at(bytes, "_with(".to_utf8(), after_call) {
				Ok(after_call + 6)
			} else if Text.at(bytes, after_call) == '(' and after_call < bytes.len() {
				Ok(after_call + 1)
			} else {
				Err(NoMatch)
			}
		quoted = Routes.quoted_at(bytes, Text.skip_space(bytes, opened?))?
		Ok({ indent: head.indent, define: head.define, name: Some(quoted.text), thunk: Bool.False, end: quoted.end })
	}

	## A kind of actor's definition at `start`: `^([ \t]*)([a-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(\|\{\}\|\s*)?
	## Actor\.define\((?:\s*\{\s*name:\s*"([^"]+)")?`.
	actor_at : List(U8), U64 -> Try({ indent : Str, define : Str, name : [Some(Str), None], thunk : Bool, end : U64 }, [NoMatch])
	actor_at = |bytes, start| {
		head = Routes.definition_head(bytes, start)?
		call = "Actor.define(".to_utf8()
		thunked = Text.starts_with_at(bytes, "|{}|".to_utf8(), head.after)
		at = if (thunked) Text.skip_space(bytes, head.after + 4) else head.after
		if !Text.starts_with_at(bytes, call, at) {
			return Err(NoMatch)
		}
		opened = at + call.len()
		brace = Text.skip_space(bytes, opened)
		named =
			if Text.at(bytes, brace) == '{' and brace < bytes.len() {
				field = Text.skip_space(bytes, brace + 1)
				if Text.starts_with_at(bytes, "name:".to_utf8(), field) {
					match Routes.quoted_at(bytes, Text.skip_space(bytes, field + 5)) {
						Ok(quoted) => Ok(quoted)
						Err(_) => Err(NoMatch)
					}
				} else {
					Err(NoMatch)
				}
			} else {
				Err(NoMatch)
			}
		match named {
			Ok(quoted) => Ok({ indent: head.indent, define: head.define, name: Some(quoted.text), thunk: thunked, end: quoted.end })
			Err(_) => Ok({ indent: head.indent, define: head.define, name: None, thunk: thunked, end: opened })
		}
	}

	## Every definition `at` finds in `source`, as JavaScript's `matchAll` finds them: each at a
	## line's start, the next after the last one's end; with its line.
	matches_in : Str, Bool -> List({ indent : Str, define : Str, name : [Some(Str), None], thunk : Bool, line : U64 })
	matches_in = |source, actors| {
		bytes = source.to_utf8()
		var $found = []
		var $from = 0
		var $more = Bool.True
		while $more {
			from_now = $from
			candidates = Routes.line_starts_from(bytes, from_now)
			hit = candidates.fold_until(
				Err(NoMatch),
				|_, start| {
					tried = if (actors) Routes.actor_at(bytes, start) else Routes.job_at(bytes, start)
					match tried {
						Ok(found) => Break(Ok({ found, start }))
						Err(_) => Continue(Err(NoMatch))
					}
				},
			)
			match hit {
				Ok(each) => {
					$found = $found.append({ indent: each.found.indent, define: each.found.define, name: each.found.name, thunk: each.found.thunk, line: Text.newlines(bytes, 0, each.start) + 1 })
					$from = each.found.end
				}
				Err(_) => {
					$more = Bool.False
				}
			}
		}
		$found
	}

	## The jobs the app under `dir` defines (`Job.define`, `Job.define_with`), and what is wrong.
	jobs_in! : Str, Table => { jobs : List(Found), problems : List(Str) }
	jobs_in! = |dir, table| {
		found = Routes.defined_in!(dir, table, Bool.False)
		{ jobs: found.found, problems: found.problems }
	}

	## The kinds of actor the app under `dir` defines (`Actor.define`), and what is wrong.
	actors_in! : Str, Table => { actors : List(Found), problems : List(Str) }
	actors_in! = |dir, table| {
		found = Routes.defined_in!(dir, table, Bool.True)
		{ actors: found.found, problems: found.problems }
	}

	## What `jobs_in!` and `actors_in!` share.
	defined_in! : Str, Table, Bool => { found : List(Found), problems : List(Str) }
	defined_in! = |dir, table, actors| {
		routes = Routes.routed_modules(table).map(|each| { key: "routes/${each.file}", module_name: each.module_name })
		walked = if (Fs.exists!(dir)) Routes.walk_definitions!(dir, "", routes, actors, { found: [], problems: [] }) else { found: [], problems: [] }
		twice = |each|
			if actors {
				"there is a kind of actor called \"${each.name}\" already"
			} else {
				"there is a job called \"${each.name}\" already"
			}
		why = if (actors) "the host finds an actor's kind by its name, and keeps its state under it, so give each its own" else "the workers find a job by its name, so give each its own"
		named = walked.found.fold(
			{ seen: [], problems: [] },
			|so_far, each|
				match so_far.seen.find_first(|other| other.name == each.name) {
					Ok(other) => { ..so_far, problems: so_far.problems.append("${each.file}:${each.line.to_str()}: ${twice(each)} (${other.file}:${other.line.to_str()}): ${why}") }
					Err(_) => { ..so_far, seen: so_far.seen.append(each) }
				},
		)
		{ found: walked.found, problems: walked.problems.concat(named.problems) }
	}

	walk_definitions! : Str, Str, List({ key : Str, module_name : Str }), Bool, { found : List(Found), problems : List(Str) } => { found : List(Found), problems : List(Str) }
	walk_definitions! = |at, prefix, routes, actors, so_far| {
		var $state = so_far
		for entry in Fs.entries!(at) {
			skipped = (entry.starts_with(".") and entry != Routes.well_known) or entry == "build" or entry == "dist" or entry == "Generated" or entry == "node_modules"
			if !skipped {
				path = Fs.join([at, entry])
				file = if (prefix.is_empty()) entry else "${prefix}/${entry}"
				if Fs.is_dir!(path) {
					$state = Routes.walk_definitions!(path, file, routes, actors, $state)
				} else if entry.ends_with(".roc") or entry.ends_with(".rocx") {
					source = Fs.read_or_empty!(path)
					rocx_written = entry.ends_with(".roc") and (Fs.exists!("${path}x") or Routes.last_line(source).starts_with(Routes.marker))
					if !rocx_written {
						route = routes.find_first(|each| each.key == file)
						for each in Routes.matches_in(source, actors) {
							mod_path =
								match route {
									Ok(found) => "${Routes.generated_dir}/${found.module_name}"
									Err(_) => if (file.ends_with(".rocx")) file.drop_suffix(".rocx") else file.drop_suffix(".roc")
								}
							type_name = mod_path.split_on("/").last() ?? mod_path
							is_route =
								match route {
									Ok(_) => Bool.True
									Err(_) => Bool.False
								}
							wanted = if (is_route) "" else "\t"
							misnamed = actors and each.name == None
							if each.indent != wanted or misnamed {
								where_it_is = if (each.indent.is_empty()) "outside its module's block" else "inside a definition"
								tab = if (is_route) "" else "\t"
								name = Routes.or_empty(each.name)
								said =
									if actors and misnamed {
										"the kind of actor `${each.define}` doesn't start with its name: define it as `${each.define} = Actor.define({ name: \"…\", initial, receive! })`, so rocx build can list it"
									} else if actors {
										"the kind of actor \"${name}\" is defined ${where_it_is}: define it at the top of `${type_name} := [].{ … }`, as `${tab}${each.define} = Actor.define({ … })`, so Generated/App can name it (`${type_name}.${each.define}`)"
									} else {
										"the job \"${name}\" is defined ${where_it_is}: define it at the top of `${type_name} := [].{ … }`, as `${tab}${each.define} = Job.define(…)`, so Generated/App can name it (`${type_name}.${each.define}`)"
									}
								$state = { ..$state, problems: $state.problems.append("${file}:${each.line.to_str()}: ${said}") }
							} else {
								route_mod =
									match route {
										Ok(found) => Some(found.module_name)
										Err(_) => None
									}
								$state = { ..$state, found: $state.found.append({ define: each.define, name: Routes.or_empty(each.name), module_path: mod_path, file, line: each.line, route: route_mod, thunk: each.thunk }) }
							}
						}
					}
				}
			}
		}
		$state
	}

	## The app's migrations, `migrations/*.sql` under `dir`, in the order of their names.
	migrations_in! : Str => List(Str)
	migrations_in! = |dir| {
		at = Fs.join([dir, "migrations"])
		if Fs.is_dir!(at) {
			var $names = []
			for name in Fs.entries!(at) {
				if name.ends_with(".sql") and Fs.is_file!(Fs.join([at, name])) {
					$names = $names.append(name)
				}
			}
			$names
		} else {
			[]
		}
	}

	## A migration's name as a Roc name: `m`, then its name in lower case, each run of what isn't
	## `[a-z0-9_]` one `_`.
	migration_name : Str -> Str
	migration_name = |name| {
		bytes = Text.lower(if (name.ends_with(".sql")) name.drop_suffix(".sql") else name).to_utf8()
		var $out = ['m']
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if Text.is_lower(c) or Text.is_digit(c) or c == '_' {
				$out = $out.append(c)
				$i = $i + 1
			} else {
				$out = $out.append('_')
				$i = Text.run_end(bytes, $i, |b| !(Text.is_lower(b) or Text.is_digit(b) or b == '_'))
			}
		}
		Str.from_utf8_lossy($out)
	}

	## `Routes.claims`'s lines: each of the app's routes, its method (`*` for `respond!`; GET for a
	## stream of events) and its path, and its file, which the server compares plugins' routes with
	## when it starts.
	claims_lines : Table, List(Source) -> List(Str)
	claims_lines = |table, sources| {
		rows = Routes.route_list(table, sources).keep_if(|row| row.path.starts_with("/"))
		listed = rows.map(|row| "\t\t{ method: ${Text.roc_string(if (row.method == "EVENTS") "GET" else row.method)}, path: ${Text.roc_string(row.path)}, file: ${Text.roc_string(row.file)} },")
		[
			"\t## The app's routes, each a method and a path (`*`: any), and the file it is in: what the server",
			"\t## checks plugins' routes against when it starts (`program.routes`).",
			"\tclaims : List({ method : Str, path : Str, file : Str })",
		]
			.concat(if (listed.is_empty()) ["\tclaims = []"] else ["\tclaims = ["].concat(listed).append("\t]"))
	}

	## `Generated/App.roc`, the server's program.
	app_module : { jobs : List(Found), actors : List(Found), migrations : List(Str), endpoints : Bool, jobs_package : Str } -> Str
	app_module = |input| {
		# The jobs package, as the app's header names it (packages/jobs): `App.jobs` is for its plugin.
		jobs_package = input.jobs_package
		alias = |found|
			match found.route {
				Some(route) => route
				None => found.module_path.replace_each("/", "")
			}
		import_line = |found|
			match found.route {
				Some(route) => "import ${route}"
				None => "import ../${found.module_path} as ${alias(found)}"
			}
		import_lines =
			input.jobs
				.concat(input.actors)
				.fold(
					[],
					|so_far, found|
						match so_far.find_first_index(|each| each.key == alias(found)) {
							Ok(i) => so_far.update(i, |each| { ..each, value: import_line(found) }) ?? so_far
							Err(_) => so_far.append({ key: alias(found), value: import_line(found) })
						},
				)
				.sort_with(|a, b| if (Text.order(a.key, b.key) == Before) Before else After)
				.map(|each| each.value)
		embedded =
			input.migrations
				.fold(
					[],
					|so_far, name| {
						base = Routes.migration_name(name)
						second : U64
						second = 2
						var $as = base
						var $i = second
						while so_far.any(|each| each.as_name == $as) {
							$as = "${base}_${$i.to_str()}"
							$i = $i + 1
						}
						so_far.append({ name, as_name: $as })
					},
				)
		lines =
			[
				"## Written by rocx build: the app's `program`, for its main.roc, which says what only it can",
				"## (`program = App.program({ context, middleware })`, `database` if it isn't Postgres, `openapi` if it serves its endpoints' OpenAPI",
				"## document, and `plugins`). Every request is answered by a plugin's route or the app's",
				"## (`Routes.respond!`), behind the app's middleware; the kinds of actor are the ones its modules",
				"## define (`Actor.define`), and so are the kinds of job in `App.jobs` (`Job.define`), for the jobs",
				"## plugin; the migrations, migrations/*.sql, in the order of their names; the log's format is",
				"## `Auto` (`ROCX_LOG`, or pretty on a terminal and JSON elsewhere), which the app may change:",
				"## `program = { ..App.program({ … }), logs: { format: Json } }`.",
				"import pf.Server",
				"import pf.Endpoint",
				"import pf.Middleware",
				"import pf.OpenApi",
				"import pf.Plugin",
			]
				.concat(if (jobs_package.is_empty()) [] else ["import ${jobs_package}.Job"])
				.concat(if (input.actors.is_empty()) [] else ["import pf.Actor"])
				.concat(if (input.endpoints) ["import Api"] else [])
				.concat(["import Routes"])
				.concat(import_lines)
				.concat(embedded.map(|each| "import ${Text.roc_string("../migrations/${each.name}")} as ${each.as_name} : Str"))
				.concat([
					"",
					"${Routes.app_name} := [].{",
				])
				.concat(
					if jobs_package.is_empty() {
						[]
					} else {
						[
							"\t## The kinds of job the app's modules define (`Job.define`, which rocx build finds), for the jobs",
							"\t## plugin: `Job.plugin({ jobs: App.jobs, crons: [Cron.every(…)] })`.",
							"\tjobs : List(Job.Handler)",
							"\tjobs = [${Str.join_with(input.jobs.map(|job| "Job.handler(${alias(job)}.${job.define})"), ", ")}]",
							"",
						]
					},
				)
				.concat([
					"\t## What only the app can say: `context`, what its middleware is given from what the server was",
					"\t## started with (`--context-file`: `|started| …`); `middleware`, which runs around every",
					"\t## request; `database`, its database (D-045): `Postgres` unless it says, at `--database-url`, or",
					"\t## `Sqlite(path)`, a file in the server's process (`--database-url sqlite:<path>` puts it elsewhere),",
					"\t## or `Turso(path)`, the same SQL on Turso's engine (D-046; `turso:<path>` runs a SQLite app on it);",
					"\t## `openapi`, whether it serves its endpoints' OpenAPI document, and a page to read it",
					"\t## in (`OpenApi.Serving`): `Off` unless it says; and `plugins`, what packages add to it",
					"\t## (`Plugin`): their routes answer behind the middleware, before the app's own, and the",
					"\t## platform runs the rest (the jobs plugin: `App.jobs`, and its schedules).",
					"\tConfig(given, handed) := {",
					"\t\tcontext : Str -> given,",
					"\t\tmiddleware : Middleware(given, handed),",
					"\t\tdatabase : [Postgres, Sqlite(Str), Turso(Str)] ?? Postgres,",
					"\t\topenapi : OpenApi.Serving ?? Off,",
					"\t\tplugins : List(Plugin.Value(handed)) ?? [],",
					"\t}",
					"",
					"\t## The platform's program, from what the app says (`Config`).",
					"\tprogram : Config(_, _) -> _",
					"\tprogram = |config| {",
					"\t\t# The request as the host gives it (its address too: `peer`), and what the server was started with.",
					"\t\trespond!: |parsed, started| {",
					"\t\t\t# The route that answers it (`/blog/[slug]`), for the middleware: what a metric groups requests by.",
					"\t\t\trequest = { ..parsed, route: Plugin.pattern(config.plugins, parsed.method, parsed.path) ?? Routes.pattern(parsed.path) }",
					"\t\t\t# The end of a channel's subscription, as the host tells it: its route's `on_close!`, outside",
					"\t\t\t# the middleware (a subscriber refused at a beat ends too).",
					"\t\t\tif (Endpoint.channel_asked(request) == \"close\") {",
					"\t\t\t\tRoutes.closed!(request)",
					"\t\t\t} else {",
					"\t\t\t\t# A page a browser asks for lets a plain form's flash go (`Server.flash!`): it has read it, or never will.",
				])
				.concat(
					if input.endpoints {
						[
							"\t\t\t\t# The app's middleware, then the endpoints' OpenAPI document and its page, as the app says",
							"\t\t\t\t# (`OpenApi.middleware`), then the routes.",
							"\t\t\t\tchain = config.middleware.then(OpenApi.middleware(config.openapi, Api.openapi))",
						]
					} else {
						["\t\t\t\tchain = config.middleware"]
					},
				)
				.concat([
					"\t\t\t\t# A plugin's route, or the app's.",
					"\t\t\t\tServer.clear_flash(request, Middleware.run!(chain, request, (config.context)(started), |passed, context| Plugin.respond!(config.plugins, passed, context, |routed, handed| Routes.respond!(routed, handed))))",
					"\t\t\t}",
					"\t\t},",
					"\t\tdatabase: config.database,",
					"\t\tmigrations: [${Str.join_with(embedded.map(|each| "{ name: ${Text.roc_string(each.name)}, sql: ${each.as_name} }"), ", ")}],",
					"\t\tactors: [${Str.join_with(input.actors.map(|actor| "Actor.handler(${alias(actor)}.${actor.define}${if (actor.thunk) "({})" else ""})"), ", ")}],",
					"\t\tlogs: { format: Auto },",
					"\t\tplugins: config.plugins.map(Plugin.running),",
					"\t\troutes: Routes.claims,",
					"\t}",
					"}",
					"",
					"${Routes.marker} the app: rocx build writes it.",
					"",
				])
		Str.join_with(lines, "\n")
	}

	## The browser's app (`rocx build --client <out>`, `<out>/main.roc`).
	client_main_module : { web : Str, package_lines : List(Str), dir : Str } -> Str
	client_main_module = |input|
		Str.join_with(
			[
				"## The browser's app, written by rocx build --client from ${input.dir}: the app's page (`Generated/Root`),",
				"## which the browser hydrates (web/start.js), on the web platform. Don't edit it.",
				"app [main!] { ${Str.join_with(input.package_lines.append("pf: platform ${Text.json_string(input.web)}"), ", ")} }",
				"",
				"import pf.Html",
				"import ${Routes.generated_dir}/${Routes.root_name}",
				"",
				"main! : {} => Html",
				"main! = |{}| ${Routes.root_name}.view!({})",
				"",
				"${Routes.marker} the routes: rocx build --client writes it.",
				"",
			],
			"\n",
		)

	## Every route, as `rocx routes` prints it, by path.
	route_list : Table, List(Source) -> List(Row)
	route_list = |table, sources| {
		rows = table.paths.sort_with(|a, b| Text.order(a.path, b.path)).join_map(
			|at| {
				page_rows =
					match at.page {
						Some(page) => [{ method: "GET", path: at.path, file: "routes/${page.file}", middleware: Routes.defs_of(sources, page.file).middleware }]
						None => []
					}
				server_rows =
					match at.server {
						Some(server) => {
							defs = Routes.defs_of(sources, server.file)
							file = "routes/${server.file}"
							methods = defs.methods.map(|method| { method: if (method == "events!") "EVENTS" else Routes.verb_of(method), path: at.path, file, middleware: defs.middleware })
							responds = if (defs.respond) [{ method: "*", path: at.path, file, middleware: defs.middleware }] else []
							channels =
								match defs.channel {
									Some(_) => [{ method: "CHANNEL", path: at.path, file, middleware: defs.middleware }]
									None => []
								}
							methods.concat(responds).concat(channels)
						}
						None => []
					}
				page_rows.concat(server_rows)
			},
		)
		match table.error {
			Some(error) => rows.append({ method: "*", path: "(anything else)", file: "routes/${error.file}", middleware: None })
			None => rows
		}
	}

	## `rocx routes`: the routes of the app in `dir`, a line each, in columns.
	routes_table! : Str => Try(Str, [Problem(Str)])
	routes_table! = |dir| {
		routes = Fs.join([dir, "routes"])
		table = Routes.route_table(Routes.find_route_files!(routes))?
		var $sources = []
		for file in Routes.routed_files(table) {
			$sources = $sources.append({ file, defs: Routes.definitions(Fs.read_or_empty!(Fs.join([routes, file]))) })
		}
		rows = Routes.route_list(table, $sources).map(|row| [row.method, row.path, row.file, if (row.middleware == None) "-" else Routes.or_empty(row.middleware)])
		header = ["METHOD", "PATH", "FILE", "MIDDLEWARE (after the app's default)"]
		widths = header.map_with_index(|title, i| rows.fold(Text.length(title), |widest, row| if (Text.length(row.get(i) ?? "") > widest) Text.length(row.get(i) ?? "") else widest))
		Ok(Str.join_with([header].concat(rows).map(|row| Str.join_with(row.map_with_index(|cell, i| if (i + 1 == row.len()) cell else Text.pad_end(cell, widths.get(i) ?? 0)), "  ")), "\n"))
	}

	## Whether `path` (`/blog/rocx`) is the path of a page whose route is `route` (`/blog/[slug]`).
	matches : Str, Str -> Bool
	matches = |route, path| {
		want = route.split_on("/").keep_if(|part| !part.is_empty())
		have = path.split_on("/").keep_if(|part| !part.is_empty())
		want.len() == have.len() and want.map_with_index(|part, i| part.starts_with("[") or Ok(part) == have.get(i)).all(|ok| ok)
	}

	# ---- rocx internal ----

	failed : Str -> [Failed(Value), Unknown(Str)]
	failed = |message| Failed(Value.problem(message))

	## A table, from the JSON `route_table` answered (rebuilt from its route files' paths).
	table_from : Value -> Try(Table, [Failed(Value), Unknown(Str)])
	table_from = |value|
		match Routes.route_table(Value.items(Value.field(value, "files")).map(Value.str)) {
			Ok(table) => Ok(table)
			Err(Problem(message)) => Err(Routes.failed(message))
		}

	maybe_text : Value -> [Some(Str), None]
	maybe_text = |value|
		match value {
			Text(text) => Some(text)
			_ => None
		}

	## JavaScript's truthiness, for a definitions object's flags.
	truthy : Value -> Bool
	truthy = |value|
		match value {
			Null => Bool.False
			Boolean(yes) => yes
			Number(n) => n != 0
			Text(text) => !text.is_empty()
			_ => Bool.True
		}

	defs_from : Value -> Defs
	defs_from = |value| {
		channel = Value.field(value, "channel")
		{
			view: Routes.maybe_text(Value.field(value, "view")),
			meta: Routes.truthy(Value.field(value, "meta")),
			methods: Value.items(Value.field(value, "methods")).map(Value.str),
			middleware: Routes.maybe_text(Value.field(value, "middleware")),
			docs: Value.fields(Value.field(value, "docs")).map(|each| { key: each.key, value: Value.str(each.value) }),
			respond: Routes.truthy(Value.field(value, "respond")),
			channel: if (Routes.truthy(channel)) Some(Value.items(Value.field(channel, "hooks")).map(Value.str)) else None,
			hooks: Value.items(Value.field(value, "hooks")).map(Value.str),
			handlers: Value.fields(Value.field(value, "handlers")).map(
				|each| {
					given = each.value
					types =
						if Routes.truthy(Value.field(given, "unannotated")) {
							Unannotated
						} else if Routes.truthy(Value.field(given, "defined")) {
							Defined(Value.items(Value.field(given, "defined")).map(Value.str))
						} else if Routes.truthy(Value.field(given, "unreadable")) {
							Unreadable(Value.str(Value.field(given, "unreadable")))
						} else {
							Typed({ body: Value.str_or(Value.field(given, "body"), ""), answer: Value.str_or(Value.field(given, "answer"), "{}") })
						}
					{ method: each.key, line: Routes.count_of(Value.field(given, "line")), types }
				},
			),
			imported: Value.items(Value.field(value, "imports")).map(Value.str),
		}
	}

	sources_from : Value -> List(Source)
	sources_from = |value| Value.fields(value).map(|each| { file: each.key, defs: Routes.defs_from(each.value) })

	count_of : Value -> U64
	count_of = |value| Value.int_or(value, 0).to_u64_wrap()

	placed_from : Value -> Placed
	placed_from = |value| {
		text = |key| Value.str(Value.field(value, key))
		{ file: text("file"), module_path: text("module"), component: text("component"), name: text("name"), def: text("def"), line: Routes.count_of(Value.field(value, "line")), id: text("id"), alias: text("alias") }
	}

	found_from : Value -> Found
	found_from = |value| {
		text = |key| Value.str(Value.field(value, key))
		{ define: text("define"), name: text("name"), module_path: text("module"), file: text("file"), line: Routes.count_of(Value.field(value, "line")), route: Routes.maybe_text(Value.field(value, "route")), thunk: Routes.truthy(Value.field(value, "thunk")) }
	}

	param_value : Param -> Value
	param_value = |param| Object([{ key: "name", value: Text(param.name) }, { key: "at", value: Value.count(param.at) }])

	layout_value : Layout -> Value
	layout_value = |layout|
		Object([{ key: "file", value: Text(layout.file) }, { key: "kind", value: Text(layout.kind) }, { key: "parts", value: Value.strs(layout.parts) }, { key: "module", value: Text(layout.module_name) }, { key: "name", value: Text(layout.name) }])

	entry_value : Entry -> Value
	entry_value = |entry|
		Object([
			{ key: "file", value: Text(entry.file) },
			{ key: "kind", value: Text(entry.kind) },
			{ key: "parts", value: Value.strs(entry.parts) },
			{ key: "module", value: Text(entry.module_name) },
			{ key: "name", value: Text(entry.name) },
			{ key: "path", value: Text(entry.path) },
			{ key: "params", value: Array(entry.params.map(Routes.param_value)) },
			{ key: "layouts", value: Array(entry.layouts.map(Routes.layout_value)) },
		])

	error_value : Entry -> Value
	error_value = |entry|
		Object([
			{ key: "file", value: Text(entry.file) },
			{ key: "kind", value: Text(entry.kind) },
			{ key: "parts", value: Value.strs(entry.parts) },
			{ key: "module", value: Text(entry.module_name) },
			{ key: "name", value: Text(entry.name) },
			{ key: "layouts", value: Array(entry.layouts.map(Routes.layout_value)) },
		])

	at_value : At -> Value
	at_value = |at| {
		page =
			match at.page {
				Some(entry) => [{ key: "page", value: Routes.entry_value(entry) }]
				None => []
			}
		server =
			match at.server {
				Some(entry) => [{ key: "server", value: Routes.entry_value(entry) }]
				None => []
			}
		Object([{ key: "path", value: Text(at.path) }, { key: "parts", value: Value.strs(at.parts) }, { key: "params", value: Array(at.params.map(Routes.param_value)) }, { key: "name", value: Text(at.name) }].concat(page).concat(server))
	}

	table_value : Table -> Value
	table_value = |table|
		Object([
			{ key: "pages", value: Array(table.pages.map(Routes.entry_value)) },
			{ key: "servers", value: Array(table.servers.map(Routes.entry_value)) },
			{ key: "layouts", value: Array(table.layouts.map(Routes.layout_value)) },
			{
				key: "error",
				value: match table.error {
					Some(entry) => Routes.error_value(entry)
					None => Null
				},
			},
			{ key: "paths", value: Array(table.paths.map(Routes.at_value)) },
			{ key: "files", value: Value.strs(table.files) },
		])

	defs_value : Defs -> Value
	defs_value = |defs| {
		respond = if (defs.respond) [{ key: "respond", value: Boolean(Bool.True) }] else []
		channel =
			match defs.channel {
				Some(hooks) => [{ key: "channel", value: Object([{ key: "hooks", value: Value.strs(hooks) }]) }]
				None => if (defs.hooks.is_empty()) [] else [{ key: "hooks", value: Value.strs(defs.hooks) }]
			}
		handler_value = |handler| {
			types =
				match handler.types {
					Typed(found) => [{ key: "body", value: Text(found.body) }, { key: "answer", value: Text(found.answer) }]
					Unreadable(why) => [{ key: "unreadable", value: Text(why) }]
					Unannotated => [{ key: "unannotated", value: Boolean(Bool.True) }]
					Defined(named) => [{ key: "defined", value: Value.strs(named) }]
				}
			{ key: handler.method, value: Object([{ key: "line", value: Value.count(handler.line) }].concat(types)) }
		}
		Object(
			[
				{ key: "view", value: Value.text_or_null(defs.view) },
				{ key: "meta", value: Boolean(defs.meta) },
				{ key: "methods", value: Value.strs(defs.methods) },
				{ key: "middleware", value: Value.text_or_null(defs.middleware) },
				{ key: "docs", value: Object(defs.docs.map(|doc| { key: doc.key, value: Text(doc.value) })) },
			]
				.concat(respond)
				.concat(channel)
				.concat(if (defs.handlers.is_empty()) [] else [{ key: "handlers", value: Object(defs.handlers.map(handler_value)) }])
				.concat(if (defs.handlers.is_empty()) [] else [{ key: "imports", value: Value.strs(defs.imported) }]),
		)
	}

	found_value : Found, Bool -> Value
	found_value = |found, actors| {
		thunk = if (actors) [{ key: "thunk", value: Boolean(found.thunk) }] else []
		Object(
			[{ key: "define", value: Text(found.define) }]
				.concat(thunk)
				.concat([
					{ key: "name", value: Text(found.name) },
					{ key: "module", value: Text(found.module_path) },
					{ key: "file", value: Text(found.file) },
					{ key: "line", value: Value.count(found.line) },
					{ key: "route", value: Value.text_or_null(found.route) },
				]),
		)
	}

	row_value : Row -> Value
	row_value = |row|
		Object([{ key: "method", value: Text(row.method) }, { key: "path", value: Text(row.path) }, { key: "file", value: Text(row.file) }, { key: "middleware", value: Value.text_or_null(row.middleware) }])

	## `rocx internal`'s calls of this module's functions (rocx-cli/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, args| {
		arg = |i| args.get(i) ?? Null
		option = |key| Value.field(arg(1), key)
		match name {
			"findRouteFiles" => Ok(Value.strs(Routes.find_route_files!(Value.str(arg(0)))))
			"routeTable" =>
				match Routes.route_table(Value.items(arg(0)).map(Value.str)) {
					Ok(table) => Ok(Routes.table_value(table))
					Err(Problem(message)) => Err(Routes.failed(message))
				}
			"definitions" => Ok(Routes.defs_value(Routes.definitions(Value.str(arg(0)))))
			"tagNames" => Ok(Value.strs(Routes.tag_names(Value.items(arg(0)).map(Value.str))))
			"routeModule" => {
				place = { name: Value.str(option("name")), source: Value.str(option("source")), generated: Value.str(option("generated")) }
				match Routes.route_module_in(Fs.cwd!(), Value.str(arg(0)), place) {
					Ok(code) => Ok(Text(code))
					Err(Problem(message)) => Err(Routes.failed(message))
				}
			}
			"viewProblems" => {
				table = Routes.table_from(arg(0))?
				Ok(Value.strs(Routes.view_problems(table, Routes.sources_from(arg(1)))))
			}
			"routesModule" => {
				table = Routes.table_from(arg(0))?
				stories =
					match option("stories") {
						Array(list) => Some(list.map(Routes.placed_from))
						_ => None
					}
				Ok(Text(Routes.routes_module(table, Routes.sources_from(option("sources")), stories)))
			}
			"apiModule" => {
				table = Routes.table_from(arg(0))?
				Ok(Text(Routes.api_module(table, Routes.sources_from(option("sources")), { client: Value.bool_or(option("client"), Bool.False), tags: Value.items(option("tags")).map(Value.str), title: Value.str_or(option("title"), "app") })))
			}
			"handlersModule" => {
				table = Routes.table_from(arg(0))?
				Ok(Text(Routes.handlers_module(table, Routes.sources_from(option("sources")))))
			}
			"contractProblems" => {
				table = Routes.table_from(arg(0))?
				Ok(Value.strs(Routes.contract_problems(table, Routes.sources_from(arg(1)))))
			}
			"pathsModule" => {
				table = Routes.table_from(arg(0))?
				Ok(Text(Routes.paths_module(table)))
			}
			"rootModule" => {
				table = Routes.table_from(arg(0))?
				Ok(Text(Routes.root_module(table, Routes.sources_from(option("sources")), Value.items(option("stories")).map(Routes.placed_from))))
			}
			"jobsIn" => {
				table = Routes.table_from(arg(1))?
				found = Routes.jobs_in!(Value.str(arg(0)), table)
				Ok(Object([{ key: "jobs", value: Array(found.jobs.map(|job| Routes.found_value(job, Bool.False))) }, { key: "problems", value: Value.strs(found.problems) }]))
			}
			"actorsIn" => {
				table = Routes.table_from(arg(1))?
				found = Routes.actors_in!(Value.str(arg(0)), table)
				Ok(Object([{ key: "actors", value: Array(found.actors.map(|actor| Routes.found_value(actor, Bool.True))) }, { key: "problems", value: Value.strs(found.problems) }]))
			}
			"migrationsIn" => Ok(Value.strs(Routes.migrations_in!(Value.str(arg(0)))))
			"appModule" => {
				input = arg(0)
				Ok(Text(Routes.app_module({ jobs: Value.items(Value.field(input, "jobs")).map(Routes.found_from), actors: Value.items(Value.field(input, "actors")).map(Routes.found_from), migrations: Value.items(Value.field(input, "migrations")).map(Value.str), endpoints: Routes.truthy(Value.field(input, "endpoints")), jobs_package: Value.str_or(Value.field(input, "jobsPackage"), "") })))
			}
			"clientMainModule" => {
				input = arg(0)
				Ok(Text(Routes.client_main_module({ web: Value.str(Value.field(input, "web")), package_lines: Value.items(Value.field(input, "packages")).map(Value.str), dir: Value.str_or(Value.field(input, "dir"), ".") })))
			}
			"routeList" => {
				table = Routes.table_from(arg(0))?
				Ok(Array(Routes.route_list(table, Routes.sources_from(arg(1))).map(Routes.row_value)))
			}
			"routesTable" =>
				match Routes.routes_table!(Value.str(arg(0))) {
					Ok(text) => Ok(Text(text))
					Err(Problem(message)) => Err(Routes.failed(message))
				}
			"matches" => Ok(Boolean(Routes.matches(Value.str(arg(0)), Value.str(arg(1)))))
			_ => Err(Unknown(name))
		}
	}
}
