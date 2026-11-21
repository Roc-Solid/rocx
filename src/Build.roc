## `rocx build`: every .rocx file under an app's directory into the .roc beside it, its route files
## into modules under Generated/ with Routes, Paths, Styles, Api, Root and App, the components of the
## packages its headers name into Generated/<package>/, a dev build's stories, and with `--client`
## the browser's copy of the app (was bin/rocx.mjs's build()).
import Fs
import Text
import Transpile
import Routes
import Stories

Build := [].{

	## Where rocx writes the modules for an app's routes.
	generated : Str
	generated = "Generated"

	## The module rocx writes the app's component pages in.
	root_module_name : Str
	root_module_name = "Root"

	## The module rocx writes the app's program in.
	app_module_name : Str
	app_module_name = "App"

	## `rocx build`: whether every file built, and what it had to say, a message each. Paths are
	## relative to `cwd`; `rocx` is where rocx is (the repo: web/platform, web/start.js and
	## web/runtime.js are there). `Err` for what the JavaScript threw (a wrong `--client`).
	build! : List(Str), { client : [Some(Str), None], cwd : Str, dev : Bool, rocx : Str } => Try({ ok : Bool, said : List(Str) }, [Problem(Str)])
	build! = |dirs, options| {
		match options.client {
			Some(_) if dirs.len() > 1 => return Err(Problem("rocx build --client: one directory, the app's"))
			_ => {}
		}
		var $state = { failed: Bool.False, written: 0, said: [] }
		for given in dirs {
			$state = Build.build_dir!(given, options, $state)?
		}
		final = $state
		said = if (final.written > 0) final.said.append("rocx: ${final.written.to_str()} file${if (final.written == 1) "" else "s"} written") else final.said
		Ok({ ok: !final.failed, said })
	}

	## One directory's build: what `build!` does for each.
	build_dir! : Str, { client : [Some(Str), None], cwd : Str, dev : Bool, rocx : Str }, { failed : Bool, written : U64, said : List(Str) } => Try({ failed : Bool, written : U64, said : List(Str) }, [Problem(Str)])
	build_dir! = |given, options, state| {
		cwd = options.cwd
		dir = Fs.resolve(cwd, [given])
		var $failed = state.failed
		var $written = state.written
		var $said = state.said
		here = Build.shown(cwd, dir)
		# The browser's code for each .rocx file, by its path (a route's: its module's, as .rocx).
		var $browser = []
		var $codes = []
		var $styles = []
		var $stories = []
		var $contexts = []
		pkgs = Build.component_packages!(dir)
		var $views = []
		output = |path| {
			last = Fs.basename(path)
			last == "build" or last == "dist"
		}
		package_paths = pkgs.join_map(|pkg| pkg.paths)
		for path in Fs.files!(dir, ".rocx", output).concat(package_paths) {
			module_name = Fs.basename(Fs.relative(dir, path).drop_suffix(".rocx"))
			source = Fs.read_or_empty!(path)
			for found in Transpile.contexts_defined(source) {
				if found.shared {
					$contexts = Build.put($contexts, Transpile.pascal_case(found.name), "${module_name}.${found.name}")
				}
			}
			$views = Build.views_of($views, source)
		}
		not_output = |path| {
			last = Fs.basename(path)
			last == "build" or last == "dist" or last == Build.generated
		}
		for path in Fs.files!(dir, ".roc", not_output) {
			if !Fs.exists!("${path}x") and !Build.is_generated!(path) {
				$views = Build.views_of($views, Fs.read_or_empty!(path))
			}
		}
		contexts = $contexts
		views = $views
		# Route files (`routes/blog/[slug]/+page.rocx`) are modules rocx writes under Generated/.
		routes = Fs.join([dir, "routes"])
		route_files = Routes.find_route_files!(routes)
		is_route = |path| Routes.is_route_file(Fs.basename(path)) and (Fs.relative(routes, path).split_on("/").first() ?? "") != ".."
		table =
			match Routes.route_table(route_files) {
				Ok(made) => made
				Err(Problem(message)) => return Ok({ failed: Bool.True, written: $written, said: $said.append("✗ ${here}/${message}") })
			}
		routed = Routes.entries(table).map(|entry| { path: Fs.join([routes].concat(entry.file.split_on("/"))), entry })
		var $route_outputs = []
		for each in routed {
			path = each.path
			entry = each.entry
			out = Fs.join([dir, Build.generated, "${entry.module_name}.roc"])
			$route_outputs = $route_outputs.append(out)
			if Fs.exists!(out) and !Build.is_generated!(out) {
				$said = $said.append("✗ ${Fs.relative(cwd, path)}: ${Fs.relative(cwd, out)} exists and was not written by rocx; rename one of them")
				$failed = Bool.True
			} else {
				source = Build.link_components(Fs.read_or_empty!(path), path, dir, pkgs)
				file = Fs.relative(cwd, path)
				module_path = "${Build.generated}/${entry.module_name}"
				place = { name: entry.module_name, source: path, generated: out }
				server_copy = { module_path, client: Bool.False, contexts, views, route: Bool.False }
				attempt =
					match Transpile.transpile_module(source, file, server_copy) {
						Err(Rocx(problem)) => Err(Build.rocx_message!(path, problem))
						Err(Crash(message)) => Err("✗ ${message}")
						Ok(made) =>
							match Routes.route_module(made.code, place) {
								Err(Problem(message)) => Err("✗ ${message}")
								Ok(server_module) => {
									browser_module =
										match options.client {
											None => Ok(None)
											Some(_) =>
												match Transpile.transpile_module(source, file, { module_path, client: Bool.True, contexts, views, route: Bool.True }) {
													Err(Rocx(problem)) => Err(Build.rocx_message!(path, problem))
													Err(Crash(message)) => Err("✗ ${message}")
													Ok(browser_made) =>
														match Routes.route_module(browser_made.code, place) {
															Ok(text) => Ok(Some(text))
															Err(Problem(message)) => Err("✗ ${message}")
														}
												}
										}
									match browser_module {
										Err(message) => Err(message)
										Ok(browser_text) => Ok({ made, server_module, browser_text })
									}
								}
							}
					}
				match attempt {
					Err(message) => {
						$said = $said.append(message)
						$failed = Bool.True
					}
					Ok({ made, server_module, browser_text }) => {
						$codes = $codes.append(made.code)
						file_in_app = Fs.relative(dir, path)
						$styles = $styles.concat(made.styles.map(|style| { file: file_in_app, line: style.line, component: style.component, css: style.css }))
						match browser_text {
							Some(text) => {
								$browser = $browser.append({ key: "${out.drop_suffix(".roc")}.rocx", value: text })
							}
							None => {}
						}
						if Build.write!(out, server_module) {
							$written = $written + 1
						}
					}
				}
			}
		}
		# An app's stories/ holds stories alone (drafts beside one another): only a dev build has it.
		stories_only = |path| (Fs.relative(dir, path).split_on("/").first() ?? "") == Stories.stories_dir
		for path in Fs.files!(dir, ".rocx", output) {
			if !is_route(path) and (options.dev or !stories_only(path)) {
				out = "${path.drop_suffix(".rocx")}.roc"
				if Fs.exists!(out) and !Build.is_generated!(out) {
					$said = $said.append("✗ ${Fs.relative(cwd, path)}: ${Fs.relative(cwd, out)} exists and was not written by rocx; rename one of them")
					$failed = Bool.True
				} else {
					source = Build.link_components(Fs.read_or_empty!(path), path, dir, pkgs)
					file = Fs.relative(cwd, path)
					module_path = Fs.relative(dir, path).drop_suffix(".rocx")
					match Transpile.transpile_module(source, file, { module_path, client: Bool.False, contexts, views, route: Bool.False }) {
						Err(Rocx(problem)) => {
							$said = $said.append(Build.rocx_message!(path, problem))
							$failed = Bool.True
						}
						Err(Crash(message)) => return Err(Problem(message))
						Ok(made) => {
							$codes = $codes.append(made.code)
							file_in_app = Fs.relative(dir, path)
							$styles = $styles.concat(made.styles.map(|style| { file: file_in_app, line: style.line, component: style.component, css: style.css }))
							$stories = $stories.concat(made.stories.map(|story| { file: file_in_app, module_path, component: story.component, name: story.name, def: story.def, line: story.line }))
							match options.client {
								None => {}
								Some(_) =>
									if made.regions > 0 {
										match Transpile.transpile_module(source, file, { module_path, client: Bool.True, contexts, views, route: Bool.False }) {
											Ok(browser_made) => {
												$browser = $browser.append({ key: path, value: browser_made.code })
											}
											Err(Rocx(problem)) => {
												$said = $said.append(Build.rocx_message!(path, problem))
												$failed = Bool.True
											}
											Err(Crash(message)) => return Err(Problem(message))
										}
									} else {
										$browser = $browser.append({ key: path, value: made.code })
									}
							}
							if Build.write!(out, made.code) {
								$written = $written + 1
							}
						}
					}
				}
			}
		}
		# Each package's components, copied into the app (`Generated/charts/BarChart.roc`): imported by
		# the name the app's header gives the package, its <style> in the app's stylesheet, and the
		# compiler's reports pointed at the package's file.
		for pkg in pkgs {
			for path in pkg.paths {
				name = Fs.basename_without(path, ".rocx")
				out = Fs.join([dir, Build.generated, pkg.name, "${name}.roc"])
				$route_outputs = $route_outputs.append(out)
				if Fs.exists!(out) and !Build.is_generated!(out) {
					$said = $said.append("✗ ${Fs.relative(cwd, out)} exists and was not written by rocx; rename it")
					$failed = Bool.True
				} else {
					read = Fs.read_or_empty!(path)
					# Its own package, which it imports by the package's directory's name, as the app names it.
					source = if (pkg.own != pkg.name) Build.rename_package_imports(read, pkg.own, pkg.name) else read
					match Transpile.transpile_module(source, Fs.relative(cwd, path), { module_path: "${Build.generated}/${pkg.name}/${name}", client: Bool.False, contexts, views, route: Bool.False }) {
						Err(Rocx(problem)) => {
							$said = $said.append(Build.rocx_message!(path, problem))
							$failed = Bool.True
						}
						Err(Crash(message)) => return Err(Problem(message))
						Ok(made) => {
							$codes = $codes.append(made.code)
							file_in_app = Fs.relative(dir, path)
							$styles = $styles.concat(made.styles.map(|style| { file: file_in_app, line: style.line, component: style.component, css: style.css }))
							from = Fs.relative(Fs.dirname(out), path)
							if Build.write!(out, Build.reattribute(made.code, from)) {
								$written = $written + 1
							}
						}
					}
				}
			}
		}
		if $failed {
			return Ok({ failed: $failed, written: $written, said: $said })
		}
		# The browser's app, for an app of component pages (`--client`): written with its copy.
		var $main = None
		if !route_files.is_empty() {
			var $sources = []
			for entry in Routes.entries(table) {
				$sources = $sources.append({ file: entry.file, defs: Routes.definitions(Fs.read_or_empty!(Fs.join([routes].concat(entry.file.split_on("/"))))) })
			}
			sources = $sources
			for server in table.servers {
				defined = Routes.defs_of(sources, server.file)
				file = Fs.relative(cwd, Fs.join([routes].concat(server.file.split_on("/"))))
				if !defined.hooks.is_empty() {
					hooks = Str.join_with(defined.hooks, ", ")
					are = if (defined.hooks.len() == 1) "is a channel's hook" else "are a channel's hooks"
					$said = $said.append("✗ ${file}: ${hooks} ${are}, and it defines no channel: define channel!, its check")
					$failed = Bool.True
				}
				has_channel =
					match defined.channel {
						Some(_) => Bool.True
						None => Bool.False
					}
				if defined.methods.is_empty() and !defined.respond and !has_channel and defined.hooks.is_empty() {
					$said = $said.append("✗ ${file}: a +server answers methods: define one of ${Str.join_with(Routes.method_names, ", ")}, or respond!, or a channel (channel!)")
					$failed = Bool.True
				}
			}
			for problem in Routes.view_problems(table, sources) {
				$said = $said.append("✗ ${here}/${problem}")
				$failed = Bool.True
			}
			pages = Routes.has_pages(table)
			jobs = Routes.jobs_in!(dir, table)
			actors = Routes.actors_in!(dir, table)
			for problem in jobs.problems.concat(actors.problems) {
				$said = $said.append("✗ ${here}/${problem}")
				$failed = Bool.True
			}
			if $failed {
				return Ok({ failed: $failed, written: $written, said: $said })
			}
			# A dev build's stories, each at its id; only a dev build has them.
			placed =
				if options.dev {
					match Stories.story_ids($stories) {
						Err(Problem(message)) => return Ok({ failed: Bool.True, written: $written, said: $said.append("✗ ${message}") })
						Ok(ids) => {
							# A story is the app's page (Root renders it): an app with no pages has nowhere to show one.
							if !pages {
								for story in ids {
									$said = $said.append("✗ ${Fs.relative(cwd, Fs.join([dir, story.file]))}:${story.line.to_str()}: the story \"${story.name}\" is shown as the app's page, and the app has none: give it routes/ with a +page.rocx")
									$failed = Bool.True
								}
							}
							Some(ids)
						}
					}
				} else {
					None
				}
			if $failed {
				return Ok({ failed: $failed, written: $written, said: $said })
			}
			title = Fs.basename(dir)
			endpoints = !table.servers.is_empty()
			stories_page =
				match placed {
					Some(ids) => [{ name: "Stories", content: Stories.stories_module(ids, title, dir) }]
					None => []
				}
			api =
				if endpoints {
					tags = Routes.tag_names($codes.concat(Build.roc_code!(dir)))
					[{ name: "Api", content: Routes.api_module(table, sources, { client: Bool.False, tags, title }) }]
				} else {
					[]
				}
			root_page = if (pages) [{ name: Build.root_module_name, content: Routes.root_module(table, sources, (match placed { Some(ids) => ids, None => [] })) }] else []
			modules_written =
				[{ name: "Routes", content: Routes.routes_module(table, sources, placed) }]
					.concat(stories_page)
					.concat([{ name: "Paths", content: Routes.paths_module(table) }, { name: "Styles", content: Build.styles_module($styles) }])
					.concat(api)
					.concat(root_page)
					.concat([{ name: Build.app_module_name, content: Routes.app_module({ jobs: jobs.jobs, actors: actors.actors, migrations: Routes.migrations_in!(dir), endpoints }) }])
			if pages {
				match options.client {
					Some(_) => {
						$main = Some(here)
					}
					None => {}
				}
			}
			if endpoints {
				match options.client {
					Some(_) => {
						$browser = $browser.append({ key: Fs.join([dir, Build.generated, "Api.rocx"]), value: Routes.api_module(table, sources, { client: Bool.True, tags: [], title: "app" }) })
					}
					None => {}
				}
			}
			for each in modules_written {
				out = Fs.join([dir, Build.generated, "${each.name}.roc"])
				$route_outputs = $route_outputs.append(out)
				if Fs.exists!(out) and !Build.is_generated!(out) {
					$said = $said.append("✗ ${Fs.relative(cwd, out)} exists and was not written by rocx; rename it")
					$failed = Bool.True
				} else if Build.write!(out, each.content) {
					$written = $written + 1
				}
			}
		}
		if route_files.is_empty() and !$styles.is_empty() {
			files = Str.join_with(Text.unique($styles.map(|style| style.file)), ", ")
			$said = $said.append("rocx: ${here} has <style>s (${files}) but no routes/, so no layout to put them in")
		}
		# A .roc file rocx wrote for a .rocx file that is gone is stale, and so is a route's that is
		# gone (a route file's .roc beside it, from a rocx before routes, too: its module is under
		# Generated/); so is a story module's, but in a dev build.
		for path in Fs.files!(dir, ".roc", |_| Bool.False) {
			rocx = "${path.drop_suffix(".roc")}.rocx"
			stale = !Fs.exists!(rocx) or is_route(rocx) or (stories_only(path) and !options.dev)
			if !$route_outputs.contains(path) and stale and Build.is_generated!(path) {
				Fs.delete!(path)
			}
		}
		match options.client {
			Some(client) => {
				Build.write_client!(dir, Fs.resolve(cwd, [client]), $browser, $main, options.rocx)?
			}
			None => {}
		}
		Ok({ failed: $failed, written: $written, said: $said })
	}

	## A path as the build's messages show it: relative to `cwd`, `.` for `cwd` itself.
	shown : Str, Str -> Str
	shown = |cwd, path| {
		rel = Fs.relative(cwd, path)
		if (rel.is_empty()) "." else rel
	}

	## A RocxError as the build reports it: where, why, the line, and a caret under the column.
	rocx_message! : Str, { reason : Str, file : Str, line : U64, column : U64 } => Str
	rocx_message! = |path, problem| {
		line = Text.lines(Fs.read_or_empty!(path)).get(problem.line - 1) ?? ""
		"✗ ${problem.file}:${problem.line.to_str()}:${problem.column.to_str()}: ${problem.reason}\n    ${line}\n    ${" ".repeat(problem.column - 1)}^"
	}

	## `list` with `key` set to `value` (replacing what it had).
	put : List({ key : Str, value : Str }), Str, Str -> List({ key : Str, value : Str })
	put = |list, key, value|
		match list.find_first_index(|each| each.key == key) {
			Ok(i) => list.set(i, { key, value }) ?? list
			Err(_) => list.append({ key, value })
		}

	## The value of `key`, if `list` has one.
	get : List({ key : Str, value : Str }), Str -> [Some(Str), None]
	get = |list, key|
		match list.find_first(|each| each.key == key) {
			Ok(found) => Some(found.value)
			Err(_) => None
		}

	## How each component is called, with `source`'s: a name some module defines with `view!` stays `view!`.
	views_of : List({ key : Str, value : Str }), Str -> List({ key : Str, value : Str })
	views_of = |known, source|
		Transpile.views_defined(source).fold(known, |so_far, found| Build.put(so_far, found.key, if (Build.get(so_far, found.key) == Some("view!")) "view!" else found.value))

	## Whether rocx wrote `path`: its last line is the marker (a file that only mentions it, in a string, isn't).
	is_generated! : Str => Bool
	is_generated! = |path| (Text.lines(Text.trim_end(Fs.read_or_empty!(path))).last() ?? "").starts_with(Transpile.marker)

	## Writes `content` to `path` unless it is there already (a watcher that sees the file would
	## rebuild again): whether it wrote it.
	write! : Str, Str => Bool
	write! = |path, content| {
		if Fs.exists!(path) and Fs.read_or_empty!(path) == content {
			Bool.False
		} else {
			_ = Fs.write!(path, content)
			Bool.True
		}
	}

	## A package component's code, its last line naming the package's file (`from`, relative to it).
	reattribute : Str, Str -> Str
	reattribute = |code, from| {
		lines = Text.lines(code)
		# The marker's line, then the empty one after the code's last newline.
		count = lines.len()
		last = if (count >= 2) lines.get(count - 2) ?? "" else ""
		if count >= 2 and last.starts_with("${Transpile.marker} ") and (lines.get(count - 1) ?? "") == "" {
			Str.join_with(lines.take_first(count - 2).append("${Transpile.marker} ${from}: edit that file, not this one. Line N here is line N there.").append(""), "\n")
		} else {
			code
		}
	}

	## `import <own>.X` as `import <name>.X`, at the start of each line.
	rename_package_imports : Str, Str, Str -> Str
	rename_package_imports = |source, own, name|
		Str.join_with(
			Text.lines(source).map(
				|line| {
					bytes = line.to_utf8()
					if line.starts_with("import") {
						after = Text.skip_space(bytes, 6)
						if after > 6 and Text.starts_with_at(bytes, "${own}.".to_utf8(), after) {
							"import ${name}.".concat(Text.rest(bytes, after + own.to_utf8().len() + 1))
						} else {
							line
						}
					} else {
						line
					}
				},
			),
			"\n",
		)

	## Generated/Styles.roc: every <style>, scoped to the markup it styles (a component's, or a
	## file's), as one stylesheet, which the root layout puts in its <head>.
	styles_module : List({ file : Str, line : U64, component : [Some(Str), None], css : Str }) -> Str
	styles_module = |styles| {
		ordered = styles.sort_with(
			|a, b|
				match Text.order(a.file, b.file) {
					Same => if (a.line < b.line) Before else if (a.line > b.line) After else Same
					other => other
				},
		)
		css = Str.join_with(
			ordered.map(
				|style| {
					owner =
						match style.component {
							Some(name) => ", ${name}"
							None => ""
						}
					"/* ${style.file}${owner} */\n${style.css}"
				},
			),
			"\n\n",
		)
		literal =
			if css.is_empty() {
				"\tcss = \"\""
			} else {
				lines = Str.join_with(Text.lines(css).map(|line| "\t\t${Text.roc_string(line)},"), "\n")
				"\tcss = Str.join_with([\n${lines}\n\t], \"\\n\")"
			}
		style_value = if (css.is_empty()) "Html.empty({})" else "Html.element(\"style\", [], [Html.source_text(css)])"
		Str.join_with(
			[
				"## Every <style> in the app's .rocx files, scoped to the markup it styles (a component's, or at a",
				"## file's top level the file's), as one stylesheet, which the root layout puts in its <head>:",
				"## `{=Styles.style}`. Written by rocx build: edit the <style>s.",
				"import pf.Html",
				"",
				"Styles := [].{",
				"\t## The stylesheet's text.",
				"\tcss : Str",
				literal,
				"",
				"\t## The stylesheet, as a <style> element; nothing when no file has a <style>.",
				"\tstyle : Html",
				"\tstyle = ${style_value}",
				"}",
				"",
				"${Transpile.marker} every .rocx file's <style>: rocx build writes it.",
				"",
			],
			"\n",
		)
	}

	## Relative paths in an app's, a package's or a platform's header, made relative to `to` instead of `from`.
	move_header : Str, Str, Str -> Str
	move_header = |code, from, to| {
		bytes = code.to_utf8()
		start =
			match Build.header_start(bytes) {
				Ok(at) => at
				Err(_) => return code
			}
		open =
			match Text.index_of_byte(bytes, '{', start) {
				Ok(at) => at
				Err(_) => return code
			}
		var $end = open
		var $depth = 0
		var $closed = Bool.False
		while $end < bytes.len() and !$closed {
			c = Text.at(bytes, $end)
			if c == '{' {
				$depth = $depth + 1
				$end = $end + 1
			} else if c == '}' {
				$depth = $depth - 1
				if $depth == 0 {
					$closed = Bool.True
				} else {
					$end = $end + 1
				}
			} else {
				$end = $end + 1
			}
		}
		header = Text.slice(bytes, start, $end)
		# Each "./…" or "../…" string in it.
		var $out = []
		var $i = 0
		while $i < header.len() {
			if Text.at(header, $i) == '"' {
				close = Text.index_of_byte(header, '"', $i + 1) ?? header.len()
				inside = Text.cut(header, $i + 1, close)
				relative_path = inside.starts_with("./") or inside.starts_with("../")
				if relative_path and close < header.len() {
					moved = Fs.relative(Fs.dirname(to), Fs.resolve(Fs.dirname(from), [inside]))
					moved_shown = if (moved.starts_with(".")) moved else "./${moved}"
					$out = $out.concat(Text.json_string(moved_shown).to_utf8())
					$i = close + 1
				} else if close < header.len() {
					$out = $out.concat(Text.slice(header, $i, close + 1))
					$i = close + 1
				} else {
					$out = $out.concat(Text.slice(header, $i, header.len()))
					$i = header.len()
				}
			} else {
				$out = $out.append(Text.at(header, $i))
				$i = $i + 1
			}
		}
		Text.cut(bytes, 0, start).concat(Str.from_utf8_lossy($out)).concat(Text.rest(bytes, $end))
	}

	## Where the first line starting with `app`, `package` or `platform` (a whole word) is.
	header_start : List(U8) -> Try(U64, [NotFound])
	header_start = |bytes| {
		var $at = 0
		while $at <= bytes.len() {
			for word in ["app", "package", "platform"] {
				w = word.to_utf8()
				if Text.starts_with_at(bytes, w, $at) and !Text.is_word(Text.at(bytes, $at + w.len())) {
					return Ok($at)
				}
			}
			match Text.index_of_byte(bytes, '\n', $at) {
				Ok(newline) => {
					$at = newline + 1
				}
				Err(_) => {
					$at = bytes.len() + 1
				}
			}
		}
		Err(NotFound)
	}

	## The browser's copy of the app under `dir`, in `out`: every .roc file, at the same place, but
	## a `<NoHydration>` has no children and a route file no middleware (`client` has the browser's
	## code for each .rocx file, by its path). Build output (`build/`, `dist/`) stays out.
	## `main`: for an app of component pages, the browser's app (main.roc), with the app's directory as
	## the build shows it.
	write_client! : Str, Str, List({ key : Str, value : Str }), [Some(Str), None], Str => Try({}, [Problem(Str)])
	write_client! = |dir, out, client, main, rocx| {
		root = Fs.resolve(dir, [])
		target = Fs.resolve(out, [])
		if target == root or (Fs.relative(target, root).split_on("/").first() ?? "") != ".." {
			return Err(Problem("--client ${out}: it would hold ${dir} itself"))
		}
		ours = Fs.join([target, ".rocx-client"])
		if Fs.exists!(target) and !Fs.exists!(ours) {
			return Err(Problem("--client ${out}: it exists and rocx didn't write it"))
		}
		# What rocx wrote before goes, but the wasm built from it stays (`static/rocx/*.wasm`): rocx
		# doesn't build it, so a server serving the app goes on serving pages that hydrate until the
		# wasm's own build replaces it.
		Build.clear!(target, "")
		skip = |path| {
			last = Fs.basename(path)
			Fs.resolve(path, []) == target or last == "build" or last == "dist"
		}
		for path in Fs.files!(dir, ".roc", skip) {
			to = Fs.join([target, Fs.relative(dir, path)])
			code =
				match Build.get(client, "${path.drop_suffix(".roc")}.rocx") {
					Some(browser_code) => browser_code
					None => Fs.read_or_empty!(path)
				}
			_ = Build.write!(to, Build.move_header(code, path, to))
		}
		# An app of component pages: the browser's app (main.roc, its root the app's page), and what
		# a page loads beside the wasm built from it (`static/rocx/`, served at /rocx/).
		match main {
			Some(shown_dir) => {
				main_module = Routes.client_main_module({ web: Build.web_platform!(target, rocx), package_lines: Build.header_packages!(dir, target), dir: shown_dir })
				_ = Build.write!(Fs.join([target, "main.roc"]), main_module)
				for name in ["start.js", "runtime.js"] {
					_ = Build.write!(Fs.join([target, "static", "rocx", name]), Fs.read_or_empty!(Fs.join([rocx, "web", name])))
				}
			}
			None => {}
		}
		_ = Fs.write!(ours, "The browser's copy of an app, written by rocx build --client: don't edit.\n")
		Ok({})
	}

	## Empties `dir` but for the wasm built from the copy (`static/rocx/*.wasm`, by its path inside it),
	## which stays where it is; a directory left empty goes.
	clear! : Str, Str => {}
	clear! = |dir, inside| {
		if !Fs.exists!(dir) {
			return {}
		}
		for entry in Fs.entries!(dir) {
			path = Fs.join([dir, entry])
			named = if (inside.is_empty()) entry else Fs.join([inside, entry])
			if Fs.is_dir!(path) {
				Build.clear!(path, named)
				if Fs.entries!(path).is_empty() {
					Fs.delete_all!(path)
				}
			} else if !(Fs.dirname(named) == "static/rocx" and named.ends_with(".wasm")) {
				Fs.delete!(path)
			}
		}
		{}
	}

	## A path as Roc resolves it, through symbolic links (`/tmp` is `/private/tmp` on macOS): its
	## nearest directory that is there, resolved, and the rest as it is.
	real! : Str => Str
	real! = |path| {
		var $at = path
		var $rest = []
		while !Fs.exists!($at) and Fs.dirname($at) != $at {
			$rest = $rest.prepend(Fs.basename($at))
			$at = Fs.dirname($at)
		}
		base = if (Fs.exists!($at)) Fs.real!($at) else $at
		Fs.join([base].concat($rest))
	}

	## The web platform's main.roc, as the browser's app at `out` names it.
	web_platform! : Str, Str => Str
	web_platform! = |out, rocx| {
		path = Fs.relative(Build.real!(out), Build.real!(Fs.join([rocx, "web", "platform", "main.roc"])))
		if (path.starts_with(".")) path else "./${path}"
	}

	## The `{ … }` of the first `app [program] { … }` header in `code` (`program` only, or any `[…]`).
	app_header : Str, Bool -> Try(Str, [NotFound])
	app_header = |code, program_only| {
		bytes = code.to_utf8()
		var $at = 0
		while $at <= bytes.len() {
			match Build.app_header_at(bytes, $at, program_only) {
				Some(found) => return Ok(found)
				None => {}
			}
			$at =
				match Text.index_of_byte(bytes, '\n', $at) {
					Ok(newline) => newline + 1
					Err(_) => bytes.len() + 1
				}
		}
		Err(NotFound)
	}

	## `^app\s*\[\s*program\s*\]\s*\{([^}]*)\}` (or `\[[^\]]*\]`) at `at`.
	app_header_at : List(U8), U64, Bool -> [Some(Str), None]
	app_header_at = |bytes, at, program_only| {
		if !Text.starts_with_at(bytes, "app".to_utf8(), at) {
			return None
		}
		open = Text.skip_space(bytes, at + 3)
		if Text.at(bytes, open) != '[' {
			return None
		}
		close =
			if program_only {
				word = Text.skip_space(bytes, open + 1)
				if !Text.starts_with_at(bytes, "program".to_utf8(), word) {
					return None
				}
				after = Text.skip_space(bytes, word + 7)
				if (Text.at(bytes, after) == ']') after else return None
			} else {
				match Text.index_of_byte(bytes, ']', open + 1) {
					Ok(found) => found
					Err(_) => return None
				}
			}
		brace = Text.skip_space(bytes, close + 1)
		if Text.at(bytes, brace) != '{' {
			return None
		}
		match Text.index_of_byte(bytes, '}', brace + 1) {
			Ok(end) => Some(Text.cut(bytes, brace + 1, end))
			Err(_) => None
		}
	}

	## Each `name: "path"` in a header (`platform` ones only with `platform` before the string when
	## `with_platform`; without, those don't match at all), as `{ name, platform, path }`.
	named_paths : Str, Bool -> List({ name : Str, is_platform : Bool, path : Str })
	named_paths = |header, with_platform| {
		bytes = header.to_utf8()
		var $found = []
		var $i = 0
		while $i < bytes.len() {
			match Build.named_path_at(bytes, $i, with_platform) {
				Some(each) => {
					$found = $found.append(each.found)
					$i = each.end
				}
				None => {
					$i = $i + 1
				}
			}
		}
		$found
	}

	## `([a-z_][a-z0-9_]*)\s*:\s*(platform\s+)?"([^"]+)"` at `i`.
	named_path_at : List(U8), U64, Bool -> [Some({ found : { name : Str, is_platform : Bool, path : Str }, end : U64 }), None]
	named_path_at = |bytes, i, with_platform| {
		first = Text.at(bytes, i)
		if !(Text.is_lower(first) or first == '_') {
			return None
		}
		name_end = Text.run_end(bytes, i + 1, |b| Text.is_lower(b) or Text.is_digit(b) or b == '_')
		colon = Text.skip_space(bytes, name_end)
		if Text.at(bytes, colon) != ':' {
			return None
		}
		value = Text.skip_space(bytes, colon + 1)
		platform_word = Text.starts_with_at(bytes, "platform".to_utf8(), value)
		after_word = Text.skip_space(bytes, value + 8)
		is_platform = with_platform and platform_word and after_word > value + 8 and Text.at(bytes, after_word) == '"'
		quote = if (is_platform) after_word else value
		if Text.at(bytes, quote) != '"' {
			return None
		}
		match Text.index_of_byte(bytes, '"', quote + 1) {
			Ok(close) if close > quote + 1 => Some({ found: { name: Text.cut(bytes, i, name_end), is_platform, path: Text.cut(bytes, quote + 1, close) }, end: close + 1 })
			_ => None
		}
	}

	## The packages the app's server half names in its header (main.roc's, or another
	## `app [program]`'s), besides its platform, each as the browser's app at `out` names it.
	header_packages! : Str, Str => List(Str)
	header_packages! = |dir, out| {
		named = if (Fs.exists!(Fs.join([dir, "main.roc"]))) ["main.roc"] else Fs.entries!(dir).keep_if(|entry| entry.ends_with(".roc"))
		for entry in named {
			match Build.app_header(Fs.read_or_empty!(Fs.join([dir, entry])), Bool.True) {
				Err(_) => {}
				Ok(header) => {
					var $lines = []
					for each in Build.named_paths(header, Bool.True) {
						if !each.is_platform {
							if !(each.path.starts_with("./") or each.path.starts_with("../")) {
								$lines = $lines.append("${each.name}: ${Text.json_string(each.path)}")
							} else {
								moved = Fs.relative(Build.real!(out), Build.real!(Fs.resolve(dir, [each.path])))
								$lines = $lines.append("${each.name}: ${Text.json_string(if (moved.starts_with(".")) moved else "./${moved}")}")
							}
						}
					}
					return $lines
				}
			}
		}
		[]
	}

	## The Roc an app is written in besides its .rocx files: its own .roc files (not rocx's, nor its
	## build output), and the packages' and platforms' its headers name. Where a type an endpoint is
	## sent or answers comes from, so its tags are among their names (`tag_names`).
	roc_code! : Str => List(Str)
	roc_code! = |dir| {
		skip = |path| {
			last = Fs.basename(path)
			last == "build" or last == "dist" or last == Build.generated
		}
		var $codes = []
		var $dirs = []
		for path in Fs.files!(dir, ".roc", skip) {
			code = Fs.read_or_empty!(path)
			ends_marked = (Text.lines(Text.trim_end(code)).last() ?? "").starts_with(Transpile.marker)
			if !ends_marked and !Routes.is_route_file(Fs.basename(path)) {
				$codes = $codes.append(code)
				header = Build.app_header(code, Bool.False) ?? ""
				for named in Build.quoted_relative(header) {
					found = Fs.dirname(Fs.resolve(Fs.dirname(path), [named]))
					if !$dirs.contains(found) {
						$dirs = $dirs.append(found)
					}
				}
			}
		}
		for named in $dirs {
			outside = (Fs.relative(dir, named).split_on("/").first() ?? "") == ".."
			if named != dir and outside and Fs.exists!(named) {
				for path in Fs.files!(named, ".roc", skip) {
					$codes = $codes.append(Fs.read_or_empty!(path))
				}
			}
		}
		$codes
	}

	## Each `"./…"` or `"../…"` string in `text` (with something after the slash).
	quoted_relative : Str -> List(Str)
	quoted_relative = |text| {
		bytes = text.to_utf8()
		var $found = []
		var $i = 0
		while $i < bytes.len() {
			if Text.at(bytes, $i) == '"' {
				match Text.index_of_byte(bytes, '"', $i + 1) {
					Ok(close) => {
						inside = Text.cut(bytes, $i + 1, close)
						rest_after = if (inside.starts_with("../")) inside.drop_prefix("../") else inside.drop_prefix("./")
						if (inside.starts_with("./") or inside.starts_with("../")) and !rest_after.is_empty() {
							$found = $found.append(inside)
							$i = close + 1
						} else {
							$i = $i + 1
						}
					}
					Err(_) => {
						$i = bytes.len()
					}
				}
			} else {
				$i = $i + 1
			}
		}
		$found
	}

	## The packages an app's headers name that have components (`components/*.rocx`), such as
	## packages/charts: each as the header names it, as its components import it (`own`, its
	## directory's name), and its components.
	component_packages! : Str => List({ name : Str, own : Str, paths : List(Str), modules : List(Str) })
	component_packages! = |dir| {
		var $found = []
		for entry in Fs.entries!(dir) {
			if entry.ends_with(".roc") and !Fs.is_dir!(Fs.join([dir, entry])) {
				header = Build.app_header(Fs.read_or_empty!(Fs.join([dir, entry])), Bool.False) ?? ""
				for each in Build.named_paths(header, Bool.False) {
					after_slash = if (each.path.starts_with("../")) each.path.drop_prefix("../") else each.path.drop_prefix("./")
					if (each.path.starts_with("./") or each.path.starts_with("../")) and !after_slash.is_empty() {
						root = Fs.dirname(Fs.resolve(dir, [each.path]))
						components = Fs.join([root, "components"])
						if !$found.any(|pkg| pkg.name == each.name) and Fs.exists!(components) {
							paths = Fs.files!(components, ".rocx", |_| Bool.False)
							$found = $found.append({ name: each.name, own: Fs.basename(root), paths, modules: paths.map(|path| Fs.basename_without(path, ".rocx")) })
						}
					}
				}
			}
		}
		$found
	}

	## `import charts.BarChart`, a package's component, as an import of the app's copy of it
	## (`import ../Generated/charts/BarChart`), relative to the file at `path`: a line for a line.
	link_components : Str, Str, Str, List({ name : Str, own : Str, paths : List(Str), modules : List(Str) }) -> Str
	link_components = |source, path, dir, pkgs| {
		if pkgs.is_empty() {
			return source
		}
		Str.join_with(
			Text.lines(source).map(
				|line| {
					bytes = line.to_utf8()
					if !line.starts_with("import") {
						return line
					}
					name_at = Text.skip_space(bytes, 6)
					if name_at == 6 {
						return line
					}
					first = Text.at(bytes, name_at)
					if !(Text.is_lower(first) or first == '_') {
						return line
					}
					name_end = Text.run_end(bytes, name_at, |b| Text.is_lower(b) or Text.is_digit(b) or b == '_')
					if Text.at(bytes, name_end) != '.' or !Text.is_upper(Text.at(bytes, name_end + 1)) {
						return line
					}
					module_end = Text.run_end(bytes, name_end + 1, Text.is_alnum)
					if Text.is_word(Text.at(bytes, module_end)) and module_end < bytes.len() {
						return line
					}
					name = Text.cut(bytes, name_at, name_end)
					component_name = Text.cut(bytes, name_end + 1, module_end)
					if pkgs.any(|pkg| pkg.name == name and pkg.modules.contains(component_name)) {
						"import ${Fs.relative(Fs.dirname(path), Fs.join([dir, Build.generated, name, component_name]))}${Text.rest(bytes, module_end)}"
					} else {
						line
					}
				},
			),
			"\n",
		)
	}
}
