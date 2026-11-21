## What both parsers ask of the bytes: which characters are spaces or punctuation (Unicode's, as
## far as emphasis needs them), backslash escapes and entities (`&amp;`, `&#35;`), the label a
## reference is found by, and where an HTML tag, comment or declaration ends. Not exposed.
Chars := [].{

	## The byte at `i`, or 0 past the end.
	at : List(U8), U64 -> U8
	at = |bytes, i| bytes.get(i) ?? 0

	is_space_or_tab : U8 -> Bool
	is_space_or_tab = |b| b == ' ' or b == '\t'

	## A space, a tab, a line ending or a form feed: the whitespace Markdown means.
	is_whitespace : U8 -> Bool
	is_whitespace = |b| b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0C or b == 0x0B

	is_digit : U8 -> Bool
	is_digit = |b| b >= '0' and b <= '9'

	is_letter : U8 -> Bool
	is_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	is_alnum : U8 -> Bool
	is_alnum = |b| Chars.is_letter(b) or Chars.is_digit(b)

	## ASCII punctuation: what a backslash can escape.
	is_punct : U8 -> Bool
	is_punct = |b| (b >= '!' and b <= '/') or (b >= ':' and b <= '@') or (b >= '[' and b <= '`') or (b >= '{' and b <= '~')

	## Whether everything from `i` on is spaces and tabs.
	blank_from : List(U8), U64 -> Bool
	blank_from = |bytes, i| {
		var $j = i
		while $j < bytes.len() {
			if !Chars.is_whitespace(Chars.at(bytes, $j)) {
				return Bool.False
			}
			$j = $j + 1
		}
		Bool.True
	}

	## The first index from `i` where `stop` holds, or the end.
	until : List(U8), U64, (U8 -> Bool) -> U64
	until = |bytes, i, stop| {
		var $j = i
		while $j < bytes.len() and !stop(Chars.at(bytes, $j)) {
			$j = $j + 1
		}
		$j
	}

	## The bytes from `start` to `end`, as text.
	slice : List(U8), U64, U64 -> Str
	slice = |bytes, start, end| if (end <= start) "" else Str.from_utf8_lossy(bytes.sublist({ start, len: end - start }))

	## What the character before `i` is, for emphasis: whitespace (or the start), punctuation, or
	## something else.
	class_before : List(U8), U64 -> [Space, Punct, Other]
	class_before = |bytes, i|
		if i == 0 {
			Space
		} else {
			var $start = i - 1
			while $start > 0 and Chars.at(bytes, $start) >= 0x80 and Chars.at(bytes, $start) < 0xC0 {
				$start = $start - 1
			}
			class_of(decode(bytes, $start).code)
		}

	## What the character at `i` is: whitespace (or the end), punctuation, or something else.
	class_at : List(U8), U64 -> [Space, Punct, Other]
	class_at = |bytes, i| if (i >= bytes.len()) Space else class_of(decode(bytes, i).code)

	## A code point as UTF-8. One that isn't a character (0, a surrogate, past U+10FFFF) is U+FFFD.
	utf8 : U32 -> List(U8)
	utf8 = |code|
		if code == 0 or (code >= 0xD800 and code <= 0xDFFF) or code > 0x10FFFF {
			[0xEF, 0xBF, 0xBD]
		} else if code < 0x80 {
			[code.to_u8_wrap()]
		} else if code < 0x800 {
			[(0xC0 + code // 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else if code < 0x10000 {
			[(0xE0 + code // 4096).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else {
			[(0xF0 + code // 262144).to_u8_wrap(), (0x80 + (code // 4096) % 64).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		}

	## An entity or a numeric reference at `i` (which is `&`): what it stands for, and where it
	## ends. `&copy;`, `&#169;` and `&#xA9;` are ©; an unknown name is no entity.
	entity : List(U8), U64 -> Try({ text : List(U8), end : U64 }, [NotEntity])
	entity = |bytes, i| {
		if Chars.at(bytes, i + 1) == '#' {
			hex = Chars.at(bytes, i + 2) == 'x' or Chars.at(bytes, i + 2) == 'X'
			start = if (hex) i + 3 else i + 2
			digit = |b| if (hex) Chars.is_digit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F') else Chars.is_digit(b)
			end = Chars.until(bytes, start, |b| !digit(b))
			count = end - start
			if count == 0 or count > (if (hex) 6 else 7) or Chars.at(bytes, end) != ';' {
				Err(NotEntity)
			} else {
				var $code = 0
				for b in bytes.sublist({ start, len: count }) {
					value = if (b <= '9') b - '0' else if (b >= 'a') b - 'a' + 10 else b - 'A' + 10
					$code = $code * (if (hex) 16 else 10) + value.to_u32()
				}
				Ok({ text: Chars.utf8($code), end: end + 1 })
			}
		} else {
			end = Chars.until(bytes, i + 1, |b| !Chars.is_alnum(b))
			if end == i + 1 or Chars.at(bytes, end) != ';' {
				Err(NotEntity)
			} else {
				name = Chars.slice(bytes, i + 1, end)
				match entities.find_first(|(known, _)| known == name) {
					Ok((_, text)) => Ok({ text: text.to_utf8(), end: end + 1 })
					Err(_) => Err(NotEntity)
				}
			}
		}
	}

	## Backslash escapes and entities replaced: `\*` is `*`, `&amp;` is `&`. A link's destination
	## and title, and a code block's info string, are read this way.
	unescape : Str -> Str
	unescape = |text| {
		if !(text.contains("\\") or text.contains("&")) {
			return text
		}
		bytes = text.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = Chars.at(bytes, $i)
			if b == '\\' and Chars.is_punct(Chars.at(bytes, $i + 1)) {
				$out = $out.append(Chars.at(bytes, $i + 1))
				$i = $i + 2
			} else if b == '&' {
				match Chars.entity(bytes, $i) {
					Ok({ text: decoded, end }) => {
						$out = $out.concat(decoded)
						$i = end
					}
					Err(_) => {
						$out = $out.append(b)
						$i = $i + 1
					}
				}
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}

	## A reference's label as it is looked up: case folded, its runs of whitespace one space,
	## trimmed. The folding knows ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic, and `ß`.
	label_key : Str -> Str
	label_key = |label| {
		words = label.to_utf8().split_if(Chars.is_whitespace).keep_if(|word| !word.is_empty())
		folded = words.intersperse([' ']).join()
		if (folded.all(|b| b < 0x80)) Str.from_utf8_lossy(folded).with_ascii_lowercased() else fold_case(folded)
	}

	## Where an HTML open tag starting at `i` (`<`) ends: `<a href="x">`, `<br/>`.
	open_tag : List(U8), U64 -> Try(U64, [NotTag])
	open_tag = |bytes, i| {
		if Chars.at(bytes, i) != '<' or !Chars.is_letter(Chars.at(bytes, i + 1)) {
			return Err(NotTag)
		}
		var $j = tag_name_end(bytes, i + 1)
		var $going = Bool.True
		while $going {
			spaced = skip_whitespace(bytes, $j)
			match attribute(bytes, spaced) {
				Ok(end) if spaced > $j => {
					$j = end
				}
				_ => {
					$going = Bool.False
				}
			}
		}
		$j = skip_whitespace(bytes, $j)
		if Chars.at(bytes, $j) == '/' and Chars.at(bytes, $j + 1) == '>' {
			Ok($j + 2)
		} else if Chars.at(bytes, $j) == '>' {
			Ok($j + 1)
		} else {
			Err(NotTag)
		}
	}

	## Where an HTML closing tag starting at `i` ends: `</a>`.
	close_tag : List(U8), U64 -> Try(U64, [NotTag])
	close_tag = |bytes, i| {
		if Chars.at(bytes, i) != '<' or Chars.at(bytes, i + 1) != '/' or !Chars.is_letter(Chars.at(bytes, i + 2)) {
			return Err(NotTag)
		}
		j = skip_whitespace(bytes, tag_name_end(bytes, i + 2))
		if (Chars.at(bytes, j) == '>') Ok(j + 1) else Err(NotTag)
	}

	## Where any raw HTML starting at `i` ends, as Markdown finds it among text: a tag, a closing
	## tag, a comment, a processing instruction, a declaration or a CDATA section.
	raw_html : List(U8), U64 -> Try(U64, [NotTag])
	raw_html = |bytes, i| {
		next = Chars.at(bytes, i + 1)
		if Chars.is_letter(next) {
			Chars.open_tag(bytes, i)
		} else if next == '/' {
			Chars.close_tag(bytes, i)
		} else if next == '?' {
			after(bytes, i + 2, "?>")
		} else if next == '!' {
			third = Chars.at(bytes, i + 2)
			if third == '-' and Chars.at(bytes, i + 3) == '-' {
				# `<!-->` and `<!--->` are comments too.
				if Chars.at(bytes, i + 4) == '>' {
					Ok(i + 5)
				} else if Chars.at(bytes, i + 4) == '-' and Chars.at(bytes, i + 5) == '>' {
					Ok(i + 6)
				} else {
					after(bytes, i + 4, "-->")
				}
			} else if Chars.slice(bytes, i, i + 9) == "<![CDATA[" {
				after(bytes, i + 9, "]]>")
			} else if Chars.is_letter(third) {
				after(bytes, i + 2, ">")
			} else {
				Err(NotTag)
			}
		} else {
			Err(NotTag)
		}
	}

	## A link's destination at `i`: `<…>` (which may be empty), or text without spaces whose
	## parentheses balance. Its escapes and entities are replaced.
	destination : List(U8), U64 -> Try({ url : Str, end : U64 }, [NoDestination])
	destination = |bytes, i| {
		if Chars.at(bytes, i) == '<' {
			var $j = i + 1
			while $j < bytes.len() {
				b = Chars.at(bytes, $j)
				if b == '\\' and Chars.is_punct(Chars.at(bytes, $j + 1)) {
					$j = $j + 2
				} else if b == '>' {
					return Ok({ url: Chars.unescape(Chars.slice(bytes, i + 1, $j)), end: $j + 1 })
				} else if b == '<' or b == '\n' {
					return Err(NoDestination)
				} else {
					$j = $j + 1
				}
			}
			Err(NoDestination)
		} else {
			var $j = i
			var $depth = 0
			var $going = Bool.True
			while $going and $j < bytes.len() {
				b = Chars.at(bytes, $j)
				if b == '\\' and Chars.is_punct(Chars.at(bytes, $j + 1)) {
					$j = $j + 2
				} else if b == '(' {
					$depth = $depth + 1
					$j = $j + 1
				} else if b == ')' and $depth > 0 {
					$depth = $depth - 1
					$j = $j + 1
				} else if b == ')' or b <= ' ' or b == 0x7F {
					$going = Bool.False
				} else {
					$j = $j + 1
				}
			}
			if $j == i or $depth > 0 {
				Err(NoDestination)
			} else {
				Ok({ url: Chars.unescape(Chars.slice(bytes, i, $j)), end: $j })
			}
		}
	}

	## A link's title at `i`: in double or single quotes, or in parentheses. Its escapes and entities
	## are replaced.
	title : List(U8), U64 -> Try({ title : Str, end : U64 }, [NoTitle])
	title = |bytes, i| {
		open = Chars.at(bytes, i)
		close = if (open == '(') ')' else open
		if !(open == '"' or open == '\'' or open == '(') {
			return Err(NoTitle)
		}
		var $j = i + 1
		while $j < bytes.len() {
			b = Chars.at(bytes, $j)
			if b == '\\' and Chars.is_punct(Chars.at(bytes, $j + 1)) {
				$j = $j + 2
			} else if b == close {
				return Ok({ title: Chars.unescape(Chars.slice(bytes, i + 1, $j)), end: $j + 1 })
			} else if open == '(' and b == '(' {
				return Err(NoTitle)
			} else {
				$j = $j + 1
			}
		}
		Err(NoTitle)
	}

	## Past spaces and tabs from `i`, and at most one line ending.
	space_line : List(U8), U64 -> U64
	space_line = |bytes, i| {
		j = Chars.until(bytes, i, |b| !Chars.is_space_or_tab(b))
		if (Chars.at(bytes, j) == '\n') Chars.until(bytes, j + 1, |b| !Chars.is_space_or_tab(b)) else j
	}

	## `text` without the spaces, tabs and line endings at its end.
	trim_end : Str -> Str
	trim_end = |text| {
		bytes = text.to_utf8()
		var $end = bytes.len()
		while $end > 0 and Chars.is_whitespace(Chars.at(bytes, $end - 1)) {
			$end = $end - 1
		}
		if ($end == bytes.len()) text else Chars.slice(bytes, 0, $end)
	}

	## `text` without the spaces, tabs and line endings at either end.
	trim : Str -> Str
	trim = |text| {
		bytes = text.to_utf8()
		start = Chars.until(bytes, 0, |b| !Chars.is_whitespace(b))
		Chars.trim_end(Chars.slice(bytes, start, bytes.len()))
	}

	## The tag's name at `i` (letters, digits and `-`), lowercased: `""` if none starts there.
	tag_name : List(U8), U64 -> Str
	tag_name = |bytes, i| if (Chars.is_letter(Chars.at(bytes, i))) Chars.slice(bytes, i, tag_name_end(bytes, i)).with_ascii_lowercased() else ""
}

tag_name_end : List(U8), U64 -> U64
tag_name_end = |bytes, i| Chars.until(bytes, i, |b| !(Chars.is_alnum(b) or b == '-'))

skip_whitespace : List(U8), U64 -> U64
skip_whitespace = |bytes, i| Chars.until(bytes, i, |b| !Chars.is_whitespace(b))

## An attribute at `i`: its name, then maybe `=` and a value, quoted or not.
attribute : List(U8), U64 -> Try(U64, [NotTag])
attribute = |bytes, i| {
	first = Chars.at(bytes, i)
	if !(Chars.is_letter(first) or first == '_' or first == ':') {
		return Err(NotTag)
	}
	name_end = Chars.until(bytes, i + 1, |b| !(Chars.is_alnum(b) or b == '_' or b == '.' or b == ':' or b == '-'))
	eq = skip_whitespace(bytes, name_end)
	if Chars.at(bytes, eq) != '=' {
		return Ok(name_end)
	}
	v = skip_whitespace(bytes, eq + 1)
	quote = Chars.at(bytes, v)
	if quote == '"' or quote == '\'' {
		end = Chars.until(bytes, v + 1, |b| b == quote)
		if (end < bytes.len()) Ok(end + 1) else Err(NotTag)
	} else {
		end = Chars.until(bytes, v, |b| Chars.is_whitespace(b) or b == '"' or b == '\'' or b == '=' or b == '<' or b == '>' or b == '`')
		if (end > v) Ok(end) else Err(NotTag)
	}
}

## Just past the first `needle` from `i`.
after : List(U8), U64, Str -> Try(U64, [NotTag])
after = |bytes, i, needle| {
	wanted = needle.to_utf8()
	var $j = i
	while $j + wanted.len() <= bytes.len() {
		if bytes.sublist({ start: $j, len: wanted.len() }) == wanted {
			return Ok($j + wanted.len())
		}
		$j = $j + 1
	}
	Err(NotTag)
}

## Case folded, as far as `label_key` says.
fold_case : List(U8) -> Str
fold_case = |bytes| {
	var $out = []
	var $i = 0
	while $i < bytes.len() {
		found = decode(bytes, $i)
		code = found.code
		lower =
			if code >= 'A' and code <= 'Z' {
				code + 32
			} else if (code >= 0xC0 and code <= 0xDE and code != 0xD7) or (code >= 0x391 and code <= 0x3AB and code != 0x3A2) or (code >= 0x410 and code <= 0x42F) {
				code + 32
			} else if code >= 0x400 and code <= 0x40F {
				code + 80
			} else if code >= 0x100 and code <= 0x17F and code % 2 == 0 {
				code + 1
			} else if code == 0x3C2 {
				0x3C3
			} else {
				code
			}
		$out = if (code == 0xDF or code == 0x1E9E) $out.concat(['s', 's']) else $out.concat(Chars.utf8(lower))
		$i = $i + found.len
	}
	Str.from_utf8_lossy($out)
}

## The code point that starts at `i`, and how many bytes it takes.
decode : List(U8), U64 -> { code : U32, len : U64 }
decode = |bytes, i| {
	b = Chars.at(bytes, i).to_u32()
	more = |k| (Chars.at(bytes, i + k).to_u32() % 64)
	if b < 0x80 {
		{ code: b, len: 1 }
	} else if b < 0xE0 {
		{ code: (b % 32) * 64 + more(1), len: 2 }
	} else if b < 0xF0 {
		{ code: (b % 16) * 4096 + more(1) * 64 + more(2), len: 3 }
	} else {
		{ code: (b % 8) * 262144 + more(1) * 4096 + more(2) * 64 + more(3), len: 4 }
	}
}

## Unicode's whitespace and punctuation (symbols count, as CommonMark has them), as far as emphasis
## needs them: ASCII's, Latin-1's, General Punctuation, currency, arrows to miscellaneous symbols,
## CJK's and the full-width forms'.
class_of : U32 -> [Space, Punct, Other]
class_of = |code|
	if code < 0x80 {
		b = code.to_u8_wrap()
		if Chars.is_whitespace(b) {
			Space
		} else if Chars.is_punct(b) {
			Punct
		} else {
			Other
		}
	} else if code == 0xA0 or code == 0x1680 or (code >= 0x2000 and code <= 0x200A) or code == 0x202F or code == 0x205F or code == 0x3000 {
		Space
	} else if (code >= 0xA1 and code <= 0xBF and code != 0xAA and code != 0xB2 and code != 0xB3 and code != 0xB5 and code != 0xB9 and code != 0xBA) or code == 0xD7 or code == 0xF7 {
		Punct
	} else if (code >= 0x2010 and code <= 0x2027) or (code >= 0x2030 and code <= 0x205E) or (code >= 0x20A0 and code <= 0x20CF) or (code >= 0x2190 and code <= 0x2BFF) or (code >= 0x2E00 and code <= 0x2E7F) or (code >= 0x3001 and code <= 0x303F) or (code >= 0xFE30 and code <= 0xFE4F) or (code >= 0xFF01 and code <= 0xFF0F) or (code >= 0xFF1A and code <= 0xFF20) or (code >= 0xFF3B and code <= 0xFF40) or (code >= 0xFF5B and code <= 0xFF65) {
		Punct
	} else {
		Other
	}

## Named entities: HTML 4's (Latin-1, symbols, Greek, arrows, maths), and a few of HTML 5's.
entities : List((Str, Str))
entities = [
	("amp", "&"),
	("lt", "<"),
	("gt", ">"),
	("quot", "\""),
	("apos", "'"),
	("nbsp", "\u(A0)"),
	("iexcl", "¡"),
	("cent", "¢"),
	("pound", "£"),
	("curren", "¤"),
	("yen", "¥"),
	("brvbar", "¦"),
	("sect", "§"),
	("uml", "¨"),
	("copy", "©"),
	("ordf", "ª"),
	("laquo", "«"),
	("not", "¬"),
	("shy", "\u(AD)"),
	("reg", "®"),
	("macr", "¯"),
	("deg", "°"),
	("plusmn", "±"),
	("sup2", "²"),
	("sup3", "³"),
	("acute", "´"),
	("micro", "µ"),
	("para", "¶"),
	("middot", "·"),
	("cedil", "¸"),
	("sup1", "¹"),
	("ordm", "º"),
	("raquo", "»"),
	("frac14", "¼"),
	("frac12", "½"),
	("frac34", "¾"),
	("iquest", "¿"),
	("Agrave", "À"),
	("Aacute", "Á"),
	("Acirc", "Â"),
	("Atilde", "Ã"),
	("Auml", "Ä"),
	("Aring", "Å"),
	("AElig", "Æ"),
	("Ccedil", "Ç"),
	("Egrave", "È"),
	("Eacute", "É"),
	("Ecirc", "Ê"),
	("Euml", "Ë"),
	("Igrave", "Ì"),
	("Iacute", "Í"),
	("Icirc", "Î"),
	("Iuml", "Ï"),
	("ETH", "Ð"),
	("Ntilde", "Ñ"),
	("Ograve", "Ò"),
	("Oacute", "Ó"),
	("Ocirc", "Ô"),
	("Otilde", "Õ"),
	("Ouml", "Ö"),
	("times", "×"),
	("Oslash", "Ø"),
	("Ugrave", "Ù"),
	("Uacute", "Ú"),
	("Ucirc", "Û"),
	("Uuml", "Ü"),
	("Yacute", "Ý"),
	("THORN", "Þ"),
	("szlig", "ß"),
	("agrave", "à"),
	("aacute", "á"),
	("acirc", "â"),
	("atilde", "ã"),
	("auml", "ä"),
	("aring", "å"),
	("aelig", "æ"),
	("ccedil", "ç"),
	("egrave", "è"),
	("eacute", "é"),
	("ecirc", "ê"),
	("euml", "ë"),
	("igrave", "ì"),
	("iacute", "í"),
	("icirc", "î"),
	("iuml", "ï"),
	("eth", "ð"),
	("ntilde", "ñ"),
	("ograve", "ò"),
	("oacute", "ó"),
	("ocirc", "ô"),
	("otilde", "õ"),
	("ouml", "ö"),
	("divide", "÷"),
	("oslash", "ø"),
	("ugrave", "ù"),
	("uacute", "ú"),
	("ucirc", "û"),
	("uuml", "ü"),
	("yacute", "ý"),
	("thorn", "þ"),
	("yuml", "ÿ"),
	("OElig", "Œ"),
	("oelig", "œ"),
	("Scaron", "Š"),
	("scaron", "š"),
	("Yuml", "Ÿ"),
	("Dcaron", "Ď"),
	("fnof", "ƒ"),
	("circ", "ˆ"),
	("tilde", "˜"),
	("ensp", "\u(2002)"),
	("emsp", "\u(2003)"),
	("thinsp", "\u(2009)"),
	("zwnj", "\u(200C)"),
	("zwj", "\u(200D)"),
	("lrm", "\u(200E)"),
	("rlm", "\u(200F)"),
	("ndash", "–"),
	("mdash", "—"),
	("lsquo", "‘"),
	("rsquo", "’"),
	("sbquo", "‚"),
	("ldquo", "“"),
	("rdquo", "”"),
	("bdquo", "„"),
	("dagger", "†"),
	("Dagger", "‡"),
	("bull", "•"),
	("hellip", "…"),
	("permil", "‰"),
	("prime", "′"),
	("Prime", "″"),
	("lsaquo", "‹"),
	("rsaquo", "›"),
	("oline", "‾"),
	("frasl", "⁄"),
	("euro", "€"),
	("trade", "™"),
	("HilbertSpace", "ℋ"),
	("DifferentialD", "ⅆ"),
	("larr", "←"),
	("uarr", "↑"),
	("rarr", "→"),
	("darr", "↓"),
	("harr", "↔"),
	("crarr", "↵"),
	("lArr", "⇐"),
	("uArr", "⇑"),
	("rArr", "⇒"),
	("dArr", "⇓"),
	("hArr", "⇔"),
	("forall", "∀"),
	("part", "∂"),
	("exist", "∃"),
	("empty", "∅"),
	("nabla", "∇"),
	("isin", "∈"),
	("notin", "∉"),
	("ni", "∋"),
	("prod", "∏"),
	("sum", "∑"),
	("minus", "−"),
	("lowast", "∗"),
	("radic", "√"),
	("prop", "∝"),
	("infin", "∞"),
	("ang", "∠"),
	("and", "∧"),
	("or", "∨"),
	("cap", "∩"),
	("cup", "∪"),
	("int", "∫"),
	("ClockwiseContourIntegral", "∲"),
	("there4", "∴"),
	("sim", "∼"),
	("cong", "≅"),
	("asymp", "≈"),
	("ne", "≠"),
	("equiv", "≡"),
	("le", "≤"),
	("ge", "≥"),
	("ngE", "≧̸"),
	("sub", "⊂"),
	("sup", "⊃"),
	("nsub", "⊄"),
	("sube", "⊆"),
	("supe", "⊇"),
	("oplus", "⊕"),
	("otimes", "⊗"),
	("perp", "⊥"),
	("sdot", "⋅"),
	("lceil", "⌈"),
	("rceil", "⌉"),
	("lfloor", "⌊"),
	("rfloor", "⌋"),
	("lang", "⟨"),
	("rang", "⟩"),
	("loz", "◊"),
	("spades", "♠"),
	("clubs", "♣"),
	("hearts", "♥"),
	("diams", "♦"),
	("check", "✓"),
	("star", "☆"),
	("Alpha", "Α"),
	("Beta", "Β"),
	("Gamma", "Γ"),
	("Delta", "Δ"),
	("Epsilon", "Ε"),
	("Zeta", "Ζ"),
	("Eta", "Η"),
	("Theta", "Θ"),
	("Iota", "Ι"),
	("Kappa", "Κ"),
	("Lambda", "Λ"),
	("Mu", "Μ"),
	("Nu", "Ν"),
	("Xi", "Ξ"),
	("Omicron", "Ο"),
	("Pi", "Π"),
	("Rho", "Ρ"),
	("Sigma", "Σ"),
	("Tau", "Τ"),
	("Upsilon", "Υ"),
	("Phi", "Φ"),
	("Chi", "Χ"),
	("Psi", "Ψ"),
	("Omega", "Ω"),
	("alpha", "α"),
	("beta", "β"),
	("gamma", "γ"),
	("delta", "δ"),
	("epsilon", "ε"),
	("zeta", "ζ"),
	("eta", "η"),
	("theta", "θ"),
	("iota", "ι"),
	("kappa", "κ"),
	("lambda", "λ"),
	("mu", "μ"),
	("nu", "ν"),
	("xi", "ξ"),
	("omicron", "ο"),
	("pi", "π"),
	("rho", "ρ"),
	("sigmaf", "ς"),
	("sigma", "σ"),
	("tau", "τ"),
	("upsilon", "υ"),
	("phi", "φ"),
	("chi", "χ"),
	("psi", "ψ"),
	("omega", "ω"),
]

expect Chars.unescape("\\*not\\* &amp; &copy; &#35; &#x22; &bogus; \\q") == "*not* & © # \" &bogus; \\q"
expect Chars.unescape("&#0;") == "\u(FFFD)"
expect Chars.label_key("  Foo\n  BAR  ") == "foo bar"
expect Chars.label_key("ΑΓΩ Straße") == Chars.label_key("αγω STRASSE")
expect Chars.class_at("€".to_utf8(), 0) == Punct
expect Chars.open_tag("<a href=\"x\" data-y='1' z>".to_utf8(), 0) == Ok(25)
expect Chars.open_tag("<br/>".to_utf8(), 0) == Ok(5)
expect Chars.open_tag("<a h*1>".to_utf8(), 0) == Err(NotTag)
expect Chars.close_tag("</em >".to_utf8(), 0) == Ok(6)
expect Chars.raw_html("<!-- c -->x".to_utf8(), 0) == Ok(10)
expect Chars.raw_html("<?php echo ?>".to_utf8(), 0) == Ok(13)
expect Chars.utf8(0x1F600) == [0xF0, 0x9F, 0x98, 0x80]
expect Chars.class_before("a.b".to_utf8(), 2) == Punct
expect Chars.class_at("—x".to_utf8(), 0) == Punct
expect Chars.class_at("éx".to_utf8(), 0) == Other
expect Chars.destination("<a b>".to_utf8(), 0) == Ok({ url: "a b", end: 5 })
expect Chars.destination("a(b)c) x".to_utf8(), 0) == Ok({ url: "a(b)c", end: 5 })
expect Chars.destination("a\\)b".to_utf8(), 0) == Ok({ url: "a)b", end: 4 })
expect Chars.title("\"t \\\" &amp;\" x".to_utf8(), 0) == Ok({ title: "t \" &", end: 12 })
expect Chars.trim("  a b \t\n") == "a b"
