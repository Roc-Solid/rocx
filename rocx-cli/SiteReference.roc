## The platform's reference, for the docs site (`rocx site prepare`), read from the platform itself:
## every module the server platform exposes (server/platform/main.roc's `exposes`), each from its
## canonical source (web/platform for the modules both platforms have, which the server's build
## copies into server/platform; else server/platform), with its doc comment and, for each item of
## its block, its name, its type, and the `##` lines above it. The docs' reference page shows it
## (site/routes/platform/reference), and the site's test holds every effect to a doc comment
## (`undocumented`, through `rocx internal`), so neither can drift from the code.
import Fs
import Text
import Value

SiteReference := [].{
	Item : { name : Str, type : Str, doc : Str, line : U64 }
	Module : { name : Str, file : Str, shared : Bool, doc : Str, effects : List(Item), functions : List(Item) }
	Inline : { kind : Str, text : Str }
	Block : [Para(List(Inline)), Sample(Str), Bullets(List(List(Inline)))]

	## The modules both platforms have: the browser's platform's, copied into the server platform
	## (server/build.mjs's `SHARED_MODULES`, which the JavaScript tests still use).
	shared_modules : List(Str)
	shared_modules = ["Html", "Solid", "Store", "Repeat", "Loading", "Errored", "Call", "Server", "Context", "Endpoint", "FormBody", "Middleware", "Events", "OpenApi", "Router", "HttpStatusCode", "Transition", "Browser", "Submission", "Submissions", "Title", "Channel", "A", "Search", "Leave"]

	## The modules server/platform/main.roc exposes, in its order (`/^\s*exposes\s*\[([^\]]*)\]/m`).
	exposed : Str -> Try(List(Str), [Problem(Str)])
	exposed = |main| {
		bytes = main.to_utf8()
		var $at = 0
		for line in Text.lines(main) {
			rest = Text.trim_start(line)
			if rest.starts_with("exposes") {
				after = Text.trim_start(rest.drop_prefix("exposes"))
				if after.starts_with("[") {
					start = $at + (line.to_utf8().len() - after.to_utf8().len()) + 1
					close = Text.index_of_byte(bytes, ']', start) ?? bytes.len()
					names = Text.cut(bytes, start, close).split_on(",").map(Text.trim).keep_if(|name| !name.is_empty())
					return Ok(names)
				}
			}
			$at = $at + line.to_utf8().len() + 1
		}
		Err(Problem("server/platform/main.roc: no `exposes [...]`"))
	}

	## Where a module is written: web/platform for one both platforms have, server/platform else.
	source_of : Str -> Str
	source_of = |name| if (SiteReference.shared_modules.contains(name)) "web/platform/${name}.roc" else "server/platform/${name}.roc"

	## The text of the `##` lines that end just above line `at` (indented by `indent`), without their `##`.
	doc_above : List(Str), U64, Str -> Str
	doc_above = |lines, at, indent| {
		prefix = "${indent}##"
		var $start = at
		while $start > 0 and (lines.get($start - 1) ?? "").starts_with(prefix) {
			$start = $start - 1
		}
		texts = lines.sublist({ start: $start, len: at - $start }).map(
			|line| {
				rest = line.drop_prefix(prefix)
				if (rest.starts_with(" ")) rest.drop_prefix(" ") else rest
			},
		)
		Text.trim(Str.join_with(texts, "\n"))
	}

	## Whether `line` starts a module's header: `Name :=`, `Name ::`, or the same with type
	## arguments (`/^Name(\(.*\))?\s*(:=|::)/`).
	is_header : Str, Str -> Bool
	is_header = |line, name| {
		if !line.starts_with(name) {
			return Bool.False
		}
		rest = line.drop_prefix(name)
		opens = |text| {
			after = Text.trim_start(text)
			after.starts_with(":=") or after.starts_with("::")
		}
		if opens(rest) {
			return Bool.True
		}
		if !rest.starts_with("(") {
			return Bool.False
		}
		# `\(.*\)`, greedy: the last `)` the rest of the line opens after, then any before it.
		bytes = rest.to_utf8()
		var $i = bytes.len()
		while $i > 0 {
			$i = $i - 1
			if Text.at(bytes, $i) == ')' and opens(Text.rest(bytes, $i + 1)) {
				return Bool.True
			}
		}
		Bool.False
	}

	## `name` at the start of a line one tab in (`/^\t([a-z_][a-zA-Z0-9_]*!?)/`): the name and the
	## rest of the line after it.
	item_name : Str -> [Some({ name : Str, rest : Str }), None]
	item_name = |line| {
		bytes = line.to_utf8()
		first = Text.at(bytes, 1)
		if Text.at(bytes, 0) != '\t' or !(Text.is_lower(first) or first == '_') {
			return None
		}
		var $i = 2
		while Text.is_alnum(Text.at(bytes, $i)) or Text.at(bytes, $i) == '_' {
			$i = $i + 1
		}
		if Text.at(bytes, $i) == '!' {
			$i = $i + 1
		}
		Some({ name: Text.cut(bytes, 1, $i), rest: Text.rest(bytes, $i) })
	}

	## `rest` after an item's name: `\s*:(?!=)\s*(.*)`, its type; or `\s*=(?!=)`, a definition.
	after_name : Str -> [Annotated(Str), Defined, Neither]
	after_name = |rest| {
		after = Text.trim_start(rest)
		if after.starts_with(":") and !after.starts_with(":=") {
			Annotated(Text.trim_start(after.drop_prefix(":")))
		} else if after.starts_with("=") and !after.starts_with("==") {
			Defined
		} else {
			Neither
		}
	}

	## A type on more lines than one, joined as one line: `f(⏎a,⏎b,⏎)` as `f(a, b)`, `{⏎a : A,⏎}`
	## as `{ a : A }`.
	joined : List(Str) -> Str
	joined = |parts| {
		first = parts.first() ?? ""
		parts.drop_first(1).fold(
			first,
			|so_far, part| {
				unended = if (so_far.ends_with(",")) so_far.drop_suffix(",") else so_far
				if part.starts_with(")") or part.starts_with("]") {
					unended.concat(part)
				} else if part.starts_with("}") {
					"${unended} ${part}"
				} else if so_far.ends_with("(") or so_far.ends_with("[") {
					so_far.concat(part)
				} else {
					"${so_far} ${part}"
				}
			},
		)
	}

	## One module, from its source's text: its doc comment (the `##` lines above `Name :=` or
	## `Name ::`), and each item of its block (a line one tab in, `name : type`, the type joined if it
	## spans lines; or `name =`, one with no annotation): name, type, doc, and its line.
	read_module : Str, Str -> Try(Module, [Problem(Str)])
	read_module = |name, text| {
		file = SiteReference.source_of(name)
		lines = Text.lines(text)
		header = match lines.find_first_index(|line| SiteReference.is_header(line, name)) {
			Ok(at) => at
			Err(_) => return Err(Problem("${file}: no `${name} :=` or `${name} ::`"))
		}
		count = lines.len()
		var $open = header
		while $open < count and !Text.trim_end(lines.get($open) ?? "").ends_with(".{") {
			$open = $open + 1
		}
		var $close = $open + 1
		while $close < count and !(lines.get($close) ?? "").starts_with("}") {
			$close = $close + 1
		}
		var $items = []
		var $seen = []
		# No block, or one never closed: no items (as `findIndex` finding none).
		if $open < count and $close < count {
			var $i = $open + 1
			while $i < $close {
				line = lines.get($i) ?? ""
				match SiteReference.item_name(line) {
					Some(found) =>
						match SiteReference.after_name(found.rest) {
							Annotated(type_text) => {
								var $parts = [Text.trim(type_text)]
								# Each further line is indented more, up to the definition.
								while $i + 1 < $close and (lines.get($i + 1) ?? "").starts_with("\t\t") {
									$i = $i + 1
									$parts = $parts.append(Text.trim(lines.get($i) ?? ""))
								}
								at = $i - ($parts.len() - 1)
								$items = $items.append({ name: found.name, type: SiteReference.joined($parts), doc: SiteReference.doc_above(lines, at, "\t"), line: at + 1 })
								$seen = $seen.append(found.name)
							}
							Defined if !$seen.contains(found.name) => {
								$items = $items.append({ name: found.name, type: "", doc: SiteReference.doc_above(lines, $i, "\t"), line: $i + 1 })
								$seen = $seen.append(found.name)
							}
							_ => {}
						}
					None => {}
				}
				$i = $i + 1
			}
		}
		Ok({
			name,
			file,
			shared: SiteReference.shared_modules.contains(name),
			doc: SiteReference.doc_above(lines, header, ""),
			effects: $items.keep_if(|item| item.name.ends_with("!")),
			functions: $items.keep_if(|item| !item.name.ends_with("!")),
		})
	}

	## Every module the server platform exposes, read (`read_module`), in the order it exposes them;
	## `root` is the repository's.
	platform_reference! : Str => Try(List(Module), [Problem(Str)])
	platform_reference! = |root| {
		main = Fs.read!(Fs.join([root, "server", "platform", "main.roc"])) ?? ""
		var $modules = []
		for name in SiteReference.exposed(main)? {
			text = Fs.read!(Fs.join([root, SiteReference.source_of(name)])) ?? ""
			$modules = $modules.append(SiteReference.read_module(name, text)?)
		}
		Ok($modules)
	}

	## The effects with no doc comment, as `Module.name! (file:line)`: none, or the docs have a gap.
	undocumented : List(Module) -> List(Str)
	undocumented = |modules|
		modules.fold(
			[],
			|found, m| found.concat(m.effects.keep_if(|effect| effect.doc.is_empty()).map(|effect| "${m.name}.${effect.name} (${m.file}:${effect.line.to_str()})")),
		)

	## The parts of the docs, each module in one; a module none names is in "Other", at the end, so a
	## new one is never left off the page.
	groups : List({ id : Str, name : Str, modules : List(Str) })
	groups = [
		{ id: "requests", name: "Requests and HTTP", modules: ["Server", "Endpoint", "Middleware", "Router", "Http", "HttpResponse", "Events", "Call", "Submission", "OpenApi"] },
		{ id: "data", name: "Data", modules: ["Db", "Kv"] },
		{ id: "plugins", name: "Plugins", modules: ["Plugin"] },
		{ id: "background", name: "Background", modules: ["Actor", "Live"] },
		{ id: "crypto", name: "Crypto", modules: ["AesGcm", "Random"] },
		{ id: "system", name: "System", modules: ["Env", "Time", "Log", "Tcp"] },
		{ id: "components", name: "Components and reactivity", modules: ["Solid", "Store", "Html", "Repeat", "Loading", "Errored", "Context", "Transition", "Title", "HttpStatusCode", "Browser"] },
	]

	## The modules, in their groups (`groups`), in the order each lists them.
	grouped : List(Module) -> List({ id : Str, name : Str, modules : List(Module) })
	grouped = |modules| {
		named = |wanted| modules.keep_if(|m| m.name == wanted)
		listed = SiteReference.groups.map(|g| { id: g.id, name: g.name, modules: g.modules.fold([], |found, wanted| found.concat(named(wanted))) })
		placed = SiteReference.groups.fold([], |all, g| all.concat(g.modules))
		others = modules.keep_if(|m| !placed.contains(m.name))
		with_others = if (others.is_empty()) listed else listed.append({ id: "other", name: "Other", modules: others })
		with_others.keep_if(|g| !g.modules.is_empty())
	}

	## A line of a doc comment as text and code: `a `b` c` is Text("a "), Mono("b"), Text(" c").
	inlines : Str -> List(Inline)
	inlines = |text|
		text.split_on("`").map_with_index(|piece, i| { kind: if (i % 2 == 1) "Mono" else "Text", text: piece }).keep_if(|piece| !piece.text.is_empty())

	## Whether a line starts with four spaces (`/^ {4}/`).
	indented : Str -> Bool
	indented = |line| line.starts_with("    ")

	## A doc comment as blocks: paragraphs (lines joined), lists (`- ` lines), and code: a fenced
	## block (```), or lines indented four spaces.
	blocks : Str -> List(Block)
	blocks = |doc| {
		lines = Text.lines(doc)
		line_at = |i| lines.get(i) ?? ""
		count = lines.len()
		var $out = []
		var $i = 0
		while $i < count {
			line = line_at($i)
			if Text.trim(line).is_empty() {
				$i = $i + 1
			} else if Text.trim_start(line).starts_with("```") {
				var $code = []
				$i = $i + 1
				while $i < count and !Text.trim_start(line_at($i)).starts_with("```") {
					$code = $code.append(line_at($i))
					$i = $i + 1
				}
				$i = $i + 1
				$out = $out.append(Sample(Str.join_with($code, "\n")))
			} else if SiteReference.indented(line) {
				var $code = []
				while $i < count and (SiteReference.indented(line_at($i)) or (Text.trim(line_at($i)).is_empty() and SiteReference.indented(line_at($i + 1)))) {
					# `slice(4)`: a blank line shorter than that is left empty.
					bytes = line_at($i).to_utf8()
					$code = $code.append(Text.rest(bytes, if (bytes.len() < 4) bytes.len() else 4))
					$i = $i + 1
				}
				$out = $out.append(Sample(Str.join_with($code, "\n")))
			} else if line.starts_with("- ") {
				var $items = []
				while $i < count and line_at($i).starts_with("- ") {
					var $item = [line_at($i).drop_prefix("- ")]
					$i = $i + 1
					while $i < count and SiteReference.continues(line_at($i)) {
						$item = $item.append(Text.trim(line_at($i)))
						$i = $i + 1
					}
					$items = $items.append(SiteReference.inlines(Str.join_with($item, " ")))
				}
				$out = $out.append(Bullets($items))
			} else {
				var $text = []
				while $i < count and !Text.trim(line_at($i)).is_empty() and !SiteReference.indented(line_at($i)) and !line_at($i).starts_with("- ") and !Text.trim_start(line_at($i)).starts_with("```") {
					$text = $text.append(Text.trim(line_at($i)))
					$i = $i + 1
				}
				$out = $out.append(Para(SiteReference.inlines(Str.join_with($text, " "))))
			}
		}
		$out
	}

	## A list item's next line (`/^ {2}\S/`): two spaces, then anything but whitespace.
	continues : Str -> Bool
	continues = |line| {
		bytes = line.to_utf8()
		Text.at(bytes, 0) == ' ' and Text.at(bytes, 1) == ' ' and bytes.len() > 2 and !Text.is_space_at(bytes, 2)
	}

	## The reference as a Roc module (site/Generated/PlatformReference.roc), for the page to show.
	module_text : List(Module) -> Str
	module_text = |modules| {
		q = Text.roc_string
		inline = |piece| "${piece.kind}(${q(piece.text)})"
		inline_list = |pieces| Str.join_with(pieces.map(inline), ", ")
		block = |b|
			match b {
				Sample(code) => "Sample(${q(code)})"
				Bullets(items) => "Bullets([${Str.join_with(items.map(|item| "[${inline_list(item)}]"), ", ")}])"
				Para(pieces) => "Para([${inline_list(pieces)}])"
			}
		doc = |text| "[${Str.join_with(SiteReference.blocks(text).map(block), ", ")}]"
		effect = |it| "{ name: ${q(it.name)}, type: ${q(it.type)}, doc: ${doc(it.doc)} }"
		function = |it| "{ name: ${q(it.name)}, type: ${q(it.type)} }"
		module_lines = |m| [
			"\t\t\t\t{",
			"\t\t\t\t\tname: ${q(m.name)},",
			"\t\t\t\t\tfile: ${q(m.file)},",
			"\t\t\t\t\tshared: Bool.${if (m.shared) "True" else "False"},",
			"\t\t\t\t\tdoc: ${doc(m.doc)},",
			"\t\t\t\t\teffects: [${Str.join_with(m.effects.map(effect), ", ")}],",
			"\t\t\t\t\tfunctions: [${Str.join_with(m.functions.map(function), ", ")}],",
			"\t\t\t\t},",
		]
		in_groups = SiteReference.grouped(modules)
		effect_count = modules.fold(0, |sum, m| sum + m.effects.len())
		function_count = modules.fold(0, |sum, m| sum + m.functions.len())
		group_lines = in_groups.fold(
			[],
			|so_far, g|
				so_far
					.concat(["\t\t{", "\t\t\tid: ${q(g.id)},", "\t\t\tname: ${q(g.name)},", "\t\t\tmodules: ["])
					.concat(g.modules.fold([], |all, m| all.concat(module_lines(m))))
					.concat(["\t\t\t],", "\t\t},"]),
		)
		toc = Str.join_with(in_groups.map(|g| "{ id: ${q(g.id)}, label: ${q(g.name)} }"), ", ")
		lines =
			[
				"## Written by `rocx site prepare` (rocx-cli/SiteReference.roc): every module the server platform",
				"## exposes, each with its doc comment and its items', read from the platform's sources. Edit those",
				"## (their `##` comments), not this one.",
				"PlatformReference := [].{",
				"\tInline : [Text(Str), Mono(Str)]",
				"\tBlock : [Para(List(Inline)), Sample(Str), Bullets(List(List(Inline)))]",
				"\tEffect : { name : Str, type : Str, doc : List(Block) }",
				"\tFunction : { name : Str, type : Str }",
				"\tModule : { name : Str, file : Str, shared : Bool, doc : List(Block), effects : List(Effect), functions : List(Function) }",
				"\tGroup : { id : Str, name : Str, modules : List(Module) }",
				"",
				"\t## The groups, for the page's contents (`meta.toc`): their ids and names alone.",
				"\ttoc : List({ id : Str, label : Str })",
				"\ttoc = [${toc}]",
				"",
				"\tmodule_count : U64",
				"\tmodule_count = ${modules.len().to_str()}",
				"",
				"\teffect_count : U64",
				"\teffect_count = ${effect_count.to_str()}",
				"",
				"\tfunction_count : U64",
				"\tfunction_count = ${function_count.to_str()}",
				"",
				"\tgroups : List(Group)",
				"\tgroups = [",
			]
				.concat(group_lines)
				.concat(["\t]", "}", ""])
		Str.join_with(lines, "\n")
	}

	# ---- As JSON, for the site's test (rocx internal) ----

	item_value : Item -> Value
	item_value = |it| Object([{ key: "name", value: Text(it.name) }, { key: "type", value: Text(it.type) }, { key: "doc", value: Text(it.doc) }, { key: "line", value: Value.count(it.line) }])

	module_value : Module -> Value
	module_value = |m|
		Object([
			{ key: "name", value: Text(m.name) },
			{ key: "file", value: Text(m.file) },
			{ key: "shared", value: Boolean(m.shared) },
			{ key: "doc", value: Text(m.doc) },
			{ key: "effects", value: Array(m.effects.map(SiteReference.item_value)) },
			{ key: "functions", value: Array(m.functions.map(SiteReference.item_value)) },
		])

	item_from : Value -> Item
	item_from = |v| { name: Value.str(Value.field(v, "name")), type: Value.str(Value.field(v, "type")), doc: Value.str(Value.field(v, "doc")), line: Value.int_or(Value.field(v, "line"), 0).to_u64_wrap() }

	module_from : Value -> Module
	module_from = |v| {
		name: Value.str(Value.field(v, "name")),
		file: Value.str(Value.field(v, "file")),
		shared: Value.bool_or(Value.field(v, "shared"), Bool.False),
		doc: Value.str(Value.field(v, "doc")),
		effects: Value.items(Value.field(v, "effects")).map(SiteReference.item_from),
		functions: Value.items(Value.field(v, "functions")).map(SiteReference.item_from),
	}

	inline_value : Inline -> Value
	inline_value = |piece| Object([{ key: "kind", value: Text(piece.kind) }, { key: "text", value: Text(piece.text) }])

	block_value : Block -> Value
	block_value = |b|
		match b {
			Sample(code) => Object([{ key: "kind", value: Text("Sample") }, { key: "code", value: Text(code) }])
			Bullets(items) => Object([{ key: "kind", value: Text("Bullets") }, { key: "items", value: Array(items.map(|item| Array(item.map(SiteReference.inline_value)))) }])
			Para(pieces) => Object([{ key: "kind", value: Text("Para") }, { key: "inlines", value: Array(pieces.map(SiteReference.inline_value)) }])
		}
}

expect SiteReference.is_header("Middleware(given, handed) ::", "Middleware")
expect SiteReference.is_header("Env := [].{", "Env")
expect !SiteReference.is_header("HttpResponse := [].{", "Http")
expect SiteReference.joined(["f(", "a,", "b,", ")"]) == "f(a, b)"
expect SiteReference.joined(["{", "a : A,", "}"]) == "{ a : A }"
expect SiteReference.exposed("platform \"\"\n\texposes [A, B,\n C]\n") == Ok(["A", "B", "C"])
