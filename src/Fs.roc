## Paths and files, as rocx's JavaScript had them from Node: posix paths as text (`join`,
## `resolve`, `relative`, `dirname`, `basename`, with Node's rules), and the effects rocx needs on
## files and directories. A directory's entries come sorted by their bytes, as Node gave them.
import pf.Path
import pf.Env
import Text

Fs := [].{

	## Node's `path.join`: the parts joined with `/`, normalized; `"."` for nothing.
	join : List(Str) -> Str
	join = |parts| {
		kept = parts.keep_if(|part| !part.is_empty())
		if (kept.is_empty()) "." else Fs.normalize(Str.join_with(kept, "/"))
	}

	## Node's `path.normalize`: `.` and `..` worked out, runs of `/` one, a trailing `/` kept.
	normalize : Str -> Str
	normalize = |path| {
		if path.is_empty() {
			return "."
		}
		absolute = path.starts_with("/")
		trailing = path.ends_with("/")
		segments = Fs.resolve_segments(path.split_on("/"), absolute)
		body = Str.join_with(segments, "/")
		joined = if (absolute) "/".concat(body) else body
		if joined.is_empty() {
			if (absolute) "/" else if (trailing) "./" else "."
		} else if trailing and joined != "/" {
			joined.concat("/")
		} else {
			joined
		}
	}

	## Segments with `.` and empty ones gone and each `..` taking the one before it (above the root,
	## for an absolute path, nothing; for a relative one, `..` stays).
	resolve_segments : List(Str), Bool -> List(Str)
	resolve_segments = |segments, absolute|
		segments.fold(
			[],
			|kept, segment|
				if segment.is_empty() or segment == "." {
					kept
				} else if segment == ".." {
					match kept.last() {
						Ok(previous) if previous != ".." => kept.drop_last(1)
						_ => if (absolute) kept else kept.append("..")
					}
				} else {
					kept.append(segment)
				},
		)

	## Node's `path.resolve(cwd, …paths)`: from the right, until a path is absolute, else from `cwd`;
	## normalized, with no trailing `/` but the root's.
	resolve : Str, List(Str) -> Str
	resolve = |cwd, paths| {
		var $parts = []
		var $absolute = Bool.False
		var $i = paths.len()
		while $i > 0 and !$absolute {
			part = paths.get($i - 1) ?? ""
			if !part.is_empty() {
				$parts = $parts.prepend(part)
				$absolute = part.starts_with("/")
			}
			$i = $i - 1
		}
		all = if ($absolute) $parts else $parts.prepend(cwd)
		segments = Fs.resolve_segments(Str.join_with(all, "/").split_on("/"), Bool.True)
		"/".concat(Str.join_with(segments, "/"))
	}

	## Node's `path.relative(from, to)`, both absolute: the way from one to the other; `""` when they're one.
	relative : Str, Str -> Str
	relative = |from, to| {
		a = Fs.resolve_segments(from.split_on("/"), Bool.True)
		b = Fs.resolve_segments(to.split_on("/"), Bool.True)
		var $common = 0
		while $common < a.len() and $common < b.len() and a.get($common) == b.get($common) {
			$common = $common + 1
		}
		ups = List.repeat("..", a.len() - $common)
		Str.join_with(ups.concat(b.drop_first($common)), "/")
	}

	## Node's `path.dirname`.
	dirname : Str -> Str
	dirname = |path| {
		bytes = path.to_utf8()
		if bytes.is_empty() {
			return "."
		}
		has_root = Text.at(bytes, 0) == '/'
		var $end = 0
		var $found = Bool.False
		var $matched_slash = Bool.True
		var $i = bytes.len() - 1
		while $i >= 1 and !$found {
			if Text.at(bytes, $i) == '/' {
				if !$matched_slash {
					$end = $i
					$found = Bool.True
				}
			} else {
				$matched_slash = Bool.False
			}
			$i = $i - 1
		}
		if !$found {
			if (has_root) "/" else "."
		} else if has_root and $end == 1 {
			"//"
		} else {
			Text.cut(bytes, 0, $end)
		}
	}

	## Node's `path.basename(path)`: the last part.
	basename : Str -> Str
	basename = |path| {
		bytes = path.to_utf8()
		var $end = bytes.len()
		while $end > 1 and Text.at(bytes, $end - 1) == '/' {
			$end = $end - 1
		}
		start =
			match Text.last_index_before(bytes, '/', $end) {
				Ok(slash) => slash + 1
				Err(_) => 0
			}
		Text.cut(bytes, start, $end)
	}

	## Node's `path.basename(path, ext)`: the last part, without `ext` if it ends with it (and is more).
	basename_without : Str, Str -> Str
	basename_without = |path, ext| {
		name = Fs.basename(path)
		if (name != ext and name.ends_with(ext)) name.drop_suffix(ext) else name
	}

	## The working directory.
	cwd! : () => Str
	cwd! = || {
		match Env.cwd!() {
			Ok(path) => path.display()
			Err(_) => "."
		}
	}

	## Whether something is at `path` (a symbolic link counts as what it links to).
	exists! : Str => Bool
	exists! = |path| Path.utf8(path).exists!() ?? Bool.False

	## Whether `path` is a directory (through symbolic links).
	is_dir! : Str => Bool
	is_dir! = |path| Path.utf8(path).is_dir!() ?? Bool.False

	## Whether `path` is a file (through symbolic links).
	is_file! : Str => Bool
	is_file! = |path| Path.utf8(path).is_file!() ?? Bool.False

	## The names in a directory, sorted by their bytes (Node's `readdirSync`); none if it can't be read.
	entries! : Str => List(Str)
	entries! = |dir| {
		match Path.utf8(dir).list!() {
			Ok(paths) => Text.sorted(paths.map(|entry| Fs.basename(entry.display())))
			Err(_) => []
		}
	}

	## A file's text; `Err` if it can't be read.
	read! : Str => Try(Str, [CantRead(Str)])
	read! = |path| {
		match Path.utf8(path).read_utf8!() {
			Ok(text) => Ok(text)
			Err(_) => Err(CantRead(path))
		}
	}

	## A file's text, or `""` if it can't be read.
	read_or_empty! : Str => Str
	read_or_empty! = |path| Fs.read!(path) ?? ""

	## Writes `content` to `path`, making the directories it is in.
	write! : Str, Str => Try({}, [CantWrite(Str)])
	write! = |path, content| {
		_ = Path.utf8(Fs.dirname(path)).create_all!()
		match Path.utf8(path).write_utf8!(content) {
			Ok({}) => Ok({})
			Err(_) => Err(CantWrite(path))
		}
	}

	## Makes a directory and those it is in.
	make_dirs! : Str => {}
	make_dirs! = |path| {
		_ = Path.utf8(path).create_all!()
		{}
	}

	## Deletes a file.
	delete! : Str => {}
	delete! = |path| {
		_ = Path.utf8(path).delete!()
		{}
	}

	## Deletes a directory and everything in it.
	delete_all! : Str => {}
	delete_all! = |path| {
		_ = Path.utf8(path).delete_all!()
		{}
	}

	## The path with its symbolic links resolved (Node's `realpathSync`); as it is if that fails.
	real! : Str => Str
	real! = |path| {
		match Path.utf8(path).canonicalize!() {
			Ok(resolved) => resolved.display()
			Err(_) => path
		}
	}

	## Every file under `dir` whose name ends with `extension`, depth first, each directory's
	## entries sorted (rocx's JavaScript `files()`): names starting with `.` and `node_modules` aren't
	## gone into, nor a directory `skip` says to skip (given its path).
	files! : Str, Str, (Str -> Bool) => List(Str)
	files! = |dir, extension, skip| Fs.files_into!(dir, extension, skip, [])

	files_into! : Str, Str, (Str -> Bool), List(Str) => List(Str)
	files_into! = |dir, extension, skip, found| {
		var $found = found
		for entry in Fs.entries!(dir) {
			if !(entry.starts_with(".") or entry == "node_modules") {
				path = Fs.join([dir, entry])
				if Fs.is_dir!(path) {
					if !skip(path) {
						$found = Fs.files_into!(path, extension, skip, $found)
					}
				} else if path.ends_with(extension) {
					$found = $found.append(path)
				}
			}
		}
		$found
	}
}
