import Env
import Log
import Plugin
import Setting

## The app's plugins (`program.plugins`), as the platform starts and runs them (`main.roc`): checked
## all at once, put in the order their needs say, and logged.
Plugins := [].{

	## Every problem with `plugins` and the app's own routes (`routes`), a line each: what stops the
	## server at start. Whether the environment and the database meet their needs is `unmet!`'s.
	problems : List(Plugin.Running), List({ method : Str, path : Str, file : Str }) -> List(Str)
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
		$found.concat(clashes(plugins, routes)).concat(circles(plugins))
	}

	## The needs of `plugins` the server doesn't meet: an environment variable unset (or empty), a
	## database it wasn't started with.
	unmet! : List(Plugin.Running) => List(Str)
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
							$found = $found.append("${plugin.name}: it needs a database: start the server with --database-url (or DATABASE_URL)")
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
	ordered : List(Plugin.Running) -> List(Plugin.Running)
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

	## What the log says `plugin` added: "jobs: 1 table, 5 loops, 1 start".
	summary : Plugin.Running -> Str
	summary = |plugin| {
		counted = |count, one, many| if (count == 0) [] else ["${count.to_str()} ${if (count == 1) one else many}"]
		parts =
			counted(plugin.claims.len(), "route", "routes")
				.concat(counted(plugin.early.len(), "early route", "early routes"))
				.concat(counted(plugin.migrations.len(), "migration", "migrations"))
				.concat(counted(plugin.calls.len(), "call", "calls"))
				.concat(counted(plugin.loops.len(), "loop", "loops"))
				.concat(counted(plugin.starts.len(), "start", "starts"))
				.concat(counted(plugin.checks.len(), "check", "checks"))
		"${plugin.name}: ${if (parts.is_empty()) "nothing" else Str.join_with(parts, ", ")}"
	}

	## Logs what each plugin added, a line a plugin, in their order.
	log! : List(Plugin.Running) => {}
	log! = |plugins|
		for plugin in plugins {
			Log.line!("rocx plugins: ${Plugins.summary(plugin)}")
		}
}

is_name : Str -> Bool
is_name = |name| !name.is_empty() and name.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-')

## The plugins `plugin` needs.
needed : Plugin.Running -> List(Str)
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
clashes : List(Plugin.Running), List({ method : Str, path : Str, file : Str }) -> List(Str)
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

## Needs that go round in a circle: "auth needs email, which needs auth", once each.
circles : List(Plugin.Running) -> List(Str)
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

none : Plugin.Running
none = { name: "", claims: [], early: [], migrations: [], calls: [], loops: [], starts: [], checks: [], needs: [] }

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
expect Plugins.ordered([{ ..none, name: "auth", needs: [Plugin("email")] }, { ..none, name: "email" }]).map(|plugin| plugin.name) == ["email", "auth"]
expect Plugins.summary({ ..none, name: "jobs", migrations: [{ name: "0001", sql: "" }], loops: [{ name: "jobs.a", run!: |{}| {} }, { name: "jobs.b", run!: |{}| {} }] }) == "jobs: 1 migration, 2 loops"
