## Scoped styles, as Svelte has them (was src/styles.mjs). A .rocx file's top-level <style> styles
## the markup that file writes, and nothing else: rocx gives each of the file's elements a class
## named after the file (`rx-k3j9qa`), and adds that class to each selector in the file's CSS. So
## `.counter` in one file and `.counter` in another never meet, and a component's styles don't reach
## into the components it renders (their elements are written in other files). `rocx build` joins
## every file's scoped CSS into one stylesheet, Generated/Styles.roc, which the root layout puts in
## its <head>.
##
## Svelte's rules, kept:
##   - `.a .b {}` becomes `.a.rx-k3j9qa .b:where(.rx-k3j9qa) {}`: each compound selector gets the
##     class, the first as a class and the rest in :where(), so a selector's specificity goes up by
##     one class (0-1-0) however long it is.
##   - `:global(…)` leaves a selector, or part of a compound, as written: `:global(body)`,
##     `div :global(strong)` (any strong inside this file's divs), `p:global(.big)`.
##   - `.a :global .b .c` scopes what comes before `:global` and leaves the rest; `:global { … }`
##     and `.a :global { … }` leave every rule inside the block as written.
##   - `@keyframes spin` is the file's own (`rx-k3j9qa-spin`), and so is `spin` in the file's
##     `animation` and `animation-name`; `@keyframes -global-spin` is `spin`, for everyone.
## And CSS nesting: a rule inside a rule is relative to one that already has the class, so its
## compounds get it in :where(), and `&` is left as it is.
##
## The CSS is scanned by its bytes; a problem's `offset` is in UTF-16 units into the CSS, as the
## JavaScript's was (a comment is blanked a space per unit, so offsets into the blanked text are
## offsets into the CSS).
import Text
import Value

Styles := [].{

	## Elements that are never styled, so get no class: what goes in <head>, and the raw-text ones.
	unscoped_elements : List(Str)
	unscoped_elements = ["head", "meta", "title", "link", "base", "script", "style"]

	## At-rules whose block holds rules (or, nested in a rule, declarations), which are scoped in turn.
	grouping_at_rules : List(Str)
	grouping_at_rules = ["media", "supports", "container", "layer", "scope", "starting-style", "document"]

	## At-rules a file's <style> can't have: rocx joins every file's into one stylesheet, and these have
	## to come first in one.
	refused_at_rules : List(Str)
	refused_at_rules = ["import", "charset", "namespace"]

	## The class a file's elements get when it has a <style>: `rx-`, then a hash of the module's name.
	scope_class : Str -> Str
	scope_class = |module_name| {
		# FNV-1a, 32 bits: the same name, the same class, in the server's copy and the browser's.
		start : U32
		start = 0x811c9dc5
		prime : U32
		prime = 0x01000193
		hash = Text.code_points(module_name).fold(start, |h, cp| h.bitwise_xor(cp).times_wrap(prime))
		padded = Text.pad_start(Text.in_base(hash.to_u64(), 36), 7, "0").to_utf8()
		"rx-".concat(Text.cut(padded, padded.len() - 6, padded.len()))
	}

	## `css`, a file's <style>, with every selector scoped to `scope` (a class from `scope_class`); or
	## the problem, and its offset into `css` in UTF-16 units.
	scope_css : Str, Str -> Try(Str, [Css({ reason : Str, offset : U64 })])
	scope_css = |css, scope| {
		css_bytes = css.to_utf8()
		source =
			match Styles.blank_comments(css_bytes) {
				Ok(blanked) => blanked
				Err(Fail(f)) => return Err(Css({ reason: f.reason, offset: Text.utf16_units(Text.slice(css_bytes, 0, f.at)) }))
			}
		at_units = |at| Text.utf16_units(Text.slice(source, 0, at))
		ctx = { src: source, scope, keyframes: Styles.own_keyframes(source, scope) }
		match Styles.items(ctx, 0, { nested: Bool.False, global: Bool.False }) {
			Ok(done) =>
				if done.pos < source.len() {
					Err(Css({ reason: "this } closes nothing", offset: at_units(done.pos) }))
				} else {
					Ok(Styles.tidy(done.out))
				}
			Err(Fail(f)) => Err(Css({ reason: f.reason, offset: at_units(f.at) }))
		}
	}

	## The file's own keyframes, by name: `spin` is `rx-k3j9qa-spin` wherever this file uses it
	## (`/@(?:-[a-z]+-)?keyframes\s+([A-Za-z_-][\w-]*)/g`).
	own_keyframes : List(U8), Str -> List({ key : Str, value : Str })
	own_keyframes = |source, scope| {
		var $found = []
		var $i = 0
		while $i < source.len() {
			if Text.at(source, $i) == '@' {
				match Styles.keyframes_name_at(source, $i + 1) {
					Ok(m) => {
						if !m.name.starts_with("-global-") {
							$found = Styles.set_key($found, m.name, "${scope}-${m.name}")
						}
						$i = m.end
					}
					Err(_) => {
						$i = $i + 1
					}
				}
			} else {
				$i = $i + 1
			}
		}
		$found
	}

	## After an `@` at `i`: `(?:-[a-z]+-)?keyframes\s+([A-Za-z_-][\w-]*)`, its name and where it ends.
	keyframes_name_at : List(U8), U64 -> Try({ name : Str, end : U64 }, [NoMatch])
	keyframes_name_at = |source, i| {
		after_keyword = |k| {
			if Text.starts_with_at(source, "keyframes".to_utf8(), k) {
				spaced = Text.skip_space(source, k + 9)
				if spaced > k + 9 and Styles.is_name_start(Text.at(source, spaced)) {
					stop = Text.run_end(source, spaced + 1, Styles.is_name_part)
					Ok({ name: Text.cut(source, spaced, stop), end: stop })
				} else {
					Err(NoMatch)
				}
			} else {
				Err(NoMatch)
			}
		}
		prefixed =
			if Text.at(source, i) == '-' {
				letters = Text.run_end(source, i + 1, Text.is_lower)
				if (letters > i + 1 and Text.at(source, letters) == '-') after_keyword(letters + 1) else Err(NoMatch)
			} else {
				Err(NoMatch)
			}
		match prefixed {
			Ok(m) => Ok(m)
			Err(_) => after_keyword(i)
		}
	}

	is_name_start : U8 -> Bool
	is_name_start = |b| Text.is_letter(b) or b == '_' or b == '-'

	is_name_part : U8 -> Bool
	is_name_part = |b| Text.is_word(b) or b == '-'

	## `pairs` with `key` set to `value`: in its place if it is there, else at the end.
	set_key : List({ key : Str, value : Str }), Str, Str -> List({ key : Str, value : Str })
	set_key = |pairs, key, value|
		if pairs.any(|p| p.key == key) {
			pairs.map(|p| if (p.key == key) { key, value } else p)
		} else {
			pairs.append({ key, value })
		}

	lookup : List({ key : Str, value : Str }), Str -> [Some(Str), None]
	lookup = |pairs, key|
		match pairs.find_first(|p| p.key == key) {
			Ok(found) => Some(found.value)
			Err(_) => None
		}

	## Comments as spaces, a space for each UTF-16 unit but a line break (kept), so offsets still point
	## into the file.
	blank_comments : List(U8) -> Try(List(U8), [Fail({ reason : Str, at : U64 })])
	blank_comments = |css| {
		var $out = List.with_capacity(css.len())
		var $i = 0
		while $i < css.len() {
			c = Text.at(css, $i)
			if c == '"' or c == '\'' {
				end = Styles.string_end(css, $i)
				$out = $out.concat(Text.slice(css, $i, end))
				$i = end
			} else if c == '/' and Text.at(css, $i + 1) == '*' {
				match Text.index_of(css, "*/".to_utf8(), $i + 2) {
					Ok(end) => {
						for b in Text.slice(css, $i, end + 2) {
							if b == '\n' {
								$out = $out.append('\n')
							} else if b < 0x80 or (b >= 0xC0 and b < 0xF0) {
								$out = $out.append(' ')
							} else if b >= 0xF0 {
								$out = $out.concat([' ', ' '])
							}
						}
						$i = end + 2
					}
					Err(_) => return Err(Fail({ reason: "this comment is never closed", at: $i }))
				}
			} else {
				$out = $out.append(c)
				$i = $i + 1
			}
		}
		Ok($out)
	}

	## Where the string that opens at `start` ends: after its closing quote, or at the line's end.
	string_end : List(U8), U64 -> U64
	string_end = |css, start| {
		quote = Text.at(css, start)
		var $i = start + 1
		while $i < css.len() and Text.at(css, $i) != quote and Text.at(css, $i) != '\n' {
			$i = $i + (if (Text.at(css, $i) == '\\') 2 else 1)
		}
		stop = if ($i < css.len() and Text.at(css, $i) == quote) $i + 1 else $i
		if (stop > css.len()) css.len() else stop
	}

	## No trailing spaces, no runs of blank lines, the common indentation gone.
	tidy : Str -> Str
	tidy = |css| {
		trimmed = css.split_on("\n").map(Text.trim_end)
		indents = trimmed.keep_if(|line| !line.is_empty()).map(|line| Text.indent(line).to_utf8().len())
		common = indents.fold(indents.first() ?? 0, |least, n| if (n < least) n else least)
		joined = Str.join_with(trimmed.map(|line| Str.from_utf8_lossy(line.to_utf8().drop_first(common))), "\n")
		Text.trim(Styles.squeeze_blank_lines(joined))
	}

	## Runs of three or more line breaks as two (`/\n{3,}/g` → `\n\n`).
	squeeze_blank_lines : Str -> Str
	squeeze_blank_lines = |text| {
		bytes = text.to_utf8()
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		while $i < bytes.len() {
			if Text.at(bytes, $i) == '\n' {
				run = Text.run_end(bytes, $i, |b| b == '\n')
				$out = if (run - $i >= 3) $out.concat(['\n', '\n']) else $out.concat(Text.slice(bytes, $i, run))
				$i = run
			} else {
				$out = $out.append(Text.at(bytes, $i))
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}

	## `text` split at the top-level occurrences of `separator` (not inside (), [] or a string).
	split_top_level : Str, U8 -> List(Str)
	split_top_level = |text, separator| {
		bytes = text.to_utf8()
		var $parts = []
		var $depth = Styles.zero
		var $from = 0
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\\' {
				$i = $i + 1
			} else if c == '"' or c == '\'' {
				$i = Styles.string_end(bytes, $i) - 1
			} else if c == '(' or c == '[' {
				$depth = $depth + 1
			} else if c == ')' or c == ']' {
				$depth = $depth - 1
			} else if c == separator and $depth == 0 {
				$parts = $parts.append(Text.cut(bytes, $from, $i))
				$from = $i + 1
			}
			$i = $i + 1
		}
		$parts.append(Text.cut(bytes, $from, bytes.len()))
	}

	zero : I64
	zero = 0

	## Whether the byte is one of `[\s>+~]`'s ASCII ones (a combinator, or the start of whitespace).
	is_combinator_char : List(U8), U64 -> Bool
	is_combinator_char = |bytes, i| {
		c = Text.at(bytes, i)
		i < bytes.len() and (c == '>' or c == '+' or c == '~' or Text.is_space_at(bytes, i))
	}

	## A selector as compounds and the combinators between them: `.a > .b c` is
	## `[Compound(".a"), Combinator(" > "), Compound(".b"), Combinator(" "), Compound("c")]`.
	compounds : Str -> List([Compound(Str), Combinator(Str)])
	compounds = |sel| {
		bytes = sel.to_utf8()
		var $parts = []
		var $depth = Styles.zero
		var $current = []
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if $depth == 0 and Styles.is_combinator_char(bytes, $i) {
				var $explicit = []
				while $i < bytes.len() and Styles.is_combinator_char(bytes, $i) {
					n = Text.space_at(bytes, $i)
					if n > 0 {
						$i = $i + n
					} else {
						$explicit = $explicit.append(Text.at(bytes, $i))
						$i = $i + 1
					}
				}
				if !$current.is_empty() {
					$parts = $parts.append(Compound(Str.from_utf8_lossy($current)))
				}
				$current = []
				$parts = $parts.append(Combinator(if ($explicit.is_empty()) " " else " ${Str.from_utf8_lossy($explicit)} "))
			} else if c == '\\' {
				$current = $current.concat(Text.slice(bytes, $i, $i + 2))
				$i = $i + 2
			} else if c == '"' or c == '\'' {
				end = Styles.string_end(bytes, $i)
				$current = $current.concat(Text.slice(bytes, $i, end))
				$i = end
			} else {
				if c == '(' or c == '[' {
					$depth = $depth + 1
				} else if c == ')' or c == ']' {
					$depth = $depth - 1
				}
				$current = $current.append(c)
				$i = $i + 1
			}
		}
		if ($current.is_empty()) $parts else $parts.append(Compound(Str.from_utf8_lossy($current)))
	}

	## Where a compound's class goes: before its first pseudo-class or pseudo-element, or at its end.
	class_position : List(U8) -> U64
	class_position = |compound| {
		var $depth = Styles.zero
		var $i = 0
		while $i < compound.len() {
			c = Text.at(compound, $i)
			if c == '\\' {
				$i = $i + 1
			} else if c == '"' or c == '\'' {
				$i = Styles.string_end(compound, $i) - 1
			} else if c == '(' or c == '[' {
				$depth = $depth + 1
			} else if c == ')' or c == ']' {
				$depth = $depth - 1
			} else if c == ':' and $depth == 0 {
				return $i
			}
			$i = $i + 1
		}
		compound.len()
	}

	## The text between the `(` at `open` and its `)`, and where that `)` is.
	parenthesised : List(U8), U64 -> Try({ inner : List(U8), close : U64 }, [NotClosed])
	parenthesised = |text, open| {
		var $depth = Styles.zero
		var $i = open
		while $i < text.len() {
			c = Text.at(text, $i)
			if c == '\\' {
				$i = $i + 1
			} else if c == '"' or c == '\'' {
				$i = Styles.string_end(text, $i) - 1
			} else if c == '(' {
				$depth = $depth + 1
			} else if c == ')' {
				$depth = $depth - 1
				if $depth == 0 {
					return Ok({ inner: Text.slice(text, open + 1, $i), close: $i })
				}
			}
			$i = $i + 1
		}
		Err(NotClosed)
	}

	## Whitespace at `pos`, as it is.
	space : List(U8), U64 -> { pos : U64, out : Str }
	space = |src, pos| {
		stop = Text.skip_space(src, pos)
		{ pos: stop, out: Text.cut(src, pos, stop) }
	}

	## The text up to the first of `stops` outside (), [] and strings, or to the end.
	until : List(U8), U64, List(U8) -> { pos : U64, out : Str }
	until = |src, pos, stops| {
		var $pos = pos
		var $depth = Styles.zero
		var $going = Bool.True
		while $going and $pos < src.len() {
			c = Text.at(src, $pos)
			if $depth == 0 and stops.contains(c) {
				$going = Bool.False
			} else {
				if c == '\\' {
					$pos = $pos + 1
				} else if c == '"' or c == '\'' {
					$pos = Styles.string_end(src, $pos) - 1
				} else if c == '(' or c == '[' {
					$depth = $depth + 1
				} else if c == ')' or c == ']' {
					$depth = if ($depth > 0) $depth - 1 else 0
				}
				$pos = $pos + 1
			}
		}
		{ pos: $pos, out: Text.cut(src, pos, $pos) }
	}

	## Rules and at-rules up to an unmatched `}` or the end, and in a rule (`nested`) declarations too.
	## `global`: in a `:global { … }` block, where selectors stay as written.
	items : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, U64, { nested : Bool, global : Bool } -> Try({ pos : U64, out : Str }, [Fail({ reason : Str, at : U64 })])
	items = |ctx, start_pos, context| {
		src = ctx.src
		var $pos = start_pos
		var $out = ""
		while $pos <= src.len() {
			spaced = Styles.space(src, $pos)
			$out = $out.concat(spaced.out)
			$pos = spaced.pos
			if $pos >= src.len() or Text.at(src, $pos) == '}' {
				return Ok({ pos: $pos, out: $out })
			}
			c = Text.at(src, $pos)
			if c == ';' {
				$out = $out.concat(";")
				$pos = $pos + 1
			} else if c == '@' {
				found = Styles.at_rule(ctx, $pos, context)?
				$out = $out.concat(found.out)
				$pos = found.pos
			} else {
				begin = $pos
				text = Styles.until(src, $pos, ['{', ';', '}'])
				$pos = text.pos
				if Text.at(src, $pos) == '{' {
					found = Styles.rule(ctx, text.out, begin, $pos + 1, context)?
					$out = $out.concat(found.out)
					$pos = found.pos
				} else {
					if !context.nested {
						return Err(Fail({ reason: "a declaration goes in a rule: ${Text.trim(text.out)}", at: begin }))
					}
					$out = $out.concat(Styles.declaration(ctx, text.out))
					if Text.at(src, $pos) == ';' {
						$out = $out.concat(";")
						$pos = $pos + 1
					}
				}
			}
		}
		Ok({ pos: $pos, out: $out })
	}

	## A block's items, then its `}` (`opened`: where it was opened, for when there is none).
	block : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, U64, U64, { nested : Bool, global : Bool } -> Try({ pos : U64, out : Str }, [Fail({ reason : Str, at : U64 })])
	block = |ctx, pos, opened, inner| {
		body = Styles.items(ctx, pos, inner)?
		if Text.at(ctx.src, body.pos) != '}' or body.pos >= ctx.src.len() {
			Err(Fail({ reason: "this { is never closed", at: opened }))
		} else {
			Ok({ pos: body.pos + 1, out: body.out })
		}
	}

	## `/^(\s*)(?:(.*?)\s+)?:global(\s*)$/s` on a rule's prelude: its lead, what comes before
	## `:global` (none: nothing does), and its trail.
	global_prelude : Str -> Try({ lead : Str, before : [Some(Str), None], trail : Str }, [NoMatch])
	global_prelude = |prelude| {
		bytes = prelude.to_utf8()
		core_end = Text.skip_space_back(bytes, bytes.len())
		if core_end < 7 or !Text.starts_with_at(bytes, ":global".to_utf8(), core_end - 7) {
			return Err(NoMatch)
		}
		g = core_end - 7
		lead_end = Text.skip_space(bytes, 0)
		trail = Text.cut(bytes, core_end, bytes.len())
		if lead_end >= g {
			Ok({ lead: Text.cut(bytes, 0, g), before: None, trail })
		} else {
			ws_start = Text.skip_space_back(bytes, g)
			if ws_start == g {
				Err(NoMatch)
			} else {
				Ok({ lead: Text.cut(bytes, 0, lead_end), before: Some(Text.cut(bytes, lead_end, ws_start)), trail })
			}
		}
	}

	## A rule, its `{` read (`pos` is after it): its selectors scoped, then its block.
	rule : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, Str, U64, U64, { nested : Bool, global : Bool } -> Try({ pos : U64, out : Str }, [Fail({ reason : Str, at : U64 })])
	rule = |ctx, prelude, start, pos, context| {
		if context.global {
			body = Styles.block(ctx, pos, start, { nested: Bool.True, global: Bool.True })?
			return Ok({ pos: body.pos, out: "${prelude}{${body.out}}" })
		}
		# `:global { … }`, and `.a :global { … }`: the rules inside stay as written.
		match Styles.global_prelude(prelude) {
			Ok(g) =>
				match g.before {
					None => {
						body = Styles.block(ctx, pos, start, { nested: context.nested, global: Bool.True })?
						Ok({ pos: body.pos, out: g.lead.concat(body.out) })
					}
					Some(before) => {
						if Styles.split_top_level(before, ',').len() > 1 {
							return Err(Fail({ reason: "`:global { … }` follows one selector, not a list", at: start }))
						}
						selected = Styles.selector(ctx, before, context, start)?
						body = Styles.block(ctx, pos, start, { nested: Bool.True, global: Bool.True })?
						Ok({ pos: body.pos, out: "${g.lead}${selected}${g.trail}{${body.out}}" })
					}
				}
			Err(_) => {
				selectors = Styles.split_top_level(prelude, ',').map_try(|one| Styles.selector(ctx, one, context, start))?
				body = Styles.block(ctx, pos, start, { nested: Bool.True, global: Bool.False })?
				Ok({ pos: body.pos, out: "${Str.join_with(selectors, ",")}{${body.out}}" })
			}
		}
	}

	## One selector of a list, scoped; the whitespace around it kept.
	selector : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, Str, { nested : Bool, global : Bool }, U64 -> Try(Str, [Fail({ reason : Str, at : U64 })])
	selector = |ctx, text, context, start| {
		bytes = text.to_utf8()
		lead_end = Text.skip_space(bytes, 0)
		body_end = if (lead_end >= bytes.len()) lead_end else Text.skip_space_back(bytes, bytes.len())
		lead = Text.cut(bytes, 0, lead_end)
		body = Text.cut(bytes, lead_end, body_end)
		trail = Text.cut(bytes, body_end, bytes.len())
		if body.is_empty() {
			return Err(Fail({ reason: "a selector is empty", at: start }))
		}
		all = Styles.compounds(body)
		combinator_at = |list, i|
			match list.get(i) {
				Ok(Combinator(c)) => Some(c)
				_ => None
			}
		# `.a :global .b`: what comes after `:global` stays as written.
		split =
			match all.find_first_index(|part| part == Compound(":global")) {
				Ok(at) => {
					before = if (at == 0) None else combinator_at(all, at - 1)
					after = combinator_at(all, at + 1)
					is_plain = |c|
						match c {
							Some(c_text) => c_text == " "
							None => Bool.False
						}
					is_some = |c|
						match c {
							Some(_) => Bool.True
							None => Bool.False
						}
					if is_some(before) and is_some(after) and !is_plain(before) and !is_plain(after) {
						return Err(Fail({ reason: "`:global` stands between two combinators", at: start }))
					}
					rest0 = all.drop_first(at + 1)
					parts0 = all.take_first(at)
					# One combinator for the two around `:global`: the one that says something (`>`, `+`, `~`).
					if is_some(before) and is_some(after) {
						if (is_plain(before)) { parts: parts0.drop_last(1), rest: rest0 } else { parts: parts0, rest: rest0.drop_first(1) }
					} else if is_some(before) {
						{ parts: parts0.drop_last(1), rest: rest0 }
					} else if is_plain(combinator_at(rest0, 0)) {
						{ parts: parts0, rest: rest0.drop_first(1) }
					} else {
						{ parts: parts0, rest: rest0 }
					}
				}
				Err(_) => { parts: all, rest: [] }
			}
		# In a nested rule, the rule around it has the class already.
		var $bumped = context.nested
		var $scoped = ""
		for part in split.parts {
			match part {
				Combinator(c) => {
					$scoped = $scoped.concat(c)
				}
				Compound(compound) => {
					cbytes = compound.to_utf8()
					if cbytes.contains('&') {
						$scoped = $scoped.concat(compound)
					} else {
						global_at = Text.index_of(cbytes, ":global(".to_utf8(), 0)
						plain_result =
							match global_at {
								Ok(gi) =>
									match Styles.parenthesised(cbytes, gi + 7) {
										Ok(found) =>
											if gi == 0 and found.close == cbytes.len() - 1 {
												Whole(found.inner)
											} else {
												Plain(Text.slice(cbytes, 0, gi).concat(found.inner).concat(Text.slice(cbytes, found.close + 1, cbytes.len())))
											}
										Err(_) => return Err(Fail({ reason: "this :global( is never closed", at: start }))
									}
								Err(_) => Plain(cbytes)
							}
						match plain_result {
							Whole(inner) => {
								$scoped = $scoped.concat(Str.from_utf8_lossy(inner))
							}
							Plain(plain) => {
								position = Styles.class_position(plain)
								added = if ($bumped) ":where(.${ctx.scope})" else ".${ctx.scope}"
								$bumped = Bool.True
								$scoped = $scoped.concat(Text.cut(plain, 0, position)).concat(added).concat(Text.cut(plain, position, plain.len()))
							}
						}
					}
				}
			}
		}
		rest_text = split.rest.fold(
			"",
			|acc, part|
				match part {
					Combinator(c) => acc.concat(c)
					Compound(c) => acc.concat(c)
				},
		)
		Ok("${lead}${$scoped}${rest_text}${trail}")
	}

	## A declaration, with this file's keyframes named as their scoped names in `animation`.
	declaration : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, Str -> Str
	declaration = |ctx, text| {
		bytes = text.to_utf8()
		match Text.index_of_byte(bytes, ':', 0) {
			Err(_) => text
			Ok(colon) =>
				if ctx.keyframes.is_empty() {
					text
				} else {
					property = Text.lower(Text.trim(Text.cut(bytes, 0, colon)))
					if !Styles.is_animation_property(property) {
						text
					} else {
						Text.cut(bytes, 0, colon + 1).concat(Styles.rename_keyframes(ctx.keyframes, Text.slice(bytes, colon + 1, bytes.len())))
					}
				}
		}
	}

	## `/^(-[a-z]+-)?animation(-name)?$/`.
	is_animation_property : Str -> Bool
	is_animation_property = |property| {
		bytes = property.to_utf8()
		start =
			if Text.at(bytes, 0) == '-' {
				letters = Text.run_end(bytes, 1, Text.is_lower)
				if (letters > 1 and Text.at(bytes, letters) == '-') letters + 1 else 0
			} else {
				0
			}
		rest = Text.cut(bytes, start, bytes.len())
		rest == "animation" or rest == "animation-name"
	}

	## A value's names (`/(^|[\s,])([A-Za-z_-][\w-]*)(?=$|[\s,!])/g`) that are this file's
	## keyframes, as their scoped names.
	rename_keyframes : List({ key : Str, value : Str }), List(U8) -> Str
	rename_keyframes = |keyframes, value| {
		name_at = |p| {
			if Styles.is_name_start(Text.at(value, p)) and p < value.len() {
				stop = Text.run_end(value, p + 1, Styles.is_name_part)
				next = Text.at(value, stop)
				if (stop >= value.len() or next == ',' or next == '!' or Text.is_space_at(value, stop)) Ok(stop) else Err(NoMatch)
			} else {
				Err(NoMatch)
			}
		}
		renamed = |p, stop| {
			name = Text.cut(value, p, stop)
			match Styles.lookup(keyframes, name) {
				Some(scoped) => scoped
				None => name
			}
		}
		var $out = ""
		var $copied = 0
		var $p = 0
		while $p < value.len() {
			first =
				if $p == 0 {
					match name_at(0) {
						Ok(stop) => Ok({ name_start: 0, stop })
						Err(_) => Err(NoMatch)
					}
				} else {
					Err(NoMatch)
				}
			found =
				match first {
					Ok(m) => Ok(m)
					Err(_) => {
						sep = if (Text.at(value, $p) == ',') 1 else Text.space_at(value, $p)
						if sep > 0 {
							match name_at($p + sep) {
								Ok(stop) => Ok({ name_start: $p + sep, stop })
								Err(_) => Err(NoMatch)
							}
						} else {
							Err(NoMatch)
						}
					}
				}
			match found {
				Ok(m) => {
					$out = $out.concat(Text.cut(value, $copied, m.name_start)).concat(renamed(m.name_start, m.stop))
					$copied = m.stop
					$p = m.stop
				}
				Err(_) => {
					$p = $p + 1
				}
			}
		}
		$out.concat(Text.cut(value, $copied, value.len()))
	}

	## An at-rule: its block scoped if it holds rules, as written if it holds declarations.
	at_rule : { src : List(U8), scope : Str, keyframes : List({ key : Str, value : Str }) }, U64, { nested : Bool, global : Bool } -> Try({ pos : U64, out : Str }, [Fail({ reason : Str, at : U64 })])
	at_rule = |ctx, start, context| {
		src = ctx.src
		name_start = start + 1
		first_letter = if (Text.at(src, name_start) == '-') name_start + 1 else name_start
		if !Text.is_letter(Text.at(src, first_letter)) or first_letter >= src.len() {
			return Err(Fail({ reason: "an at-rule needs a name: @media, @keyframes…", at: start }))
		}
		name_end = Text.run_end(src, first_letter + 1, Styles.is_name_part)
		name = Text.cut(src, name_start, name_end)
		pre = Styles.until(src, name_end, ['{', ';', '}'])
		prelude = pre.out
		pos = pre.pos
		lowered = Text.lower(name)
		if Styles.refused_at_rules.contains(lowered) {
			return Err(Fail({ reason: "@${name} can't be in a file's <style>: rocx puts every file's in one stylesheet, and @${name} has to come first in one; write it in a stylesheet of the app's own", at: start }))
		}
		if Text.at(src, pos) != '{' or pos >= src.len() {
			# A statement (`@layer base, components;`).
			if Text.at(src, pos) != ';' or pos >= src.len() {
				return Ok({ pos, out: "@${name}${prelude}" })
			}
			return Ok({ pos: pos + 1, out: "@${name}${prelude};" })
		}
		inside = pos + 1
		if Styles.is_animation_keyframes(lowered) {
			given = Text.trim(prelude)
			named =
				if given.starts_with("-global-") {
					given.drop_prefix("-global-")
				} else {
					match Styles.lookup(ctx.keyframes, given) {
						Some(scoped) => scoped
						None => given
					}
				}
			body = Styles.verbatim(src, inside, start)?
			Ok({ pos: body.pos, out: "@${name} ${named} {${body.out}}" })
		} else if Styles.grouping_at_rules.contains(lowered) {
			body = Styles.block(ctx, inside, start, context)?
			Ok({ pos: body.pos, out: "@${name}${prelude}{${body.out}}" })
		} else {
			# @font-face, @page, @property, @counter-style…: declarations, which no selector scopes.
			body = Styles.verbatim(src, inside, start)?
			Ok({ pos: body.pos, out: "@${name}${prelude}{${body.out}}" })
		}
	}

	## `/^(-[a-z]+-)?keyframes$/i`, given the name in lower case.
	is_animation_keyframes : Str -> Bool
	is_animation_keyframes = |lowered| {
		bytes = lowered.to_utf8()
		start =
			if Text.at(bytes, 0) == '-' {
				letters = Text.run_end(bytes, 1, Text.is_lower)
				if (letters > 1 and Text.at(bytes, letters) == '-') letters + 1 else 0
			} else {
				0
			}
		Text.cut(bytes, start, bytes.len()) == "keyframes"
	}

	## A block's text as written, up to its `}` (read).
	verbatim : List(U8), U64, U64 -> Try({ pos : U64, out : Str }, [Fail({ reason : Str, at : U64 })])
	verbatim = |src, start, opened| {
		var $pos = start
		var $depth = Styles.zero
		while $pos < src.len() {
			c = Text.at(src, $pos)
			if c == '\\' {
				$pos = $pos + 1
			} else if c == '"' or c == '\'' {
				$pos = Styles.string_end(src, $pos) - 1
			} else if c == '{' {
				$depth = $depth + 1
			} else if c == '}' {
				if $depth == 0 {
					return Ok({ pos: $pos + 1, out: Text.cut(src, start, $pos) })
				}
				$depth = $depth - 1
			}
			$pos = $pos + 1
		}
		Err(Fail({ reason: "this { is never closed", at: opened }))
	}

	## `rocx internal`'s calls of this module's functions (rocx-cli/rocx.mjs names them), by name.
	rpc : Str, List(Value) -> Try(Value, [Failed(Value), Unknown(Str)])
	rpc = |name, args| {
		arg = |i| args.get(i) ?? Null
		match name {
			"scopeClass" => Ok(Text(Styles.scope_class(Value.str(arg(0)))))
			"scopeCss" =>
				match Styles.scope_css(Value.str(arg(0)), Value.str(arg(1))) {
					Ok(css) => Ok(Text(css))
					Err(Css(problem)) => Err(Failed(Object([{ key: "kind", value: Text("Error") }, { key: "message", value: Text(problem.reason) }, { key: "offset", value: Value.count(problem.offset) }])))
				}
			_ => Err(Unknown(name))
		}
	}
}
