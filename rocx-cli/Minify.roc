## JavaScript made smaller for a page to download: what `rocx build` ships as a page's runtime.js
## (`--client`, but not under `--dev`, whose runtime stays as it is written, to read and debug).
## Comments go, and indentation, and runs of spaces become one; line breaks stay, so nothing
## JavaScript inserts a semicolon at changes, and no name is shortened, so a stack trace still
## names the runtime's own functions. web/runtime.js, about 270 KB, is about 160 KB after, and half
## its brotli size (65 KB to 35 KB).
##
## A small tokenizer tells code from what must stay as it is: strings, template literals (and the
## code in their `${…}`), regular expressions (a `/` where a value can't end, as after `(`, `=` or
## `return`), and comments (gone; one with a line break in it is a line break).
import Text

Minify := [].{

	## The source, its comments and indentation gone.
	js : Str -> Str
	js = |source| {
		bytes = source.to_utf8()
		count = bytes.len()
		var $out = List.with_capacity(count)
		# Nothing but indentation on this line yet: what comes next starts the line.
		var $fresh = Bool.True
		# The last byte of code written (not a space), and the last word: whether a `/` starts a
		# regular expression or divides.
		var $last = 0.U8
		var $word = []
		# The template literals the code is inside (`${…}`): each one's open braces.
		var $templates = []
		var $i = 0
		while $i < count {
			c = Text.at(bytes, $i)
			next = Text.at(bytes, $i + 1)
			if c == '\n' or c == '\r' {
				$out = Minify.trimmed($out)
				if !$fresh {
					$out = $out.append('\n')
				}
				$fresh = Bool.True
				$i = $i + 1
			} else if c == ' ' or c == '\t' {
				if !$fresh and $out.last() != Ok(' ') {
					$out = $out.append(' ')
				}
				$i = $i + 1
			} else if c == '/' and next == '/' {
				while $i < count and Text.at(bytes, $i) != '\n' {
					$i = $i + 1
				}
			} else if c == '/' and next == '*' {
				close = Text.index_of(bytes, "*/".to_utf8(), $i + 2) ?? count
				broken = Text.index_of_byte(bytes, '\n', $i) ?? count
				if broken < close {
					# A comment with a line break in it ends a line, as JavaScript reads it.
					$out = Minify.trimmed($out)
					if !$fresh {
						$out = $out.append('\n')
					}
					$fresh = Bool.True
				} else if !$fresh and $out.last() != Ok(' ') {
					$out = $out.append(' ')
				}
				$i = close + 2
			} else if c == '"' or c == '\'' {
				ends = Minify.string_end(bytes, $i)
				$out = $out.concat(Text.slice(bytes, $i, ends))
				$fresh = Bool.False
				$last = c
				$word = []
				$i = ends
			} else if c == '`' {
				# A template literal, to its end or to the code in its next `${`.
				ends = Minify.template_end(bytes, $i + 1)
				$out = $out.concat(Text.slice(bytes, $i, ends.at))
				$fresh = Bool.False
				$last = '`'
				$word = []
				if ends.code {
					$templates = $templates.append(0.U64)
				}
				$i = ends.at
			} else if c == '}' and $templates.last() == Ok(0) {
				# The end of the code in a template literal's `${…}`: the literal goes on.
				$templates = $templates.drop_last(1)
				ends = Minify.template_end(bytes, $i + 1)
				$out = $out.concat(Text.slice(bytes, $i, ends.at))
				$last = '`'
				$word = []
				if ends.code {
					$templates = $templates.append(0.U64)
				}
				$i = ends.at
			} else if c == '/' and Minify.starts_regex($last, $word) {
				ends = Minify.regex_end(bytes, $i)
				$out = $out.concat(Text.slice(bytes, $i, ends))
				$fresh = Bool.False
				$last = '/'
				$word = []
				$i = ends
			} else {
				if c == '{' and !$templates.is_empty() {
					$templates = $templates.drop_last(1).append(($templates.last() ?? 0) + 1)
				} else if c == '}' and !$templates.is_empty() {
					$templates = $templates.drop_last(1).append(($templates.last() ?? 1) - 1)
				}
				$out = $out.append(c)
				$fresh = Bool.False
				$last = c
				$word = if (Minify.word_byte(c)) $word.append(c) else []
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy(Minify.trimmed($out))
	}

	## The output without the spaces at its end.
	trimmed : List(U8) -> List(U8)
	trimmed = |out| {
		var $end = out.len()
		while $end > 0 and (Text.at(out, $end - 1) == ' ' or Text.at(out, $end - 1) == '\t') {
			$end = $end - 1
		}
		if ($end == out.len()) out else Text.slice(out, 0, $end)
	}

	## Where the string that starts at `start` (its quote) ends: after its closing quote.
	string_end : List(U8), U64 -> U64
	string_end = |bytes, start| {
		quote = Text.at(bytes, start)
		var $i = start + 1
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\\' {
				$i = $i + 2
			} else if c == quote {
				return $i + 1
			} else {
				$i = $i + 1
			}
		}
		bytes.len()
	}

	## Where a template literal's text that starts at `start` ends: after its closing backtick
	## (`code` false), or after a `${` (`code` true: code comes next, to its `}`).
	template_end : List(U8), U64 -> { at : U64, code : Bool }
	template_end = |bytes, start| {
		var $i = start
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\\' {
				$i = $i + 2
			} else if c == '`' {
				return { at: $i + 1, code: Bool.False }
			} else if c == '$' and Text.at(bytes, $i + 1) == '{' {
				return { at: $i + 2, code: Bool.True }
			} else {
				$i = $i + 1
			}
		}
		{ at: bytes.len(), code: Bool.False }
	}

	## Where the regular expression that starts at `start` (its `/`) ends: after its flags. A `/`
	## inside a class (`[/]`) or escaped doesn't end it.
	regex_end : List(U8), U64 -> U64
	regex_end = |bytes, start| {
		var $i = start + 1
		var $class = Bool.False
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\\' {
				$i = $i + 2
			} else if c == '[' {
				$class = Bool.True
				$i = $i + 1
			} else if c == ']' {
				$class = Bool.False
				$i = $i + 1
			} else if c == '/' and !$class {
				var $end = $i + 1
				while $end < bytes.len() and Text.is_letter(Text.at(bytes, $end)) {
					$end = $end + 1
				}
				return $end
			} else if c == '\n' {
				return $i
			} else {
				$i = $i + 1
			}
		}
		bytes.len()
	}

	## Whether a `/` after `last` (the last byte of code; 0 at the start) and `word` (the last word,
	## if code ended with one) starts a regular expression: where a value can't end, it does.
	starts_regex : U8, List(U8) -> Bool
	starts_regex = |last, word|
		if !word.is_empty() {
			Minify.keywords.contains(Str.from_utf8_lossy(word))
		} else {
			last == 0 or "(,=:[!&|?{};+-*%<>~^".to_utf8().contains(last)
		}

	## The words after which a `/` starts a regular expression.
	keywords : List(Str)
	keywords = ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield", "await"]

	## A byte of a name or a number.
	word_byte : U8 -> Bool
	word_byte = |c| Text.is_alnum(c) or c == '_' or c == '$' or c >= 0x80
}

expect Minify.js("// a comment\nconst a = 1; // after\n\n\t\tif (a) {\n\t\t\treturn a  +  2;\n\t\t}\n") == "const a = 1;\nif (a) {\nreturn a + 2;\n}\n"
expect Minify.js("/** Doc.\n * More.\n */\nfunction f() {}\nconst x = 1 /* inline */ + 2;") == "function f() {}\nconst x = 1 + 2;"
expect Minify.js("a = 1 /* line\nbreak */ b = 2") == "a = 1\nb = 2"
expect Minify.js("s = \"// not a comment\"; t = 'it\\'s /* kept */';") == "s = \"// not a comment\"; t = 'it\\'s /* kept */';"
expect Minify.js("u = `line one\n    // kept, indented\n\${ a + `inner \${b}` }  /* kept */ `;") == "u = `line one\n    // kept, indented\n\${ a + `inner \${b}` }  /* kept */ `;"
expect Minify.js("t = `\${ { a: 1 }.a } and \${x}`; // gone") == "t = `\${ { a: 1 }.a } and \${x}`;"
expect Minify.js("r = /https?:\\/\\/[^/]+/g.test(u); // gone") == "r = /https?:\\/\\/[^/]+/g.test(u);"
expect Minify.js("x = a / b / c; y = (a) / 2;") == "x = a / b / c; y = (a) / 2;"
expect Minify.js("return /\\s+/.exec(x);") == "return /\\s+/.exec(x);"
expect Minify.js("if (!/^\\d+$/.test(s)) f();") == "if (!/^\\d+$/.test(s)) f();"
expect Minify.js("const n = total/2; // half") == "const n = total/2;"
