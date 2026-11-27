## rocx: JSX-like markup in Roc. A .rocx file is Roc in which markup may
## stand wherever an expression can; `transpile_module` turns it into plain Roc that calls the
## platform's Html (web/platform/Html.roc: components, Solid-style), line for line, so that line N of
## the output is line N of the input and the compiler's line numbers point into the .rocx file.
## README.md describes the syntax.
##
## The source is scanned by its bytes (every character rocx reads is ASCII; the rest is copied as it
## is, a whole character at a time); a problem's column is counted in UTF-16 units, as the
## JavaScript's was.
import Text
import Value
import Styles
import Getters
import Flow

Transpile := [].{

	## A problem in a .rocx file, at a line and column (both from 1).
	RocxError : { reason : Str, file : Str, line : U64, column : U64 }

	## How a file is transpiled: `module_path` names it (`Demos/Echo`, the file's path in its app without
	## `.rocx`; `""` for the file's name); with `client`, the code is the browser's copy, in which each
	## `<NoHydration>` has no children, the imports only those used dropped. `contexts` are the contexts other modules define, by their providers'
	## tags (`PicksContext` → `Picks.picks_context`), and `views` how other modules' components are
	## called (`Heading` → `view`: pure, called where written; `view!`, put off in `Html.component`).
	Options : { module_path : Str, client : Bool, contexts : List({ key : Str, value : Str }), views : List({ key : Str, value : Str }), route : Bool, dev : Bool }

	## What a file is, transpiled: its code; how many `<NoHydration>`s it has; its <style>s, scoped (a
	## component's, or the file's when `component` is `None`); its stories (`<story>` in a component's
	## block).
	##
	## For D-070's check across files (`Build.held_once`): `once`, the props a component's body reads
	## once, as it runs (its tag's, the first read of each); `handed`, a match arm's names given to a
	## component's value props, where the arm stays while its value changes.
	Module : { code : Str, regions : U64, styles : List({ css : Str, line : U64, component : [Some(Str), None] }), stories : List({ component : Str, name : Str, def : Str, line : U64 }), warnings : List(RocxError), once : List(Once), handed : List(Handed) }

	## A prop a component's body reads once (D-052's read, D-070's check): the component's tag, the
	## prop, where.
	Once : { component : Str, prop : Str, line : U64, column : U64 }

	## A match arm's name (`data`) given to a component's value prop (`<PostsView data={data} />`).
	Handed : { tag : Str, prop : Str, name : Str, line : U64, column : U64 }

	## What a transpiler knows of the file, which doesn't change as it reads.
	Cfg : {
		src : List(U8),
		file : Str,
		module_path : Str,
		client : Bool,
		# A dev build's (`rocx build --dev`): accessors a component's body calls say where they are
		# (`Html.read_at!`, D-052).
		dev : Bool,
		scopes : List({ scope : Str, from : U64, to : U64 }),
		modules : List(Str),
		packaged : List(Str),
		contexts : List({ key : Str, value : Str }),
		pure : List(Str),
		# D-039: the views whose value props are getters, the code written otherwise for them, and the
		# file's function components that take getters, and those kept with values.
		getters : List(Getters.View),
		swaps : List(Getters.Swap),
		fns : List(Str),
		plain_fns : List(Str),
		# The names of the match arms and `.map` rows around (D-070, D-071): getters, their part kept
		# while their value changes.
		arms : List(Str),
		# Where the `key` of the `.map` row being read is (D-071): the row's key, which can't change
		# while the row is there (another key is another row), so an element's is written once.
		row_key : [At(U64), Nowhere],
	}

	## Where a transpiler is in the file, and what it has found so far.
	St : {
		pos : U64,
		styles : List({ css : Str, line : U64, component : [Some(Str), None], scope : Str, from : U64, owner : [File, Block(U64)] }),
		stories : List({ component : Str, name : Str, def : Str, line : U64 }),
		preformatted : U64,
		spans : List({ kind : Str, from : U64, to : U64 }),
		effects : U64,
		regions : U64,
		in_region : U64,
		closed : List({ id : U64, to : U64 }),
		next_block : U64,
		# The closures being read, innermost last (D-039): where a prop's read goes.
		frames : List(Frame),
		# Where a lambda starts that is known to be an effect's (a handler's, a function child's).
		effectful_at : List(U64),
		warnings : List({ reason : Str, at : U64 }),
		# A component's body's reads of its props, made once (by its tag), and match arms' names given to
		# components' props (`Module`'s `once` and `handed`).
		once : List({ component : Str, prop : Str, at : U64 }),
		handed : List({ tag : Str, prop : Str, name : Str, at : U64 }),
	}

	## A closure being read, for a prop's reads (D-039). An effectful one (a hole's, an attribute's, a
	## getter's that rocx writes; `|| …`; a handler; a function child; a lambda given to an effect)
	## reads a prop where it is written: `label!()`. One that may be pure (a lambda given to `.map`)
	## can't call a getter: its reads go to its `root`, the outermost of the pure ones above an
	## effectful one, which reads them where it is made, `(|label| |x| …)(label!())`; `level` tells
	## nested roots' names apart (`label_2`), and `names` are the props its run read.
	Frame : { pure : Bool, root : Bool, level : U64, names : List(Str) }

	## An item of a Roc list or record: a newline (with the indentation the next source line has), an
	## item, or a component's function child (`{|post, index!| …}`).
	Part : [Line(Str), Item(Str), Fn(Str)]

	## A type's block (`Counter := [].{`), open: where a <style> styles that component.
	Open : { name : Str, from : U64, items_indent : Str, id : U64 }

	## The last lines of every generated file start with this; tools tell generated files by it.
	marker : Str
	marker = "# rocx: generated from"

	zero : I64
	zero = 0

	void_elements : List(Str)
	void_elements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

	## Elements whose text keeps its whitespace as written.
	preformatted_elements : List(Str)
	preformatted_elements = ["pre", "textarea"]

	## Words after which an expression begins, so a `<` after them starts markup (and a `|`, a lambda).
	## `??` too: a default is a value (`fallback : Html ?? <></>`), where a lone `?` (`x? < y`) ends one.
	keywords_before_expression : List(Str)
	keywords_before_expression = ["else", "return", "crash", "expect", "dbg", "in", "??"]

	## A component's handlers: `on:event={handler!}` runs an effect; `on:event.value={…}` and the others
	## give it what the event says (`.keys`: the key and the modifier keys held; `.point`: where the
	## pointer is over the element; `.visible`: whether the page shows; `.data` and `.files`: what a
	## drop or a paste carries, and a file input's files); `on:event.prevent={…}` takes over what the
	## browser would do.
	handler_fn : Str -> [Some(Str), None]
	handler_fn = |takes|
		if takes == "" {
			Some("on")
		} else if takes == "value" {
			Some("on_value")
		} else if takes == "checked" {
			Some("on_checked")
		} else if takes == "key" {
			Some("on_key")
		} else if takes == "keys" {
			Some("on_keys")
		} else if takes == "prevent" {
			Some("on_prevent")
		} else if takes == "point" {
			Some("on_point")
		} else if takes == "visible" {
			Some("on_visible")
		} else if takes == "data" {
			Some("on_data")
		} else if takes == "files" {
			Some("on_files")
		} else {
			None
		}

	## Which way each transition attribute plays (`Html.transition`'s first argument).
	transition_way : Str -> Str
	transition_way = |attr| if (attr == "transition:in") "In" else if (attr == "transition:out") "Out" else if (attr == "transition:move") "Move" else "Both"

	## What an HTML entity stands for (as `name in ENTITIES` answered: Object's own methods too).
	entity_value : Str -> [Some(Str), None]
	entity_value = |entity|
		match entity {
			"amp" => Some("&")
			"lt" => Some("<")
			"gt" => Some(">")
			"quot" => Some("\"")
			"apos" => Some("'")
			"nbsp" => Some("\u(a0)")
			"copy" => Some("\u(a9)")
			"reg" => Some("\u(ae)")
			"trade" => Some("\u(2122)")
			"mdash" => Some("\u(2014)")
			"ndash" => Some("\u(2013)")
			"hellip" => Some("\u(2026)")
			"middot" => Some("\u(b7)")
			"bull" => Some("\u(2022)")
			"lsquo" => Some("\u(2018)")
			"rsquo" => Some("\u(2019)")
			"ldquo" => Some("\u(201c)")
			"rdquo" => Some("\u(201d)")
			"laquo" => Some("\u(ab)")
			"raquo" => Some("\u(bb)")
			"times" => Some("\u(d7)")
			"divide" => Some("\u(f7)")
			"rarr" => Some("\u(2192)")
			"larr" => Some("\u(2190)")
			"uarr" => Some("\u(2191)")
			"darr" => Some("\u(2193)")
			"check" => Some("\u(2713)")
			"deg" => Some("\u(b0)")
			"euro" => Some("\u(20ac)")
			"pound" => Some("\u(a3)")
			"sect" => Some("\u(a7)")
			"para" => Some("\u(b6)")
			"shy" => Some("\u(ad)")
			"thinsp" => Some("\u(2009)")
			"constructor" => Some("function Object() { [native code] }")
			"hasOwnProperty" => Some("function hasOwnProperty() { [native code] }")
			"isPrototypeOf" => Some("function isPrototypeOf() { [native code] }")
			"propertyIsEnumerable" => Some("function propertyIsEnumerable() { [native code] }")
			"toLocaleString" => Some("function toLocaleString() { [native code] }")
			"toString" => Some("function toString() { [native code] }")
			"valueOf" => Some("function valueOf() { [native code] }")
			_ => None
		}

	is_ident_start : U8 -> Bool
	is_ident_start = |b| Text.is_letter(b) or b == '_' or b == '$'

	is_ident_part : U8 -> Bool
	is_ident_part = |b| Text.is_alnum(b) or b == '_' or b == '$' or b == '!'

	is_space_or_tab : U8 -> Bool
	is_space_or_tab = |b| b == ' ' or b == '\t'

	is_lower_digit_under : U8 -> Bool
	is_lower_digit_under = |b| Text.is_lower(b) or Text.is_digit(b) or b == '_'

	is_alnum_under : U8 -> Bool
	is_alnum_under = |b| Text.is_alnum(b) or b == '_'

	## How many bytes the UTF-8 character starting with `b` has.
	char_len : U8 -> U64
	char_len = |b| if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4

	## The whole character at `i`, as text.
	char_at : List(U8), U64 -> Str
	char_at = |src, i| Text.cut(src, i, i + Transpile.char_len(Text.at(src, i)))

	## A problem at `pos`.
	fail : Cfg, Str, U64 -> [Rocx(RocxError), Crash(Str)]
	fail = |cfg, reason, pos| Rocx({ reason, file: cfg.file, line: Text.line_of(cfg.src, pos), column: Text.column(cfg.src, pos) })

	## The value of `key` in `pairs`.
	lookup : List({ key : Str, value : Str }), Str -> [Some(Str), None]
	lookup = |pairs, key|
		match pairs.find_first(|p| p.key == key) {
			Ok(found) => Some(found.value)
			Err(_) => None
		}

	## `pairs` with `key` set to `value`: in its place if it is there, else at the end.
	set_key : List({ key : Str, value : Str }), Str, Str -> List({ key : Str, value : Str })
	set_key = |pairs, key, value|
		if pairs.any(|p| p.key == key) {
			pairs.map(|p| if (p.key == key) { key, value } else p)
		} else {
			pairs.append({ key, value })
		}

	## Where each line starts: 0, and after each newline.
	line_starts : List(U8) -> List(U64)
	line_starts = |src| {
		var $starts = [0]
		var $i = 0
		while $i < src.len() {
			if Text.at(src, $i) == '\n' {
				$starts = $starts.append($i + 1)
			}
			$i = $i + 1
		}
		$starts
	}

	## A path's last part (`file.split("/").pop()`).
	last_part : Str -> Str
	last_part = |path| path.split_on("/").last() ?? path

	## The spaces and tabs at `pos`.
	indent_at : List(U8), U64 -> Str
	indent_at = |src, pos| Text.cut(src, pos, Text.run_end(src, pos, Transpile.is_space_or_tab))

	## `str` with the spaces and tabs at its end gone (`/[ \t]*$/` → ``).
	trim_spaces_end : Str -> Str
	trim_spaces_end = |str| {
		bytes = str.to_utf8()
		var $end = bytes.len()
		while $end > 0 and Transpile.is_space_or_tab(Text.at(bytes, $end - 1)) {
			$end = $end - 1
		}
		Text.cut(bytes, 0, $end)
	}

	## Whether `bytes` at `i` say `word` in any case (ASCII).
	caseless_at : List(U8), Str, U64 -> Bool
	caseless_at = |bytes, word, i| {
		w = word.to_utf8()
		var $k = 0
		while $k < w.len() {
			b = Text.at(bytes, i + $k)
			lowered = if (Text.is_upper(b)) b + 32 else b
			if i + $k >= bytes.len() or lowered != Text.at(w, $k) {
				return Bool.False
			}
			$k = $k + 1
		}
		Bool.True
	}

	## The first `</name\s*>` (any case) at `from` or after: where it starts and ends.
	closing_tag : List(U8), U64, Str -> Try({ at : U64, end : U64 }, [NotFound])
	closing_tag = |src, from, tag_name| {
		var $i = from
		while $i < src.len() {
			match Text.index_of(src, "</".to_utf8(), $i) {
				Ok(k) => {
					if Transpile.caseless_at(src, tag_name, k + 2) {
						after = Text.skip_space(src, k + 2 + tag_name.to_utf8().len())
						if Text.at(src, after) == '>' and after < src.len() {
							return Ok({ at: k, end: after + 1 })
						}
					}
					$i = k + 1
				}
				Err(_) => return Err(NotFound)
			}
		}
		Err(NotFound)
	}

	## `StatusPill` → `status_pill`: a component that is not an imported module is a local function.
	snake_case : Str -> Str
	snake_case = |tag_name| {
		bytes = tag_name.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = Text.at(bytes, $i)
			if Text.is_upper(b) {
				$out = if ($i > 0) $out.concat(['_', b + 32]) else $out.append(b + 32)
			} else {
				$out = $out.append(b)
			}
			$i = $i + 1
		}
		Str.from_utf8_lossy($out)
	}

	## `picks_context` → `PicksContext`: the tag of a context's provider, as Solid spells it.
	pascal_case : Str -> Str
	pascal_case = |snake| {
		bytes = snake.to_utf8()
		up = |b| if (Text.is_lower(b)) b - 32 else b
		is_word_char = |b| Text.is_lower(b) or Text.is_digit(b)
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = Text.at(bytes, $i)
			if $i == 0 and is_word_char(b) {
				$out = $out.append(up(b))
				$i = 1
			} else if b == '_' and is_word_char(Text.at(bytes, $i + 1)) and $i + 1 < bytes.len() {
				$out = $out.append(up(Text.at(bytes, $i + 1)))
				$i = $i + 2
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The contexts a file defines (`picks_context = create_context()`, `/^(\t?)([a-z_][a-z0-9_]*)[ \t]*=[ \t]*create_context\(/gm`):
	## their names, and whether each is in the file's module (indented by a tab), where other modules
	## can name it.
	contexts_defined : Str -> List({ name : Str, shared : Bool })
	contexts_defined = |source| {
		src = source.to_utf8()
		definition_at = |p| {
			if Transpile.is_lower_digit_under(Text.at(src, p)) and !Text.is_digit(Text.at(src, p)) and p < src.len() {
				name_end = Text.run_end(src, p + 1, Transpile.is_lower_digit_under)
				q = Text.run_end(src, name_end, Transpile.is_space_or_tab)
				if Text.at(src, q) == '=' {
					r = Text.run_end(src, q + 1, Transpile.is_space_or_tab)
					if (Text.starts_with_at(src, "create_context(".to_utf8(), r)) Ok(Text.cut(src, p, name_end)) else Err(NoMatch)
				} else {
					Err(NoMatch)
				}
			} else {
				Err(NoMatch)
			}
		}
		Transpile.line_starts(src).fold(
			[],
			|found, ls|
				if Text.at(src, ls) == '\t' {
					match definition_at(ls + 1) {
						Ok(found_name) => found.append({ name: found_name, shared: Bool.True })
						Err(_) => found
					}
				} else {
					match definition_at(ls) {
						Ok(found_name) => found.append({ name: found_name, shared: Bool.False })
						Err(_) => found
					}
				},
		)
	}

	## The types a file defines with a block, `Counter := [].{ … }`: their names, where their line starts
	## and its indentation (`/^([ \t]*)([A-Z][A-Za-z0-9_]*)(?:\([^)\n]*\))?[ \t]*:=(?:(?!\n\1[^\s\])}])[^])*?\.\{/gm`).
	type_blocks : List(U8) -> List({ name : Str, at : U64, indent : Str })
	type_blocks = |src| {
		var $found = []
		var $next = 0
		for ls in Transpile.line_starts(src) {
			if ls >= $next {
				indent_end = Text.run_end(src, ls, Transpile.is_space_or_tab)
				if Text.is_upper(Text.at(src, indent_end)) and indent_end < src.len() {
					name_end = Text.run_end(src, indent_end + 1, Transpile.is_alnum_under)
					after_params =
						if Text.at(src, name_end) == '(' {
							close = Text.run_end(src, name_end + 1, |b| b != ')' and b != '\n')
							if (Text.at(src, close) == ')' and close < src.len()) close + 1 else name_end
						} else {
							name_end
						}
					p = Text.run_end(src, after_params, Transpile.is_space_or_tab)
					if Text.starts_with_at(src, ":=".to_utf8(), p) {
						indent = Text.slice(src, ls, indent_end)
						var $j = p + 2
						var $result = NoMatch
						while $j < src.len() and $result == NoMatch {
							if Text.starts_with_at(src, ".{".to_utf8(), $j) {
								$result = Ends($j + 2)
							} else if Text.at(src, $j) == '\n' and Text.starts_with_at(src, indent, $j + 1) and $j + 1 + indent.len() < src.len() and !Text.is_space_at(src, $j + 1 + indent.len()) and !([')', ']', '}'].contains(Text.at(src, $j + 1 + indent.len()))) {
								$result = Stopped
							} else {
								$j = $j + 1
							}
						}
						match $result {
							Ends(end) => {
								$found = $found.append({ name: Text.cut(src, indent_end, name_end), at: ls, indent: Str.from_utf8_lossy(indent) })
								$next = end
							}
							_ => {}
						}
					}
				}
			}
		}
		$found
	}

	## The components a file defines, each a type with a block (`Heading := [].{ … }`), and how each is
	## called: `view!`, a component that may make signals and read contexts, run where it is rendered
	## (`Html.component`); or `view`, a pure one (no `!`), called where it is written, like a function.
	## A block with neither isn't there.
	views_defined : Str -> List({ key : Str, value : Str })
	views_defined = |source| {
		src = source.to_utf8()
		blocks = Transpile.type_blocks(src)
		var $views = []
		for ls in Transpile.line_starts(src) {
			indent_end = Text.run_end(src, ls, Transpile.is_space_or_tab)
			if indent_end > ls and Text.starts_with_at(src, "view".to_utf8(), indent_end) {
				bang = Text.at(src, indent_end + 4) == '!'
				q = Text.run_end(src, indent_end + 4 + (if (bang) 1 else 0), Transpile.is_space_or_tab)
				c = Text.at(src, q)
				if (c == ':' or c == '=') and q < src.len() {
					indent = Text.cut(src, ls, indent_end)
					indent_len = indent_end - ls
					# A `view` is the block's it is a direct member of: the innermost one opened before it whose
					# indentation is less than its own.
					owner = blocks.fold(
						None,
						|best, b|
							if b.at < ls and indent_len > b.indent.to_utf8().len() and indent.starts_with(b.indent) {
								match best {
									Some(chosen) => if (b.indent.to_utf8().len() >= chosen.indent.to_utf8().len()) Some(b) else best
									None => Some(b)
								}
							} else {
								best
							},
					)
					match owner {
						Some(b) => {
							if Transpile.lookup($views, b.name) != Some("view!") {
								$views = Transpile.set_key($views, b.name, if (bang) "view!" else "view")
							}
						}
						None => {}
					}
				}
			}
		}
		$views
	}

	## `^import\s+(?:([a-z_][a-z0-9_]*)\.)?(?:\.{0,2}\/)*(?:[A-Za-z0-9_]+\/)*([A-Z][A-Za-z0-9]*)(?:\s+as\s+([A-Z][A-Za-z0-9]*))?`
	## at `i`: the module's package, name and alias, and where the match ends.
	import_at : List(U8), U64 -> Try({ pkg : [Some(Str), None], name : Str, alias : [Some(Str), None], end : U64 }, [NoMatch])
	import_at = |src, i| {
		if !Text.starts_with_at(src, "import".to_utf8(), i) {
			return Err(NoMatch)
		}
		k = Text.skip_space(src, i + 6)
		if k == i + 6 {
			return Err(NoMatch)
		}
		pkg_part =
			if Transpile.is_lower_digit_under(Text.at(src, k)) and !Text.is_digit(Text.at(src, k)) and k < src.len() {
				e = Text.run_end(src, k + 1, Transpile.is_lower_digit_under)
				if (Text.at(src, e) == '.') { pkg: Some(Text.cut(src, k, e)), at: e + 1 } else { pkg: None, at: k }
			} else {
				{ pkg: None, at: k }
			}
		# `(?:\.{0,2}\/)*`
		var $p = pkg_part.at
		var $prefixing = Bool.True
		while $prefixing {
			dots = if (Text.at(src, $p) == '.') (if (Text.at(src, $p + 1) == '.') 2 else 1) else 0
			if Text.at(src, $p + dots) == '/' and $p + dots < src.len() {
				$p = $p + dots + 1
			} else if dots == 2 and Text.at(src, $p + 1) == '/' {
				$p = $p + 2
			} else {
				$prefixing = Bool.False
			}
		}
		# `(?:[A-Za-z0-9_]+\/)*`, most segments first, then the name.
		var $starts = [$p]
		var $q = $p
		var $segmenting = Bool.True
		while $segmenting {
			e = Text.run_end(src, $q, Transpile.is_alnum_under)
			if e > $q and Text.at(src, e) == '/' and e < src.len() {
				$q = e + 1
				$starts = $starts.append($q)
			} else {
				$segmenting = Bool.False
			}
		}
		match $starts.find_last(|s| Text.is_upper(Text.at(src, s)) and s < src.len()) {
			Ok(name_start) => {
				name_end = Text.run_end(src, name_start + 1, Text.is_alnum)
				s = Text.skip_space(src, name_end)
				aliased =
					if s > name_end and Text.starts_with_at(src, "as".to_utf8(), s) {
						t = Text.skip_space(src, s + 2)
						if t > s + 2 and Text.is_upper(Text.at(src, t)) and t < src.len() {
							alias_end = Text.run_end(src, t + 1, Text.is_alnum)
							Some({ alias: Text.cut(src, t, alias_end), end: alias_end })
						} else {
							None
						}
					} else {
						None
					}
				match aliased {
					Some(a) => Ok({ pkg: pkg_part.pkg, name: Text.cut(src, name_start, name_end), alias: Some(a.alias), end: a.end })
					None => Ok({ pkg: pkg_part.pkg, name: Text.cut(src, name_start, name_end), alias: None, end: name_end })
				}
			}
			Err(_) => Err(NoMatch)
		}
	}

	## Whether the file imports the platform's Context (`/^import\s+[a-z_][a-z0-9_]*\.Context\b/m`).
	has_context_import : List(U8) -> Bool
	has_context_import = |src|
		Transpile.line_starts(src).any(
			|ls| {
				if Text.starts_with_at(src, "import".to_utf8(), ls) {
					k = Text.skip_space(src, ls + 6)
					if k > ls + 6 and Transpile.is_lower_digit_under(Text.at(src, k)) and !Text.is_digit(Text.at(src, k)) and k < src.len() {
						e = Text.run_end(src, k + 1, Transpile.is_lower_digit_under)
						Text.starts_with_at(src, ".Context".to_utf8(), e) and !Text.is_word(Text.at(src, e + 8))
					} else {
						Bool.False
					}
				} else {
					Bool.False
				}
			},
		)

	## What a transpiler knows of the file; or the problem with how it imports Html.
	new_cfg : Str, Str, Options, List({ scope : Str, from : U64, to : U64 }) -> Try(Cfg, [Rocx(RocxError), Crash(Str)])
	new_cfg = |source, file, opts, scopes| {
		src = source.to_utf8()
		file_name = Transpile.last_part(file)
		module_path = if (opts.module_path == "") (if (file_name.ends_with(".rocx")) file_name.drop_suffix(".rocx") else file_name) else opts.module_path
		base = { src, file, module_path, client: opts.client, dev: opts.dev, scopes, modules: [], packaged: [], contexts: [], pure: [], getters: [], swaps: [], fns: [], plain_fns: [], arms: [], row_key: Nowhere }
		starts = Transpile.line_starts(src)
		# Markup is components, written with the platform's Html (both platforms have it): there is no
		# other (the html package, which rendered static pages, is gone).
		foreign = starts.fold(
			None,
			|seen, ls|
				match seen {
					Some(_) => seen
					None =>
						if Text.starts_with_at(src, "import".to_utf8(), ls) {
							k = Text.run_end(src, ls + 6, Transpile.is_space_or_tab)
							if k > ls + 6 and Transpile.is_lower_digit_under(Text.at(src, k)) and !Text.is_digit(Text.at(src, k)) and k < src.len() {
								e = Text.run_end(src, k + 1, Transpile.is_lower_digit_under)
								if Text.starts_with_at(src, ".Html".to_utf8(), e) and !Text.is_word(Text.at(src, e + 5)) {
									Some({ ls, pkg: Text.cut(src, k, e), end: e + 5 })
								} else {
									None
								}
							} else {
								None
							}
						} else {
							None
						}
				},
		)
		match foreign {
			Some(f) if f.pkg != "pf" => {
				offset = Text.index_of(Text.slice(src, f.ls, f.end), f.pkg.to_utf8(), 0) ?? 0
				return Err(Transpile.fail(base, "import ${f.pkg}.Html: markup is components, written with the platform's Html, which the server renders and the browser hydrates: import pf.Html", f.ls + offset))
			}
			_ => {}
		}
		# Modules imported by name: a component tag with one of these names calls its `view`; those
		# imported from a package (`import pf.Show`) are a platform's components, which are markup.
		var $modules = []
		var $packaged = []
		var $next = 0
		for ls in starts {
			if ls >= $next {
				match Transpile.import_at(src, ls) {
					Ok(m) => {
						name = match m.alias {
							Some(a) => a
							None => m.name
						}
						$modules = $modules.append(name)
						match m.pkg {
							Some(_) => {
								$packaged = $packaged.append(name)
							}
							None => {}
						}
						$next = m.end
					}
					Err(_) => {}
				}
			}
		}
		# And the components this file defines, each a type with a block: a file may have several.
		for b in Transpile.type_blocks(src) {
			$modules = $modules.append(b.name)
		}
		# The contexts a provider's tag may name: this file's, and those of the modules it imports.
		var $contexts = []
		for c in opts.contexts {
			owner = c.value.split_on(".").first() ?? ""
			if $modules.contains(owner) {
				$contexts = Transpile.set_key($contexts, c.key, c.value)
			}
		}
		for d in Transpile.contexts_defined(source) {
			$contexts = Transpile.set_key($contexts, Transpile.pascal_case(d.name), d.name)
		}
		# The components that are pure (`view`, no `!`): called where they are written, not put off.
		known = Transpile.views_defined(source).fold(opts.views, |all, v| Transpile.set_key(all, v.key, v.value))
		var $pure = []
		for name in $modules {
			if Transpile.lookup(known, name) == Some("view") and !$packaged.contains(name) {
				$pure = $pure.append(name)
			}
		}
		# A function component of this file's (`card = |{ title }| …`, for `<Card>`) defined with no `!`
		# is pure too: called where it is written (`card({…})`).
		for ls in starts {
			p = Text.run_end(src, ls, Transpile.is_space_or_tab)
			if Text.is_lower(Text.at(src, p)) and p < src.len() {
				name_end = Text.run_end(src, p + 1, Transpile.is_lower_digit_under)
				q = Text.run_end(src, name_end, Transpile.is_space_or_tab)
				if Text.at(src, q) == '=' {
					r = Text.run_end(src, q + 1, Transpile.is_space_or_tab)
					if Text.at(src, r) == '|' {
						name = Text.cut(src, p, name_end)
						tag = Transpile.pascal_case(name)
						if !$modules.contains(tag) and Transpile.snake_case(tag) == name {
							$pure = $pure.append(tag)
						}
					}
				}
			}
		}
		found =
			match Getters.find(src, Transpile.type_blocks(src)) {
				Ok(f) => f
				Err(Problem(problem)) => return Err(Transpile.fail(base, problem.reason, problem.at))
			}
		Ok({ ..base, modules: $modules, packaged: $packaged, contexts: $contexts, pure: $pure, getters: found.views, swaps: found.swaps, fns: found.fns, plain_fns: found.plain_fns })
	}

	## A transpiler at the start of the file.
	fresh : St
	fresh = { pos: 0, styles: [], stories: [], preformatted: 0, spans: [], effects: 0, regions: 0, in_region: 0, closed: [], next_block: 0, frames: [], effectful_at: [], warnings: [], once: [], handed: [] }

	## Items of a Roc list or record, separated by commas, with newlines where the source had them.
	render_items : List(Part) -> Str
	render_items = |list| {
		var $out = ""
		var $pending = Bool.False
		for part in list {
			match part {
				Line(indent) => {
					if $pending {
						$out = $out.concat(",")
					}
					$pending = Bool.False
					$out = $out.concat("\n").concat(indent)
				}
				Item(text) => {
					if $pending {
						$out = $out.concat(", ")
					}
					$out = $out.concat(text)
					$pending = Bool.True
				}
				Fn(_) => {
					if $pending {
						$out = $out.concat(", ")
					}
					$out = $out.concat("[object Object]")
					$pending = Bool.True
				}
			}
		}
		if ($pending) $out.concat(",") else $out
	}

	is_fn : Part -> Bool
	is_fn = |part|
		match part {
			Fn(_) => Bool.True
			_ => Bool.False
		}

	is_line : Part -> Bool
	is_line = |part|
		match part {
			Line(_) => Bool.True
			_ => Bool.False
		}

	## Text decoded as HTML would: `&amp;`, `&#39;`, `&#x2014;` (`/&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);/g`).
	## An unknown entity is a problem at `at`.
	decode_entities : Cfg, Str, U64 -> Try(Str, [Rocx(RocxError), Crash(Str)])
	decode_entities = |cfg, text, at| {
		bytes = text.to_utf8()
		if !bytes.contains('&') {
			return Ok(text)
		}
		is_hex = |b| Text.is_digit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F')
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			found =
				if c != '&' {
					None
				} else if Text.at(bytes, $i + 1) == '#' and Text.at(bytes, $i + 2) == 'x' {
					e = Text.run_end(bytes, $i + 3, is_hex)
					if (e > $i + 3 and Text.at(bytes, e) == ';') Some(Numeric({ digits: Text.slice(bytes, $i + 3, e), base: 16, end: e + 1 })) else None
				} else if Text.at(bytes, $i + 1) == '#' {
					e = Text.run_end(bytes, $i + 2, Text.is_digit)
					if (e > $i + 2 and Text.at(bytes, e) == ';') Some(Numeric({ digits: Text.slice(bytes, $i + 2, e), base: 10, end: e + 1 })) else None
				} else {
					e = Text.run_end(bytes, $i + 1, Text.is_letter)
					if (e > $i + 1 and Text.at(bytes, e) == ';') Some(Named({ name: Text.cut(bytes, $i + 1, e), end: e + 1 })) else None
				}
			match found {
				None => {
					$out = $out.append(c)
					$i = $i + 1
				}
				Some(Named(n)) =>
					match Transpile.entity_value(n.name) {
						Some(value) => {
							$out = $out.concat(value.to_utf8())
							$i = n.end
						}
						None => return Err(Transpile.fail(cfg, "unknown entity &${n.name};; write the character itself", at))
					}
				Some(Numeric(n)) => {
					digit = |b| if (Text.is_digit(b)) (b - '0').to_u64() else if (b >= 'a') (b - 'a' + 10).to_u64() else (b - 'A' + 10).to_u64()
					limit : U64
					limit = 1_000_000_000_000_000
					code = n.digits.fold(0, |acc, b| if (acc > limit) acc else acc * n.base + digit(b))
					if code > 0x10FFFF {
						return Err(Crash("Invalid code point ${code.to_str()}"))
					}
					point = code.to_u32_wrap()
					$out = $out.concat(if (point >= 0xD800 and point <= 0xDFFF) [0xEF, 0xBF, 0xBD] else Text.utf8(point))
					$i = n.end
				}
			}
		}
		Ok(Str.from_utf8_lossy($out))
	}

	## HTML's whitespace rule, as Svelte applies it: each run of spaces, tabs and newlines in text is
	## one space. At the start of an element's children (`first`) and at their end (`last`), a run
	## with a line break in it goes, and one on the same line as the tag stays, a space
	## (`<b>x </b>`). (`&nbsp;` is not whitespace.)
	collapse_whitespace : Str, Bool, Bool -> Str
	collapse_whitespace = |raw, first, last| {
		bytes = raw.to_utf8()
		var $out = []
		var $in_run = Bool.False
		# Whether the run at the start, and the one at the end so far, has a line break in it.
		var $leading_break = Bool.False
		var $trailing_break = Bool.False
		var $started = Bool.False
		for b in bytes {
			if b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0C {
				if !$in_run {
					$out = $out.append(' ')
					$trailing_break = Bool.False
				}
				$in_run = Bool.True
				if b == '\n' or b == '\r' {
					$trailing_break = Bool.True
					if !$started {
						$leading_break = Bool.True
					}
				}
			} else {
				$out = $out.append(b)
				$in_run = Bool.False
				$started = Bool.True
			}
		}
		collapsed = Str.from_utf8_lossy($out)
		started = if (first and $leading_break) Text.trim_start(collapsed) else collapsed
		if (last and $trailing_break and $in_run) Text.trim_end(started) else started
	}

	## `/^([A-Za-z_][A-Za-z0-9_]*\.)*[a-z_][A-Za-z0-9_]*!$/`: an accessor's name (`title!`, `Store.title!`).
	is_accessor_name : Str -> Bool
	is_accessor_name = |code| {
		if !code.ends_with("!") {
			return Bool.False
		}
		segments = code.drop_suffix("!").split_on(".")
		last_ok =
			match segments.last() {
				Ok(seg) => {
					b = Text.at(seg.to_utf8(), 0)
					Text.is_lower(b) or b == '_'
				}
				Err(_) => Bool.False
			}
		last_ok and segments.all(
			|seg| {
				bytes = seg.to_utf8()
				first = Text.at(bytes, 0)
				!bytes.is_empty() and (Text.is_letter(first) or first == '_') and bytes.all(Transpile.is_alnum_under)
			},
		)
	}

	## A component's static prop: a getter for a component that takes them (D-039), else the value.
	static_prop : Bool, Str, Str -> Str
	static_prop = |getters, name, value| if (getters and Getters.is_value(name)) "|| ${value}" else value

	## Reactive, a component's prop named as an effect (`title!`) is an accessor, as Solid's compiler
	## makes a prop a getter: `title!={user!().name}` passes `|| user!().name`. A prop that already is a
	## function, an accessor's name or a lambda, is passed as it is. Other props are values.
	accessor_prop : Str, Str -> Str
	accessor_prop = |prop, expr| {
		if !prop.ends_with("!") {
			return expr
		}
		code = Text.trim(expr)
		if (Transpile.is_accessor_name(code) or code.starts_with("|")) expr else "|| ${expr}"
	}

	## A closure opened (D-039): effectful, or one that may be pure, which is a root when what is
	## around it is effectful (or the component's body).
	opened : St, Bool -> St
	opened = |st, pure| {
		outer_pure =
			match st.frames.last() {
				Ok(f) => f.pure
				Err(_) => Bool.False
			}
		root = pure and !outer_pure
		level = if (root) st.frames.keep_if(|f| f.root).len() + 1 else 0
		{ ..st, frames: st.frames.append({ pure, root, level, names: [] }) }
	}

	## The root of the pure closures a read is in (the first root below the innermost), if it is in one.
	root_of : List(Frame) -> [Some(U64), None]
	root_of = |frames| {
		var $i = frames.len()
		while $i > 0 {
			match frames.get($i - 1) {
				Ok(f) => {
					if !f.pure {
						return None
					}
					if f.root {
						return Some($i - 1)
					}
				}
				Err(_) => return None
			}
			$i = $i - 1
		}
		None
	}

	## A prop read here (`key`: `label`, or `props.label` for a view that names its whole record): its
	## getter called (`label!()`) where the closure around it is effectful, or it is the body; in one
	## that may be pure, the name its root binds the value to.
	read_prop : St, Str -> { st : St, text : Str }
	read_prop = |st, key|
		match Transpile.root_of(st.frames) {
			Some(at) =>
				match st.frames.get(at) {
					Ok(root) => {
						names = if (root.names.contains(key)) root.names else root.names.append(key)
						{ st: { ..st, frames: st.frames.set(at, { ..root, names }) ?? st.frames }, text: Transpile.lent_name(key, root.level) }
					}
					Err(_) => { st, text: key }
				}
			None => { st: { ..st, effects: st.effects + 1 }, text: Transpile.getter_call(key) }
		}

	## The name a pure root binds a prop's value to: `label`, `props_label`; `label_2` in a root inside
	## another.
	lent_name : Str, U64 -> Str
	lent_name = |key, level| {
		base = key.replace_each(".", "_")
		if (level > 1) "${base}_${level.to_str()}" else base
	}

	## A prop's getter called: `label!()`, or `(props.label)()` (`props.label()` would be a method's call).
	getter_call : Str -> Str
	getter_call = |key| if (key.contains(".")) "(${key})()" else "${key}!()"

	## A prop's getter: `label!`, or `props.label`.
	getter_of : Str -> Str
	getter_of = |key| if (key.contains(".")) key else "${key}!"

	## An accessor called in a component's body, in a dev build (D-052): `Html.read_at!("file:3:9",
	## count!)`, which calls it, telling the runtime where it is, so a read made once, as the component
	## runs, is said with its place (`warnRead`). As long as `count!()` was: lines stay lines.
	read_at : Cfg, U64, Str -> Str
	read_at = |cfg, pos, accessor| {
		place = "${cfg.file}:${Text.line_of(cfg.src, pos).to_str()}:${Text.column(cfg.src, pos).to_str()}"
		"Html.read_at!(${Text.roc_string(place)}, ${accessor})"
	}

	## A prop read in a component's body (no closure around it, and not in a match arm's code) is one
	## it makes once, as it runs: noted by the component's tag, the first read of each prop, for D-070's
	## check across files (`Build.held_once`).
	read_once : Cfg, St, Try(Getters.View, [NotFound]), Str, U64, Bool -> St
	read_once = |cfg, st, in_view, key, at, in_body|
		match in_view {
			Ok(view) if in_body and cfg.arms.is_empty() and view.component != "" and !key.contains(".") and !st.once.any(|o| o.component == view.component and o.prop == key) =>
				{ ..st, once: st.once.append({ component: view.component, prop: key, at }) }
			_ => st
		}

	## A closure closed (D-039): its frame let go of. A pure root whose run read props reads them where
	## it is made: what was written from `out_at` on (`it`) becomes `(|label| it)(label!())`. Made in a
	## component's body (the lambda at `at`), those reads are the body's, said where in a dev build
	## (`read_at`, D-052).
	closed : Cfg, St, Str, U64, U64 -> { st : St, out : Str }
	closed = |cfg, st, out, out_at, at| {
		match st.frames.last() {
			Ok(frame) => {
				st1 = { ..st, frames: st.frames.drop_last(1) }
				if frame.root and !frame.names.is_empty() {
					bytes = out.to_utf8()
					bound = Str.join_with(frame.names.map(|key| Transpile.lent_name(key, frame.level)), ", ")
					in_body = cfg.dev and st1.frames.is_empty() and cfg.getters.any(|v| v.from <= at and at < v.to)
					reads = Str.join_with(frame.names.map(|key| if (in_body) Transpile.read_at(cfg, at, Transpile.getter_of(key)) else Transpile.getter_call(key)), ", ")
					view = Transpile.view_at(cfg, at)
					st2 = frame.names.fold(st1, |so_far, key| Transpile.read_once(cfg, so_far, view, key, at, st1.frames.is_empty()))
					{ st: { ..st2, effects: st2.effects + 1 }, out: "${Text.cut(bytes, 0, out_at)}(|${bound}| ${Text.rest(bytes, out_at)})(${reads})" }
				} else {
					{ st: st1, out }
				}
			}
			Err(_) => { st, out }
		}
	}

	## Every lambda a read opened, closed, the innermost first.
	close_all : Cfg, St, Str, List({ out_at : U64, brackets : U64, line_indent : U64, at : U64 }) -> { st : St, out : Str }
	close_all = |cfg, st, out, lambdas|
		lambdas.fold_rev(
			{ st, out },
			|lambda, done| Transpile.closed(cfg, done.st, done.out, lambda.out_at, lambda.at),
		)

	## Whether the lambda ends at `pos`, `brackets` being open: at a `,` or a closer of the brackets it
	## is in, at `else`, or at a line break before a line indented no deeper than the line it began on.
	lambda_ends : List(U8), U64, U64, { out_at : U64, brackets : U64, line_indent : U64, at : U64 } -> Bool
	lambda_ends = |src, pos, brackets, lambda| {
		if brackets != lambda.brackets {
			return Bool.False
		}
		c = Text.at(src, pos)
		if c == ')' or c == ']' or c == '}' or c == ',' {
			return Bool.True
		}
		if Text.starts_with_at(src, "else".to_utf8(), pos) and !Transpile.is_ident_part(Text.at(src, pos + 4)) and (pos == 0 or !Transpile.is_ident_part(Text.at(src, pos - 1))) {
			return Bool.True
		}
		if c != '\n' {
			return Bool.False
		}
		var $ls = pos + 1
		var $first = Text.run_end(src, $ls, Transpile.is_space_or_tab)
		while $first < src.len() and (Text.at(src, $first) == '\n' or Text.at(src, $first) == '\r') {
			$ls = $first + 1
			$first = Text.run_end(src, $ls, Transpile.is_space_or_tab)
		}
		$first >= src.len() or $first - $ls <= lambda.line_indent
	}

	## Whether a `|` after `last` starts a lambda: an expression may begin there (not after a value,
	## where it is a pattern's alternative).
	lambda_here : Str -> Bool
	lambda_here = |last| {
		if last == "" or Transpile.keywords_before_expression.contains(last) {
			return Bool.True
		}
		end = Text.at(last.to_utf8(), last.to_utf8().len() - 1)
		!(Transpile.is_ident_part(end) or end == ')' or end == ']' or end == '}' or end == '"' or end == '\'' or end == '?')
	}

	## Whether a lambda's parameters (`|{ day, x }|`) bind `name`.
	binds : List(U8), Str -> Bool
	binds = |params, name| {
		needle = name.to_utf8()
		var $i = 0
		while $i < params.len() {
			match Text.index_of(params, needle, $i) {
				Ok(k) => {
					e = k + needle.len()
					before = if (k == 0) ' ' else Text.at(params, k - 1)
					after = Text.run_end(params, e, Transpile.is_space_or_tab)
					if !Transpile.is_ident_part(before) and before != '.' and !Transpile.is_ident_part(Text.at(params, e)) and Text.at(params, after) != ':' {
						return Bool.True
					}
					$i = k + 1
				}
				Err(_) => return Bool.False
			}
		}
		Bool.False
	}

	## A view's prop read at `pos` (D-039): the prop (`label`; `props.label` for a view that names its
	## whole record), where its name ends, and whether it is a record's punned field (`{ id, label }`).
	## Not a read: after a `.`, or a record's label (`label: …`). A prop's name bound again is refused.
	prop_at : Cfg, Getters.View, U64, U64, Str, Str, List({ c : U8, bang : Bool }) -> Try([Read({ key : Str, end : U64, punned : Bool }), NotRead], [Rocx(RocxError), Crash(Str)])
	prop_at = |cfg, view, pos, end, word, last, open| {
		src = cfg.src
		before = if (pos > 0) Text.at(src, pos - 1) else ' '
		spread = pos >= 2 and before == '.' and Text.at(src, pos - 2) == '.'
		if before == '.' and !spread {
			return Ok(NotRead)
		}
		match view.record {
			Some(record) =>
				if word == record and Text.at(src, end) == '.' {
					f_end = Text.run_end(src, end + 1, Transpile.is_ident_part)
					field = Text.cut(src, end + 1, f_end)
					return if (Getters.is_value(field) and (view.fields.is_empty() or view.fields.contains(field))) Ok(Read({ key: "${record}.${field}", end: f_end, punned: Bool.False })) else Ok(NotRead)
				}
			None => {}
		}
		if !view.props.contains(word) {
			return Ok(NotRead)
		}
		next = Text.run_end(src, end, Transpile.is_space_or_tab)
		nc = Text.at(src, next)
		if nc == ':' and Text.at(src, next + 1) != ':' and Text.at(src, next + 1) != '=' {
			return Ok(NotRead)
		}
		first_on_line = Text.run_end(src, Text.line_start(src, pos), Transpile.is_space_or_tab) == pos
		if (nc == '=' and Text.at(src, next + 1) != '=' and Text.at(src, next + 1) != '>' and first_on_line) or last == "for" {
			return Err(Transpile.fail(cfg, "${word} is a prop of this component, which rocx reads through its getter: give this another name", pos))
		}
		in_record =
			match open.last() {
				Ok(o) => o.c == '{'
				Err(_) => Bool.False
			}
		na = Text.at(src, Getters.skip_blank(src, end, src.len()))
		punned = in_record and (last == "," or last == "{") and (na == ',' or na == '}') and !(last == "{" and na == '}')
		Ok(Read({ key: word, end, punned }))
	}

	## A swap's text (D-039's props type, or a view's pattern), its props' defaults read as code: markup
	## in one (`fallback : Html ?? <></>`) made calls, as anywhere else.
	swapped : Cfg, St, Getters.Swap -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	swapped = |cfg, st0, swap| {
		text = swap.text.to_utf8()
		var $st = st0
		var $out = ""
		var $copied = 0
		for default in swap.defaults {
			if Text.slice(cfg.src, default.from, default.to).contains('<') {
				# The source up to the default's end, read from its start: all of it, and no further.
				read = Transpile.read_code({ ..cfg, src: Text.slice(cfg.src, 0, default.to) }, { ..$st, pos: default.from }, Bool.False)?
				$out = $out.concat(Text.cut(text, $copied, default.at)).concat(read.out)
				$st = read.st
				$copied = default.at + (default.to - default.from)
			}
		}
		Ok({ st: $st, out: $out.concat(Text.cut(text, $copied, text.len())) })
	}

	## Roc code, with any markup in it turned into calls; up to an unmatched `}` when inside a hole.
	read_code : Cfg, St, Bool -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_code = |cfg, st0, inside_braces| {
		src = cfg.src
		start = st0.pos
		var $st = st0
		var $out = ""
		var $depth = Transpile.zero
		# The last significant token: after a value, `<` is the less-than operator.
		var $last = ""
		# The significant token before it (`x!` in `x! = |…|`).
		var $prev = ""
		# Each open bracket, innermost last, and whether a `(` calls an effect (`create_effect!(`).
		var $open = []
		# The lambdas this read opened and hasn't closed (D-039), innermost last: where each began in
		# `$out`, how many brackets were open there, and its line's indentation.
		var $lambdas = []
		# Whether each open `(` holds an `if` or `while` condition: after its `)`, an expression starts.
		var $parens = []
		# Each open `{`: a type's block (`Counter := [].{`), where a <style> styles that component, or none.
		var $blocks = []
		# The type a `:=` just declared, whose block a `.{` would open.
		var $declared = None
		while $st.pos < src.len() {
			pos = $st.pos
			c = Text.at(src, pos)
			last_before = $last
			var $closing = !$lambdas.is_empty()
			while $closing {
				match $lambdas.last() {
					Ok(lambda) if Transpile.lambda_ends(src, pos, $open.len(), lambda) => {
						done = Transpile.closed(cfg, $st, $out, lambda.out_at, lambda.at)
						$st = done.st
						$out = done.out
						$lambdas = $lambdas.drop_last(1)
					}
					_ => {
						$closing = Bool.False
					}
				}
			}
			if c == '}' and inside_braces and $depth == 0 {
				return Ok({ st: $st, out: $out })
			}
			if (c == '{' or c == '|') and cfg.swaps.any(|swap| swap.from == pos) {
				# Written otherwise (D-039): a view's props type, made of getters, or its pattern.
				swap = cfg.swaps.find_first(|each| each.from == pos) ?? { from: pos, to: pos + 1, text: "", defaults: [] }
				written = Transpile.swapped(cfg, $st, swap)?
				$out = $out.concat(written.out)
				$st = { ..written.st, pos: swap.to }
				$last = if (c == '|') "|" else "}"
			} else if c == '(' {
				$parens = $parens.append($last == "if" or $last == "while")
				$open = $open.append({ c, bang: $last.ends_with("!") and $last != "!" })
				$out = $out.concat("(")
				$st = { ..$st, pos: pos + 1 }
				$last = "("
			} else if c == ')' {
				condition = $parens.last() ?? Bool.False
				$parens = $parens.drop_last(1)
				$open = $open.drop_last(1)
				$out = $out.concat(")")
				$st = { ..$st, pos: pos + 1 }
				$last = if (condition) "(" else ")"
			} else if c == '{' or c == '[' {
				$open = $open.append({ c, bang: Bool.False })
				if c == '{' {
					$depth = $depth + 1
					back = Text.skip_space_back(src, pos)
					opens_block = back > 0 and Text.at(src, back - 1) == '.'
					match $declared {
						Some(declared_name) if opens_block => {
							id = $st.next_block
							$blocks = $blocks.append(Opened({ name: declared_name, from: pos, items_indent: Transpile.item_indent(src, pos), id }))
							$st = { ..$st, next_block: id + 1 }
							$declared = None
						}
						_ => {
							$blocks = $blocks.append(NotABlock)
						}
					}
				}
				$out = $out.concat(if (c == '{') "{" else "[")
				$st = { ..$st, pos: pos + 1 }
				$last = if (c == '{') "{" else "["
			} else if c == ']' {
				$open = $open.drop_last(1)
				$out = $out.concat("]")
				$st = { ..$st, pos: pos + 1 }
				$last = "]"
			} else if c == '|' and Transpile.lambda_here($last) {
				# A lambda (D-039): effectful (`|| …`; a handler's, a function child's; given to an effect,
				# `create_effect!(…, |r| …)`; bound to an effect's name, `ended! = |x| …`, or field), or one
				# that may be pure, which can't call a prop's getter.
				params_end = if (Text.at(src, pos + 1) == '|') pos + 2 else Getters.top_level(src, pos + 1, src.len(), ['|']) + 1
				params = Text.slice(src, pos, params_end)
				match Transpile.view_at(cfg, pos) {
					Ok(view) =>
						match view.props.find_first(|prop| Transpile.binds(params, prop)) {
							Ok(prop) => return Err(Transpile.fail(cfg, "${prop} is a prop of this component, which rocx reads through its getter: give this parameter another name", pos))
							Err(_) => {}
						}
					Err(_) => {}
				}
				bang_arg = ($last == "(" or $last == ",") and (
					match $open.last() {
						Ok(o) => o.c == '(' and o.bang
						Err(_) => Bool.False
					}
				)
				named = ($last == "=" or $last == ":") and $prev.ends_with("!")
				effectful = params_end == pos + 2 or $st.effectful_at.contains(pos) or bang_arg or named
				$lambdas = $lambdas.append({ out_at: $out.to_utf8().len(), brackets: $open.len(), line_indent: Text.run_end(src, Text.line_start(src, pos), Transpile.is_space_or_tab) - Text.line_start(src, pos), at: pos })
				$st = Transpile.opened({ ..$st, pos: params_end }, !effectful)
				$out = $out.concat(Str.from_utf8_lossy(params))
				$last = "|"
			} else if c == '}' {
				$open = $open.drop_last(1)
				$depth = $depth - 1
				match $blocks.last() {
					Ok(Opened(b)) => {
						$st = { ..$st, closed: $st.closed.append({ id: b.id, to: pos }) }
					}
					_ => {}
				}
				$blocks = $blocks.drop_last(1)
				$out = $out.concat("}")
				$st = { ..$st, pos: pos + 1 }
				$last = "}"
			} else if c == '#' {
				stop = Text.line_end(src, pos)
				$out = $out.concat(Text.cut(src, pos, stop))
				$st = { ..$st, pos: stop }
			} else if c == '\\' and Text.at(src, pos + 1) == '\\' {
				line = Transpile.read_multiline_line(cfg, $st)?
				$out = $out.concat(line.out)
				$st = line.st
				$last = "\""
			} else if c == '"' {
				string = Transpile.read_string(cfg, $st)?
				$out = $out.concat(string.out)
				$st = string.st
				$last = "\""
			} else if c == '\'' {
				literal = Transpile.read_char_literal(cfg, $st)?
				$out = $out.concat(literal.out)
				$st = literal.st
				$last = "'"
			} else if c == '<' and !inside_braces and Transpile.directive_here(cfg, $st, "story", $depth, $parens, $blocks) != Elsewhere {
				owner = Transpile.directive_here(cfg, $st, "story", $depth, $parens, $blocks)
				story = Transpile.read_story(cfg, $st, owner)?
				$out = $out.concat(story.out)
				$st = { ..story.st, spans: story.st.spans.append({ kind: "story", from: pos, to: story.st.pos }) }
				$last = ")"
			} else if c == '<' and !inside_braces and Transpile.directive_here(cfg, $st, "style", $depth, $parens, $blocks) != Elsewhere {
				owner = Transpile.directive_here(cfg, $st, "style", $depth, $parens, $blocks)
				sheet = Transpile.read_stylesheet(cfg, $st, owner)?
				$out = Transpile.trim_spaces_end($out).concat(sheet.out)
				$st = { ..sheet.st, spans: sheet.st.spans.append({ kind: "style", from: pos, to: sheet.st.pos }) }
			} else if c == '<' and Transpile.markup_starts(src, pos, $last) {
				markup = Transpile.read_markup(cfg, $st)?
				$out = $out.concat(markup.out)
				$st = { ..markup.st, spans: markup.st.spans.append({ kind: "markup", from: pos, to: markup.st.pos }) }
				$last = ")"
			} else if Transpile.is_ident_start(c) or Text.is_digit(c) {
				end = Text.run_end(src, pos, Transpile.is_ident_part)
				word = Text.cut(src, pos, end)
				if word == "create_context" and Text.at(src, end) == '(' {
					made = Transpile.read_context(cfg, { ..$st, pos: end }, $out, pos)?
					$out = $out.concat(made.out)
					$st = made.st
					if made.open {
						$parens = $parens.append(Bool.False)
						$open = $open.append({ c: '(', bang: Bool.False })
					}
					$last = if (made.open) "(" else ")"
				} else {
					if word == "server!" and Text.at(src, end) == '(' {
						return Err(Transpile.fail(cfg, "server!(…) is gone (D-023): define a GET endpoint (get! in a route's +server.roc) and read it with Api.get_…(params).read!()", pos))
					}
					in_view = Transpile.view_at(cfg, pos)
					read =
						match in_view {
							Ok(view) => Transpile.prop_at(cfg, view, pos, end, word, $last, $open)?
							Err(_) => NotRead
						}
					# In a dev build, a read in a component's body (no closure around it) says where it is,
					# for the browser's warning of a read made once (D-052).
					in_body = cfg.dev and in_view.is_ok() and $st.frames.is_empty()
					match read {
						Read(prop) => {
							# A prop, read through its getter (D-039).
							given = Transpile.read_prop($st, prop.key)
							text = if (in_body) Transpile.read_at(cfg, pos, Transpile.getter_of(prop.key)) else given.text
							$out = $out.concat(if (prop.punned) "${word}: ${text}" else text)
							$st = { ..Transpile.read_once(cfg, given.st, in_view, prop.key, pos, $st.frames.is_empty()), pos: prop.end }
							$last = ")"
						}
						NotRead => {
							if Text.is_upper(c) and Transpile.declares_type(src, end) {
								$declared = Some(word)
							}
							if word.ends_with("!") {
								$st = { ..$st, effects: $st.effects + 1 }
							}
							called = word.ends_with("!") and Text.at(src, end) == '(' and Text.at(src, end + 1) == ')' and (pos == 0 or Text.at(src, pos - 1) != '.')
							if called {
								# An accessor (an accessor prop: `found!`) called in the body: read once.
								$st = Transpile.read_once(cfg, $st, in_view, word, pos, $st.frames.is_empty())
							}
							if in_body and called {
								# An accessor called (`count!()`), the body's.
								$out = $out.concat(Transpile.read_at(cfg, pos, word))
								$st = { ..$st, pos: end + 2 }
								$last = ")"
							} else {
								$out = $out.concat(word)
								$st = { ..$st, pos: end }
								$last = word
							}
						}
					}
				}
			} else {
				spaced = Text.space_at(src, pos)
				if spaced > 0 {
					$out = $out.concat(Text.cut(src, pos, pos + spaced))
					$st = { ..$st, pos: pos + spaced }
				} else if c == '?' and Text.at(src, pos + 1) == '?' {
					# `??` is one token: what follows it is a value, not a comparison after `x?`.
					$out = $out.concat("??")
					$st = { ..$st, pos: pos + 2 }
					$last = "??"
				} else {
					character = Transpile.char_at(src, pos)
					$out = $out.concat(character)
					$st = { ..$st, pos: pos + Transpile.char_len(c) }
					$last = character
				}
			}
			if $last != last_before {
				$prev = last_before
			}
		}
		if inside_braces {
			return Err(Transpile.fail(cfg, "this { is never closed", start - 1))
		}
		done = Transpile.close_all(cfg, $st, $out, $lambdas)
		Ok({ st: done.st, out: done.out })
	}

	## Whether a type is declared after a capitalised word ending at `end` (`/^[ \t]*(\([^)\n]*\))?[ \t]*:=/`).
	declares_type : List(U8), U64 -> Bool
	declares_type = |src, end| {
		p = Text.run_end(src, end, Transpile.is_space_or_tab)
		after_params =
			if Text.at(src, p) == '(' {
				close = Text.run_end(src, p + 1, |b| b != ')' and b != '\n')
				if (Text.at(src, close) == ')' and close < src.len()) close + 1 else p
			} else {
				p
			}
		Text.starts_with_at(src, ":=".to_utf8(), Text.run_end(src, after_params, Transpile.is_space_or_tab))
	}

	## `name = create_context(default)`, or `create_context()` with none: Solid's context, named after
	## its module and definition (`Picks.picks_context`): `Context.define("Picks.picks_context", default)`,
	## or `Context.required(…)`. `st.pos` is at the `(`.
	read_context : Cfg, St, Str, U64 -> Try({ st : St, out : Str, open : Bool }, [Rocx(RocxError), Crash(Str)])
	read_context = |cfg, st0, so_far, begin| {
		src = cfg.src
		said = so_far.to_utf8()
		line = Text.slice(said, Text.line_start(said, said.len()), said.len())
		i = Text.skip_space(line, 0)
		first = Text.at(line, i)
		defined =
			if (Text.is_lower(first) or first == '_') and i < line.len() {
				e = Text.run_end(line, i + 1, Transpile.is_alnum_under)
				j = Text.skip_space(line, e)
				if (Text.at(line, j) == '=' and j < line.len() and Text.skip_space(line, j + 1) >= line.len()) Some(Text.cut(line, i, e)) else None
			} else {
				None
			}
		name =
			match defined {
				Some(n) => n
				None => return Err(Transpile.fail(cfg, "create_context(…) defines a context: write it as a definition, `name = create_context(…)`", begin))
			}
		if !Transpile.has_context_import(src) {
			return Err(Transpile.fail(cfg, "create_context(…) needs `import pf.Context` in this file", begin))
		}
		named = Text.roc_string("${cfg.module_path}.${name}")
		pos = st0.pos + 1
		after = Text.run_end(src, pos, |b| b == ' ')
		if Text.at(src, after) == ')' {
			Ok({ st: { ..st0, pos: after + 1 }, out: "Context.required(${named})", open: Bool.False })
		} else {
			Ok({ st: { ..st0, pos }, out: "Context.define(${named}, ", open: Bool.True })
		}
	}

	## `<PicksContext value={…}>…</PicksContext>`: Solid 2.0's provider, the context's own tag. What is
	## inside gets `value` for the context: `Context.provide!(picks_context, value, [what is inside])`.
	read_provider : Cfg, St, Str, List(Part), U64 -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_provider = |cfg, st0, tag, attrs, start| {
		inside = Transpile.read_children(cfg, st0, tag, start)?
		if inside.parts.any(Transpile.is_fn) {
			return Err(Transpile.fail(cfg, "a function child is a component's: <${tag}> can't take one", start))
		}
		fields = attrs.drop_if(Transpile.is_line)
		value_ok =
			match fields {
				[Item(field)] => field.starts_with("value: ")
				_ => Bool.False
			}
		if !value_ok {
			return Err(Transpile.fail(cfg, "<${tag}> gives its context a value: write <${tag} value={…}>, and nothing else", start))
		}
		if !Transpile.has_context_import(cfg.src) {
			return Err(Transpile.fail(cfg, "<${tag}> needs `import pf.Context` in this file", start))
		}
		value = attrs.fold(
			"",
			|acc, field|
				match field {
					Line(indent) => acc.concat("\n").concat(indent)
					Item(text) => acc.concat(Text.cut(text.to_utf8(), 7, text.to_utf8().len()))
					Fn(_) => acc
				},
		)
		defined =
			match Transpile.lookup(cfg.contexts, tag) {
				Some(d) => d
				None => "undefined"
			}
		Ok({ st: inside.st, out: "Context.provide!(${defined}, ${value}, [${Transpile.render_items(inside.parts)}])" })
	}

	## The indentation of the first line with something on it after `pos`: a block's items'
	## (`/\n([ \t]*)(?=\S)/`).
	item_indent : List(U8), U64 -> Str
	item_indent = |src, pos| {
		var $i = pos
		while $i < src.len() {
			match Text.index_of_byte(src, '\n', $i) {
				Ok(nl) => {
					indent_end = Text.run_end(src, nl + 1, Transpile.is_space_or_tab)
					if indent_end < src.len() and !Text.is_space_at(src, indent_end) {
						return Text.cut(src, nl + 1, indent_end)
					}
					$i = nl + 1
				}
				Err(_) => return ""
			}
		}
		""
	}

	## Whether the `<tag` here is that directive (`<style>`, `<story>`), and whose: first on its line,
	## either in a type's block where its definitions go (that component's), or at the file's top level,
	## at the start of the line (the file's). Elsewhere (a definition's body, deeper in), it is markup.
	directive_here : Cfg, St, Str, I64, List(Bool), List([Opened(Open), NotABlock]) -> [Elsewhere, TopLevel, Owner(Open)]
	directive_here = |cfg, st, tag, depth, parens, blocks| {
		src = cfg.src
		pos = st.pos
		tag_bytes = tag.to_utf8()
		next = pos + 1 + tag_bytes.len()
		if !parens.is_empty() or !Text.starts_with_at(src, "<".to_utf8().concat(tag_bytes), pos) or (next < src.len() and Text.is_word(Text.at(src, next))) {
			return Elsewhere
		}
		indent = Text.slice(src, Text.line_start(src, pos), pos)
		if Text.skip_space(indent, 0) < indent.len() {
			return Elsewhere
		}
		if depth == 0 {
			return if (indent.is_empty()) TopLevel else Elsewhere
		}
		match blocks.last() {
			Ok(Opened(b)) =>
				if blocks.len().to_i64_wrap() == depth and Text.utf16_units(indent) <= b.items_indent.to_utf8().len() {
					Owner(b)
				} else {
					Elsewhere
				}
			_ => Elsewhere
		}
	}

	## The byte `units` UTF-16 units after `from`.
	after_units : List(U8), U64, U64 -> U64
	after_units = |src, from, units| {
		var $i = from
		var $count = 0
		while $count < units and $i < src.len() {
			b = Text.at(src, $i)
			$count = $count + (if (b >= 0xF0) 2 else 1)
			$i = $i + Transpile.char_len(b)
		}
		$i
	}

	## A <style> that is a stylesheet: its component's, or the file's. Its CSS is scoped to the markup
	## it styles and kept for the stylesheet rocx build writes (Generated/Styles.roc); here, the lines
	## it took, blank. (A <style> in markup is an element, its text as written.)
	read_stylesheet : Cfg, St, [Elsewhere, TopLevel, Owner(Open)] -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_stylesheet = |cfg, st0, owner| {
		src = cfg.src
		start = st0.pos
		owner_name =
			match owner {
				Owner(b) => Some(b.name)
				_ => None
			}
		if st0.styles.any(|s| s.component == owner_name) {
			reason =
				match owner_name {
					Some(n) => "${n} has a <style> already: put all its CSS in the first"
					None => "a file has one <style> at its top level: put all its CSS in the first"
				}
			return Err(Transpile.fail(cfg, reason, start))
		}
		tag_end = Text.skip_space(src, start + 6)
		if Text.at(src, tag_end) != '>' or tag_end >= src.len() {
			whose =
				match owner_name {
					Some(n) => "${n}'s"
					None => "a file's"
				}
			return Err(Transpile.fail(cfg, "${whose} <style> takes no attributes: write <style>", start))
		}
		from = tag_end + 1
		closing =
			match Transpile.closing_tag(src, from, "style") {
				Ok(found) => found
				Err(_) => return Err(Transpile.fail(cfg, "<style> is never closed", start))
			}
		css = Text.cut(src, from, closing.at)
		scope = Styles.scope_class(
			match owner_name {
				Some(n) => "${cfg.module_path}.${n}"
				None => cfg.module_path
			},
		)
		scoped =
			match Styles.scope_css(css, scope) {
				Ok(done) => done
				Err(Css(problem)) => return Err(Transpile.fail(cfg, "in <style>: ${problem.reason}", Transpile.after_units(src, from, problem.offset)))
			}
		style = {
			css: scoped,
			line: Text.line_of(src, start),
			component: owner_name,
			scope,
			from: match owner {
				Owner(b) => b.from
				_ => 0
			},
			owner: match owner {
				Owner(b) => Block(b.id)
				_ => File
			},
		}
		Ok({ st: { ..st0, pos: closing.end, styles: st0.styles.append(style) }, out: "\n".repeat(Text.newlines(src, start, closing.end)) })
	}

	## `text` as JavaScript's `toLowerCase()` makes it, as far as a story's name needs it: ASCII, and the
	## two characters whose lower case is ASCII (K, the Kelvin sign; İ).
	story_lower : Str -> Str
	story_lower = |text| text.with_ascii_lowercased().replace_each("\u(212a)", "k").replace_each("\u(130)", "i\u(307)")

	## `<story name="Tip">…</story>`, beside a component's definitions: a way it looks, for the dev
	## build's catalog (`/__rocx/stories`), as a definition in its place (`story_tip!`) that renders what
	## is inside, so every build checks it and only a dev build calls it.
	read_story : Cfg, St, [Elsewhere, TopLevel, Owner(Open)] -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_story = |cfg, st0, owner| {
		src = cfg.src
		start = st0.pos
		b =
			match owner {
				Owner(open) => open
				_ => return Err(Transpile.fail(cfg, "a <story> goes in a component's block, beside its definitions: `Card := [].{ … <story name=\"Tip\">…</story> }`", start))
			}
		# `/^<story[ \t]+name="([^"\n]*)"[ \t]*>/`
		spaced = Text.run_end(src, start + 6, Transpile.is_space_or_tab)
		value_start = spaced + 6
		value_end = Text.run_end(src, value_start, |c| c != '"' and c != '\n')
		tag_end = Text.run_end(src, value_end + 1, Transpile.is_space_or_tab)
		tagged = spaced > start + 6 and Text.starts_with_at(src, "name=\"".to_utf8(), spaced) and Text.at(src, value_end) == '"' and value_end < src.len() and Text.at(src, tag_end) == '>' and tag_end < src.len()
		if !tagged {
			return Err(Transpile.fail(cfg, "a <story> is named, and takes nothing else: <story name=\"Tip\">", start))
		}
		name = Text.trim(Text.cut(src, value_start, value_end))
		lowered = Transpile.story_lower(name).to_utf8()
		var $words = []
		var $in_gap = Bool.False
		for c in lowered {
			if Text.is_lower(c) or Text.is_digit(c) {
				$words = $words.append(c)
				$in_gap = Bool.False
			} else {
				if !$in_gap {
					$words = $words.append('_')
				}
				$in_gap = Bool.True
			}
		}
		words_start = Text.run_end($words, 0, |c| c == '_')
		var $words_end = $words.len()
		while $words_end > words_start and Text.at($words, $words_end - 1) == '_' {
			$words_end = $words_end - 1
		}
		words = Text.cut($words, words_start, $words_end)
		if !Text.is_lower(Text.at(words.to_utf8(), 0)) {
			return Err(Transpile.fail(cfg, "a story's name starts with a letter: \"${name}\"", start))
		}
		# A component's story is an effect's name, as its view is, and run where it is rendered (`Root`).
		def = "story_${words}!"
		match st0.stories.find_first(|s| s.component == b.name and s.def == def) {
			Ok(twin) => return Err(Transpile.fail(cfg, "${b.name} has a story \"${twin.name}\" already, which \"${name}\" would be named like (${def})", start))
			Err(_) => {}
		}
		inside = Transpile.read_children(cfg, { ..st0, pos: tag_end + 1 }, "story", start)?
		told = { component: b.name, name, def, line: Text.line_of(src, start) }
		# It is given nothing: what it needs, it asks for, as a component does (`Router.location!`).
		Ok({ st: { ..inside.st, stories: inside.st.stories.append(told) }, out: "${def} = |{}| Html.join([${Transpile.render_items(inside.parts)}])" })
	}

	## The classes of the <style>s whose markup the element at `pos` is in.
	scopes_at : Cfg, U64 -> List(Str)
	scopes_at = |cfg, pos| cfg.scopes.keep_if(|s| s.from <= pos and pos <= s.to).map(|s| s.scope)

	## Whether the `<` at `pos` starts markup: an expression may begin here, and a tag follows.
	markup_starts : List(U8), U64, Str -> Bool
	markup_starts = |src, pos, last| {
		next = Text.at(src, pos + 1)
		window_end = if (pos + 10 < src.len()) pos + 10 else src.len()
		doctype = Text.starts_with_at(src, "<!".to_utf8(), pos) and Transpile.caseless_at(src, "doctype", pos + 2) and (pos + 9 >= window_end or !Text.is_word(Text.at(src, pos + 9)))
		tag_follows = (pos + 1 < src.len() and (Text.is_letter(next) or next == '>')) or doctype
		if !tag_follows {
			Bool.False
		} else if last == "" or Transpile.keywords_before_expression.contains(last) {
			Bool.True
		} else {
			# First on its line: a block's last expression after a statement that ended in `}` or `)`.
			var $back = pos
			while $back > 0 and Transpile.is_space_or_tab(Text.at(src, $back - 1)) {
				$back = $back - 1
			}
			if $back == 0 or Text.at(src, $back - 1) == '\n' {
				Bool.True
			} else {
				end = Text.at(last.to_utf8(), last.to_utf8().len() - 1)
				!(Transpile.is_ident_part(end) or end == ')' or end == ']' or end == '}' or end == '"' or end == '\'' or end == '?')
			}
		}
	}

	read_string : Cfg, St -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_string = |cfg, st0| {
		src = cfg.src
		start = st0.pos
		var $st = { ..st0, pos: start + 1 }
		var $out = "\""
		var $going = Bool.True
		while $going {
			pos = $st.pos
			c = Text.at(src, pos)
			if pos >= src.len() or c == '\n' {
				return Err(Transpile.fail(cfg, "this string is never closed", start))
			}
			if c == '\\' {
				# The backslash and the character after it (JavaScript's next unit: a whole character, or half
				# of one whose other half is copied next, which comes to the same).
				size = if (pos + 1 < src.len()) Transpile.char_len(Text.at(src, pos + 1)) else 1
				$out = $out.concat(Text.cut(src, pos, pos + 1 + size))
				$st = { ..$st, pos: pos + 1 + size }
			} else if c == '$' and Text.at(src, pos + 1) == '{' {
				inner = Transpile.read_code(cfg, { ..$st, pos: pos + 2 }, Bool.True)?
				$out = $out.concat("\${").concat(inner.out).concat("}")
				$st = { ..inner.st, pos: inner.st.pos + 1 }
			} else if c == '"' {
				return Ok({ st: { ..$st, pos: pos + 1 }, out: $out.concat("\"") })
			} else {
				run = Text.run_end(src, pos, |b| b != '\\' and b != '$' and b != '"' and b != '\n')
				stop = if (run == pos) pos + 1 else run
				$out = $out.concat(Text.cut(src, pos, stop))
				$st = { ..$st, pos: stop }
			}
		}
		Ok({ st: $st, out: $out })
	}

	read_multiline_line : Cfg, St -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_multiline_line = |cfg, st0| {
		src = cfg.src
		var $st = st0
		var $out = ""
		while $st.pos < src.len() and Text.at(src, $st.pos) != '\n' {
			pos = $st.pos
			if Text.at(src, pos) == '$' and Text.at(src, pos + 1) == '{' {
				inner = Transpile.read_code(cfg, { ..$st, pos: pos + 2 }, Bool.True)?
				$out = $out.concat("\${").concat(inner.out).concat("}")
				$st = { ..inner.st, pos: inner.st.pos + 1 }
			} else {
				run = Text.run_end(src, pos, |b| b != '$' and b != '\n')
				stop = if (run == pos) pos + 1 else run
				$out = $out.concat(Text.cut(src, pos, stop))
				$st = { ..$st, pos: stop }
			}
		}
		Ok({ st: $st, out: $out })
	}

	read_char_literal : Cfg, St -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_char_literal = |cfg, st0| {
		src = cfg.src
		start = st0.pos
		var $pos = start + 1
		while Text.at(src, $pos) != '\'' or $pos >= src.len() {
			if $pos >= src.len() or Text.at(src, $pos) == '\n' {
				return Err(Transpile.fail(cfg, "this character literal is never closed", start))
			}
			if Text.at(src, $pos) == '\\' {
				$pos = $pos + 1
			}
			$pos = $pos + 1
		}
		Ok({ st: { ..st0, pos: $pos + 1 }, out: Text.cut(src, start, $pos + 1) })
	}

	## `/^<!doctype\s+html\s*>/i` in the 40 characters at `pos`: where it ends.
	doctype_end : List(U8), U64 -> Try(U64, [NoMatch])
	doctype_end = |src, pos| {
		window = Text.slice(src, pos, pos + 40)
		if !(Text.starts_with_at(window, "<!".to_utf8(), 0) and Transpile.caseless_at(window, "doctype", 2)) {
			return Err(NoMatch)
		}
		spaced = Text.skip_space(window, 9)
		if spaced == 9 or !Transpile.caseless_at(window, "html", spaced) {
			return Err(NoMatch)
		}
		closing = Text.skip_space(window, spaced + 4)
		if (Text.at(window, closing) == '>' and closing < window.len()) Ok(pos + closing + 1) else Err(NoMatch)
	}

	## One element, component, fragment or doctype, as a Roc expression.
	read_markup : Cfg, St -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_markup = |cfg, st0| {
		src = cfg.src
		start = st0.pos
		match Transpile.doctype_end(src, start) {
			Ok(end) => return Ok({ st: { ..st0, pos: end }, out: "Html.doctype({})" })
			Err(_) => {}
		}
		pos = start + 1
		if Text.at(src, pos) == '>' and pos < src.len() {
			parts = Transpile.read_children(cfg, { ..st0, pos: pos + 1 }, "", start)?
			if parts.parts.any(Transpile.is_fn) {
				return Err(Transpile.fail(cfg, "a function child is a component's: <> can't take one", start))
			}
			return Ok({ st: parts.st, out: "Html.join([${Transpile.render_items(parts.parts)}])" })
		}
		if !Text.is_letter(Text.at(src, pos)) or pos >= src.len() {
			return Err(Transpile.fail(cfg, "expected a tag name after <", pos))
		}
		name_end = Text.run_end(src, pos + 1, |b| Text.is_alnum(b) or b == '-')
		name = Text.cut(src, pos, name_end)
		name_bytes = name.to_utf8()
		lowered = Text.lower(name)
		# `<DIV>` is an HTML tag in capitals, not a component: a component's name has lower case in it.
		if name_bytes.len() > 1 and name == Text.upper(name) and name_bytes.any(Text.is_upper) {
			return Err(Transpile.fail(cfg, "write HTML tags in lower case: <${lowered}>", start))
		}
		component = Text.is_upper(Text.at(name_bytes, 0))
		if component and name_bytes.contains('-') {
			return Err(Transpile.fail(cfg, "a component's name is a Roc name: <${name}> has a -", start))
		}
		if !component and name != lowered {
			return Err(Transpile.fail(cfg, "write HTML tags in lower case: <${lowered}>", start))
		}
		# `<Document on:keydown.Mod+K={…} />`, `<Window on:resize={…} />`: handlers on the whole document
		# or window, written as an element's are; unless the file has a module of that name.
		listener = Transpile.is_listener(cfg, name)
		# `<Meta name="description" content={…} />`, `<Link rel="canonical" href={…} />`,
		# `<Style>…</Style>` (@solidjs/meta's, D-054): an element in the document's <head>, written as
		# one; unless the file has a module of that name.
		head = Transpile.is_head(cfg, name)
		# How a component is given its props (D-039). The platform's (`<Show>`) and a context's provider
		# take what their types say, where they are written; a pure one (`view`), values, its call a hole
		# of its own when one is read from what changes; any other, getters, unless it is a function of
		# this file's that the file also calls (values then, and the call a hole).
		packaged = component and cfg.packaged.contains(name)
		# D-070: `<Show>`, `<Switch>` and `<Match>` are gone; a hole's `if` and `match` are what they were.
		# The platform's (an old `import pf.Show`) or none: the app's own module or function by that name
		# is the app's.
		gone = ["Show", "Switch", "Match"].contains(name) and (cfg.packaged.contains(name) or (!cfg.modules.contains(name) and !cfg.fns.contains(name) and !cfg.plain_fns.contains(name)))
		if component and gone {
			return Err(Transpile.fail(cfg, "<${name}> is gone (D-070): write a hole's if or match, which makes only the branch that holds and keeps it while it does: {if (ready!()) <p>Ready</p> else <p>Waiting</p>}, {match card!() { Ok(card) => <Card card={card} />, Err(_) => <></> }}", start))
		}
		# D-071: `<For>` is gone too; a hole's `.map` is what it was.
		if component and name == "For" and (cfg.packaged.contains(name) or (!cfg.modules.contains(name) and !cfg.fns.contains(name) and !cfg.plain_fns.contains(name))) {
			return Err(Transpile.fail(cfg, "<For> is gone (D-071): write a hole's .map, a row per key, kept as the list changes: {...todos!().map(|todo| <li key={todo.id}>{todo.title}</li>)}; for a row per position, .map_with_index(|name, i| <li key={i}>{name}</li>)", start))
		}
		provider = component and Transpile.lookup(cfg.contexts, name) != None
		pure = component and cfg.pure.contains(name)
		own_fn = component and !cfg.modules.contains(name)
		getters = component and !listener and !head and !packaged and !provider and !pure and (!own_fn or cfg.fns.contains(name))
		read = Transpile.read_attributes(cfg, { ..st0, pos: name_end }, if (head) lowered else name, component and !listener and !head, getters, component and !listener and !head and !packaged and !provider, start)?
		attrs = read.attrs
		self_closing = read.self_closing
		if name == "NoHydration" {
			return Transpile.read_no_hydration(cfg, read.st, attrs, self_closing, start)
		}
		if listener {
			return Transpile.read_listener(cfg, read.st, name, attrs, self_closing, start)
		}
		if head {
			return Transpile.read_head(cfg, read.st, name, attrs, self_closing, start)
		}
		# A component is an effect (`Picks.view!`), and so is a provider (`Context.provide!`); a pure one
		# (`Heading.view`) isn't.
		st1 = if (component and !pure) { ..read.st, effects: read.st.effects + 1 } else read.st
		if component and Transpile.lookup(cfg.contexts, name) != None {
			if self_closing {
				return Err(Transpile.fail(cfg, "<${name}> gives its context to what is inside: it needs children", start))
			}
			return Transpile.read_provider(cfg, st1, name, attrs, start)
		}
		if component {
			# A function child (`<Errored fallback>`'s, a component's own): `view_with`, given the function as `children`.
			var $fields = attrs
			var $suffix = ""
			var $st = st1
			if !self_closing {
				inside = Transpile.read_children(cfg, $st, name, start)?
				$st = inside.st
				if inside.parts.any(Transpile.is_fn) {
					if inside.parts.drop_if(Transpile.is_line).len() > 1 {
						return Err(Transpile.fail(cfg, "<${name}>'s function child must be its only child", start))
					}
					$suffix = "_with"
					$fields = $fields.concat(
						inside.parts.map(
							|part|
								match part {
									Fn(code) => Item("children: ${code}")
									other => other
								},
						),
					)
				} else if inside.parts.any(|part| !Transpile.is_line(part)) {
					$fields = $fields.append(Item("children: [${Transpile.render_items(inside.parts)}]"))
				} else {
					$fields = $fields.concat(inside.parts)
				}
			}
			# A component may make signals, as in Solid: it is an effect. A pure one (`view`, no `!`) can't.
			effect = if (pure) "" else "!"
			callee = if (cfg.modules.contains(name)) "${name}.view${$suffix}${effect}" else "${Transpile.snake_case(name)}${$suffix}${effect}"
			fields = Transpile.merged(cfg, $fields, name, start)?
			rendered = Transpile.render_items(fields)
			# A record rocx doesn't know the fields of, alone, is passed as it is.
			items = fields.keep_if(|part| !Transpile.is_line(part))
			alone =
				match items.first() {
					Ok(Item(text)) if items.len() == 1 and text.starts_with("..") => Some(text.drop_prefix(".."))
					_ => None
				}
			call =
				match alone {
					Some(record) => "${callee}(${record})"
					None => "${callee}({ ${rendered} })".replace_first("({  })", "({})")
				}
			# A component runs where it is rendered, and once, as in Solid, so it sees the contexts
			# provided above that place: its call is put off (`Html.component`), and its value props are
			# getters, read where it reads them (D-039). A platform's (`<Loading>`, `<Errored>`…) is markup, made
			# now, and so is a pure one's: given a value read from what changes, that call is a hole of
			# its own, made anew when the value changes. So is a function of this file's that the file
			# also calls, which keeps values.
			out =
				if packaged {
					call
				} else if pure {
					if (read.reads_props) "Html.html_of(|| ${call})" else call
				} else if getters or !read.reads_props {
					"Html.component(|| ${call})"
				} else {
					"Html.html_of(|| (|props| Html.component(|| ${callee}(props)))({ ${rendered} }))"
				}
			kept =
				if !getters and !pure and !packaged and read.reads_props and cfg.plain_fns.contains(name) {
					fn_name = Transpile.snake_case(name)
					reason = "<${name}> keeps values for props (D-039), since this file also calls ${fn_name}${effect} directly: a value read from what changes is read here, and <${name}> made anew when it changes, its signals with it; render it only as a tag (then its props are getters), or pass an accessor (name!={…})"
					{ ..$st, warnings: $st.warnings.append({ reason, at: start }) }
				} else {
					$st
				}
			return Ok({ st: kept, out })
		}
		function_child = |list|
			if list.any(Transpile.is_fn) {
				Err(Transpile.fail(cfg, "a function child is a component's: <${name}> can't take one", start))
			} else {
				Ok(list)
			}
		quoted = Text.roc_string(name)
		if Transpile.void_elements.contains(name) {
			if !self_closing {
				return Err(Transpile.fail(cfg, "<${name}> has no children or closing tag: write <${name} />", start))
			}
			return Ok({ st: st1, out: "Html.void(${quoted}, [${Transpile.render_items(attrs)}])" })
		}
		if self_closing {
			# A `<script … />` is the file's too, its text none (D-079: a script is written only with
			# its text as the file has it).
			empty_text = if (name == "script") "Html.source_text(\"\")" else ""
			return Ok({ st: st1, out: "Html.element(${quoted}, [${Transpile.render_items(attrs)}], [${empty_text}])" })
		}
		if name == "script" or name == "style" {
			raw = Transpile.read_raw_text(cfg, st1, name, start)?
			return Ok({ st: raw.st, out: "Html.element(${quoted}, [${Transpile.render_items(attrs)}], [${Transpile.render_items([Item(raw.out)])}])" })
		}
		keeps = Transpile.preformatted_elements.contains(name)
		inside = Transpile.read_children(cfg, if (keeps) { ..st1, preformatted: st1.preformatted + 1 } else st1, name, start)?
		children = function_child(inside.parts)?
		after = if (keeps) { ..inside.st, preformatted: inside.st.preformatted - 1 } else inside.st
		Ok({ st: after, out: "Html.element(${quoted}, [${Transpile.render_items(attrs)}], [${Transpile.render_items(children)}])" })
	}

	## Whether `<name>` is the platform's `<Document>` or `<Window>`: handlers on the whole document or
	## window. A module of the file's own by that name (`import Document`) is a component instead.
	is_listener : Cfg, Str -> Bool
	is_listener = |cfg, name| (name == "Document" or name == "Window") and !cfg.modules.contains(name)

	## `<Document on:keydown.Escape={close!} />` (or `<Window …>`): handlers on the whole document (or
	## window) while what renders it is there (`Html.on_document`, `Html.on_window`), written as an
	## element's are, and nothing else: it renders nothing.
	read_listener : Cfg, St, Str, List(Part), Bool, U64 -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_listener = |cfg, st, name, attrs, self_closing, start| {
		if !self_closing {
			return Err(Transpile.fail(cfg, "<${name}> renders nothing, so it has no children: write <${name} on:keydown.Escape={…} />", start))
		}
		if attrs.any(|part| !Transpile.is_handler_part(part)) {
			return Err(Transpile.fail(cfg, "<${name}> takes handlers only (on:keydown.Mod+K={…}, on:click={…}): it renders nothing", start))
		}
		made = if (name == "Window") "Html.on_window" else "Html.on_document"
		Ok({ st, out: "${made}([${Transpile.render_items(attrs)}])" })
	}

	## Whether `<name>` is the platform's `<Meta>`, `<Link>` or `<Style>` (@solidjs/meta's, D-054): an
	## element in the document's `<head>`. A module of the file's own by that name is a component
	## instead.
	is_head : Cfg, Str -> Bool
	is_head = |cfg, name| (name == "Meta" or name == "Link" or name == "Style") and !cfg.modules.contains(name)

	## `<Meta … />`, `<Link … />` (attributes as a `<meta>`'s and a `<link>`'s, holes and all) or
	## `<Style>…</Style>` (its CSS static, as a `<style>`'s): the element in the document's `<head>`
	## while what renders it is there (`Html.document_head`), rendering nothing where it is.
	read_head : Cfg, St, Str, List(Part), Bool, U64 -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_head = |cfg, st, name, attrs, self_closing, start| {
		if attrs.any(|part| Transpile.is_handler_part(part) and !Transpile.is_line(part)) {
			return Err(Transpile.fail(cfg, "<${name}> is an element in the document's <head>: it takes no handlers", start))
		}
		if name == "Style" {
			if self_closing {
				return Err(Transpile.fail(cfg, "<Style> holds its CSS: write <Style>p { … }</Style>", start))
			}
			raw = Transpile.read_raw_text(cfg, st, "style", start)?
			return Ok({ st: raw.st, out: "Html.document_head(Html.element(\"style\", [${Transpile.render_items(attrs)}], [${raw.out}]))" })
		}
		if !self_closing {
			return Err(Transpile.fail(cfg, "<${name}> has no children: write <${name} … />", start))
		}
		Ok({ st, out: "Html.document_head(Html.void(\"${Text.lower(name)}\", [${Transpile.render_items(attrs)}]))" })
	}

	## Whether an attribute, as rocx writes it, is a handler `<Document>` takes (a line between them is).
	is_handler_part : Part -> Bool
	is_handler_part = |part|
		match part {
			Item(code) => ["Html.on(", "Html.on_value(", "Html.on_checked(", "Html.on_key(", "Html.on_keys(", "Html.on_named_key(", "Html.on_prevent(", "Html.on_point(", "Html.on_visible(", "Html.on_data(", "Html.on_files("].any(|prefix| code.starts_with(prefix))
			Line(_) => Bool.True
			Fn(_) => Bool.False
		}

	## `<NoHydration>…</NoHydration>` (Solid's): what is inside is rendered on the server only, as static
	## markup (`Html.no_hydration`), and the browser keeps the server's nodes there. The browser's copy
	## has no children in its place (its lines kept as lines), so none of it, nor an import only it
	## used, is in the wasm.
	read_no_hydration : Cfg, St, List(Part), Bool, U64 -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_no_hydration = |cfg, st0, attrs, self_closing, start| {
		if attrs.any(|a| !Transpile.is_line(a)) {
			return Err(Transpile.fail(cfg, "<NoHydration> takes no attributes: write <NoHydration>…</NoHydration>", start))
		}
		if self_closing {
			return Err(Transpile.fail(cfg, "<NoHydration> holds what the server alone renders: write <NoHydration>…</NoHydration>", start))
		}
		inside = Transpile.read_children(cfg, { ..st0, in_region: st0.in_region + 1 }, "NoHydration", start)?
		st1 = { ..inside.st, in_region: inside.st.in_region - 1 }
		if inside.parts.any(Transpile.is_fn) {
			return Err(Transpile.fail(cfg, "a function child is a component's: <NoHydration> can't take one", start))
		}
		st2 = { ..st1, regions: st1.regions + 1 }
		rendered = Transpile.render_items(inside.parts)
		if cfg.client {
			# The browser's copy: each line what it begins with (its indentation), none of the code.
			kept = rendered.split_on("\n").map_with_index(|line, i| if (i == 0) "" else Text.indent(line))
			Ok({ st: st2, out: "Html.no_hydration([${Str.join_with(kept, "\n")}])" })
		} else {
			Ok({ st: st2, out: "Html.no_hydration([${rendered}])" })
		}
	}

	## `JSON.stringify` of the UTF-16 unit at `pos` (for a problem's message).
	json_unit : List(U8), U64 -> Str
	json_unit = |src, pos| {
		b = Text.at(src, pos)
		if b >= 0xF0 {
			code = Text.code_points(Transpile.char_at(src, pos)).first() ?? 0
			high = 0xD800 + (code - 0x10000) // 0x400
			"\"\\u${Text.hex(high)}\""
		} else {
			Text.json_string(Transpile.char_at(src, pos))
		}
	}

	## `/^[a-z_][A-Za-z0-9_]*!?$/`: a component's prop, a Roc field name.
	is_prop_name : Str -> Bool
	is_prop_name = |prop| {
		bytes = prop.drop_suffix("!").to_utf8()
		first = Text.at(bytes, 0)
		!bytes.is_empty() and (Text.is_lower(first) or first == '_') and bytes.all(Transpile.is_alnum_under)
	}

	## `/^style:--[A-Za-z0-9_-]+$/` (a custom property) or `/^style:[A-Za-z-]+$/` (a property): one
	## property of an element's `style`, its value from data.
	is_style_property : Str -> Bool
	is_style_property = |attr| {
		custom = attr.to_utf8().drop_first(8)
		plain = attr.to_utf8().drop_first(6)
		if attr.starts_with("style:--") {
			!custom.is_empty() and custom.all(|b| Transpile.is_alnum_under(b) or b == '-')
		} else {
			attr.starts_with("style:") and !plain.is_empty() and plain.all(|b| Text.is_letter(b) or b == '-')
		}
	}

	## Why a `style:` attribute's name is refused.
	style_name_refused : Str -> Str
	style_name_refused = |attr| "${attr}: a style property's name is letters and dashes (style:color={…}), or a custom property's (style:--size={…})"

	## Attributes up to `>` or `/>`, as Html.attr calls (elements) or record fields (components). A
	## component that takes getters (D-039) is given each value prop as one (`label: || word!()`); with
	## `framed`, a component's value props are read as a computation's code is (a getter's, or a pure
	## component's call in a hole of its own).
	## An `<img enhanced:src>`'s attributes besides what is written (D-125): `loading="lazy"` unless
	## it says how it loads (`loading`, or `fetchpriority`), and `decoding="async"` unless it says how
	## it decodes. Its `src` and `srcset` are the server's to write: writing them too is refused.
	enhanced_defaults : Cfg, List(Str), U64 -> Try(List(Part), [Rocx(RocxError), Crash(Str)])
	enhanced_defaults = |cfg, names, at_pos| {
		for refused in ["src", "srcset"] {
			if names.contains(refused) {
				return Err(Transpile.fail(cfg, "<img> has enhanced:src and ${refused}: enhanced:src is its src, and the server writes its srcset", at_pos))
			}
		}
		loading = if (names.contains("loading") or names.contains("fetchpriority")) [] else [Item("Html.attr_literal(\"loading\", \"lazy\")")]
		decoding = if (names.contains("decoding")) [] else [Item("Html.attr_literal(\"decoding\", \"async\")")]
		Ok(loading.concat(decoding))
	}

	read_attributes : Cfg, St, Str, Bool, Bool, Bool, U64 -> Try({ st : St, attrs : List(Part), self_closing : Bool, reads_props : Bool }, [Rocx(RocxError), Crash(Str)])
	read_attributes = |cfg, st0, tag, component, getters, framed, at_pos| {
		src = cfg.src
		# Inside a component with a <style> (or a file with one), the element's classes end with its
		# (`rx-k3j9qa`): joined to its `class`, or a `class` of its own.
		scopes = if (component or Styles.unscoped_elements.contains(tag) or Transpile.is_listener(cfg, tag)) "" else Str.join_with(Transpile.scopes_at(cfg, at_pos), " ")
		scoped = scopes != ""
		var $classed = Bool.False
		var $reads_props = Bool.False
		var $attrs = []
		# The names written on an element, and whether one is `enhanced:src` (D-125).
		var $names = []
		var $enhanced = Bool.False
		var $st = st0
		var $going = Bool.True
		while $going {
			spaced = Transpile.read_whitespace(src, $st.pos)
			$attrs = $attrs.concat(spaced.lines)
			$st = { ..$st, pos: spaced.pos }
			pos = $st.pos
			if pos >= src.len() {
				return Err(Transpile.fail(cfg, "<${tag}> is never closed", pos))
			}
			closing =
				if Text.starts_with_at(src, "/>".to_utf8(), pos) {
					Some({ end: pos + 2, self_closing: Bool.True })
				} else if Text.at(src, pos) == '>' {
					Some({ end: pos + 1, self_closing: Bool.False })
				} else {
					None
				}
			match closing {
				Some(done) => {
					class_attr = if (scoped and !$classed) [Item(if (component) "class: ${Text.roc_string(scopes)}" else "Html.attr_literal(\"class\", ${Text.roc_string(scopes)})")] else []
					enhanced_attrs = if ($enhanced) Transpile.enhanced_defaults(cfg, $names, at_pos)? else []
					return Ok({ st: { ..$st, pos: done.end }, attrs: $attrs.concat(class_attr).concat(enhanced_attrs), self_closing: done.self_closing, reads_props: $reads_props })
				}
				None => {}
			}
			# A record spread on a component (`{...rest}`, D-052): its fields passed on as they are.
			if component and Text.at(src, pos) == '{' and Text.starts_with_at(src, "...".to_utf8(), pos + 1) {
				spread = Transpile.read_spread(cfg, $st, tag, getters, pos)?
				$attrs = $attrs.concat(spread.attrs)
				$st = spread.st
			} else {
				name_start = pos
				first = Text.at(src, pos)
				if !(Text.is_letter(first) or first == '_' or first == '@') {
					return Err(Transpile.fail(cfg, "unexpected ${Transpile.json_unit(src, pos)} in <${tag}>", pos))
				}
				name_end = Text.run_end(src, pos + 1, |b| Transpile.is_alnum_under(b) or b == ':' or b == '.' or b == '-' or b == '+')
				# A component's prop may be an effect, named as Roc names one: `title!={title!}`.
				banged = component and Text.at(src, name_end) == '!'
				name = if (banged) Text.cut(src, pos, name_end + 1) else Text.cut(src, pos, name_end)
				after_name = if (banged) name_end + 1 else name_end
				# `name?={bool}` is a boolean attribute, `name??={str}` one left out when the string is empty.
				optional = Text.starts_with_at(src, "??=".to_utf8(), after_name)
				flag = !optional and Text.starts_with_at(src, "?=".to_utf8(), after_name)
				eq = if (optional) after_name + 2 else if (flag) after_name + 1 else after_name
				oops = |reason| Transpile.fail(cfg, reason, name_start)
				# `on:click={…}` is a component's Roc handler; `onclick="…"` would be a script in an attribute.
				handler = !component and name.starts_with("on:")
				if handler {
					_ = Transpile.handler_name(cfg, name, name_start)?
				} else if name.contains("+") {
					return Err(oops("unexpected + in ${name}: a + joins the keys of a combination, as in on:keydown.Shift+Enter"))
				}
				# Inside a <NoHydration>, nothing is ever hydrated: what would only work in the browser is refused.
				if $st.in_region > 0 and !component {
					never = "<NoHydration>, which the browser never hydrates"
					if handler {
						return Err(oops("${name} is inside ${never}, so this handler would never run: put <${tag}> outside <NoHydration>"))
					}
					if name == "key" {
						return Err(oops("key is inside ${never}: nothing keeps <${tag}> by it there; drop it, or put <${tag}> outside <NoHydration>"))
					}
					if name == "transition" or name.starts_with("transition:") {
						return Err(oops("${name} is inside ${never}, so nothing there comes or goes: put <${tag}> outside <NoHydration>"))
					}
					if name.starts_with("drag:") {
						return Err(oops("${name} is inside ${never}, so no drag of it starts: put <${tag}> outside <NoHydration>"))
					}
				}
				if handler and (flag or optional) {
					return Err(oops("${name} takes {a handler}: write ${name}={…}"))
				}
				if !component and !handler and Transpile.caseless_at(name.to_utf8(), "on", 0) {
					return Err(oops("inline event handlers (${name}) aren't allowed: in a component, write on:${Text.lower(Text.cut(name.to_utf8(), 2, name.to_utf8().len()))}={…}"))
				}
				# `drag:data={…}` (what a drag carries for other pages) and `drag:image={…}` (what it shows): D-055.
				drag = !component and name.starts_with("drag:")
				if drag {
					if !(name == "drag:data" or name == "drag:image") {
						return Err(oops("${name}: write drag:data={[(type, value), …]} (what a drag of it carries) or drag:image={id} (the element it shows)"))
					}
					if flag or optional or Text.at(src, eq) != '=' or (Text.at(src, eq + 1) != '{' and !(name == "drag:image" and (Text.at(src, eq + 1) == '"' or Text.at(src, eq + 1) == '\''))) {
						return Err(oops(if (name == "drag:data") "drag:data needs {a list of (type, value)}: write drag:data={[(\"text/plain\", title)]}" else "drag:image needs an element's id: write drag:image=\"ghost\" or drag:image={id}"))
					}
				}
				# `enhanced:src={…}` (D-125): an `<img>`'s photo, which the server makes smaller copies of.
				enhanced = !component and name.starts_with("enhanced:")
				if enhanced {
					if name != "enhanced:src" {
						return Err(oops("${name}: write enhanced:src={…}, an <img>'s photo the server makes smaller copies of"))
					}
					if tag != "img" {
						return Err(oops("enhanced:src is an <img>'s: <${tag}> has no photo to make copies of"))
					}
					if flag or optional or Text.at(src, eq) != '=' or !(Text.at(src, eq + 1) == '{' or Text.at(src, eq + 1) == '"' or Text.at(src, eq + 1) == '\'') {
						return Err(oops("enhanced:src needs a path of this site: write enhanced:src=\"/images/harbour.jpg\" or enhanced:src={photo}"))
					}
					$enhanced = Bool.True
				}
				if !component {
					$names = $names.append(name)
				}
				# `transition={…}`, `transition:in={…}`, `transition:out={…}`: a Transition the element plays.
				transition = !component and (name == "transition" or name.starts_with("transition:"))
				if transition {
					if !(name == "transition" or name == "transition:in" or name == "transition:out" or name == "transition:move") {
						return Err(oops("${name}: write transition={…} (both ways), transition:in={…}, transition:out={…} or transition:move={…}"))
					}
					if flag or optional or Text.at(src, eq) != '=' or Text.at(src, eq + 1) != '{' {
						return Err(oops("${name} needs {a Transition}: write ${name}={Transition.fade}"))
					}
				}
				if component and !Transpile.is_prop_name(name) {
					return Err(oops("a component's props are Roc field names: ${name}"))
				}
				# `key` on a component is a `.map` row's key (D-071), when the component is the row's root:
				# rocx's, never a prop (elsewhere it says nothing, as on a list that doesn't change).
				row_key = component and name == "key"
				if row_key and !(Text.at(src, eq) == '=' and Text.at(src, eq + 1) == '{') {
					return Err(oops("key on a component takes {…}: the key of the .map row it is the root of (D-071)"))
				}
				if row_key {
					# Passed over: the row's key is read where its rows are (`read_rows`).
					$st = { ..$st, pos: Getters.matching(src, eq + 1) + 1 }
				} else if Text.at(src, eq) != '=' or eq >= src.len() {
					if flag {
						return Err(oops("${name}?= needs {a Bool}"))
					}
					if optional {
						return Err(oops("${name}??= needs {a Str}"))
					}
					if handler {
						return Err(oops("${name} needs {a handler}: write ${name}={…}"))
					}
					if name == "key" and !component {
						return Err(oops("key needs {a Str}: write key={…}"))
					}
					if name.starts_with("class:") {
						return Err(oops("${name} needs {a Bool}: write ${name}={…}"))
					}
					if name.starts_with("style:") {
						return Err(oops("${name} needs {a value}: write ${name}={…}"))
					}
					$attrs = $attrs.append(Item(if (component) "${name}: ${Transpile.static_prop(getters, name, "Bool.True")}" else "Html.flag(${Text.roc_string(name)}, Bool.True)"))
					$st = { ..$st, pos: eq }
				} else {
					vpos = eq + 1
					quote = Text.at(src, vpos)
					if (quote == '"' or quote == '\'') and vpos < src.len() {
						if flag {
							return Err(oops("${name}?= needs {a Bool}, not a string"))
						}
						if optional {
							return Err(oops("${name}??= needs {a Str}; a static value is always there"))
						}
						if handler {
							return Err(oops("${name} needs {a handler}, not a string: a handler is Roc, never script"))
						}
						if name.starts_with("class:") {
							return Err(oops("${name} needs {a Bool}"))
						}
						if name.starts_with("style:") {
							return Err(oops("${name} needs {a value}; a static one belongs in style=\"…\""))
						}
						end =
							match Text.index_of_byte(src, quote, vpos + 1) {
								Ok(e) => e
								Err(_) => return Err(oops("the value of ${name} is never closed"))
							}
						raw = Text.slice(src, vpos + 1, end)
						if raw.contains('\n') {
							return Err(oops("the value of ${name} can't span lines"))
						}
						decoded0 = Transpile.decode_entities(cfg, Str.from_utf8_lossy(raw), name_start)?
						decoded =
							if scoped and name == "class" {
								$classed = Bool.True
								trimmed = Text.trim(decoded0)
								if (trimmed != "") "${trimmed} ${scopes}" else scopes
							} else {
								decoded0
							}
						value = Text.roc_string(decoded)
						$attrs = $attrs.append(Item(if (component) "${name}: ${Transpile.static_prop(getters, name, value)}" else if (name == "key") "Html.key(${value})" else if (drag) "Html.drag_image(${value})" else if (enhanced) "Html.attr_literal(\"src\", ${value}), Html.enhanced" else "Html.attr_literal(${Text.roc_string(name)}, ${value})"))
						$st = { ..$st, pos: end + 1 }
					} else if quote == '{' {
						effects_before = $st.effects
						# Where a prop read in it goes (D-039): an element's attribute that computes is a computation,
						# and so is a component's getter (or a pure one's call, in a hole of its own); a handler, and
						# a platform's component's value, are what is around them. A lambda given as a handler or
						# as an effect's prop (`pick!={|id| …}`) is an effect's.
						code_at = Text.skip_space(src, vpos + 1)
						effect_value = handler or (component and name.ends_with("!"))
						framed_here = if (component) (name.ends_with("!") or framed) else !handler
						marked = if (effect_value and Text.at(src, code_at) == '|') { ..$st, effectful_at: $st.effectful_at.append(code_at) } else $st
						entered = if (framed_here) Transpile.opened(marked, Bool.False) else marked
						inner = Transpile.read_code(cfg, { ..entered, pos: vpos + 1 }, Bool.True)?
						left = if (framed_here) { ..inner.st, frames: inner.st.frames.drop_last(1) } else inner.st
						$st = { ..left, pos: inner.st.pos + 1 }
						# An expression that calls nothing named with `!` reads nothing that changes: static.
						computed = $st.effects > effects_before
						if Text.trim(inner.out) == "" {
							return Err(oops("${name}={} is empty"))
						}
						# A computed class is the whole attribute, set again when it changes: the file's class goes in it.
						expr =
							if scoped and name == "class" and !flag and !optional {
								$classed = Bool.True
								"Str.concat(${inner.out}, ${Text.roc_string(" ${scopes}")})"
							} else {
								inner.out
							}
						if component and computed and !name.ends_with("!") and !Text.trim_start(expr).starts_with("|") and !Transpile.is_accessor_name(Text.trim(expr)) {
							$reads_props = Bool.True
						}
						# A match arm's name given to a component's value prop, or as its accessor prop
						# (`found!={found}`): D-070's check across files.
						if component and !cfg.arms.is_empty() {
							code = Text.trim(Text.cut(src, vpos + 1, inner.st.pos))
							given =
								if name.ends_with("!") {
									if (cfg.arms.contains(code.drop_suffix("!"))) [code.drop_suffix("!")] else []
								} else if getters and Getters.is_value(name) {
									Flow.used_in(code, cfg.arms)
								} else {
									[]
								}
							for arm_name in given {
								$st = { ..$st, handed: $st.handed.append({ tag, prop: name, name: arm_name, at: name_start }) }
							}
						}
						attr =
							if component {
								# An accessor named through a prop (`left!={clock.left!}`, `clock` a getter now: D-039) is
								# called by an accessor of its own, so it follows the prop.
								written = Text.trim(Text.cut(src, vpos + 1, inner.st.pos))
								through_prop = name.ends_with("!") and Transpile.is_accessor_name(written) and Text.trim(expr) != written
								Ok("${name}: ${if (getters and Getters.is_value(name)) "|| ${expr}" else if (through_prop) "|| (${Text.trim(expr)})()" else Transpile.accessor_prop(name, expr)}")
							} else if transition {
								Ok(if (computed) "Html.transition_of(${Transpile.transition_way(name)}, || ${expr})" else "Html.transition(${Transpile.transition_way(name)}, ${expr})")
							} else if drag {
								fn_name = if (name == "drag:data") "drag_data" else "drag_image"
								Ok(if (computed) "Html.${fn_name}_of(|| ${expr})" else "Html.${fn_name}(${expr})")
							} else if enhanced {
								Ok(if (computed) "Html.attr_of(\"src\", || ${expr}), Html.enhanced" else "Html.attr(\"src\", ${expr}), Html.enhanced")
							} else if name == "key" and cfg.row_key == At(name_start) {
								# The row's own key, on its root: read once, as the row is made (D-071).
								Ok("Html.key(${expr})")
							} else if computed or handler or name == "key" {
								Transpile.reactive_attribute(cfg, name, expr, flag, optional, name_start, computed)
							} else if flag {
								Ok("Html.flag(${Text.roc_string(name)}, ${expr})")
							} else if optional {
								Ok("Html.optional(${Text.roc_string(name)}, ${expr})")
							} else if name.starts_with("class:") {
								Ok("Html.class_if(${Text.roc_string(name.drop_prefix("class:"))}, ${expr})")
							} else if name.starts_with("style:") {
								if (Transpile.is_style_property(name)) Ok("Html.style_var(${Text.roc_string(name.drop_prefix("style:"))}, ${expr})") else Err(oops(Transpile.style_name_refused(name)))
							} else if name == "style" {
								Err(oops("style takes a static value: change classes, not styles, with data"))
							} else {
								Ok("Html.attr(${Text.roc_string(name)}, ${expr})")
							}
						$attrs = $attrs.append(Item(attr?))
					} else {
						return Err(oops("${name}= needs \"a value\" or {an expression}: unquoted values aren't allowed"))
					}
				}
			}
		}
		Ok({ st: $st, attrs: $attrs, self_closing: Bool.False, reads_props: $reads_props })
	}

	## A record spread on a component (`<Base {...rest} size={3} />`, D-052): what JSX's spread is, and
	## Solid's `merge` is to a props object, the fields of a record passed on as they are, so a record
	## of getters (a view's `|props|`, or the `..rest` of its pattern: Solid's `omit`) stays live in the
	## component given it. Where rocx knows the record's fields (the view's props are annotated), each
	## is written out (`label: rest.label`), so attributes may add or replace some (the last of each
	## wins, as in JSX); else it is Roc's record update, `{ ..rest, size: || 3 }`, and the component's
	## props must be the record's type. `pos` is at the `{`.
	read_spread : Cfg, St, Str, Bool, U64 -> Try({ st : St, attrs : List(Part) }, [Rocx(RocxError), Crash(Str)])
	read_spread = |cfg, st, tag, getters, pos| {
		src = cfg.src
		close = Getters.matching(src, pos)
		if close >= src.len() {
			return Err(Transpile.fail(cfg, "this { is never closed", pos))
		}
		expr = Text.trim(Text.cut(src, pos + 4, close))
		if !Transpile.is_record_name(expr) {
			return Err(Transpile.fail(cfg, "spread a record by its name: {...rest} (a view's |{ kind, ..rest }|, or |props|)", pos))
		}
		if !getters {
			return Err(Transpile.fail(cfg, "<${tag}> takes its props as they are written: {...${expr}} passes a component's getters on, to a component written in rocx (view!)", pos))
		}
		fields =
			match Transpile.view_at(cfg, pos) {
				Ok(view) if view.record == Some(expr) => view.all
				_ => []
			}
		attrs = if (fields.is_empty()) [Item("..${expr}")] else fields.map(|field| Item("${field}: ${expr}.${field}"))
		Ok({ st: { ..st, pos: close + 1 }, attrs })
	}

	## `/^[a-z_][A-Za-z0-9_]*(\.[a-z_][A-Za-z0-9_]*)*$/`: a record by its name (`rest`, `card.props`).
	is_record_name : Str -> Bool
	is_record_name = |name|
		!name.is_empty() and name.split_on(".").all(
			|part| {
				bytes = part.to_utf8()
				first = Text.at(bytes, 0)
				!bytes.is_empty() and (Text.is_lower(first) or first == '_') and bytes.all(Transpile.is_alnum_under)
			},
		)

	## A component's fields, a spread's among them (D-052): of two of a name, the last, as JSX's spread
	## and Solid's `merge` have it; a spread rocx doesn't know the fields of (`..rest`) first, as Roc's
	## record update writes it. Two of those can't be merged: Roc has no record made of two.
	merged : Cfg, List(Part), Str, U64 -> Try(List(Part), [Rocx(RocxError), Crash(Str)])
	merged = |cfg, fields, tag, start| {
		name_of = |part|
			match part {
				Item(text) if !text.starts_with("..") =>
					match text.split_first(":") {
						Ok(split) => Text.trim(split.before)
						Err(_) => ""
					}
				_ => ""
			}
		updates = fields.keep_if(
			|part|
				match part {
					Item(text) => text.starts_with("..")
					_ => Bool.False
				},
		)
		if updates.len() > 1 {
			return Err(Transpile.fail(cfg, "<${tag}> is given two records whose fields rocx doesn't know, which Roc can't merge: annotate the props of the view that names them (view! : { … } => Html), so rocx writes their fields out", start))
		}
		var $kept = []
		var $i = 0
		for part in fields {
			name = name_of(part)
			later = name != "" and fields.drop_first($i + 1).any(|other| name_of(other) == name)
			if !later {
				$kept = $kept.append(part)
			}
			$i = $i + 1
		}
		Ok(updates.concat($kept.drop_if(|part| updates.contains(part))))
	}

	## `on:input.value` → the event (`input`) and what its handler is given (`value`; "" for nothing).
	## `on:frame.ms` is the runtime's own event, each animation frame, and `on:viewport` another, once
	## the element shows and each time it scrolls or changes size; `on:keydown.ArrowUp` (a key's
	## name: capitalised, or one letter or digit; `.Space` for the space bar) runs its handler for that
	## key only, with no modifier key held; `on:keydown.Shift+Enter`, with exactly those held (`Shift`,
	## `Ctrl`, `Alt`, `Meta`, and `Mod`: ⌘ on macOS, Ctrl elsewhere), each once, before the key.
	handler_name : Cfg, Str, U64 -> Try({ event : Str, takes : Str, key : [Some(Str), None] }, [Rocx(RocxError), Crash(Str)])
	handler_name = |cfg, attr, name_start| {
		bytes = attr.to_utf8()
		event_end = Text.run_end(bytes, 3, Text.is_lower)
		parsed =
			if !attr.starts_with("on:") or event_end == 3 {
				None
			} else if event_end == bytes.len() {
				Some({ event: Text.cut(bytes, 3, event_end), takes: "" })
			} else if Text.at(bytes, event_end) == '.' and event_end + 1 < bytes.len() and Text.run_end(bytes, event_end + 1, |b| Text.is_alnum(b) or b == '+') == bytes.len() {
				Some({ event: Text.cut(bytes, 3, event_end), takes: Text.cut(bytes, event_end + 1, bytes.len()) })
			} else {
				None
			}
		match parsed {
			None => Err(Transpile.fail(cfg, "${attr}: write on:event={a handler}, e.g. on:click={save!}", name_start))
			Some({ event, takes }) =>
				if event == "frame" or takes == "ms" {
					if (event != "frame" or takes != "ms") Err(Transpile.fail(cfg, "${attr}: frames are on:frame.ms={…}, which gets the milliseconds since the last one", name_start)) else Ok({ event, takes, key: None })
				} else if event == "viewport" {
					if (takes != "") Err(Transpile.fail(cfg, "${attr}: write on:viewport={|view| …}, which gets what of the element shows (an Html.Viewport)", name_start)) else Ok({ event, takes, key: None })
				} else if takes == "visible" and event != "visibilitychange" {
					Err(Transpile.fail(cfg, "${attr}: .visible goes with on:visibilitychange (on <Document>), which says whether the page shows", name_start))
				} else if (takes == "data" or takes == "files") and event != "drop" and event != "paste" and !(takes == "files" and (event == "change" or event == "input")) {
					Err(Transpile.fail(cfg, "${attr}: .${takes} goes with on:drop or on:paste${if (takes == "files") ", or a file input's on:change" else ""}, which carry it", name_start))
				} else if Transpile.handler_fn(takes) != None {
					Ok({ event, takes, key: None })
				} else {
					# A key's name, after the modifier keys held with it: `Mod+Shift+K`.
					parts = takes.split_on("+")
					held = parts.take_first(parts.len() - 1)
					key = parts.get(parts.len() - 1) ?? ""
					t = key.to_utf8()
					named_key = !t.is_empty() and ((Text.is_upper(Text.at(t, 0)) and t.all(Text.is_alnum)) or (t.len() == 1 and (Text.is_lower(Text.at(t, 0)) or Text.is_digit(Text.at(t, 0)))))
					modifiers = ["Shift", "Ctrl", "Alt", "Meta", "Mod"]
					unknown = held.keep_if(|name| !modifiers.contains(name))
					if !named_key {
						Err(Transpile.fail(cfg, "${attr}: a handler takes .value, .checked, .key, .keys, .point, .visible, .data or .files, a key's name (.Enter, .ArrowUp, .w) after any modifier keys (.Shift+Enter, .Mod+K), or .prevent, not .${takes}", name_start))
					} else if event != "keydown" and event != "keyup" {
						Err(Transpile.fail(cfg, "${attr}: a key's name goes with on:keydown or on:keyup", name_start))
					} else if !unknown.is_empty() {
						Err(Transpile.fail(cfg, "${attr}: ${Str.join_with(unknown, ", ")} isn't a modifier key: the keys held are Shift, Ctrl, Alt, Meta and Mod (⌘ on macOS, Ctrl elsewhere), before the key", name_start))
					} else if held.any(|name| held.count_if(|other| other == name) > 1) {
						Err(Transpile.fail(cfg, "${attr}: each modifier key goes in once", name_start))
					} else if held.contains("Mod") and (held.contains("Ctrl") or held.contains("Meta")) {
						Err(Transpile.fail(cfg, "${attr}: Mod is ⌘ on macOS and Ctrl elsewhere, so it goes with Shift and Alt, not Ctrl or Meta", name_start))
					} else {
						Ok({ event, takes, key: Some(Str.join_with(held.append(if (key == "Space") " " else key), "+")) })
					}
				}
		}
	}

	## Whitespace in a tag, as newlines (spaces between attributes become the comma).
	read_whitespace : List(U8), U64 -> { pos : U64, lines : List(Part) }
	read_whitespace = |src, start| {
		var $pos = start
		var $lines = []
		var $n = Text.space_at(src, $pos)
		while $n > 0 {
			if Text.at(src, $pos) == '\n' {
				$lines = $lines.append(Line(Transpile.indent_at(src, $pos + 1)))
			}
			$pos = $pos + $n
			$n = Text.space_at(src, $pos)
		}
		{ pos: $pos, lines: $lines }
	}

	## Children up to `</name>` (`</>` for a fragment): items for a Roc list.
	read_children : Cfg, St, Str, U64 -> Try({ st : St, parts : List(Part) }, [Rocx(RocxError), Crash(Str)])
	read_children = |cfg, st0, tag, opened_at| {
		src = cfg.src
		var $st = st0
		var $parts = []
		# The source of the text so far (from `text_start`), and what it says: comments in it say nothing
		# but their line breaks, so the whitespace around one is a single run.
		var $has_text = Bool.False
		var $said = []
		var $text_start = st0.pos
		var $going = Bool.True
		while $going {
			pos = $st.pos
			if pos >= src.len() {
				return Err(Transpile.fail(cfg, "<${tag}> is never closed", opened_at))
			}
			c = Text.at(src, pos)
			# The text so far, as items: on the first line that has some, so output lines stay source lines.
			# `last`: the closing tag follows, so trailing whitespace goes.
			flushed = |last| {
				if !$has_text {
					return Ok($parts)
				}
				first = $parts.all(Transpile.is_line)
				said = Str.from_utf8_lossy($said)
				kept = if ($st.preformatted > 0) said else Transpile.collapse_whitespace(said, first, last)
				content = Transpile.decode_entities(cfg, kept, $text_start)?
				text_lines = Text.cut(src, $text_start, pos).split_on("\n")
				home = text_lines.find_first_index(|line| Text.trim(line) != "") ?? 0
				var $out = $parts
				var $at = $text_start
				var $i = 0
				for line in text_lines {
					if $i > 0 {
						$out = $out.append(Line(Transpile.indent_at(src, $at)))
					}
					if $i == home and content != "" {
						$out = $out.append(Item("Html.text(${Text.roc_string(content)})"))
					}
					$at = $at + line.to_utf8().len() + 1
					$i = $i + 1
				}
				Ok($out)
			}
			if Text.starts_with_at(src, "</".to_utf8(), pos) {
				$parts = flushed(Bool.True)?
				end =
					match Text.index_of_byte(src, '>', pos) {
						Ok(e) => e
						Err(_) => return Err(Transpile.fail(cfg, "this closing tag is never closed", pos))
					}
				closing = Text.trim(Text.cut(src, pos + 2, end))
				if closing != tag {
					reason = if (tag != "") "<${tag}> is closed by </${closing}>" else "<> is closed by </${closing}>"
					return Err(Transpile.fail(cfg, reason, pos))
				}
				return Ok({ st: { ..$st, pos: end + 1 }, parts: $parts })
			}
			comment =
				if Text.starts_with_at(src, "<!--".to_utf8(), pos) {
					Some({ closer: "-->", unclosed: "this comment is never closed" })
				} else if Text.starts_with_at(src, "{#".to_utf8(), pos) {
					Some({ closer: "}", unclosed: "this {# comment} is never closed" })
				} else {
					None
				}
			match comment {
				Some(cm) => {
					closer = cm.closer.to_utf8()
					end =
						match Text.index_of(src, closer, pos) {
							Ok(e) => e + closer.len()
							Err(_) => return Err(Transpile.fail(cfg, cm.unclosed, pos))
						}
					if !$has_text {
						$text_start = pos
						$has_text = Bool.True
					}
					$said = $said.concat(List.repeat('\n', Text.newlines(src, pos, end)))
					$st = { ..$st, pos: end }
				}
				None =>
					if c == '<' {
						if !Transpile.markup_starts(src, pos, "") {
							return Err(Transpile.fail(cfg, "a < in text starts a tag: write &lt; or {\"<\"}", pos))
						}
						$parts = flushed(Bool.False)?
						$has_text = Bool.False
						$said = []
						markup = Transpile.read_markup(cfg, $st)?
						$parts = $parts.append(Item(markup.out))
						$st = markup.st
						$text_start = $st.pos
					} else if c == '{' {
						$parts = flushed(Bool.False)?
						$has_text = Bool.False
						$said = []
						hole = Transpile.read_hole(cfg, $st)?
						$parts = $parts.concat(hole.parts)
						$st = hole.st
						$text_start = $st.pos
					} else if c == '}' {
						return Err(Transpile.fail(cfg, "a } in text: write {\"}\"}", pos))
					} else if c == '>' {
						return Err(Transpile.fail(cfg, "a > in text: write &gt; or {\">\"}", pos))
					} else {
						if !$has_text {
							$text_start = pos
							$has_text = Bool.True
						}
						run = Text.run_end(src, pos, |b| b != '<' and b != '{' and b != '}' and b != '>')
						stop = if (run == pos) pos + 1 else run
						$said = $said.concat(Text.slice(src, pos, stop))
						$st = { ..$st, pos: stop }
					}
			}
		}
		Ok({ st: $st, parts: $parts })
	}

	## An attribute from an expression, reactive: a computation, or a handler that is an effect.
	reactive_attribute : Cfg, Str, Str, Bool, Bool, U64, Bool -> Try(Str, [Rocx(RocxError), Crash(Str)])
	reactive_attribute = |cfg, attr, expr, flag, optional, name_start, computed| {
		if attr == "key" {
			return Ok(if (computed) "Html.key_of(|| ${expr})" else "Html.key(${expr})")
		}
		if attr.starts_with("on:") {
			h = Transpile.handler_name(cfg, attr, name_start)?
			if h.takes == "ms" {
				return Ok("Html.on_frame(${expr})")
			}
			if h.event == "viewport" {
				return Ok("Html.on_viewport(${expr})")
			}
			return match h.key {
				Some(k) => Ok("Html.on_named_key(${Text.roc_string(h.event)}, ${Text.roc_string(k)}, ${expr})")
				None => {
					handler =
						match Transpile.handler_fn(h.takes) {
							Some(fn_name) => fn_name
							None => "on"
						}
					Ok("Html.${handler}(${Text.roc_string(h.event)}, ${expr})")
				}
			}
		}
		if flag {
			Ok("Html.flag_of(${Text.roc_string(attr)}, || ${expr})")
		} else if optional {
			Ok("Html.optional_of(${Text.roc_string(attr)}, || ${expr})")
		} else if attr.starts_with("class:") {
			Ok("Html.class_of(${Text.roc_string(attr.drop_prefix("class:"))}, || ${expr})")
		} else if attr.starts_with("style:") {
			if Transpile.is_style_property(attr) {
				Ok("Html.style_of(${Text.roc_string(attr.drop_prefix("style:"))}, || ${expr})")
			} else {
				Err(Transpile.fail(cfg, Transpile.style_name_refused(attr), name_start))
			}
		} else if attr == "style" {
			Err(Transpile.fail(cfg, "style takes a static value: change classes, not styles, with data", name_start))
		} else {
			Ok("Html.attr_of(${Text.roc_string(attr)}, || ${expr})")
		}
	}

	## `{text}`, `{=html}` or `{...list}` among children.
	read_hole : Cfg, St -> Try({ st : St, parts : List(Part) }, [Rocx(RocxError), Crash(Str)])
	read_hole = |cfg, st0| {
		src = cfg.src
		start = st0.pos
		kind =
			if Text.starts_with_at(src, "...".to_utf8(), start + 1) {
				{ name: "list", skip: 3 }
			} else if Text.at(src, start + 1) == '=' {
				{ name: "html", skip: 1 }
			} else {
				{ name: "text", skip: 0 }
			}
		# A hole is a computation of its own, or markup made where it is: either way, a prop read in it is
		# read there (D-039). A function child (`{|post!, index!| …}`) is an effect's lambda.
		code_at = Text.skip_space(src, start + 1 + kind.skip)
		marked = if (kind.name == "text" and Text.at(src, code_at) == '|') { ..st0, effectful_at: st0.effectful_at.append(code_at) } else st0
		inner = Transpile.read_code(cfg, Transpile.opened({ ..marked, pos: start + 1 + kind.skip }, Bool.False), Bool.True)?
		st1 = { ..inner.st, pos: inner.st.pos + 1, frames: inner.st.frames.drop_last(1) }
		expr = inner.out
		trimmed = Text.trim(expr)
		if trimmed == "" {
			return Err(Transpile.fail(cfg, "this {} is empty", start))
		}
		# A function where a child goes is a component's function child (`{|post, index!| …}`).
		if kind.name == "text" and trimmed.starts_with("|") {
			return Ok({ st: st1, parts: [Fn(expr)] })
		}
		# A list whose `.map` reads a list that changes: its rows, kept by key (D-071).
		if kind.name == "list" and st1.effects > st0.effects {
			listed = inner.st.spans.keep_if(|span| span.from >= code_at and span.to <= inner.st.pos).map(|span| { from: span.from, to: span.to })
			match Transpile.read_rows(cfg, Transpile.opened({ ..marked, pos: code_at }, Bool.False), code_at, inner.st.pos, listed)? {
				Rowed(done) => return Ok({ st: { ..done.st, pos: inner.st.pos + 1, frames: done.st.frames.drop_last(1) }, parts: [Item(done.out)] })
				Plain => {}
			}
		}
		# An `if` or a `match` that reads what changes: its branch's part (D-070); an `if` with no `else`,
		# its empty one.
		if kind.name != "list" and (st1.effects > st0.effects or Flow.starts_with_word(src, { from: code_at, to: inner.st.pos }, "if")) {
			spans = inner.st.spans.keep_if(|span| span.from >= code_at and span.to <= inner.st.pos).map(|span| { from: span.from, to: span.to })
			flowed = Transpile.read_flow(cfg, Transpile.opened({ ..marked, pos: code_at }, Bool.False), start + 1 + kind.skip, inner.st.pos, spans)?
			match flowed {
				Flowed(done) => return Ok({ st: { ..done.st, pos: inner.st.pos + 1, frames: done.st.frames.drop_last(1) }, parts: [Item(done.out)] })
				Plain => {}
			}
		}
		# A hole that calls something named with `!` is a computation; one that calls nothing so named
		# can't change after its component ran, as in Solid: static, written once. `{x}` and `{=x}`
		# are one hole (D-070): text, a number or markup, as the compiler finds `x`'s type
		# (`Html.hole`); `{...x}` a list of markup.
		out =
			if kind.name == "list" {
				if (st1.effects > st0.effects) "Html.list_of(|| ${expr})" else "Html.join(${expr})"
			} else if st1.effects > st0.effects {
				"Html.hole_of(|| Html.hole(${expr}))"
			} else {
				"Html.shown(${expr})"
			}
		Ok({ st: st1, parts: [Item(out)] })
	}

	## D-070: a hole whose code is an `if` (its `else if`s too) or a `match`, whose conditions or
	## value read what changes, is the part its branch makes (`Html.branched`, as Solid's `<Show>` and
	## `<Switch>`): made when it holds, once, as a component is, and made again only when another
	## branch does, not each time what the conditions read changes. Each branch is a hole of its own,
	## so what it reads itself still follows. A `match` arm's names are getters (D-039's, read where
	## the arm's code reads them), so the arm stays while its value changes. `Plain` for any other
	## hole, and for one whose conditions read nothing that changes (run once, as before).
	read_flow : Cfg, St, U64, U64, List(Flow.Piece) -> Try([Flowed({ st : St, out : Str }), Plain], [Rocx(RocxError), Crash(Str)])
	read_flow = |cfg, st0, from, to, spans|
		match Flow.chain(cfg.src, from, to, spans) {
			Ok(chain) => Transpile.read_chain(cfg, st0, from, to, chain, spans)
			Err(NotFlow) =>
				match Flow.arms(cfg.src, from, to, spans) {
					Ok(found) => Transpile.read_arms(cfg, st0, from, to, found, spans)
					Err(NotFlow) => Ok(Plain)
				}
		}

	## The view whose body `pos` is in (D-039): the innermost, a match arm's (D-070) inside its component's.
	view_at : Cfg, U64 -> Try(Getters.View, [NotFound])
	view_at = |cfg, pos|
		cfg.getters.fold(
			Err(NotFound),
			|found, view|
				if view.from <= pos and pos < view.to {
					match found {
						Ok(outer) if outer.from > view.from => found
						_ => Ok(view)
					}
				} else {
					found
				},
		)

	## Whether a piece is a string literal and nothing else (`"settled"`, `"${n} left"`).
	is_text_literal : List(U8), Flow.Piece -> Bool
	is_text_literal = |src, piece| {
		at = Text.skip_space(src, piece.from)
		at < piece.to and Text.at(src, at) == '"' and Text.is_blank(Text.cut(src, Flow.string_end(src, at, piece.to), piece.to))
	}

	## A piece of a hole's code read on its own: what it is, and whether it reads what changes.
	read_piece : Cfg, St, Flow.Piece -> Try({ st : St, out : Str, reads : Bool }, [Rocx(RocxError), Crash(Str)])
	read_piece = |cfg, st, piece| {
		read = Transpile.read_code({ ..cfg, src: Text.slice(cfg.src, 0, piece.to) }, { ..st, pos: piece.from }, Bool.False)?
		Ok({ st: { ..read.st, pos: piece.to }, out: read.out, reads: read.st.effects > st.effects })
	}

	## A branch: a hole of its own (`Html.hole_of`, or `Html.hole` when it reads nothing that
	## changes), or, when it is an `if` or a `match` of its own that reads, that one's part.
	read_branch : Cfg, St, Flow.Piece, List(Flow.Piece) -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_branch = |cfg, st, piece, spans| {
		read = Transpile.read_piece(cfg, st, piece)?
		if read.reads {
			inside = spans.keep_if(|span| span.from >= piece.from and span.to <= piece.to)
			match Transpile.read_flow(cfg, st, piece.from, piece.to, inside)? {
				Flowed(done) => return Ok({ st: { ..done.st, pos: piece.to }, out: done.out })
				Plain => {}
			}
		}
		Ok({ st: read.st, out: if (read.reads) "Html.hole_of(|| Html.hole(${read.out}))" else "Html.shown(${read.out})" })
	}

	## The source's line ends from `from` up to `to`, as they are, and then the indentation of the
	## line `to` is on: what keeps a piece's lines, and where they start, when what is between pieces
	## is written otherwise (a line at a definition's place would read as one).
	newlines_in : List(U8), U64, U64 -> Str
	newlines_in = |src, from, to| {
		count = Text.newlines(src, from, to)
		if count == 0 {
			""
		} else {
			start = Text.line_start(src, to)
			"\n".repeat(count).concat(Text.cut(src, start, Text.run_end(src, start, |c| c == ' ' or c == '\t')))
		}
	}

	## Code on one line, written again where it isn't (a condition in the part's case): not when it
	## has a comment, which would hide what follows.
	one_line : Str -> Try(Str, [HasComment])
	one_line = |code| if (code.contains("#")) Err(HasComment) else Ok(code.replace_each("\n", " "))

	read_chain : Cfg, St, U64, U64, Flow.Chain, List(Flow.Piece) -> Try([Flowed({ st : St, out : Str }), Plain], [Rocx(RocxError), Crash(Str)])
	read_chain = |cfg, st0, from, to, chain, spans| {
		src = cfg.src
		# Text in each branch (`"refreshing"`, `"settled"`): a text hole, patched, as before.
		literal =
			match chain.otherwise {
				Else(piece) => chain.branches.map(|branch| branch.body).append(piece).all(|each| Transpile.is_text_literal(src, each))
				NoElse => Bool.False
			}
		if literal {
			return Ok(Plain)
		}
		var $st = st0
		var $reads = Bool.False
		# Whether the conditions go on one line, for the part's case (a comment in one doesn't).
		var $cased = Bool.True
		var $case = ""
		var $made = ""
		var $at = from
		var $index = 0.U64
		for branch in chain.branches {
			read = Transpile.read_piece(cfg, $st, branch.condition)?
			$st = read.st
			$reads = $reads or read.reads
			condition = if (branch.parens) read.out else "(${read.out})"
			match Transpile.one_line(condition) {
				Ok(line) => {
					$case = $case.concat("if ${line} \"${$index.to_str()}\" else ")
				}
				Err(_) => {
					$cased = Bool.False
				}
			}
			body = Transpile.read_branch(cfg, $st, branch.body, spans)?
			$st = body.st
			$made = $made.concat(Transpile.newlines_in(src, $at, branch.condition.from)).concat("if ${condition} ").concat(Transpile.newlines_in(src, branch.condition.to, branch.body.from)).concat(body.out).concat(" else ")
			$at = branch.body.to
			$index = $index + 1
		}
		match chain.otherwise {
			Else(piece) => {
				# Run once, or not on one line: the hole as it is written.
				if !$reads or !$cased {
					return Ok(Plain)
				}
				last = Transpile.read_branch(cfg, $st, piece, spans)?
				made = $made.concat(Transpile.newlines_in(src, $at, piece.from)).concat(last.out).concat(Transpile.newlines_in(src, piece.to, to))
				case = $case.concat("\"${$index.to_str()}\"")
				Ok(Flowed({ st: last.st, out: "Html.branched(|| Ok(${case}), || ${made})" }))
			}
			NoElse => {
				# No `else`, in a hole: nothing shows otherwise. Each branch is a hole, so an empty one fits
				# whatever the branches show.
				made = $made.concat("Html.empty({})").concat(Transpile.newlines_in(src, $at, to))
				if !$reads {
					Ok(Flowed({ st: $st, out: "(${made})" }))
				} else if !$cased {
					Ok(Flowed({ st: $st, out: "Html.hole_of(|| ${made})" }))
				} else {
					case = $case.concat("\"${$index.to_str()}\"")
					Ok(Flowed({ st: $st, out: "Html.branched(|| Ok(${case}), || ${made})" }))
				}
			}
		}
	}

	read_arms : Cfg, St, U64, U64, Flow.Arms, List(Flow.Piece) -> Try([Flowed({ st : St, out : Str }), Plain], [Rocx(RocxError), Crash(Str)])
	read_arms = |cfg, st0, from, to, found, spans| {
		src = cfg.src
		if found.arms.all(|arm| Transpile.is_text_literal(src, arm.body)) {
			return Ok(Plain)
		}
		read = Transpile.read_piece(cfg, st0, found.value)?
		value =
			match Transpile.one_line(read.out) {
				Ok(line) if read.reads => line
				_ => return Ok(Plain)
			}
		var $st = read.st
		var $cases = []
		var $made = Transpile.newlines_in(src, from, found.value.from).concat("match ${read.out}")
		var $at = found.value.to
		var $index = 0.U64
		for arm in found.arms {
			pattern_text = Text.trim(Text.cut(src, arm.pattern.from, arm.pattern.to))
			names = Flow.bindings(pattern_text).map(|binding| binding.name)
			(guard, guard_names) =
				match arm.guard {
					Guard(piece) => {
						g = Transpile.read_piece(cfg, $st, piece)?
						$st = g.st
						match Transpile.one_line(g.out) {
							Ok(line) => (" if ${line}", Flow.used_in(Text.cut(src, piece.from, piece.to), names))
							Err(_) => return Ok(Plain)
						}
					}
					NoGuard => ("", [])
				}
			pattern = Transpile.one_line(Flow.keeping(pattern_text, guard_names)) ?? return Ok(Plain)
			$cases = $cases.append("${pattern}${guard} => \"${$index.to_str()}\"")
			# The arm's code, its names read through getters, as a component's props are (D-039).
			# Inside a component, its own props are still read through theirs.
			view =
				match Transpile.view_at(cfg, arm.body.from) {
					Ok(outer) => { ..outer, from: arm.body.from, to: arm.body.to, props: outer.props.keep_if(|prop| !names.contains(prop)).concat(names) }
					Err(_) => { from: arm.body.from, to: arm.body.to, props: names, record: None, fields: [], all: [], component: "" }
				}
			body = Transpile.read_branch({ ..cfg, getters: cfg.getters.append(view), arms: cfg.arms.concat(names) }, $st, arm.body, spans)?
			$st = body.st
			used = names.keep_if(|name| body.out.contains("${name}!"))
			irrefutable = Text.trim(Flow.keeping(pattern_text, [])) == "_" and guard == ""
			getters = used.map(
				|name| {
					binding = Transpile.one_line(Flow.keeping(pattern_text, guard_names.append(name))) ?? pattern
					gone = if (irrefutable) "" else ", _ => Html.unmatched!(\"${name} is read after its match arm stopped matching\")"
					"|| match ${value} { ${binding}${guard} => ${name}${gone} }"
				},
			)
			code = if (used.is_empty()) body.out else "(|${Str.join_with(used.map(|name| "${name}!"), ", ")}| ${body.out})(${Str.join_with(getters, ", ")})"
			between = Transpile.newlines_in(src, $at, arm.pattern.from)
			separator = if ($index > 0 and between == "") ", " else ""
			$made = $made.concat(if ($index == 0) " {" else "").concat(separator).concat(between).concat("${pattern}${guard} => ").concat(Transpile.newlines_in(src, arm.pattern.from, arm.body.from)).concat(code)
			$at = arm.body.to
			$index = $index + 1
		}
		made = $made.concat(Transpile.newlines_in(src, $at, to)).concat(" }")
		case = "match ${value} { ${Str.join_with($cases, ", ")} }"
		Ok(Flowed({ st: $st, out: "Html.branched(|| Ok(${case}), || ${made})" }))
	}

	## D-071: a hole's `.map` whose list reads what changes (`{...todos!().map(|todo| <li
	## key={todo.id}>…</li>)}`) is its rows, kept as Solid 2.0's `<For>` keeps them: `Html.rows!`, a
	## row per key, or, keyed by the index (`.map_with_index(|name, i| <li key={i}>…`), `Html.rows_at!`,
	## a row per position. Roc's values have no identity, so the row's root says its key. The row's
	## name and its index's are getters, as a match arm's are (D-070): a row stays while its item
	## changes, and reads the newest. `Plain` for any other hole, and for a `.map` whose list reads
	## nothing that changes (made once, as before).
	read_rows : Cfg, St, U64, U64, List(Flow.Piece) -> Try([Rowed({ st : St, out : Str }), Plain], [Rocx(RocxError), Crash(Str)])
	read_rows = |cfg, st0, from, to, spans| {
		src = cfg.src
		found =
			match Flow.mapped(src, from, to, spans) {
				Ok(mapped) => mapped
				Err(NotMapped) => return Ok(Plain)
			}
		list = Transpile.read_piece(cfg, st0, found.list)?
		# Inside a <NoHydration>, nothing is kept: the list as it is.
		if !list.reads or st0.in_region > 0 {
			return Ok(Plain)
		}
		index_name =
			match found.index {
				Index(name) => name
				NoIndex => ""
			}
		inside = spans.keep_if(|span| span.from >= found.body.from and span.to <= found.body.to)
		way = "give the row's root its key, as in <li key={${found.item}.id}> (where the row is an if, each branch's), or, for a row per position, write .map_with_index(|${found.item}, i| …) and key={i}"
		root =
			match Flow.root(src, found.body, inside) {
				Ok(r) => r
				Err(NoRoot) => return Err(Transpile.fail(cfg, "a list that changes is a row per key, and this row has no markup to say its key: make it an element or a component (a <li> around it, say), and ${way}", Text.skip_space(src, found.body.from)))
			}
		key =
			match root.key {
				Key(k) => k
				NoKey => return Err(Transpile.fail(cfg, "a list that changes is a row per key, kept as the list changes, and Roc's values have no identity: ${way}", root.at))
			}
		key_text = Text.trim(Text.cut(src, key.code.from, key.code.to))
		by_position = index_name != "" and key_text == index_name
		if !by_position and index_name != "" and !Flow.used_in(key_text, [index_name]).is_empty() {
			return Err(Transpile.fail(cfg, "a key made from the index is a row per position: write key={${index_name}} alone", key.name_at))
		}
		# The row's names, getters: its item's, and, in a row per key, its index's, which changes as the row
		# moves (a row per position's is its position: a value).
		names = [found.item].concat(if (index_name == "" or by_position) [] else [index_name])
		# The key, the row's item a value in it (`|todo| todo.id`).
		keyed = Transpile.read_piece(cfg, list.st, key.code)?
		key_line =
			match Transpile.one_line(keyed.out) {
				Ok(line) => line
				Err(_) => return Err(Transpile.fail(cfg, "a row's key is one line", key.name_at))
			}
		# The row, its names getters (a component's key is passed over where it is read: the row's).
		view =
			match Transpile.view_at(cfg, found.body.from) {
				Ok(outer) => { ..outer, from: found.body.from, to: found.body.to, props: outer.props.keep_if(|prop| !names.contains(prop)).concat(names) }
				Err(_) => { from: found.body.from, to: found.body.to, props: names, record: None, fields: [], all: [], component: "" }
			}
		body = Transpile.read_piece({ ..cfg, getters: cfg.getters.append(view), arms: cfg.arms.concat(names), row_key: At(key.name_at) }, keyed.st, found.body)?
		# A name the row doesn't read (`_`, `_item`, or one never read: its getter not called) is `_`.
		param = |name| if (name == "" or name.starts_with("_") or !Transpile.calls(body.out, "${name}!")) "_" else "${name}!"
		item_param = param(found.item)
		index_param =
			if by_position {
				if (index_name.starts_with("_") or !Transpile.calls(body.out, index_name)) "_" else index_name
			} else {
				param(index_name)
			}
		head =
			if by_position {
				"Html.rows_at!(|| ${list.out}, |${item_param}, ${index_param}|"
			} else {
				"Html.rows!(|| ${list.out}, |${found.item}| ${key_line}, |${item_param}, ${index_param}|"
			}
		# The row a template (D-084), named by its module and how many `.map`s come before it there
		# (which formatting doesn't change, as it does where in the file it is).
		site = Text.roc_string("${cfg.module_path}:${Transpile.maps_before(src, found.list.from).to_str()}")
		out = head.concat(Transpile.newlines_in(src, found.list.to, found.body.from)).concat(" Html.template(${site}, ").concat(body.out).concat(")").concat(Transpile.newlines_in(src, found.body.to, to)).concat(")")
		Ok(Rowed({ st: body.st, out }))
	}

	## How many `.map`s (`.map(`, `.map_with_index(`) come before `at`.
	maps_before : List(U8), U64 -> U64
	maps_before = |src, at| {
		word = ".map".to_utf8()
		var $count = 0
		var $from = 0
		while $from < at {
			match Text.index_of(src, word, $from) {
				Ok(i) if i < at => {
					$count = $count + 1
					$from = i + 1
				}
				_ => {
					$from = at
				}
			}
		}
		$count
	}

	## Whether `code` calls `name` (`todo!`) or reads it (`i`), in a string's interpolation too: the name,
	## not part of another (`my_todo!`, `index`) nor a field (`.todo!`).
	calls : Str, Str -> Bool
	calls = |code, name| {
		bytes = code.to_utf8()
		word = name.to_utf8()
		var $at = 0
		var $found = Bool.False
		while !$found and $at < bytes.len() {
			match Text.index_of(bytes, word, $at) {
				Ok(i) => {
					before = if (i == 0) ' ' else Text.at(bytes, i - 1)
					after = Text.at(bytes, i + word.len())
					if !(Text.is_alnum(before) or before == '_' or before == '.') and !(i + word.len() < bytes.len() and (Text.is_alnum(after) or after == '_')) {
						$found = Bool.True
					}
					$at = i + 1
				}
				Err(_) => {
					$at = bytes.len()
				}
			}
		}
		$found
	}

	## A <script> or <style> body: static, as written, its lines kept as lines.
	read_raw_text : Cfg, St, Str, U64 -> Try({ st : St, out : Str }, [Rocx(RocxError), Crash(Str)])
	read_raw_text = |cfg, st0, tag, opened_at| {
		src = cfg.src
		start = st0.pos
		closing =
			match Transpile.closing_tag(src, start, tag) {
				Ok(found) => found
				Err(_) => return Err(Transpile.fail(cfg, "<${tag}> is never closed", opened_at))
			}
		content = Text.cut(src, start, closing.at)
		st1 = { ..st0, pos: closing.end }
		content_lines = content.split_on("\n")
		if content_lines.len() == 1 {
			return Ok({ st: st1, out: "Html.source_text(${Text.roc_string(content)})" })
		}
		var $at = start
		var $pieces = []
		var $i = 0
		for line in content_lines {
			indent = if ($i == 0) "" else "\n${Transpile.indent_at(src, $at)}"
			$at = $at + line.to_utf8().len() + 1
			$pieces = $pieces.append("${indent}${Text.roc_string(line)}")
			$i = $i + 1
		}
		Ok({ st: st1, out: "Html.source_text(Str.join_with([${Str.join_with($pieces, ", ")}], \"\\n\"))" })
	}

	## Whether `code` (its lines but its imports) uses `name.` (`/(^|[^A-Za-z0-9_.])name\./m`).
	uses_name : List(U8), Str -> Bool
	uses_name = |code, name| {
		needle = name.concat(".").to_utf8()
		var $i = 0
		while $i < code.len() {
			match Text.index_of(code, needle, $i) {
				Ok(k) => {
					before = Text.at(code, k - 1)
					if k == 0 or !(Transpile.is_alnum_under(before) or before == '.') {
						return Bool.True
					}
					$i = k + 1
				}
				Err(_) => return Bool.False
			}
		}
		Bool.False
	}

	## The lines of `code` that aren't imports (`/^import\s/`), joined.
	without_imports : Str -> List(U8)
	without_imports = |code|
		Str.join_with(code.split_on("\n").drop_if(|line| line.starts_with("import") and Text.is_space_at(line.to_utf8(), 6)), "\n").to_utf8()

	## The browser's copy without the imports only what it drops (a `<NoHydration>`'s children) used:
	## each such line left empty, so lines stay lines. `server` is the server's
	## copy; an import its code doesn't use either is kept, for the compiler to warn about. A module a
	## comment or a string names (`## Behind Middlewares.member`) isn't used by that.
	without_server_imports : Str, Str -> Str
	without_server_imports = |browser, server| {
		browser_code = Transpile.code_only(Transpile.without_imports(browser))
		server_code = Transpile.code_only(Transpile.without_imports(server))
		kept = browser.split_on("\n").map(
			|line| {
				match Transpile.import_at(line.to_utf8(), 0) {
					Ok(m) => {
						name =
							match m.alias {
								Some(a) => a
								None => m.name
							}
						if (!Transpile.uses_name(browser_code, name) and Transpile.uses_name(server_code, name)) "" else line
					}
					Err(_) => line
				}
			},
		)
		Str.join_with(kept, "\n")
	}

	## The browser's copy with each name that only what it drops used (a `<NoHydration>`'s children)
	## rewritten where it is bound, so the compiler doesn't warn that it is unused (a warning is
	## `roc build`'s exit code 2, which a script reads as a failure): a field of a record pattern,
	## `|{ params }|`, is `params: _`; a lambda's parameter, `|props|`, or a definition, `lang = …`,
	## takes a `_` (`_props`, `_lang = …`). Only a name the server's copy uses, whose one occurrence
	## left in the browser's is where it is bound; one in a place this can't tell is left as it is.
	without_server_bindings : Str, Str -> Str
	without_server_bindings = |browser, server| {
		code = browser.to_utf8()
		server_code = server.to_utf8()
		mask = Transpile.code_mask(code)
		server_mask = Transpile.code_mask(server_code)
		var $out = code
		# How far what was rewritten so far moved the rest: a rewrite may be shorter (`params!` → `_`).
		var $shift = 0.I64
		for name in Transpile.bound_names(code, mask) {
			found = Transpile.occurrences(code, mask, name)
			if found.len() == 1 and Transpile.occurrences(server_code, server_mask, name).len() > 1 {
				at = found.first() ?? 0
				match Transpile.unbound(code, mask, at, name) {
					Ok(rewritten) => {
						moved = (at.to_i64_wrap() + $shift).to_u64_wrap()
						$out = $out.take_first(moved).concat(rewritten.to_utf8()).concat($out.drop_first(moved + name.count_utf8_bytes()))
						$shift = $shift + rewritten.count_utf8_bytes().to_i64_wrap() - name.count_utf8_bytes().to_i64_wrap()
					}
					Err(Unsure) => {}
				}
			}
		}
		Str.from_utf8_lossy($out)
	}

	## Which bytes of `code` are code (`Bool.True`), not a string's text (a `${…}` in one is code), a
	## character (`'"'`) or a comment.
	code_mask : List(U8) -> List(Bool)
	code_mask = |code| {
		var $mask = List.with_capacity(code.len())
		# The strings open here, innermost last: in each, how many `{` of a `${…}` are open (0: its text).
		var $strings = []
		var $comment = Bool.False
		var $char = Bool.False
		var $escaped = Bool.False
		var $dollar = Bool.False
		for b in code {
			in_text =
				match $strings.last() {
					Ok(depth) => depth == 0
					Err(_) => Bool.False
				}
			if $comment {
				$mask = $mask.append(Bool.False)
				$comment = b != '\n'
			} else if $escaped {
				$mask = $mask.append(Bool.False)
				$escaped = Bool.False
				$dollar = Bool.False
			} else if $char {
				$mask = $mask.append(Bool.False)
				$escaped = b == '\\'
				$char = b != '\''
			} else if in_text {
				$mask = $mask.append(Bool.False)
				if b == '\\' {
					$escaped = Bool.True
				} else if b == '"' {
					$strings = $strings.drop_last(1)
				} else if b == '{' and $dollar {
					$strings = $strings.drop_last(1).append(1)
				}
				$dollar = b == '$'
			} else if b == '"' {
				$mask = $mask.append(Bool.False)
				$strings = $strings.append(0)
			} else if b == '\'' {
				$mask = $mask.append(Bool.False)
				$char = Bool.True
			} else if b == '#' {
				$mask = $mask.append(Bool.False)
				$comment = Bool.True
			} else {
				$mask = $mask.append(Bool.True)
				# Code in a `${…}`: its braces count to its end.
				depth = $strings.last() ?? 0
				if !$strings.is_empty() and b == '{' {
					$strings = $strings.drop_last(1).append(depth + 1)
				} else if !$strings.is_empty() and b == '}' {
					$strings = $strings.drop_last(1).append(depth - 1)
				}
			}
		}
		$mask
	}

	## `code` with what isn't code (`code_mask`'s) blanked, a space for each byte and its line breaks
	## kept, so offsets and lines stay.
	code_only : List(U8) -> List(U8)
	code_only = |code| {
		mask = Transpile.code_mask(code)
		code.map_with_index(|b, i| if (b == '\n' or (mask.get(i) ?? Bool.True)) b else ' ')
	}

	## Where `name` occurs in `code` as a name, in its code (`mask`), not in a string's text or a
	## comment: not part of a longer one (`params` isn't in `params2`, `intl` isn't `intl!`) and not a
	## field read (`.params`), in the order it occurs.
	occurrences : List(U8), List(Bool), Str -> List(U64)
	occurrences = |code, mask, name| {
		needle = name.to_utf8()
		size = needle.len()
		var $found = []
		var $i = 0
		while $i < code.len() {
			match Text.index_of(code, needle, $i) {
				Ok(k) => {
					before = if (k == 0) ' ' else Text.at(code, k - 1)
					after = Text.at(code, k + size)
					longer = Transpile.is_alnum_under(after) or (after == '!' and Text.at(code, k + size + 1) != '=' and !name.ends_with("!"))
					if !(Transpile.is_alnum_under(before) or before == '.' or before == '$') and !longer and (mask.get(k) ?? Bool.False) {
						$found = $found.append(k)
					}
					$i = k + 1
				}
				Err(_) => {
					$i = code.len()
				}
			}
		}
		$found
	}

	## The names the code binds that a rewrite may touch: each lowercase word followed, past spaces,
	## by `,`, `}`, `|` or a lone `=` (a pattern's field, a parameter, a definition), each once.
	bound_names : List(U8), List(Bool) -> List(Str)
	bound_names = |code, mask| {
		var $names = []
		var $i = 0
		while $i < code.len() {
			b = Text.at(code, $i)
			before = if ($i == 0) ' ' else Text.at(code, $i - 1)
			if Text.is_lower(b) and (mask.get($i) ?? Bool.False) and !(Transpile.is_alnum_under(before) or before == '.' or before == '$' or before == '"') {
				var $j = $i
				while $j < code.len() and Transpile.is_alnum_under(Text.at(code, $j)) {
					$j = $j + 1
				}
				if Text.at(code, $j) == '!' and Text.at(code, $j + 1) != '=' {
					$j = $j + 1
				}
				name = Str.from_utf8_lossy(code.sublist({ start: $i, len: $j - $i }))
				next = Text.at(code, Text.skip_space(code, $j))
				single = next == '=' and Text.at(code, Text.skip_space(code, $j) + 1) != '='
				if (next == ',' or next == '}' or next == '|' or single) and !$names.contains(name) {
					$names = $names.append(name)
				}
				$i = $j
			} else {
				$i = $i + 1
			}
		}
		$names
	}

	## `name` at `at`, rewritten so it binds nothing the compiler would call unused: in a record
	## pattern, `name: _`; a lambda's parameter or a definition at the start of its line, `_name`.
	## `Unsure` anywhere else.
	unbound : List(U8), List(Bool), U64, Str -> Try(Str, [Unsure])
	unbound = |code, mask, at, name| {
		end = at + name.count_utf8_bytes()
		next_at = Text.skip_space(code, end)
		next = Text.at(code, next_at)
		var $start = at
		while $start > 0 and Text.at(code, $start - 1) != '\n' {
			$start = $start - 1
		}
		lead = code.sublist({ start: $start, len: at - $start })
		if lead.all(|b| b == ' ' or b == '\t') {
			# A definition: a local in a function's body (the nearest line above, less indented, has a
			# lambda), never a member of a block or the module, which another module may read.
			definition = next == '=' and Text.at(code, next_at + 1) != '='
			return if (definition and !lead.is_empty() and Transpile.in_lambda(code, $start, lead.len())) Ok("_${name}") else Err(Unsure)
		}
		# Inside what, on its own line: the nearest `{` or `|` before it that isn't closed.
		var $depth = 0
		var $k = at
		var $inside = Nothing
		while $k > $start and $inside == Nothing {
			$k = $k - 1
			c = if (mask.get($k) ?? Bool.False) Text.at(code, $k) else ' '
			if c == '}' {
				$depth = $depth + 1
			} else if c == '{' and $depth == 0 {
				$inside = Braces
			} else if c == '{' {
				$depth = $depth - 1
			} else if c == '|' and $depth == 0 {
				$inside = Bars
			}
		}
		# A field bound to a name of its own (`{ params: params! }`, a prop's getter, D-039): `_` alone.
		back = Text.skip_space_back(code, at)
		renamed = back > 0 and Text.at(code, back - 1) == ':'
		match $inside {
			Braces if (next == ',' or next == '}') and renamed => Ok("_")
			Braces if next == ',' or next == '}' => Ok("${name}: _")
			Bars if next == ',' or next == '|' => Ok("_${name}")
			_ => Err(Unsure)
		}
	}

	## Whether the nearest line above the one at `start` that isn't blank and is indented less than
	## `indent` has a lambda (`|`): a definition there is a local of its body.
	in_lambda : List(U8), U64, U64 -> Bool
	in_lambda = |code, start, indent| {
		var $end = start
		while $end > 0 {
			var $begin = $end - 1
			while $begin > 0 and Text.at(code, $begin - 1) != '\n' {
				$begin = $begin - 1
			}
			line = code.sublist({ start: $begin, len: $end - 1 - $begin })
			lead = line.take_first(line.find_first_index(|b| b != ' ' and b != '\t') ?? line.len())
			if lead.len() < line.len() and lead.len() < indent {
				return line.contains('|')
			}
			$end = $begin
		}
		Bool.False
	}

	## `transpile`, and what the file has besides its code (`Module`). A <style> may come after the markup
	## it styles: a first run finds them, and a second, when there are any, gives each element the classes
	## of those whose markup it is in.
	transpile_module : Str, Str, Options -> Try(Module, [Rocx(RocxError), Crash(Str)])
	transpile_module = |source, file, opts| {
		cfg1 = Transpile.new_cfg(source, file, opts, [])?
		first = Transpile.read_code(cfg1, Transpile.fresh, Bool.False)?
		len = cfg1.src.len()
		styles = first.st.styles.map(
			|s| {
				to =
					match s.owner {
						File => len
						Block(id) =>
							match first.st.closed.find_first(|c| c.id == id) {
								Ok(c) => c.to
								Err(_) => len
							}
					}
				{ css: s.css, line: s.line, component: s.component, scope: s.scope, from: s.from, to }
			},
		)
		scopes = styles.map(|s| { scope: s.scope, from: s.from, to: s.to })
		second =
			if scopes.is_empty() {
				first
			} else {
				cfg2 = Transpile.new_cfg(source, file, opts, scopes)?
				Transpile.read_code(cfg2, Transpile.fresh, Bool.False)?
			}
		body0 = second.out
		body =
			if opts.client and second.st.regions > 0 {
				server_cfg = Transpile.new_cfg(source, file, { ..opts, client: Bool.False }, scopes)?
				server = Transpile.read_code(server_cfg, Transpile.fresh, Bool.False)?
				Transpile.without_server_bindings(Transpile.without_server_imports(body0, server.out), server.out)
			} else {
				body0
			}
		body_bytes = body.to_utf8()
		var $end = body_bytes.len()
		while $end > 0 and Text.at(body_bytes, $end - 1) == '\n' {
			$end = $end - 1
		}
		name = Transpile.last_part(file)
		code = "${Text.cut(body_bytes, 0, $end)}\n\n${Transpile.marker} ${name}: edit that file, not this one. Line N here is line N there.\n"
		warnings = first.st.warnings.map(|w| { reason: w.reason, file, line: Text.line_of(cfg1.src, w.at), column: Text.column(cfg1.src, w.at) })
		once = first.st.once.map(|o| { component: o.component, prop: o.prop, line: Text.line_of(cfg1.src, o.at), column: Text.column(cfg1.src, o.at) })
		handed = first.st.handed.map(|h| { tag: h.tag, prop: h.prop, name: h.name, line: Text.line_of(cfg1.src, h.at), column: Text.column(cfg1.src, h.at) })
		Ok({ code, regions: second.st.regions, styles: styles.map(|s| { css: s.css, line: s.line, component: s.component }), stories: first.st.stories, warnings, once, handed })
	}

	## Where a .rocx file's markup is, for rocx fmt: each markup expression its Roc has, those in holes too
	## (`kind: "markup"`), each stylesheet (`"style"`) and each story (`"story"`), as byte offsets.
	markup_spans : Str, Str, Options -> Try(List({ kind : Str, from : U64, to : U64 }), [Rocx(RocxError), Crash(Str)])
	markup_spans = |source, file, opts| {
		cfg = Transpile.new_cfg(source, file, opts, [])?
		read = Transpile.read_code(cfg, Transpile.fresh, Bool.False)?
		Ok(read.st.spans)
	}

	## The options rocx internal is given (`{ module?, client?, contexts?, views?, route? }`).
	options_of : Value -> Options
	options_of = |given| {
		pairs = |v| Value.fields(v).map(|f| { key: f.key, value: Value.str(f.value) })
		{
			module_path: Value.str_or(Value.field(given, "module"), ""),
			client: Value.bool_or(Value.field(given, "client"), Bool.False),
			contexts: pairs(Value.field(given, "contexts")),
			views: pairs(Value.field(given, "views")),
			route: Value.bool_or(Value.field(given, "route"), Bool.False),
			dev: Value.bool_or(Value.field(given, "dev"), Bool.False),
		}
	}

	## A transpiler's problem, as `rocx internal` answers it.
	problem_value : [Rocx(RocxError), Crash(Str)] -> Value
	problem_value = |problem|
		match problem {
			Rocx(e) => Value.rocx_problem(e)
			Crash(message) => Value.problem(message)
		}

	## `rocx internal`'s calls of this module's functions (rocx-cli/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, args| {
		arg = |i| args.get(i) ?? Null
		file_arg = Value.str_or(arg(1), "input.rocx")
		match name {
			"transpile" =>
				match Transpile.transpile_module(Value.str(arg(0)), file_arg, Transpile.options_of(arg(2))) {
					Ok(m) => Ok(Text(m.code))
					Err(problem) => Err(Failed(Transpile.problem_value(problem)))
				}
			"transpileModule" =>
				match Transpile.transpile_module(Value.str(arg(0)), file_arg, Transpile.options_of(arg(2))) {
					Ok(m) =>
						Ok(
							Object([
								{ key: "code", value: Text(m.code) },
								{ key: "regions", value: Value.count(m.regions) },
								{ key: "styles", value: Array(m.styles.map(|s| Object([{ key: "css", value: Text(s.css) }, { key: "line", value: Value.count(s.line) }, { key: "component", value: Value.text_or_null(s.component) }]))) },
								{ key: "stories", value: Array(m.stories.map(|s| Object([{ key: "component", value: Text(s.component) }, { key: "name", value: Text(s.name) }, { key: "def", value: Text(s.def) }, { key: "line", value: Value.count(s.line) }]))) },
								{ key: "warnings", value: Array(m.warnings.map(|w| Object([{ key: "reason", value: Text(w.reason) }, { key: "line", value: Value.count(w.line) }, { key: "column", value: Value.count(w.column) }]))) },
							]),
						)
					Err(problem) => Err(Failed(Transpile.problem_value(problem)))
				}
			"markupSpans" => {
				source = Value.str(arg(0))
				bytes = source.to_utf8()
				units = |offset| Value.count(Text.utf16_units(Text.slice(bytes, 0, offset)))
				match Transpile.markup_spans(source, file_arg, Transpile.options_of(arg(2))) {
					Ok(spans) => Ok(Array(spans.map(|s| Object([{ key: "kind", value: Text(s.kind) }, { key: "from", value: units(s.from) }, { key: "to", value: units(s.to) }]))))
					Err(problem) => Err(Failed(Transpile.problem_value(problem)))
				}
			}
			"viewsDefined" => Ok(Object(Transpile.views_defined(Value.str(arg(0))).map(|v| { key: v.key, value: Text(v.value) })))
			"contextsDefined" => Ok(Array(Transpile.contexts_defined(Value.str(arg(0))).map(|c| Object([{ key: "name", value: Text(c.name) }, { key: "shared", value: Boolean(c.shared) }]))))
			"pascalCase" => Ok(Text(Transpile.pascal_case(Value.str(arg(0)))))
			_ => Err(Unknown(name))
		}
	}
}
