## The browser's runtime with only what an app uses (D-087): what `rocx build --static` and
## `--release` ship as runtime.js, before it is minified. web/runtime.js answers every host function
## any app's wasm may call (`makeImports`), and has the code each needs; an app's wasm imports only
## the ones its code reaches (the js-framework-benchmark's page, 22 of about 70). So the imports it
## doesn't import go, and then every member of `Runtime` nothing left names: a member is kept when
## its name follows a `.` in code that is kept (`this.flush()`, `runtime.live()`, `Runtime.target(…)`),
## starting from everything outside the class, the constructor, the static fields, the imports the
## wasm has, and what code outside the runtime calls (`kept`: start.js, the tests, plugins' scripts).
## A name is a name wherever it is (in a string, another object's property): what that keeps is kept
## for nothing, never taken away for something.
##
## It reads the runtime by its lines, as it is written: a member begins at a line with one tab and
## ends at the next line that is one tab and `}` (a field is one line), and the imports are the
## entries at three tabs in `makeImports`'s object. A runtime written another way is `Unshaped`, and
## the caller ships it whole.
import Minify
import Text

Shake := [].{

	## What code outside the runtime calls on it: start.js (`load`, `hydrateDocument`), the tests
	## (`hydrate`, `mount`, `live`, `flush`, `notes`, `allocations`), and pages' and plugins' scripts
	## (`fileOf`, `here`, `under`). (`navigate` is the app's when it navigates, and `renderToString`
	## the server's, never a browser's.)
	kept : List(Str)
	kept = ["constructor", "load", "hydrateDocument", "hydrate", "mount", "flush", "live", "notes", "allocations", "fileOf", "here", "under"]

	## The features a line of the runtime may be marked with (`… //#nav`), each left out with its lines
	## where the app doesn't use it (`Static.features!` says which it does): navigating in place
	## (D-040), drags, a pointer's point, and moves (`transition:move`'s glides).
	features : List(Str)
	features = ["nav", "drag", "point", "moves"]

	## The runtime without what the wasm, importing `imported`, never reaches, nor the lines of the
	## features not in `used`; or why it can't be read.
	runtime : Str, List(Str), List(Str) -> Try(Str, [Unshaped(Str)])
	runtime = |whole, imported, used| {
		off = Shake.features.keep_if(|feature| !used.contains(feature)).map(|feature| "//#${feature}")
		lines = whole.split_on("\n").keep_if(|line| !off.any(|mark| line.ends_with(mark)))
		begin = Shake.index_where(lines, 0, |line| line.starts_with("export class Runtime {")) ?? return Err(Unshaped("no `export class Runtime {`"))
		end = Shake.index_where(lines, begin + 1, |line| line == "}") ?? return Err(Unshaped("the class never ends"))
		listed = Shake.members(lines, begin + 1, end)?
		answered = Shake.entries(lines, listed)?
		# What is kept for certain: everything outside the class, its fields and the members others
		# call, and the imports the wasm has.
		outside = lines.take_first(begin + 1).concat(lines.drop_first(end))
		roots = listed.keep_if(|member| member.field or Shake.kept.contains(member.name))
		wanted = answered.keep_if(|entry| imported.contains(entry.name))
		# A member's own code: `makeImports`'s without its entries, each reached on its own.
		entry_lines = answered.map(|entry| (entry.from, entry.to))
		var $names = Shake.names(Str.join_with(outside, "\n"), [])
		for member in roots {
			$names = Shake.names(Shake.text_except(lines, member.from, member.to, entry_lines), $names)
		}
		for entry in wanted {
			$names = Shake.names(Shake.text_of(lines, entry.from, entry.to), $names)
		}
		# Then every member a kept one names, until nothing more is.
		var $keep = roots.map(|member| member.name)
		var $grew = Bool.True
		while $grew {
			$grew = Bool.False
			for member in listed {
				if !$keep.contains(member.name) and $names.contains(member.name) {
					$keep = $keep.append(member.name)
					$names = Shake.names(Shake.text_except(lines, member.from, member.to, entry_lines), $names)
					$grew = Bool.True
				}
			}
		}
		# An import the wasm hasn't, unless kept code names it.
		gone_members = listed.keep_if(|member| !$keep.contains(member.name)).map(|member| (member.from, member.to))
		gone_entries = answered.keep_if(|entry| !imported.contains(entry.name) and !$names.contains(entry.name)).map(|entry| (entry.from, entry.to))
		gone = gone_members.concat(gone_entries)
		var $out = List.with_capacity(lines.len())
		var $at = 0
		for line in lines {
			if !gone.any(|(from, to)| $at >= from and $at < to) {
				$out = $out.append(line)
			}
			$at = $at + 1
		}
		Ok(Str.join_with($out, "\n"))
	}

	## The class's members, each its name and its lines (`from` to before `to`); a field is a line.
	## Lines between them are blank or comments.
	members : List(Str), U64, U64 -> Try(List({ name : Str, from : U64, to : U64, field : Bool }), [Unshaped(Str)])
	members = |lines, from, to| {
		var $out = []
		var $at = from
		while $at < to {
			line = (lines.get($at) ?? "")
			if line == "" or Shake.comment(line) or !line.starts_with("\t") or line.starts_with("\t\t") {
				if !(line == "" or Shake.comment(line)) {
					return Err(Unshaped("line ${($at + 1).to_str()} is outside any member: ${line}"))
				}
				$at = $at + 1
			} else {
				name = Shake.member_name(line) ?? return Err(Unshaped("line ${($at + 1).to_str()} begins no member I know: ${line}"))
				if line.ends_with("{") {
					close = Shake.index_where(lines, $at + 1, |each| each == "\t}") ?? return Err(Unshaped("${name} never ends"))
					$out = $out.append({ name, from: $at, to: close + 1, field: Bool.False })
					$at = close + 1
				} else if line.ends_with(";") {
					$out = $out.append({ name, from: $at, to: $at + 1, field: Bool.True })
					$at = $at + 1
				} else {
					return Err(Unshaped("line ${($at + 1).to_str()} is a member I can't see the end of: ${line}"))
				}
			}
		}
		Ok($out)
	}

	## `makeImports`'s entries (`js_…: …` at three tabs in the object it answers), each its name and
	## its lines, to the next entry, comment or the object's end.
	entries : List(Str), List({ name : Str, from : U64, to : U64, field : Bool }) -> Try(List({ name : Str, from : U64, to : U64 }), [Unshaped(Str)])
	entries = |lines, listed| {
		made = listed.find_first(|member| member.name == "makeImports") ?? return Err(Unshaped("no makeImports"))
		var $out = []
		var $at = made.from
		while $at < made.to {
			line = (lines.get($at) ?? "")
			if line.starts_with("\t\t\tjs_") {
				name = Str.from_utf8_lossy(Shake.word(line.to_utf8(), 3))
				var $end = $at + 1
				while $end < made.to and !Shake.entry_ends((lines.get($end) ?? "")) {
					$end = $end + 1
				}
				$out = $out.append({ name, from: $at, to: $end })
				$at = $end
			} else {
				$at = $at + 1
			}
		}
		if ($out.is_empty()) Err(Unshaped("makeImports has no js_ entries")) else Ok($out)
	}

	## Where an entry ends: the next entry, a comment at its depth, or the object's end.
	entry_ends : Str -> Bool
	entry_ends = |line| line.starts_with("\t\t\tjs_") or line.starts_with("\t\t\t//") or line.starts_with("\t\t}")

	## A member's name from its first line: a field's (`static ASKED = 1000;`), or a method's
	## (`static async load(…) {`, `get x() {`).
	member_name : Str -> Try(Str, [NotAMember])
	member_name = |line| {
		var $bytes = line.to_utf8().drop_first(1)
		for prefix in ["static ", "async ", "get ", "set "] {
			if Text.starts_with_at($bytes, prefix.to_utf8(), 0) {
				$bytes = $bytes.drop_first(prefix.to_utf8().len())
			}
		}
		name = Shake.word($bytes, 0)
		after = $bytes.drop_first(name.len())
		if !name.is_empty() and (Text.starts_with_at(after, "(".to_utf8(), 0) or Text.starts_with_at(after, " = ".to_utf8(), 0)) {
			Ok(Str.from_utf8_lossy(name))
		} else {
			Err(NotAMember)
		}
	}

	## A comment's line at the class's depth (`// …`, `/** …`, ` * …`, ` */`).
	comment : Str -> Bool
	comment = |line| line.starts_with("\t//") or line.starts_with("\t/*") or line.starts_with("\t *") or line.starts_with("\t*/")

	## Every name after a `.` in `code` (its comments aside) that isn't in `known` already, added to it.
	names : Str, List(Str) -> List(Str)
	names = |code, known| {
		bytes = Minify.js(code).to_utf8()
		var $out = known
		var $at = 0
		while $at < bytes.len() {
			if Text.at(bytes, $at) == '.' {
				name = Shake.word(bytes, $at + 1)
				if !name.is_empty() {
					found = Str.from_utf8_lossy(name)
					if !$out.contains(found) {
						$out = $out.append(found)
					}
				}
				$at = $at + 1 + name.len()
			} else {
				$at = $at + 1
			}
		}
		$out
	}

	## The name at `from` (letters, digits, `_` and `$`), its bytes.
	word : List(U8), U64 -> List(U8)
	word = |bytes, from| {
		var $end = from
		while $end < bytes.len() and (Text.is_alnum(Text.at(bytes, $end)) or Text.at(bytes, $end) == '_' or Text.at(bytes, $end) == '$') {
			$end = $end + 1
		}
		Text.slice(bytes, from, $end)
	}

	## The lines from `from` to before `to`, but those in `skipped`, joined.
	text_except : List(Str), U64, U64, List((U64, U64)) -> Str
	text_except = |lines, from, to, skipped| {
		var $out = []
		var $at = from
		while $at < to {
			if !skipped.any(|(start, end)| $at >= start and $at < end) {
				$out = $out.append(lines.get($at) ?? "")
			}
			$at = $at + 1
		}
		Str.join_with($out, "\n")
	}

	## The lines from `from` to before `to`, joined.
	text_of : List(Str), U64, U64 -> Str
	text_of = |lines, from, to| Str.join_with(lines.drop_first(from).take_first(to - from), "\n")

	## The first line at or after `from` that `wanted` says is it.
	index_where : List(Str), U64, (Str -> Bool) -> Try(U64, [NotFound])
	index_where = |lines, from, wanted| {
		var $at = from
		while $at < lines.len() {
			if wanted((lines.get($at) ?? "")) {
				return Ok($at)
			}
			$at = $at + 1
		}
		Err(NotFound)
	}

	## The functions a wasm module imports from `env` (its import section), in order; none if it
	## isn't one.
	wasm_imports : List(U8) -> List(Str)
	wasm_imports = |bytes| {
		if bytes.len() < 8 or bytes.take_first(4) != [0, 'a', 's', 'm'] {
			return []
		}
		var $at = 8
		while $at < bytes.len() {
			id = Text.at(bytes, $at)
			size = Shake.leb(bytes, $at + 1)
			if id == 2 {
				return Shake.import_names(bytes, size.next, size.next + size.value)
			}
			$at = size.next + size.value
		}
		[]
	}

	import_names : List(U8), U64, U64 -> List(Str)
	import_names = |bytes, from, to| {
		count = Shake.leb(bytes, from)
		var $at = count.next
		var $names = []
		var $left = count.value
		while $left > 0 and $at < to {
			owner = Shake.name_at(bytes, $at)
			field = Shake.name_at(bytes, owner.next)
			kind = Text.at(bytes, field.next)
			after = field.next + 1
			next =
				if kind == 0 {
					Shake.leb(bytes, after).next
				} else if kind == 1 {
					Shake.limits_end(bytes, after + 1)
				} else if kind == 2 {
					Shake.limits_end(bytes, after)
				} else if kind == 3 {
					after + 2
				} else {
					to
				}
			if kind == 0 and owner.text == "env" {
				$names = $names.append(field.text)
			}
			$at = next
			$left = $left - 1
		}
		$names
	}

	## A name in a wasm module: its length (LEB128), then its bytes.
	name_at : List(U8), U64 -> { text : Str, next : U64 }
	name_at = |bytes, at| {
		length = Shake.leb(bytes, at)
		{ text: Str.from_utf8_lossy(Text.slice(bytes, length.next, length.next + length.value)), next: length.next + length.value }
	}

	## A table's or a memory's limits: a flag, the minimum, and the maximum if the flag says so.
	limits_end : List(U8), U64 -> U64
	limits_end = |bytes, at| {
		flag = Text.at(bytes, at)
		minimum = Shake.leb(bytes, at + 1)
		if (flag.bitwise_and(1) == 1) Shake.leb(bytes, minimum.next).next else minimum.next
	}

	## An unsigned LEB128 number at `at`, and where it ends.
	leb : List(U8), U64 -> { value : U64, next : U64 }
	leb = |bytes, at| {
		var $value = 0.U64
		var $shift = 0.U8
		var $i = at
		var $more = Bool.True
		while $more and $i < bytes.len() {
			byte = Text.at(bytes, $i)
			$value = $value.bitwise_or(byte.bitwise_and(0x7f).to_u64().shl_wrap($shift))
			$shift = $shift + 7
			$i = $i + 1
			$more = byte.bitwise_and(0x80) != 0
		}
		{ value: $value, next: $i }
	}
}

expect Shake.leb([0xE5, 0x8E, 0x26], 0) == { value: 624485, next: 3 }
expect Shake.leb([5], 0) == { value: 5, next: 1 }

# A module importing `env.js_a` (a function) and `env.memory`'s like (a memory), and `js_b`.
expect {
	named = |text| [text.to_utf8().len().to_u8_wrap()].concat(text.to_utf8())
	listed = [3]
		.concat(named("env"))
		.concat(named("js_a"))
		.concat([0, 1])
		.concat(named("env"))
		.concat(named("mem"))
		.concat([2, 1, 1, 4])
		.concat(named("env"))
		.concat(named("js_b"))
		.concat([0, 0])
	wasm = [0, 'a', 's', 'm', 1, 0, 0, 0, 1, 1, 0, 2, listed.len().to_u8_wrap()].concat(listed)
	Shake.wasm_imports(wasm) == ["js_a", "js_b"]
}

runtime_sample : Str
runtime_sample =
	Str.join_with(
		[
			"const ids = 0;",
			"export class Runtime {",
			"\tstatic ASKED = 1000;",
			"",
			"\t/** Made. */",
			"\tconstructor() {",
			"\t\tthis.imports = this.makeImports();",
			"\t}",
			"",
			"\tmakeImports() {",
			"\t\treturn {",
			"\t\t\t// A log.",
			"\t\t\tjs_log: (ptr) => this.said(ptr),",
			"\t\t\tjs_take: (dest) => {",
			"\t\t\t\tthis.took(dest);",
			"\t\t\t},",
			"\t\t};",
			"\t}",
			"",
			"\tsaid(ptr) {",
			"\t\treturn ptr;",
			"\t}",
			"",
			"\ttook(dest) {",
			"\t\tthis.helped();",
			"\t}",
			"",
			"\thelped() {",
			"\t\treturn 1;",
			"\t}",
			"",
			"\tflush() {",
			"\t\tthis.went(); //#nav",
			"\t\treturn 2;",
			"\t}",
			"}",
		],
		"\n",
	)

expect {
	shaken = Shake.runtime(runtime_sample, ["js_log"], []) ?? ""
	# js_take goes, and what only it reached (took, helped); flush stays (code outside calls it).
	shaken.contains("js_log") and !shaken.contains("js_take") and !shaken.contains("took(dest)") and !shaken.contains("helped()") and shaken.contains("said(ptr) {") and shaken.contains("flush()") and !shaken.contains("went")
}

expect {
	shaken = Shake.runtime(runtime_sample, ["js_log", "js_take"], ["nav"]) ?? ""
	shaken.contains("js_take") and shaken.contains("took(dest) {") and shaken.contains("helped() {") and shaken.contains("this.went(); //#nav")
}

expect Shake.runtime("export class Runtime {\n\tweird stuff here\n}", [], []) != Ok("")
