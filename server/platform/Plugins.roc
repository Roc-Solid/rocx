import Env
import Host
import Log
import Plugin
import Setting

## The app's plugins (`program.plugins`), as the platform starts and runs them (`main.roc`): checked
## all at once, put in the order their needs say, and logged.
Plugins := [].{

	## Every problem with `plugins` and the app's own routes (`routes`), a line each: what stops the
	## server at start. Whether the environment and the database meet their needs is `unmet!`'s.
	problems : List(Plugin.Running(context)), List({ method : Str, path : Str, file : Str }) -> List(Str)
	problems = |plugins, routes| {
		names = plugins.map(|plugin| plugin.name)
		var $found = []
		var $seen = []
		for plugin in plugins {
			if !is_name(plugin.name) {
				$found = $found.append("plugin \"${plugin.name}\": a plugin's name is lowercase letters, digits and -")
			}
			if $seen.contains(plugin.name) {
				$found = $found.append("two plugins are called ${plugin.name}")
			} else {
				$seen = $seen.append(plugin.name)
			}
			named = plugin.calls.map(|each| ("call", each.name)).concat(plugin.loops.map(|each| ("loop", each.name))).concat(plugin.checks.map(|each| ("check", each.name)))
			for (what, name) in named {
				if !name.starts_with("${plugin.name}.") or name == "${plugin.name}." {
					$found = $found.append("${plugin.name}: the ${what} ${name} is named ${plugin.name}.${name}, with the plugin's name first")
				}
			}
			for early in plugin.early {
				if !early.path.starts_with("/__rocx/") {
					$found = $found.append("${plugin.name}: the early path ${early.path} is under /__rocx/, where the app's paths never are")
				}
			}
			for file in plugin.files {
				if !is_file_path(file.path) {
					$found = $found.append("${plugin.name}: the file ${file.path} needs a relative path (sw.js, icons/bell.svg)")
				} else if file.at == Root and (file.path.starts_with("rocx/") or file.path.starts_with("__rocx/")) {
					$found = $found.append("${plugin.name}: the file ${file.path} is at the root, under /${file.path.split_on("/").first() ?? ""}/, which is the platform's")
				}
			}
			for script in plugin.scripts {
				if !plugin.files.any(|file| file.path == script) {
					$found = $found.append("${plugin.name}: the script ${script} is none of its files")
				}
			}
			for need in plugin.needs {
				match need {
					Plugin(other) =>
						if !names.contains(other) {
							$found = $found.append("${plugin.name} needs the ${other} plugin, which isn't in plugins")
						}
					_ => {}
				}
			}
		}
		$found.concat(clashes(plugins, routes)).concat(file_clashes(plugins, routes)).concat(circles(plugins))
	}

	## The needs of `plugins` the server doesn't meet: an environment variable unset (or empty), a
	## database it wasn't started with.
	unmet! : List(Plugin.Running(context)) => List(Str)
	unmet! = |plugins| {
		var $found = []
		for plugin in plugins {
			for need in plugin.needs {
				match need {
					Env(name) =>
						match Env.var!(name) {
							Ok(value) if !value.is_empty() => {}
							_ => {
								$found = $found.append("${plugin.name}: ${name} isn't set")
							}
						}
					Database =>
						if !Setting.database!({}) {
							$found = $found.append("${plugin.name}: it needs a database: say `database: Sqlite(path)` in the app's program, or start the server with --database-url (or DATABASE_URL)")
						}
					Postgres =>
						if Host.db_flavor!({}) != "postgres" {
							$found = $found.append("${plugin.name}: it needs Postgres, and the app's database is ${described(Host.db_flavor!({}))}")
						}
					Sqlite =>
						if Host.db_flavor!({}) != "sqlite" and Host.db_flavor!({}) != "turso" {
							$found = $found.append("${plugin.name}: it needs SQLite, and the app's database is ${described(Host.db_flavor!({}))}")
						}
					Plugin(_) => {}
				}
			}
		}
		$found
	}

	## `plugins` in the order they start and migrate in: each after the plugins it needs, the
	## list's order breaking ties. (Needs that go round in a circle were refused already; what is
	## left of one goes last, as listed.)
	ordered : List(Plugin.Running(context)) -> List(Plugin.Running(context))
	ordered = |plugins| {
		names = plugins.map(|plugin| plugin.name)
		var $placed = []
		var $left = plugins
		var $going = Bool.True
		while $going {
			placed_names = $placed.map(|plugin| plugin.name)
			ready = $left.find_first_index(|plugin| needed(plugin).all(|other| !names.contains(other) or placed_names.contains(other)))
			match ready {
				Ok(i) =>
					match $left.get(i) {
						Ok(plugin) => {
							$placed = $placed.append(plugin)
							$left = $left.drop_at(i)
						}
						Err(_) => {
							$going = Bool.False
						}
					}
				Err(_) => {
					$going = Bool.False
				}
			}
		}
		$placed.concat($left)
	}

	## What the log says `plugin` adds, counted: "1 migration, 5 loops, 1 start", or "nothing".
	added : Plugin.Running(context) -> Str
	added = |plugin| {
		counted = |count, one, many| if (count == 0) [] else ["${count.to_str()} ${if (count == 1) one else many}"]
		parts =
			counted(plugin.claims.len(), "route", "routes")
				.concat(counted(plugin.early.len(), "early route", "early routes"))
				.concat(counted(plugin.files.len(), "file", "files"))
				.concat(counted(plugin.scripts.len(), "script", "scripts"))
				.concat(counted(plugin.migrations.len(), "migration", "migrations"))
				.concat(counted(plugin.calls.len(), "call", "calls"))
				.concat(counted(plugin.loops.len(), "loop", "loops"))
				.concat(counted(plugin.starts.len(), "start", "starts"))
				.concat(counted(plugin.checks.len(), "check", "checks"))
		if (parts.is_empty()) "nothing" else Str.join_with(parts, ", ")
	}

	## Logs the plugins started, in their order, one line at info (`rocx plugins: jobs, email`, D-111),
	## and with `detailed` (the server's `--debug`) what each added, at debug (`rocx plugins: added`,
	## `plugin=jobs adds="1 migration, 5 loops"`). One that adds nothing but links (the app's own)
	## is in neither.
	log! : List(Plugin.Running(context)), Bool => {}
	log! = |plugins, detailed| {
		named = plugins.keep_if(|plugin| Plugins.added(plugin) != "nothing")
		if detailed {
			for plugin in named {
				Log.debug!("rocx plugins: added", { plugin: plugin.name, adds: Plugins.added(plugin) })
			}
		}
		names = named.map(|plugin| plugin.name)
		if !names.is_empty() {
			Log.info!("rocx plugins: ${Str.join_with(names, ", ")}", {})
		}
	}

	## The plugins' links, in their order, as `Host.dev_links!` takes them (D-111): a line each, its
	## label, a tab, its path or URL.
	links_text : List(Plugin.Running(context)) -> Str
	links_text = |plugins| Str.join_with(plugins.join_map(|plugin| plugin.links).map(|link| "${link.label}\t${link.path}"), "\n")
}

is_name : Str -> Bool
is_name = |name| !name.is_empty() and name.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-')

## The plugins `plugin` needs.
needed : Plugin.Running(context) -> List(Str)
needed = |plugin|
	plugin.needs.keep_oks(
		|need|
			match need {
				Plugin(other) => Ok(other)
				_ => Err(NotAPlugin)
			},
	)

## A route's path with each `[param]` as `[]`: two routes whose paths differ only in their params'
## names answer the same requests.
shape : Str -> Str
shape = |path| Str.join_with(path.split_on("/").map(|segment| if (segment.starts_with("[") and segment.ends_with("]")) "[]" else segment), "/")

## Whether routes for methods `a` and `b` answer some request alike: the same method, or `*`; GET
## and HEAD are one.
same_method : Str, Str -> Bool
same_method = |a, b| {
	plain = |method| if (method == "HEAD") "GET" else method
	a == "*" or b == "*" or plain(a) == plain(b)
}

## Two claims on one method and path: the app's route and a plugin's, two plugins', or two early
## paths; a line each. (The app's own routes are rocx build's to check: a page and its `+server.roc`
## share a path.)
clashes : List(Plugin.Running(context)), List({ method : Str, path : Str, file : Str }) -> List(Str)
clashes = |plugins, routes| {
	claimed =
		routes.map(|route| { method: route.method, path: route.path, owner: route.file, early: Bool.False, by_app: Bool.True })
			.concat(plugins.join_map(|plugin| plugin.claims.map(|claim| { method: claim.method, path: claim.path, owner: "the ${plugin.name} plugin", early: Bool.False, by_app: Bool.False })))
			.concat(plugins.join_map(|plugin| plugin.early.map(|early| { method: early.method, path: early.path, owner: "the ${plugin.name} plugin (early)", early: Bool.True, by_app: Bool.False })))
	var $found = []
	var $i = 0
	while $i < claimed.len() {
		var $j = $i + 1
		while $j < claimed.len() {
			match (claimed.get($i), claimed.get($j)) {
				(Ok(a), Ok(b)) =>
					if a.early == b.early and !(a.by_app and b.by_app) and a.owner != b.owner and same_method(a.method, b.method) and shape(a.path) == shape(b.path) {
						method = if (a.method == "*") b.method else a.method
						$found = $found.append("${method} ${a.path}: ${a.owner}, and ${b.owner}")
					}
				_ => {}
			}
			$j = $j + 1
		}
		$i = $i + 1
	}
	$found
}

## Two files at one URL (two plugins' at the root, or one plugin's twice), and a file at the root
## where a route is (the app's, or a plugin's): a line each. A route with a `[param]` that a file's
## path would fit isn't one: the file is answered first, and the route answers the rest.
file_clashes : List(Plugin.Running(context)), List({ method : Str, path : Str, file : Str }) -> List(Str)
file_clashes = |plugins, routes| {
	files = plugins.join_map(|plugin| plugin.files.map(|file| { url: Plugin.url(plugin.name, file), plugin: plugin.name }))
	others =
		routes.map(|route| { path: route.path, owner: route.file })
			.concat(plugins.join_map(|plugin| plugin.claims.map(|claim| { path: claim.path, owner: "the ${plugin.name} plugin" })))
	var $found = []
	var $i = 0
	while $i < files.len() {
		var $j = $i + 1
		while $j < files.len() {
			match (files.get($i), files.get($j)) {
				(Ok(a), Ok(b)) =>
					if a.url == b.url {
						$found = $found.append(if (a.plugin == b.plugin) "${a.plugin}: two of its files are at ${a.url}" else "${a.url}: the ${a.plugin} plugin's file, and the ${b.plugin} plugin's file")
					}
				_ => {}
			}
			$j = $j + 1
		}
		$i = $i + 1
	}
	for file in files {
		for other in others {
			if other.path == file.url {
				$found = $found.append("${file.url}: ${other.owner}, and the ${file.plugin} plugin's file")
			}
		}
	}
	$found
}

## Whether `path` is a file's relative path: segments of something, none `.` or `..`, no `?` or
## `#`.
is_file_path : Str -> Bool
is_file_path = |path|
	!path.is_empty() and !path.contains("?") and !path.contains("#") and !path.contains("\\") and path.split_on("/").all(|segment| !segment.is_empty() and segment != "." and segment != "..")

## Needs that go round in a circle: "auth needs email, which needs auth", once each.
circles : List(Plugin.Running(context)) -> List(Str)
circles = |plugins| {
	needs_of = |name| plugins.find_first(|plugin| plugin.name == name).map_ok(needed) ?? []
	var $found = []
	var $reported = []
	for plugin in plugins {
		# Walk from `plugin`, depth first, along its needs, until the walk comes back to it.
		var $paths = needed(plugin).map(|other| [plugin.name, other])
		var $steps = 0
		var $circle = Err(NotFound)
		while !$paths.is_empty() and $steps < 1000 and $circle == Err(NotFound) {
			path = $paths.first() ?? []
			$paths = $paths.drop_first(1)
			last = path.last() ?? ""
			if last == plugin.name {
				$circle = Ok(path)
			} else if path.drop_last(1).contains(last) {
				{}
			} else {
				$paths = $paths.concat(needs_of(last).map(|other| path.append(other)))
			}
			$steps = $steps + 1
		}
		match $circle {
			Ok(path) =>
				if !path.any(|name| $reported.contains(name)) {
					$reported = $reported.concat(path)
					first = path.first() ?? ""
					rest = path.drop_first(1).map(|name| "which needs ${name}")
					$found = $found.append("${first} needs ${Str.join_with(rest, ", ").drop_prefix("which needs ")}")
				}
			Err(_) => {}
		}
	}
	$found
}

none : Plugin.Running({})
none = { name: "", claims: [], early: [], files: [], scripts: [], migrations: [], calls: [], loops: [], starts: [], checks: [], needs: [], links: [] }

expect is_name("push") and is_name("open-api2") and !is_name("Push") and !is_name("")
expect shape("/push/[id]/x") == "/push/[]/x"
expect same_method("*", "POST") and same_method("GET", "HEAD") and !same_method("GET", "POST")
expect
	Plugins.problems([{ ..none, name: "push", claims: [{ method: "GET", path: "/push/key" }] }], [{ method: "GET", path: "/push/key", file: "routes/push/key/+server.roc" }])
		== ["GET /push/key: routes/push/key/+server.roc, and the push plugin"]
expect
	Plugins.problems([{ ..none, name: "a", claims: [{ method: "*", path: "/x/[id]" }] }, { ..none, name: "b", claims: [{ method: "POST", path: "/x/[key]" }] }], [])
		== ["POST /x/[id]: the a plugin, and the b plugin"]
expect Plugins.problems([], [{ method: "GET", path: "/m", file: "routes/m/+page.rocx" }, { method: "GET", path: "/m", file: "routes/m/+server.roc" }]) == []
expect Plugins.problems([{ ..none, name: "auth", needs: [Plugin("email")] }], []) == ["auth needs the email plugin, which isn't in plugins"]
expect
	Plugins.problems([{ ..none, name: "auth", needs: [Plugin("email")] }, { ..none, name: "email", needs: [Plugin("auth")] }], [])
		== ["auth needs email, which needs auth"]
expect Plugins.problems([{ ..none, name: "push", loops: [{ name: "deliver", run!: |{}| {} }] }], []) == ["push: the loop deliver is named push.deliver, with the plugin's name first"]
expect Plugins.problems([{ ..none, name: "a" }, { ..none, name: "a" }], []) == ["two plugins are called a"]
expect is_file_path("push-sw.js") and is_file_path("icons/bell.svg") and !is_file_path("/sw.js") and !is_file_path("../x") and !is_file_path("a//b") and !is_file_path("")
expect
	Plugins.problems([{ ..none, name: "push", files: [{ path: "x", at: Root, content_type: "text/plain", body: [] }] }], [{ method: "POST", path: "/x", file: "routes/x/+server.roc" }])
		== ["/x: routes/x/+server.roc, and the push plugin's file"]
expect
	Plugins.problems([{ ..none, name: "a", files: [{ path: "sw.js", at: Root, content_type: "text/javascript", body: [] }] }, { ..none, name: "b", files: [{ path: "sw.js", at: Root, content_type: "text/javascript", body: [] }, { path: "sw.js", at: Plugin, content_type: "text/javascript", body: [] }] }], [])
		== ["/sw.js: the a plugin's file, and the b plugin's file"]
expect Plugins.problems([{ ..none, name: "a", scripts: ["a.js"] }], []) == ["a: the script a.js is none of its files"]
expect Plugins.ordered([{ ..none, name: "auth", needs: [Plugin("email")] }, { ..none, name: "email" }]).map(|plugin| plugin.name) == ["email", "auth"]
expect Plugins.added({ ..none, name: "jobs", migrations: [{ name: "0001", sql: "" }], loops: [{ name: "jobs.a", run!: |{}| {} }, { name: "jobs.b", run!: |{}| {} }] }) == "1 migration, 2 loops"
expect Plugins.added({ ..none, name: "quiet" }) == "nothing"

## The database the server opened (`Host.db_flavor!`), for a message.
described : Str -> Str
described = |flavor|
	match flavor {
		"postgres" => "Postgres"
		"sqlite" => "SQLite"
		"turso" => "Turso"
		_ => "none"
	}
