## Colours for code: `.rocx` and Roc source (which start in code), or HTML (which starts among
## children). A small state machine over the bytes, with a stack of what it is inside: Roc code,
## a tag's attributes, an element's children, or a <script>'s raw text. Like rocx itself, `<`
## starts a tag only where an expression could begin.
Highlight := [].{
	Token : { kind : Str, text : Str }

	## The tokens of `source`, line by line. A token's `kind` names its colour ("" is plain).
	lines : Str, [Code, Markup] -> List(List(Token))
	lines = |source, start| {
		bytes = source.to_utf8()
		first = match start {
			Code => Roc(0)
			Markup => Children("")
		}
		var $state = { i: 0, stack: [first], out: [] }
		while $state.i < bytes.len() {
			before = $state.i
			stepped = step(bytes, $state)
			# Every step moves on; this only guards against a mistake here hanging a page.
			$state = if (stepped.i > before) stepped else emit(stepped, bytes, "", before, before + 1)
		}
		split_lines($state.out)
	}
}

Frame : [Roc(U64), Tag({ name : Str, closing : Bool }), Children(Str), Raw(Str)]

State : { i : U64, stack : List(Frame), out : List(Highlight.Token) }

step : List(U8), State -> State
step = |bytes, state|
	match state.stack.last() {
		Ok(Roc(depth)) => code_step(bytes, state, depth)
		Ok(Tag(tag)) => tag_step(bytes, state, tag)
		Ok(Children(_)) => children_step(bytes, state)
		Ok(Raw(name)) => raw_step(bytes, state, name)
		Err(_) => code_step(bytes, { ..state, stack: [Roc(0)] }, 0)
	}

keywords : List(Str)
keywords = ["if", "else", "match", "import", "expect", "var", "for", "in", "while", "return", "crash", "dbg", "as", "app", "package", "platform", "module", "where"]

## Words after which `<` starts markup, as rocx has them.
before_expression : List(Str)
before_expression = ["else", "return", "crash", "expect", "dbg", "in"]

void_elements : List(Str)
void_elements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

code_step : List(U8), State, U64 -> State
code_step = |bytes, state, depth| {
	i = state.i
	b = at(bytes, i)
	next = at(bytes, i + 1)
	if b == '#' {
		emit(state, bytes, "comment", i, until(bytes, i, |c| c == '\n'))
	} else if b == '"' {
		emit(state, bytes, "string", i, string_end(bytes, i))
	} else if b == '\'' and at(bytes, i + 2) == '\'' {
		emit(state, bytes, "string", i, i + 3)
	} else if b == '<' and tag_follows(bytes, i) and markup_can_start(bytes, i) {
		open_tag(bytes, state)
	} else if b == '{' {
		emit(replace_top(state, Roc(depth + 1)), bytes, "punct", i, i + 1)
	} else if b == '}' and depth == 0 and state.stack.len() > 1 {
		emit(pop(state), bytes, "hole", i, i + 1)
	} else if b == '}' {
		emit(replace_top(state, Roc(if (depth > 0) depth - 1 else 0)), bytes, "punct", i, i + 1)
	} else if is_letter(b) or b == '_' or b == '$' {
		end = until(bytes, i, |c| !is_ident(c))
		word = Str.from_utf8_lossy(bytes.sublist({ start: i, len: end - i }))
		kind =
			if keywords.contains(word) {
				"keyword"
			} else if b >= 'A' and b <= 'Z' {
				"type"
			} else if at(bytes, end) == '(' {
				"call"
			} else {
				""
			}
		emit(state, bytes, kind, i, end)
	} else if b >= '0' and b <= '9' {
		emit(state, bytes, "number", i, until(bytes, i, |c| !(is_ident(c) or c == '.')))
	} else if (b == '=' or b == '-') and next == '>' {
		emit(state, bytes, "op", i, i + 2)
	} else if b == '|' or b == '?' or b == '!' or b == '=' or b == ':' {
		emit(state, bytes, "op", i, i + 1)
	} else {
		emit(state, bytes, "", i, until(bytes, i + 1, |c| !is_space(c) or c == '\n'))
	}
}

tag_step : List(U8), State, { name : Str, closing : Bool } -> State
tag_step = |bytes, state, tag| {
	i = state.i
	b = at(bytes, i)
	if is_space(b) {
		emit(state, bytes, "", i, until(bytes, i, |c| !is_space(c)))
	} else if b == '/' and at(bytes, i + 1) == '>' {
		emit(pop(state), bytes, "punct", i, i + 2)
	} else if b == '>' {
		after = pop(state)
		inner =
			if tag.closing {
				# The closing tag ends the element: its children go too.
				pop(after)
			} else if void_elements.contains(tag.name) {
				after
			} else if tag.name == "script" or tag.name == "style" {
				push(after, Raw(tag.name))
			} else {
				push(after, Children(tag.name))
			}
		emit(inner, bytes, "punct", i, i + 1)
	} else if b == '"' or b == '\'' {
		emit(state, bytes, "string", i, past(bytes, i + 1, [b]))
	} else if b == '{' {
		emit(push(state, Roc(0)), bytes, "hole", i, i + 1)
	} else if b == '=' or b == '?' {
		emit(state, bytes, "op", i, i + 1)
	} else {
		emit(state, bytes, "attr", i, until(bytes, i, |c| is_space(c) or c == '=' or c == '>' or c == '/' or c == '?'))
	}
}

children_step : List(U8), State -> State
children_step = |bytes, state| {
	i = state.i
	b = at(bytes, i)
	next = at(bytes, i + 1)
	if b == '<' and next == '!' and at(bytes, i + 2) == '-' {
		emit(state, bytes, "comment", i, past(bytes, i, "-->".to_utf8()))
	} else if b == '<' and next == '/' {
		name_end = until(bytes, i + 2, |c| !(is_ident(c) or c == '-'))
		name = Str.from_utf8_lossy(bytes.sublist({ start: i + 2, len: name_end - i - 2 }))
		emit(emit(push(state, Tag({ name, closing: True })), bytes, "punct", i, i + 2), bytes, "tag", i + 2, name_end)
	} else if b == '<' and tag_follows(bytes, i) {
		open_tag(bytes, state)
	} else if b == '{' and next == '#' {
		emit(state, bytes, "comment", i, past(bytes, i, ['}']))
	} else if b == '{' {
		end = if (next == '=') i + 2 else if (next == '.' and at(bytes, i + 2) == '.' and at(bytes, i + 3) == '.') i + 4 else i + 1
		emit(push(state, Roc(0)), bytes, "hole", i, end)
	} else if b == '&' {
		end = until(bytes, i, |c| c == ';' or is_space(c) or c == '<')
		if (at(bytes, end) == ';') emit(state, bytes, "entity", i, end + 1) else emit(state, bytes, "text", i, i + 1)
	} else {
		emit(state, bytes, "text", i, until(bytes, i, |c| c == '<' or c == '{' or c == '&'))
	}
}

raw_step : List(U8), State, Str -> State
raw_step = |bytes, state, name| {
	closing = "</${name}".to_utf8()
	end = past(bytes, state.i, closing)
	stop = if (end >= closing.len() and bytes.sublist({ start: end - closing.len(), len: closing.len() }) == closing) end - closing.len() else end
	emit(replace_top(state, Children(name)), bytes, "text", state.i, stop)
}

## `<name`, `<>` or `<!doctype …>`, in code or among children.
open_tag : List(U8), State -> State
open_tag = |bytes, state| {
	i = state.i
	next = at(bytes, i + 1)
	if next == '>' {
		emit(push(state, Children("")), bytes, "punct", i, i + 2)
	} else if next == '!' {
		emit(state, bytes, "tag", i, past(bytes, i, ['>']))
	} else {
		name_end = until(bytes, i + 1, |c| !(is_ident(c) or c == '-'))
		name = Str.from_utf8_lossy(bytes.sublist({ start: i + 1, len: name_end - i - 1 }))
		kind = if (at(bytes, i + 1) >= 'A' and at(bytes, i + 1) <= 'Z') "type" else "tag"
		emit(emit(push(state, Tag({ name, closing: Bool.False })), bytes, "punct", i, i + 1), bytes, kind, i + 1, name_end)
	}
}

tag_follows : List(U8), U64 -> Bool
tag_follows = |bytes, i| {
	next = at(bytes, i + 1)
	is_letter(next) or next == '>' or next == '!'
}

## After a value (`a < b`, `f(x) < y`), `<` compares; first on a line, after `=`, `(`, `,`, `=>`,
## `|…|` or `else`, it starts markup.
markup_can_start : List(U8), U64 -> Bool
markup_can_start = |bytes, i| {
	var $back = i
	while $back > 0 and (at(bytes, $back - 1) == ' ' or at(bytes, $back - 1) == '\t') {
		$back = $back - 1
	}
	if $back == 0 {
		Bool.True
	} else {
		previous = at(bytes, $back - 1)
		if previous == '\n' {
			Bool.True
		} else if is_ident(previous) {
			var $start = $back - 1
			while $start > 0 and is_ident(at(bytes, $start - 1)) {
				$start = $start - 1
			}
			before_expression.contains(Str.from_utf8_lossy(bytes.sublist({ start: $start, len: $back - $start })))
		} else {
			!(previous == ')' or previous == ']' or previous == '}' or previous == '"' or previous == '\'')
		}
	}
}

string_end : List(U8), U64 -> U64
string_end = |bytes, i| {
	var $j = i + 1
	while $j < bytes.len() and at(bytes, $j) != '"' and at(bytes, $j) != '\n' {
		$j = if (at(bytes, $j) == '\\') $j + 2 else $j + 1
	}
	U64.min($j + 1, bytes.len())
}

emit : State, List(U8), Str, U64, U64 -> State
emit = |state, bytes, kind, from, stop|
	if stop <= from {
		state
	} else {
		# A token never ends inside a character: one that stopped after a character's first byte
		# (`…` is three) takes the rest of it, or each byte would decode to U+FFFD on its own.
		to = whole_character(bytes, stop)
		text = Str.from_utf8_lossy(bytes.sublist({ start: from, len: to - from }))
		out =
			match state.out.last() {
				Ok(last) if last.kind == kind => state.out.drop_last(1).append({ kind, text: last.text.concat(text) })
				_ => state.out.append({ kind, text })
			}
		{ ..state, i: to, out }
	}

## `index`, moved past the bytes that continue a character (`0b10xxxxxx`).
whole_character : List(U8), U64 -> U64
whole_character = |bytes, index|
	match bytes.get(index) {
		Ok(byte) if byte >= 0x80 and byte < 0xC0 => whole_character(bytes, index + 1)
		_ => index
	}

push : State, Frame -> State
push = |state, frame| { ..state, stack: state.stack.append(frame) }

pop : State -> State
pop = |state| { ..state, stack: state.stack.drop_last(1) }

replace_top : State, Frame -> State
replace_top = |state, frame| { ..state, stack: state.stack.drop_last(1).append(frame) }

at : List(U8), U64 -> U8
at = |bytes, i| bytes.get(i) ?? 0

is_letter : U8 -> Bool
is_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

is_ident : U8 -> Bool
is_ident = |b| is_letter(b) or (b >= '0' and b <= '9') or b == '_' or b == '!' or b == '$'

is_space : U8 -> Bool
is_space = |b| b == ' ' or b == '\t' or b == '\n' or b == '\r'

## The first index from `i` where `stop` holds, or the end.
until : List(U8), U64, (U8 -> Bool) -> U64
until = |bytes, i, stop| {
	var $j = i
	while $j < bytes.len() and !stop(at(bytes, $j)) {
		$j = $j + 1
	}
	$j
}

## Just past the first `needle` from `i`, or the end.
past : List(U8), U64, List(U8) -> U64
past = |bytes, i, needle| {
	var $j = i
	while $j < bytes.len() and bytes.sublist({ start: $j, len: needle.len() }) != needle {
		$j = $j + 1
	}
	U64.min($j + needle.len(), bytes.len())
}

split_lines : List(Highlight.Token) -> List(List(Highlight.Token))
split_lines = |tokens| {
	var $lines = [[]]
	for token in tokens {
		parts = token.text.split_on("\n")
		var $first = Bool.True
		for part in parts {
			$lines = if ($first) $lines else $lines.append([])
			$first = Bool.False
			$lines =
				if part.is_empty() {
					$lines
				} else {
					last = $lines.last() ?? []
					$lines.drop_last(1).append(last.append({ kind: token.kind, text: part }))
				}
		}
	}
	if ($lines.last() == Ok([]) and $lines.len() > 1) $lines.drop_last(1) else $lines
}

kinds : Str, [Code, Markup] -> List(Str)
kinds = |source, start| Highlight.lines(source, start).join_map(|line| line.map(|token| "${token.kind}:${token.text}"))

expect kinds("x = <a href={link}>Hi {name}</a> # done", Code) == [":x ", "op:=", ": ", "punct:<", "tag:a", ": ", "attr:href", "op:=", "hole:{", ":link", "hole:}", "punct:>", "text:Hi ", "hole:{", ":name", "hole:}", "punct:</", "tag:a", "punct:>", ": ", "comment:# done"]
expect kinds("y = a < b", Code) == [":y ", "op:=", ": a < b"]
expect kinds("<p>a &amp; b<br><!-- c --></p>", Markup) == ["punct:<", "tag:p", "punct:>", "text:a ", "entity:&amp;", "text: b", "punct:<", "tag:br", "punct:>", "comment:<!-- c -->", "punct:</", "tag:p", "punct:>"]
expect Highlight.lines("a\n\nb\n", Code).len() == 3
expect kinds("a … b", Code) == [":a … b"]
expect kinds("<script>if (a < b) {}</script>", Markup) == ["punct:<", "tag:script", "punct:>", "text:if (a < b) {}", "punct:</", "tag:script", "punct:>"]
expect kinds("<Pill on={x} />", Code) == ["punct:<", "type:Pill", ": ", "attr:on", "op:=", "hole:{", ":x", "hole:}", ": ", "punct:/>"]
