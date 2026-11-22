## What the browser's copy of an app (`rocx build --client`) can't compile: a module it reaches that
## imports what only the server platform has (`pf.Db`, `pf.Env`, `pf.Job`: a module the server
## platform exposes and the browser's doesn't). The browser's build would fail on it, far from the
## import that pulled it in; rocx build says where that import is instead.
import Fs
import Text

ServerOnly := [].{

	## An import a file makes: of the platform's module (`import pf.Db`: `platform`), or of a module
	## of the app's (`import ../Db/Users`: `path`, the file it names, relative to the importer).
	Import : { line : U64, written : Str, target : [Platform(Str), File(Str)] }

	## A step on the way from a root to a module: the file, and its line that imports the next.
	Step : { file : Str, line : U64, written : Str }

	## A module the browser's copy reaches that imports a module only the server has.
	Reached : { module_file : Str, platform_module : Str, line : U64, chain : List(Step) }

	## The modules a platform's main.roc exposes (`exposes [Audio, Browser, …]`).
	exposed_by! : Str => List(Str)
	exposed_by! = |platform_main| {
		bytes = Fs.read_or_empty!(platform_main).to_utf8()
		var $at = 0
		while $at <= bytes.len() {
			word = Text.skip_space(bytes, $at)
			if Text.starts_with_at(bytes, "exposes".to_utf8(), word) {
				open = Text.skip_space(bytes, word + 7)
				if Text.at(bytes, open) == '[' {
					match Text.index_of_byte(bytes, ']', open + 1) {
						Ok(close) =>
							return Text.cut(bytes, open + 1, close).split_on(",").map(Text.trim).keep_if(|name| !name.is_empty())
						Err(_) => {}
					}
				}
			}
			$at =
				match Text.index_of_byte(bytes, '\n', $at) {
					Ok(newline) => newline + 1
					Err(_) => bytes.len() + 1
				}
		}
		[]
	}

	## The modules only the server's platform has: exposed by `server`, not by `web` (main.roc paths).
	server_only_modules! : Str, Str => List(Str)
	server_only_modules! = |server, web| {
		browser = ServerOnly.exposed_by!(web)
		ServerOnly.exposed_by!(server).keep_if(|name| !browser.contains(name))
	}

	## What `import ` is followed by, as `^import\s+((?:\.{1,2}\/)*(?:[A-Za-z0-9_]+\/)*[A-Za-z0-9_.]+)`
	## takes it; nothing if it takes nothing.
	written_import : Str -> [Some(Str), None]
	written_import = |line| {
		bytes = line.to_utf8()
		if !line.starts_with("import") {
			return None
		}
		start = Text.skip_space(bytes, 6)
		if start == 6 {
			return None
		}
		var $at = start
		var $ups = Bool.True
		while $ups {
			if Text.starts_with_at(bytes, "../".to_utf8(), $at) {
				$at = $at + 3
			} else if Text.starts_with_at(bytes, "./".to_utf8(), $at) {
				$at = $at + 2
			} else {
				$ups = Bool.False
			}
		}
		# Directories: a word and a slash, each; then the last part, which may have dots.
		var $last_start = $at
		var $dirs = Bool.True
		while $dirs {
			word_end = Text.run_end(bytes, $last_start, Text.is_word)
			if word_end > $last_start and Text.at(bytes, word_end) == '/' {
				$last_start = word_end + 1
			} else {
				$dirs = Bool.False
			}
		}
		last_end = Text.run_end(bytes, $last_start, |b| Text.is_word(b) or b == '.')
		if last_end > $last_start {
			Some(Text.cut(bytes, start, last_end))
		} else if $last_start > $at {
			# The last directory is the last part (the regular expression gives it back).
			Some(Text.cut(bytes, start, $last_start - 1))
		} else {
			dots = Text.run_end(bytes, start, |b| Text.is_word(b) or b == '.')
			if (dots > start) Some(Text.cut(bytes, start, dots)) else None
		}
	}

	## `^([a-z_][a-z0-9_]*)\.([A-Z][A-Za-z0-9_]*)$`: a package's module, `pf.Db`, as its two names.
	dotted : Str -> [Some({ alias : Str, module_name : Str }), None]
	dotted = |written| {
		match written.split_first(".") {
			Ok({ before, after }) => {
				b = before.to_utf8()
				a = after.to_utf8()
				first = Text.at(b, 0)
				alias_ok = !b.is_empty() and (Text.is_lower(first) or first == '_') and b.all(|c| Text.is_lower(c) or Text.is_digit(c) or c == '_')
				module_ok = !a.is_empty() and Text.is_upper(Text.at(a, 0)) and a.all(Text.is_word)
				if (alias_ok and module_ok) Some({ alias: before, module_name: after }) else None
			}
			Err(_) => None
		}
	}

	## `^(?:\.{1,2}\/)*(?:[A-Za-z0-9_]+\/)*[A-Z][A-Za-z0-9_]*$`: a module of the app's, by its path.
	is_module_path : Str -> Bool
	is_module_path = |written| {
		var $rest = written
		var $ups = Bool.True
		while $ups {
			if $rest.starts_with("../") {
				$rest = $rest.drop_prefix("../")
			} else if $rest.starts_with("./") {
				$rest = $rest.drop_prefix("./")
			} else {
				$ups = Bool.False
			}
		}
		parts = $rest.split_on("/")
		count = parts.len()
		dirs_ok = parts.take_first(count - 1).all(|part| Text.all_of(part, Text.is_word))
		last = (parts.last() ?? "").to_utf8()
		dirs_ok and !last.is_empty() and Text.is_upper(Text.at(last, 0)) and last.all(Text.is_word)
	}

	## A module's imports, each with its line (from 1): of the platform (`alias`), or of a module of
	## the app's. A package's module and an embedded file are left out.
	imports_of : Str, Str, Str -> List(Import)
	imports_of = |file, code, alias| {
		var $found = []
		var $n = 0
		for text in Text.lines(code) {
			$n = $n + 1
			match ServerOnly.written_import(text) {
				None => {}
				Some(written) =>
					match ServerOnly.dotted(written) {
						Some(names) =>
							if names.alias == alias {
								$found = $found.append({ line: $n, written, target: Platform(names.module_name) })
							}
						None =>
							if ServerOnly.is_module_path(written) {
								$found = $found.append({ line: $n, written, target: File(Fs.resolve(Fs.dirname(file), ["${written}.roc"])) })
							}
					}
			}
		}
		$found
	}

	## Every module of the browser's copy in `target` that its `roots` reach, and that imports a
	## platform module in `server_only`, each once, by the shortest chain of imports from a root (root
	## first; none when the root itself imports it).
	server_only_reached! : Str, List(Str), List(Str) => List(Reached)
	server_only_reached! = |target, roots, server_only| {
		inside = |file| !Fs.relative(target, file).split_on("/").contains("..")
		var $via = roots.map(|root| { file: Fs.resolve(root, []), step: None })
		var $queue = $via.map(|each| each.file)
		var $found = []
		while !$queue.is_empty() {
			file = $queue.first() ?? ""
			$queue = $queue.drop_first(1)
			file_imports = if (Fs.exists!(file)) ServerOnly.imports_of(file, Fs.read_or_empty!(file), "pf") else []
			first_server_only = file_imports.find_first(
				|each|
					match each.target {
						Platform(name) => server_only.contains(name)
						File(_) => Bool.False
					},
			)
			match first_server_only {
				Ok(each) => {
					platform_module =
						match each.target {
							Platform(name) => name
							File(_) => ""
						}
					$found = $found.append({ module_file: file, platform_module, line: each.line, chain: ServerOnly.chain_to($via, file) })
				}
				Err(_) => {}
			}
			for each in file_imports {
				match each.target {
					File(path) =>
						if !$via.any(|seen| seen.file == path) and inside(path) and Fs.exists!(path) {
							$via = $via.append({ file: path, step: Some({ file, line: each.line, written: each.written }) })
							$queue = $queue.append(path)
						}
					Platform(_) => {}
				}
			}
		}
		$found
	}

	## The imports that reached `file`, from its root.
	chain_to : List({ file : Str, step : [Some(Step), None] }), Str -> List(Step)
	chain_to = |via, file| {
		var $chain = []
		var $at = file
		var $going = Bool.True
		while $going {
			match via.find_first(|each| each.file == $at) {
				Ok({ step: Some(step), .. }) => {
					$chain = $chain.prepend(step)
					$at = step.file
				}
				_ => {
					$going = Bool.False
				}
			}
		}
		$chain
	}

	## The apps in `dir` (the browser's copy) whose header names the platform at `web` (its main.roc).
	web_apps! : Str, Str => List(Str)
	web_apps! = |dir, web| {
		found = if (Fs.exists!(dir)) ServerOnly.web_apps_in!(dir, web, []) else []
		Text.sorted(found)
	}

	web_apps_in! : Str, Str, List(Str) => List(Str)
	web_apps_in! = |at, web, found| {
		var $found = found
		for entry in Fs.entries!(at) {
			path = Fs.join([at, entry])
			if Fs.is_dir!(path) {
				if !(entry == "build" or entry == "dist" or entry == "static" or entry == "node_modules") {
					$found = ServerOnly.web_apps_in!(path, web, $found)
				}
			} else if entry.ends_with(".roc") {
				match ServerOnly.platform_of(Fs.read_or_empty!(path)) {
					Some(named) =>
						if Fs.resolve(Fs.dirname(path), [named]) == Fs.resolve(web, []) {
							$found = $found.append(path)
						}
					None => {}
				}
			}
		}
		$found
	}

	## `^app\s*\[[^\]]*\]\s*\{[^}]*\bplatform\s+"([^"]+)"`: the platform an app's header names.
	platform_of : Str -> [Some(Str), None]
	platform_of = |code| {
		bytes = code.to_utf8()
		var $at = 0
		while $at <= bytes.len() {
			match ServerOnly.platform_at(bytes, $at) {
				Some(found) => return Some(found)
				None => {}
			}
			$at =
				match Text.index_of_byte(bytes, '\n', $at) {
					Ok(newline) => newline + 1
					Err(_) => bytes.len() + 1
				}
		}
		None
	}

	platform_at : List(U8), U64 -> [Some(Str), None]
	platform_at = |bytes, at| {
		if !Text.starts_with_at(bytes, "app".to_utf8(), at) {
			return None
		}
		open = Text.skip_space(bytes, at + 3)
		if Text.at(bytes, open) != '[' {
			return None
		}
		close = Text.index_of_byte(bytes, ']', open + 1) ?? bytes.len()
		brace = Text.skip_space(bytes, close + 1)
		if close >= bytes.len() or Text.at(bytes, brace) != '{' {
			return None
		}
		end = Text.index_of_byte(bytes, '}', brace + 1) ?? bytes.len()
		var $i = brace + 1
		while $i < end {
			word_boundary = $i == 0 or !Text.is_word(Text.at(bytes, $i - 1))
			if word_boundary and Text.starts_with_at(bytes, "platform".to_utf8(), $i) {
				quote = Text.skip_space(bytes, $i + 8)
				if quote > $i + 8 and quote < end and Text.at(bytes, quote) == '"' {
					match Text.index_of_byte(bytes, '"', quote + 1) {
						Ok(closing) if closing > quote + 1 => return Some(Text.cut(bytes, quote + 1, closing))
						_ => {}
					}
				}
			}
			$i = $i + 1
		}
		None
	}

	## A file's last line: where rocx writes its marker.
	last_line! : Str => Str
	last_line! = |file| Text.lines(Text.trim_end(Fs.read_or_empty!(file))).last() ?? ""

	## The source a file of the browser's copy was written from, relative to the app: a .rocx file's
	## (its marker line names it), or the .roc file itself, at the same place in the app.
	source_of! : Str, Str => Str
	source_of! = |target, file| {
		last = ServerOnly.last_line!(file)
		at =
			match last.split_first("# rocx: generated from ") {
				Ok({ after, .. }) =>
					match after.split_first(": edit that file") {
						Ok({ before, .. }) if !before.is_empty() => Fs.resolve(Fs.dirname(file), [before])
						_ => file
					}
				Err(_) => file
			}
		Fs.relative(target, at)
	}

	## Whether rocx wrote a file of the browser's copy from an author's .rocx file (a component, a page).
	from_rocx! : Str => Bool
	from_rocx! = |file| {
		last = ServerOnly.last_line!(file)
		last.starts_with("# rocx: ") and last.contains(": edit that file")
	}

	## Whether a file of the browser's copy is one the app's author wrote, or rocx wrote from one.
	authored! : Str => Bool
	authored! = |file| !ServerOnly.last_line!(file).starts_with("# rocx:") or ServerOnly.from_rocx!(file)

	## The warning for one module the browser's copy reaches that imports what only the server has,
	## said where browser code meets it: at the last component or page on the way, or else at the
	## first file the author wrote. `app` is the app's directory, as the build names it.
	warning! : Str, Str, Reached => Str
	warning! = |target, app_dir, reached| {
		chain = reached.chain
		var $from = None
		if !ServerOnly.from_rocx!(reached.module_file) {
			var $i = chain.len()
			while $i > 0 and $from == None {
				if ServerOnly.from_rocx!((chain.get($i - 1) ?? { file: "", line: 0, written: "" }).file) {
					$from = Some($i - 1)
				}
				$i = $i - 1
			}
			if $from == None {
				var $k = 0
				while $k < chain.len() and $from == None {
					if ServerOnly.authored!((chain.get($k) ?? { file: "", line: 0, written: "" }).file) {
						$from = Some($k)
					}
					$k = $k + 1
				}
			}
		}
		steps =
			match $from {
				Some(index) => chain.drop_first(index)
				None => []
			}
		place =
			match steps.first() {
				Ok(step) => { file: step.file, line: step.line }
				Err(_) => { file: reached.module_file, line: reached.line }
			}
		file_imports =
			if steps.is_empty() {
				"imports pf.${reached.platform_module}"
			} else {
				"imports ${Str.join_with(steps.map(|step| step.written), ", which imports ")}, which imports pf.${reached.platform_module}"
			}
		source = Str.join_with([app_dir, ServerOnly.source_of!(target, place.file)].keep_if(|part| !part.is_empty() and part != "."), "/")
		"⚠ ${source}:${place.line.to_str()}: the browser's copy ${file_imports}, which only the server has, so the browser's build can't compile it. Use it in an endpoint (+server.roc) or middleware, which the browser's copy leaves out."
	}
}
