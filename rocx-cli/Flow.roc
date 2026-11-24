## D-070: a hole's `if` and `match`, taken apart. rocx writes a hole whose code is an `if` (with
## `else if`s) or a `match`, and whose condition or value reads what changes, as the part the
## branch that holds makes, made again only when another branch holds (as Solid's `<Show>` and
## `<Switch>` are). For that it needs the pieces: each condition and branch, each arm's pattern,
## guard and body, and the names a pattern binds. This finds them in the source, its markup (as
## rocx read it: `spans`) passed over whole, and strings, characters and comments too. Plain bytes in,
## byte ranges out: Transpile reads each piece as the Roc it is.
import Text

Flow := [].{

	## A significant token of a hole's code, outside its markup, strings and comments: a word, a
	## bracket, `=>`, `,` or a line's end, and how many brackets were open before it.
	Token : { kind : [Word(Str), Open(U8), Close(U8), Arrow, Comma, Newline], at : U64, depth : U64 }

	## A piece of the source, from `from` up to `to`.
	Piece : { from : U64, to : U64 }

	## An `if`: each condition (`(…)` as written, or what is between `if` and a block's `{`) and its
	## branch, and the last branch, `else`'s; in a hole, an `if` may have none (`{if open!() { … }}`:
	## nothing shows otherwise).
	Chain : { branches : List({ condition : Flow.Piece, parens : Bool, body : Flow.Piece }), otherwise : [Else(Flow.Piece), NoElse] }

	## A `match`: its value, and its arms, each a pattern, maybe a guard (`if …`), and a body.
	Arms : { value : Flow.Piece, arms : List({ pattern : Flow.Piece, guard : [Guard(Flow.Piece), NoGuard], body : Flow.Piece }) }

	## D-071: a hole's `.map`, the last call of its code (`todos!().map(|todo| <li key={todo.id}>…</li>)`):
	## the list before it, the row's names (its item's, and with `.map_with_index` its index's), the
	## row's code, and where `.map` is.
	Mapped : { list : Flow.Piece, item : Str, index : [Index(Str), NoIndex], body : Flow.Piece, at : U64 }

	## A row's key (D-071): the markup whose tag has it (where it starts; whether it is a component), and
	## its `key={…}`: where the attribute's name is and its code.
	Root : { at : U64, component : Bool, key : [Key({ name_at : U64, code : Flow.Piece }), NoKey] }

	## A name a pattern binds, where it is (`from`, `to`), and how it is written: plainly (`x`), as a
	## record's punned field (`{ x }`), as a list's rest (`..x`) or after `as` (`as x`, `as` at `as_at`).
	Binding : { name : Str, from : U64, to : U64, form : [Plain, Punned, Rest, As(U64)] }

	## The tokens from `from` up to `to`; markup (`spans`) passed over.
	tokens : List(U8), U64, U64, List(Flow.Piece) -> List(Flow.Token)
	tokens = |src, from, to, spans| {
		var $out = []
		var $i = from
		var $depth = 0
		while $i < to {
			c = Text.at(src, $i)
			at = $i
			match spans.find_first(|span| span.from == at) {
				Ok(span) => {
					$i = span.to
				}
				Err(_) => {
					if c == '#' or (c == '\\' and Text.at(src, $i + 1) == '\\') {
						$i = Text.line_end(src, $i)
					} else if c == '"' {
						$i = Flow.string_end(src, $i, to)
					} else if c == '\'' {
						$i = Flow.char_end(src, $i, to)
					} else if c == '(' or c == '[' or c == '{' {
						$out = $out.append({ kind: Open(c), at, depth: $depth })
						$depth = $depth + 1
						$i = $i + 1
					} else if c == ')' or c == ']' or c == '}' {
						$depth = if ($depth > 0) $depth - 1 else 0
						$out = $out.append({ kind: Close(c), at, depth: $depth })
						$i = $i + 1
					} else if c == '=' and Text.at(src, $i + 1) == '>' {
						$out = $out.append({ kind: Arrow, at, depth: $depth })
						$i = $i + 2
					} else if c == ',' {
						$out = $out.append({ kind: Comma, at, depth: $depth })
						$i = $i + 1
					} else if c == '\n' {
						$out = $out.append({ kind: Newline, at, depth: $depth })
						$i = $i + 1
					} else if Text.is_letter(c) or c == '_' {
						end = Text.run_end(src, $i, Flow.is_word_part)
						$out = $out.append({ kind: Word(Text.cut(src, $i, end)), at, depth: $depth })
						$i = end
					} else if Text.is_digit(c) {
						$i = Text.run_end(src, $i, Flow.is_word_part)
					} else {
						$i = $i + 1
					}
				}
			}
		}
		$out
	}

	## A word's letters, digits, `_` and `!`.
	is_word_part : U8 -> Bool
	is_word_part = |c| Text.is_alnum(c) or c == '_' or c == '!'

	## Where a string that starts at `at` (`"`) ends: past its closing quote; `${…}` read through.
	string_end : List(U8), U64, U64 -> U64
	string_end = |src, at, to| {
		var $i = at + 1
		var $end = to
		var $going = Bool.True
		while $going and $i < to {
			c = Text.at(src, $i)
			if c == '\\' {
				$i = $i + 2
			} else if c == '"' {
				$end = $i + 1
				$going = Bool.False
			} else if c == '$' and Text.at(src, $i + 1) == '{' {
				$i = Flow.interpolation_end(src, $i + 2, to)
			} else {
				$i = $i + 1
			}
		}
		$end
	}

	## Where an interpolation's code (`${` read, its code from `at`) ends: past its `}`.
	interpolation_end : List(U8), U64, U64 -> U64
	interpolation_end = |src, at, to| {
		var $i = at
		var $depth = 1
		var $end = to
		while $depth > 0 and $i < to {
			c = Text.at(src, $i)
			if c == '"' {
				$i = Flow.string_end(src, $i, to)
			} else if c == '{' {
				$depth = $depth + 1
				$i = $i + 1
			} else if c == '}' {
				$depth = $depth - 1
				$i = $i + 1
				if $depth == 0 {
					$end = $i
				}
			} else {
				$i = $i + 1
			}
		}
		$end
	}

	## Where a character literal that starts at `at` (`'`) ends: past its closing quote.
	char_end : List(U8), U64, U64 -> U64
	char_end = |src, at, to| {
		var $i = at + 1
		if Text.at(src, $i) == '\\' {
			$i = $i + 2
		} else {
			$i = $i + 1
		}
		while $i < to and Text.at(src, $i) != '\'' {
			$i = $i + 1
		}
		if ($i < to) $i + 1 else to
	}

	## The token that closes the bracket opened by the token at `index`: the next `Close` as deep.
	closing : List(Flow.Token), U64 -> Try(U64, [NotFound])
	closing = |toks, index| {
		depth = (toks.get(index) ?? { kind: Comma, at: 0, depth: 0 }).depth
		var $i = index + 1
		var $found = Err(NotFound)
		while $i < toks.len() and $found == Err(NotFound) {
			token = toks.get($i) ?? { kind: Comma, at: 0, depth: 0 }
			match token.kind {
				Close(_) if token.depth == depth => {
					$found = Ok($i)
				}
				_ => {}
			}
			$i = $i + 1
		}
		$found
	}

	## The index of the first token at `depth`, from `start`, that `is` says is it.
	first_at : List(Flow.Token), U64, U64, (Flow.Token -> Bool) -> Try(U64, [NotFound])
	first_at = |toks, start, depth, is| {
		var $i = start
		var $found = Err(NotFound)
		while $i < toks.len() and $found == Err(NotFound) {
			token = toks.get($i) ?? { kind: Comma, at: 0, depth: 0 }
			if token.depth == depth and is(token) {
				$found = Ok($i)
			}
			$i = $i + 1
		}
		$found
	}

	## Whether the token is the word.
	is_word : Flow.Token, Str -> Bool
	is_word = |token, word|
		match token.kind {
			Word(w) => w == word
			_ => Bool.False
		}

	## The `if` the code from `from` up to `to` is, as a chain of branches, if it is one: `if`
	## first, a condition, a branch, `else`, and a last branch or another `if`.
	chain : List(U8), U64, U64, List(Flow.Piece) -> Try(Flow.Chain, [NotFlow])
	chain = |src, from, to, spans| {
		toks = Flow.tokens(src, from, to, spans)
		Flow.chain_from(src, toks, 0, to, [])
	}

	chain_from : List(U8), List(Flow.Token), U64, U64, List({ condition : Flow.Piece, parens : Bool, body : Flow.Piece }) -> Try(Flow.Chain, [NotFlow])
	chain_from = |src, toks, index, to, before| {
		first = toks.get(index) ?? { kind: Comma, at: 0, depth: 9 }
		if !Flow.is_word(first, "if") or first.depth != 0 {
			return Err(NotFlow)
		}
		after_if = Text.skip_space(src, first.at + 2)
		next = toks.get(index + 1) ?? { kind: Comma, at: 0, depth: 9 }
		# `if (…) branch`, unless the condition goes on after its `)` (`if (a) and b {`).
		parenthesized =
			match next.kind {
				Open('(') if next.at == after_if =>
					match Flow.closing(toks, index + 1) {
						Ok(close) => {
							close_at = (toks.get(close) ?? first).at
							if (Flow.goes_on(src, close_at + 1, to)) Err(NotFound) else Ok(close)
						}
						Err(_) => Err(NotFound)
					}
				_ => Err(NotFound)
			}
		(condition, parens, body_from, body_index) =
			match parenthesized {
				Ok(close) => {
					close_at = (toks.get(close) ?? first).at
					({ from: after_if, to: close_at + 1 }, Bool.True, close_at + 1, close + 1)
				}
				Err(_) =>
					match Flow.first_at(toks, index + 1, 0, |t| t.kind == Open('{')) {
						Ok(open) => {
							open_at = (toks.get(open) ?? first).at
							({ from: after_if, to: open_at }, Bool.False, open_at, open)
						}
						Err(_) => return Err(NotFlow)
					}
			}
		otherwise_index =
			match Flow.first_at(toks, body_index, 0, |t| Flow.is_word(t, "else")) {
				Ok(at) => at
				Err(_) => {
					# No `else`: the branch is the rest of the hole, and nothing shows otherwise.
					body = { from: body_from, to }
					if Flow.starts_with_word(src, body, "if") or Text.is_blank(Text.cut(src, condition.from, condition.to)) or Text.is_blank(Text.cut(src, body.from, body.to)) {
						return Err(NotFlow)
					}
					return Ok({ branches: before.append({ condition, parens, body }), otherwise: NoElse })
				}
			}
		else_at = (toks.get(otherwise_index) ?? first).at
		body = { from: body_from, to: else_at }
		# A branch that is an `if` of its own would take this `else` for its own: left as it is.
		if Flow.starts_with_word(src, body, "if") or Text.is_blank(Text.cut(src, condition.from, condition.to)) or Text.is_blank(Text.cut(src, body.from, body.to)) {
			return Err(NotFlow)
		}
		branches = before.append({ condition, parens, body })
		rest_from = Text.skip_space(src, else_at + 4)
		if Flow.starts_with_word(src, { from: rest_from, to }, "if") {
			Flow.chain_from(src, toks, otherwise_index + 1, to, branches)
		} else if Text.is_blank(Text.cut(src, else_at + 4, to)) {
			Err(NotFlow)
		} else {
			Ok({ branches, otherwise: Else({ from: else_at + 4, to }) })
		}
	}

	## Whether a condition goes on after a `)` at `at`: an operator or `and`/`or` next, not a branch.
	goes_on : List(U8), U64, U64 -> Bool
	goes_on = |src, at, to| {
		next = Text.skip_space(src, at)
		if next >= to {
			return Bool.False
		}
		c = Text.at(src, next)
		word = Text.cut(src, next, Text.run_end(src, next, Flow.is_word_part))
		markup = c == '<' and (Text.is_letter(Text.at(src, next + 1)) or Text.at(src, next + 1) == '>')
		word == "and" or word == "or" or (!markup and "=!<>+-*/%.?&|".to_utf8().contains(c))
	}

	## Whether the piece's code starts with the word, a word of its own.
	starts_with_word : List(U8), Flow.Piece, Str -> Bool
	starts_with_word = |src, piece, word| {
		at = Text.skip_space(src, piece.from)
		end = Text.run_end(src, at, Flow.is_word_part)
		at < piece.to and Text.cut(src, at, end) == word
	}

	## The `match` the code from `from` up to `to` is, if it is one: `match`, a value, and a block of
	## arms, with nothing after it. Arms are on lines of their own, or after a `,`.
	arms : List(U8), U64, U64, List(Flow.Piece) -> Try(Flow.Arms, [NotFlow])
	arms = |src, from, to, spans| {
		toks = Flow.tokens(src, from, to, spans)
		first = toks.get(0) ?? { kind: Comma, at: 0, depth: 9 }
		if !Flow.is_word(first, "match") or first.depth != 0 or first.at != Text.skip_space(src, from) {
			return Err(NotFlow)
		}
		open = Flow.first_at(toks, 1, 0, |t| t.kind == Open('{')) ?? return Err(NotFlow)
		close = Flow.closing(toks, open) ?? return Err(NotFlow)
		open_at = (toks.get(open) ?? first).at
		close_at = (toks.get(close) ?? first).at
		value = { from: first.at + 5, to: open_at }
		if !Text.is_blank(Text.cut(src, close_at + 1, to)) or Text.is_blank(Text.cut(src, value.from, value.to)) {
			return Err(NotFlow)
		}
		inside = toks.sublist({ start: open + 1, len: close - open - 1 }).keep_if(|t| t.depth == 1)
		arrows = inside.keep_if(|t| t.kind == Arrow)
		if arrows.is_empty() {
			return Err(NotFlow)
		}
		var $arms = []
		var $pattern_from = open_at + 1
		var $i = 0
		while $i < arrows.len() {
			arrow = arrows.get($i) ?? first
			body_to =
				match arrows.get($i + 1) {
					Ok(next) => {
						# The next arm's pattern starts after the last `,` or line end before its `=>`.
						seps = inside.keep_if(|t| t.at > arrow.at and t.at < next.at and (t.kind == Comma or t.kind == Newline))
						match seps.last() {
							Ok(sep) => sep.at
							Err(_) => return Err(NotFlow)
						}
					}
					Err(_) => close_at
				}
			# The pattern from its first character: the line end before it is the arm's line.
			$pattern_from = Text.skip_space(src, $pattern_from)
			guard_at = inside.find_first(|t| t.at >= $pattern_from and t.at < arrow.at and Flow.is_word(t, "if"))
			(pattern, guard) =
				match guard_at {
					Ok(word) => ({ from: $pattern_from, to: word.at }, Guard({ from: word.at + 2, to: arrow.at }))
					Err(_) => ({ from: $pattern_from, to: arrow.at }, NoGuard)
				}
			body = { from: arrow.at + 2, to: body_to }
			if Text.is_blank(Text.cut(src, pattern.from, pattern.to)) or Text.is_blank(Text.cut(src, body.from, body.to)) {
				return Err(NotFlow)
			}
			$arms = $arms.append({ pattern, guard, body })
			$pattern_from = body_to + 1
			$i = $i + 1
		}
		Ok({ value, arms: $arms })
	}

	## The `.map` (or `.map_with_index`) the code from `from` up to `to` ends in, if it does (D-071):
	## `list.map(|name| row)`, the call last, nothing after its `)`; its lambda's names plain (no `!`).
	mapped : List(U8), U64, U64, List(Flow.Piece) -> Try(Flow.Mapped, [NotMapped])
	mapped = |src, from, to, spans| {
		toks = Flow.tokens(src, from, to, spans)
		none = { kind: Comma, at: 0, depth: 9 }
		var $found = Err(NotMapped)
		var $i = 0
		while $i + 1 < toks.len() {
			t = toks.get($i) ?? none
			next = toks.get($i + 1) ?? none
			word_len = if (Flow.is_word(t, "map")) 3 else if (Flow.is_word(t, "map_with_index")) 14 else 0
			if word_len > 0 and t.depth == 0 and t.at > from and Text.at(src, t.at - 1) == '.' and next.kind == Open('(') and next.at == t.at + word_len {
				$found = Ok($i)
			}
			$i = $i + 1
		}
		at = $found ?? return Err(NotMapped)
		word = toks.get(at) ?? none
		with_index = Flow.is_word(word, "map_with_index")
		open = toks.get(at + 1) ?? none
		close = toks.get(Flow.closing(toks, at + 1) ?? return Err(NotMapped)) ?? none
		list = { from, to: word.at - 1 }
		if !Text.is_blank(Text.cut(src, close.at + 1, to)) or Text.is_blank(Text.cut(src, list.from, list.to)) {
			return Err(NotMapped)
		}
		bar = Text.skip_space(src, open.at + 1)
		if Text.at(src, bar) != '|' {
			return Err(NotMapped)
		}
		bar_end = Text.index_of_byte(src, '|', bar + 1) ?? return Err(NotMapped)
		names = Text.cut(src, bar + 1, bar_end).split_on(",").map(Text.trim)
		plain = |name| !name.is_empty() and (Text.is_lower(Text.at(name.to_utf8(), 0)) or Text.at(name.to_utf8(), 0) == '_') and name.to_utf8().all(|c| Text.is_alnum(c) or c == '_')
		if bar_end >= close.at or !names.all(plain) or names.len() != (if (with_index) 2 else 1) {
			return Err(NotMapped)
		}
		item = names.get(0) ?? ""
		index = if (with_index) Index(names.get(1) ?? "") else NoIndex
		Ok({ list, item, index, body: { from: bar_end + 1, to: close.at }, at: word.at })
	}

	## A row's key (D-071): the first `key={…}` on its outermost markup's tags, in order (the row's root,
	## `<li key={todo.id}>`; or, where the row is an `if`, each branch's, `<a key={c.id}>` and `<button
	## key={c.id}>`). With none, where its first markup starts (`NoKey`); with no markup, `NoRoot`.
	root : List(U8), Flow.Piece, List(Flow.Piece) -> Try(Flow.Root, [NoRoot])
	root = |src, body, spans| {
		outer = spans.keep_if(|span| span.from >= body.from and span.to <= body.to and !spans.any(|other| other.from < span.from and span.to <= other.to and other.from >= body.from))
		first = outer.first() ?? return Err(NoRoot)
		var $found = Err(NotFound)
		for span in outer {
			if $found == Err(NotFound) and Text.at(src, span.from) == '<' {
				match Flow.tag_key(src, span) {
					Key(k) => {
						$found = Ok({ at: span.from, component: Text.is_upper(Text.at(src, span.from + 1)), key: Key(k) })
					}
					NoKey => {}
				}
			}
		}
		match $found {
			Ok(r) => Ok(r)
			Err(_) => Ok({ at: first.from, component: Text.is_upper(Text.at(src, first.from + 1)), key: NoKey })
		}
	}

	## The `key={…}` of the tag that opens the markup `span`, if it has one.
	tag_key : List(U8), Flow.Piece -> [Key({ name_at : U64, code : Flow.Piece }), NoKey]
	tag_key = |src, span| {
		name_end = Text.run_end(src, span.from + 1, |c| Text.is_alnum(c) or c == '_' or c == '.' or c == '-')
		var $i = name_end
		var $key = NoKey
		while $i < span.to and Text.at(src, $i) != '>' and !(Text.at(src, $i) == '/' and Text.at(src, $i + 1) == '>') {
			c = Text.at(src, $i)
			if c == '{' {
				$i = Flow.braces_end(src, $i, span.to)
			} else if c == '"' {
				$i = Flow.string_end(src, $i, span.to)
			} else if Text.is_letter(c) and !Flow.is_word_part(Text.at(src, $i - 1)) {
				word_end = Text.run_end(src, $i, |b| Text.is_alnum(b) or b == '_' or b == ':' or b == '-' or b == '!' or b == '?')
				if Text.cut(src, $i, word_end) == "key" and Text.at(src, word_end) == '=' and Text.at(src, word_end + 1) == '{' {
					close = Flow.braces_end(src, word_end + 1, span.to)
					$key = Key({ name_at: $i, code: { from: word_end + 2, to: close - 1 } })
				}
				$i = word_end
			} else {
				$i = $i + 1
			}
		}
		$key
	}

	## Where the braces opened at `at` (`{`) close: past their `}`, strings read through.
	braces_end : List(U8), U64, U64 -> U64
	braces_end = |src, at, to| {
		var $depth = 0
		var $i = at
		var $end = to
		var $going = Bool.True
		while $going and $i < to {
			c = Text.at(src, $i)
			if c == '"' {
				$i = Flow.string_end(src, $i, to)
			} else {
				if c == '{' {
					$depth = $depth + 1
				} else if c == '}' {
					$depth = $depth - 1
					if $depth == 0 {
						$end = $i + 1
						$going = Bool.False
					}
				}
				$i = $i + 1
			}
		}
		$end
	}

	## The names a pattern binds, from its source `pattern` (a tag's payload `Ok(user)`, a record's
	## fields `{ name, age: years }`, a list's items and rest `[first, ..rest]`, `as total`); not a
	## tag, a record's label, `_` or a name starting with `_`, nor what is in a string.
	bindings : Str -> List(Flow.Binding)
	bindings = |pattern| {
		src = pattern.to_utf8()
		var $out = []
		var $i = 0
		# Each open bracket's character, innermost last: a punned field is a `{`'s.
		var $open = []
		var $as_at = Err(None)
		while $i < src.len() {
			c = Text.at(src, $i)
			if c == '"' {
				$i = Flow.string_end(src, $i, src.len())
			} else if c == '\'' {
				$i = Flow.char_end(src, $i, src.len())
			} else if c == '(' or c == '[' or c == '{' {
				$open = $open.append(c)
				$i = $i + 1
			} else if c == ')' or c == ']' or c == '}' {
				$open = $open.drop_last(1)
				$i = $i + 1
			} else if Text.is_upper(c) {
				$i = Text.run_end(src, $i, Flow.is_word_part)
			} else if Text.is_lower(c) or c == '_' {
				end = Text.run_end(src, $i, Flow.is_word_part)
				word = Text.cut(src, $i, end)
				before = Text.skip_space_back(src, $i)
				prev = if (before > 0) Text.at(src, before - 1) else ' '
				next = Text.at(src, Text.skip_space(src, end))
				rest = before >= 2 and prev == '.' and Text.at(src, before - 2) == '.'
				if word == "as" {
					$as_at = Ok($i)
				} else if word.starts_with("_") or (prev == '.' and !rest) or next == ':' {
					{}
				} else {
					form =
						match $as_at {
							Ok(at) => As(at)
							Err(_) =>
								if rest {
									Rest
								} else if $open.last() == Ok('{') and (prev == '{' or prev == ',') and (next == ',' or next == '}') {
									Punned
								} else {
									Plain
								}
						}
					$out = $out.append({ name: word, from: $i, to: end, form })
					$as_at = Err(None)
				}
				$i = end
			} else {
				$i = $i + 1
			}
		}
		$out
	}

	## The pattern with only the names in `keep` bound: each other name `_` (`{ name }`'s `name: _`,
	## a rest's name gone, `as total` gone), so that a pattern matches as it did and binds no name
	## that would go unused.
	keeping : Str, List(Str) -> Str
	keeping = |pattern, keep| {
		src = pattern.to_utf8()
		var $out = ""
		var $copied = 0
		for binding in Flow.bindings(pattern) {
			if !keep.contains(binding.name) {
				(cut_from, written) =
					match binding.form {
						Plain => (binding.from, "_")
						Punned => (binding.from, "${binding.name}: _")
						Rest => (binding.from, "")
						As(at) => (Text.skip_space_back(src, at), "")
					}
				$out = $out.concat(Text.cut(src, $copied, cut_from)).concat(written)
				$copied = binding.to
			}
		}
		$out.concat(Text.cut(src, $copied, src.len()))
	}

	## The names of `bindings` that `code` uses, as words of their own.
	used_in : Str, List(Str) -> List(Str)
	used_in = |code, names| {
		src = code.to_utf8()
		var $out = []
		var $i = 0
		while $i < src.len() {
			c = Text.at(src, $i)
			if Text.is_letter(c) or c == '_' {
				end = Text.run_end(src, $i, Flow.is_word_part)
				word = Text.cut(src, $i, end)
				prev = if ($i > 0) Text.at(src, $i - 1) else ' '
				if prev != '.' and names.contains(word) and !$out.contains(word) {
					$out = $out.append(word)
				}
				$i = end
			} else if c == '"' {
				$i = Flow.string_end(src, $i, src.len())
			} else {
				$i = $i + 1
			}
		}
		$out
	}
}

expect {
	src = "if (count!() > 3) <Timer /> else <></>".to_utf8()
	spans = [{ from: 18, to: 27 }, { from: 33, to: 38 }]
	match Flow.chain(src, 0, src.len(), spans) {
		Ok(chain) => chain.branches.len() == 1 and Text.cut(src, (chain.branches.get(0) ?? { condition: { from: 0, to: 0 }, parens: Bool.False, body: { from: 0, to: 0 } }).condition.from, 17) == "(count!() > 3)" and (
			match chain.otherwise {
				Else(piece) => Text.trim(Text.cut(src, piece.from, piece.to)) == "<></>"
				NoElse => Bool.False
			}
		)
		Err(_) => Bool.False
	}
}

expect {
	src = "if a!() and b { x } else if c!() { y } else { z }".to_utf8()
	match Flow.chain(src, 0, src.len(), []) {
		Ok(chain) => chain.branches.len() == 2 and chain.branches.map(|b| Text.trim(Text.cut(src, b.condition.from, b.condition.to))) == ["a!() and b", "c!()"] and chain.branches.map(|b| Text.trim(Text.cut(src, b.body.from, b.body.to))) == ["{ x }", "{ y }"] and (
			match chain.otherwise {
				Else(piece) => Text.trim(Text.cut(src, piece.from, piece.to)) == "{ z }"
				NoElse => Bool.False
			}
		)
		Err(_) => Bool.False
	}
}

# A condition with "else" in a string, and a branch that is an `if` of its own (left as it is).
expect {
	src = "if (s!() == \"else\") \"a\" else \"b\"".to_utf8()
	Flow.chain(src, 0, src.len(), []).is_ok()
}

expect {
	src = "if (a!()) if (b) x else y else z".to_utf8()
	Flow.chain(src, 0, src.len(), []) == Err(NotFlow)
}

# No `else`, in a hole: the last branch is the rest, and nothing shows otherwise.
expect {
	src = "if open!() { <p>Open</p> }".to_utf8()
	spans = [{ from: 13, to: 24 }]
	match Flow.chain(src, 0, src.len(), spans) {
		Ok(chain) => chain.otherwise == NoElse and chain.branches.map(|b| Text.trim(Text.cut(src, b.body.from, b.body.to))) == ["{ <p>Open</p> }"]
		Err(_) => Bool.False
	}
}

expect {
	src = "if (a!()) <i /> else if (b!()) <u />".to_utf8()
	spans = [{ from: 10, to: 15 }, { from: 31, to: 36 }]
	match Flow.chain(src, 0, src.len(), spans) {
		Ok(chain) => chain.otherwise == NoElse and chain.branches.len() == 2
		Err(_) => Bool.False
	}
}

expect {
	src = "match user!() {\n\tOk({ name, age: years }) if years > 17 =>\n\t\tname\n\tErr(_) => \"nobody\"\n}".to_utf8()
	match Flow.arms(src, 0, src.len(), []) {
		Ok(found) => {
			texts = found.arms.map(|arm| Text.trim(Text.cut(src, arm.pattern.from, arm.pattern.to)))
			bodies = found.arms.map(|arm| Text.trim(Text.cut(src, arm.body.from, arm.body.to)))
			guards = found.arms.map(
				|arm| match arm.guard {
					Guard(g) => Text.trim(Text.cut(src, g.from, g.to))
					NoGuard => ""
				},
			)
			texts == ["Ok({ name, age: years })", "Err(_)"] and bodies == ["name", "\"nobody\""] and guards == ["years > 17", ""] and Text.trim(Text.cut(src, found.value.from, found.value.to)) == "user!()"
		}
		Err(_) => Bool.False
	}
}

expect {
	src = "match tab!() { Home => \"h\", Settings(s) => s.title }".to_utf8()
	match Flow.arms(src, 0, src.len(), []) {
		Ok(found) => found.arms.map(|arm| Text.trim(Text.cut(src, arm.body.from, arm.body.to))) == ["\"h\"", "s.title"]
		Err(_) => Bool.False
	}
}

expect Flow.bindings("Ok({ name, age: years })").map(|b| b.name) == ["name", "years"]
expect Flow.bindings("[first, ..rest]").map(|b| b.name) == ["first", "rest"]
expect Flow.bindings("Point(x, _y) as p").map(|b| b.name) == ["x", "p"]
expect Flow.keeping("Ok({ name, age: years })", []) == "Ok({ name: _, age: _ })"
expect Flow.keeping("Ok({ name, age: years })", ["years"]) == "Ok({ name: _, age: years })"
expect Flow.keeping("[first, ..rest]", ["first"]) == "[first, ..]"
expect Flow.keeping("Point(x, _y) as p", ["x"]) == "Point(x, _y)"
expect Flow.used_in("years > 17 and name.len() > 0", ["name", "years", "age"]) == ["years", "name"]

# D-071: a hole's `.map`, its list, names and row; its row's root and key.
expect {
	src = "todos!().keep_if(|t| t.open).map(|todo| <li key={todo.id}>{todo.title}</li>)".to_utf8()
	spans = [{ from: 40, to: 75 }]
	match Flow.mapped(src, 0, src.len(), spans) {
		Ok(found) => {
			list_ok = Text.cut(src, found.list.from, found.list.to) == "todos!().keep_if(|t| t.open)"
			row_ok = Text.trim(Text.cut(src, found.body.from, found.body.to)) == "<li key={todo.id}>{todo.title}</li>"
			root_ok =
				match Flow.root(src, found.body, spans) {
					Ok({ component, key: Key({ code, .. }), .. }) => !component and Text.cut(src, code.from, code.to) == "todo.id"
					_ => Bool.False
				}
			list_ok and row_ok and found.item == "todo" and found.index == NoIndex and root_ok
		}
		Err(_) => Bool.False
	}
}

expect {
	src = "names!().map_with_index(|name, i| <Row key={i} name={name} />)".to_utf8()
	match Flow.mapped(src, 0, src.len(), [{ from: 34, to: 61 }]) {
		Ok(found) => found.item == "name" and found.index == Index("i")
		Err(_) => Bool.False
	}
}

# Not a `.map` last: something after it, or a lambda with a `!` name.
expect Flow.mapped("xs!().map(|x| x).len()".to_utf8(), 0, 22, []) == Err(NotMapped)
expect Flow.mapped("xs!().map(|x!| x)".to_utf8(), 0, 17, []) == Err(NotMapped)
