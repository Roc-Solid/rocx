## Bytes and text, the way rocx's JavaScript had them, for its Roc: a file's bytes scanned by index
## (every character rocx reads is ASCII; the rest is copied as it is), Roc's and JSON's string
## literals, JavaScript's whitespace (what `\s` and `trim()` meant there), columns in UTF-16 units
## (what a JavaScript string's index was), and the orders JavaScript sorted strings in.
Text := [].{

	## The byte at `i`, or 0 past the end.
	at : List(U8), U64 -> U8
	at = |bytes, i| bytes.get(i) ?? 0

	## The bytes from `start` to `end` (none when `end` is not after `start`).
	slice : List(U8), U64, U64 -> List(U8)
	slice = |bytes, start, end| if (end <= start) [] else bytes.sublist({ start, len: end - start })

	## The text of the bytes from `start` to `end`.
	cut : List(U8), U64, U64 -> Str
	cut = |bytes, start, end| Str.from_utf8_lossy(Text.slice(bytes, start, end))

	## The bytes from `start` to the end, as text.
	rest : List(U8), U64 -> Str
	rest = |bytes, start| Text.cut(bytes, start, bytes.len())

	## Whether `prefix` is at `i`.
	starts_with_at : List(U8), List(U8), U64 -> Bool
	starts_with_at = |bytes, prefix, i| {
		var $k = 0
		while $k < prefix.len() {
			if Text.at(bytes, i + $k) != Text.at(prefix, $k) or i + $k >= bytes.len() {
				return Bool.False
			}
			$k = $k + 1
		}
		Bool.True
	}

	## Where `needle` first is at `from` or after (JavaScript's `indexOf(needle, from)`).
	index_of : List(U8), List(U8), U64 -> Try(U64, [NotFound])
	index_of = |bytes, needle, from| {
		n = needle.len()
		if n == 0 {
			return if (from <= bytes.len()) Ok(from) else Ok(bytes.len())
		}
		first = Text.at(needle, 0)
		var $i = from
		while $i + n <= bytes.len() {
			if Text.at(bytes, $i) == first and Text.starts_with_at(bytes, needle, $i) {
				return Ok($i)
			}
			$i = $i + 1
		}
		Err(NotFound)
	}

	## Where `byte` first is at `from` or after.
	index_of_byte : List(U8), U8, U64 -> Try(U64, [NotFound])
	index_of_byte = |bytes, byte, from| {
		var $i = from
		while $i < bytes.len() {
			if Text.at(bytes, $i) == byte {
				return Ok($i)
			}
			$i = $i + 1
		}
		Err(NotFound)
	}

	## Where `byte` last is before `before` (JavaScript's `lastIndexOf(byte, before - 1)`).
	last_index_before : List(U8), U8, U64 -> Try(U64, [NotFound])
	last_index_before = |bytes, byte, before| {
		var $i = if (before > bytes.len()) bytes.len() else before
		while $i > 0 {
			if Text.at(bytes, $i - 1) == byte {
				return Ok($i - 1)
			}
			$i = $i - 1
		}
		Err(NotFound)
	}

	## Where the line holding `pos` starts: after the last newline before it.
	line_start : List(U8), U64 -> U64
	line_start = |bytes, pos|
		match Text.last_index_before(bytes, '\n', pos) {
			Ok(i) => i + 1
			Err(_) => 0
		}

	## Where the line holding `pos` ends: its newline, or the end.
	line_end : List(U8), U64 -> U64
	line_end = |bytes, pos| Text.index_of_byte(bytes, '\n', pos) ?? bytes.len()

	## How many newlines the bytes from `start` to `end` have.
	newlines : List(U8), U64, U64 -> U64
	newlines = |bytes, start, end| {
		var $count = 0
		var $i = start
		while $i < end and $i < bytes.len() {
			if Text.at(bytes, $i) == '\n' {
				$count = $count + 1
			}
			$i = $i + 1
		}
		$count
	}

	## The line (from 1) of the byte at `pos`.
	line_of : List(U8), U64 -> U64
	line_of = |bytes, pos| Text.newlines(bytes, 0, pos) + 1

	## The column (from 1) of `pos` on its line, counted in UTF-16 units, as a JavaScript string's
	## index counted them.
	column : List(U8), U64 -> U64
	column = |bytes, pos| Text.utf16_units(Text.slice(bytes, Text.line_start(bytes, pos), pos)) + 1

	## How many UTF-16 units the text in `bytes` takes: JavaScript's `length`.
	utf16_units : List(U8) -> U64
	utf16_units = |bytes|
		bytes.fold(0, |count, b| if (b >= 0xF0) count + 2 else if (b >= 0x80 and b < 0xC0) count else count + 1)

	## `str`'s JavaScript `length`.
	length : Str -> U64
	length = |str| Text.utf16_units(str.to_utf8())

	## How many bytes the JavaScript whitespace character at `i` has (what `\s` matched), or 0.
	space_at : List(U8), U64 -> U64
	space_at = |bytes, i| {
		b = Text.at(bytes, i)
		if i >= bytes.len() {
			0
		} else if b == ' ' or (b >= 0x09 and b <= 0x0D) {
			1
		} else if b == 0xC2 and Text.at(bytes, i + 1) == 0xA0 {
			2
		} else if b == 0xE1 and Text.at(bytes, i + 1) == 0x9A and Text.at(bytes, i + 2) == 0x80 {
			3
		} else if b == 0xE2 {
			c = Text.at(bytes, i + 1)
			d = Text.at(bytes, i + 2)
			if (c == 0x80 and ((d >= 0x80 and d <= 0x8A) or d == 0xA8 or d == 0xA9 or d == 0xAF)) or (c == 0x81 and d == 0x9F) 3 else 0
		} else if b == 0xE3 and Text.at(bytes, i + 1) == 0x80 and Text.at(bytes, i + 2) == 0x80 {
			3
		} else if b == 0xEF and Text.at(bytes, i + 1) == 0xBB and Text.at(bytes, i + 2) == 0xBF {
			3
		} else {
			0
		}
	}

	## Whether the byte at `i` starts JavaScript whitespace.
	is_space_at : List(U8), U64 -> Bool
	is_space_at = |bytes, i| Text.space_at(bytes, i) > 0

	## How many bytes the JavaScript whitespace character ending at `end` has, or 0.
	space_before : List(U8), U64 -> U64
	space_before = |bytes, end| {
		b = Text.at(bytes, end - 1)
		if end == 0 {
			0
		} else if b == ' ' or (b >= 0x09 and b <= 0x0D) {
			1
		} else if end >= 2 and Text.space_at(bytes, end - 2) == 2 {
			2
		} else if end >= 3 and Text.space_at(bytes, end - 3) == 3 {
			3
		} else {
			0
		}
	}

	## Where the whitespace at `i` ends.
	skip_space : List(U8), U64 -> U64
	skip_space = |bytes, i| {
		var $i = i
		var $n = Text.space_at(bytes, $i)
		while $n > 0 {
			$i = $i + $n
			$n = Text.space_at(bytes, $i)
		}
		$i
	}

	## Where the whitespace ending at `end` starts.
	skip_space_back : List(U8), U64 -> U64
	skip_space_back = |bytes, end| {
		var $end = end
		var $n = Text.space_before(bytes, $end)
		while $n > 0 {
			$end = $end - $n
			$n = Text.space_before(bytes, $end)
		}
		$end
	}

	## Whether `str` has only JavaScript whitespace (or nothing): `!/\S/.test(str)`.
	is_blank : Str -> Bool
	is_blank = |str| {
		bytes = str.to_utf8()
		Text.skip_space(bytes, 0) >= bytes.len()
	}

	## JavaScript's `trim()`.
	trim : Str -> Str
	trim = |str| {
		bytes = str.to_utf8()
		start = Text.skip_space(bytes, 0)
		Text.cut(bytes, start, Text.skip_space_back(bytes, bytes.len()))
	}

	## JavaScript's `trimStart()`.
	trim_start : Str -> Str
	trim_start = |str| {
		bytes = str.to_utf8()
		Text.rest(bytes, Text.skip_space(bytes, 0))
	}

	## JavaScript's `trimEnd()`.
	trim_end : Str -> Str
	trim_end = |str| {
		bytes = str.to_utf8()
		Text.cut(bytes, 0, Text.skip_space_back(bytes, bytes.len()))
	}

	## The spaces and tabs a line starts with.
	indent : Str -> Str
	indent = |line| {
		bytes = line.to_utf8()
		var $i = 0
		while Text.at(bytes, $i) == ' ' or Text.at(bytes, $i) == '\t' {
			$i = $i + 1
		}
		Text.cut(bytes, 0, $i)
	}

	## The lines of `str`: JavaScript's `split("\n")`.
	lines : Str -> List(Str)
	lines = |str| str.split_on("\n")

	is_upper : U8 -> Bool
	is_upper = |b| b >= 'A' and b <= 'Z'

	is_lower : U8 -> Bool
	is_lower = |b| b >= 'a' and b <= 'z'

	is_letter : U8 -> Bool
	is_letter = |b| Text.is_upper(b) or Text.is_lower(b)

	is_digit : U8 -> Bool
	is_digit = |b| b >= '0' and b <= '9'

	is_alnum : U8 -> Bool
	is_alnum = |b| Text.is_letter(b) or Text.is_digit(b)

	## A word's character in a JavaScript regular expression (`\w`): `[A-Za-z0-9_]`.
	is_word : U8 -> Bool
	is_word = |b| Text.is_alnum(b) or b == '_'

	## Where the run of bytes `keep` says yes to, from `i`, ends.
	run_end : List(U8), U64, (U8 -> Bool) -> U64
	run_end = |bytes, i, keep| {
		var $j = i
		while $j < bytes.len() and keep(Text.at(bytes, $j)) {
			$j = $j + 1
		}
		$j
	}

	## Whether every byte of `str` is one `keep` says yes to, and there is one.
	all_of : Str, (U8 -> Bool) -> Bool
	all_of = |str, keep| {
		bytes = str.to_utf8()
		!bytes.is_empty() and bytes.all(keep)
	}

	## `str` with A to Z in lower case (JavaScript's `toLowerCase()` for ASCII).
	lower : Str -> Str
	lower = |str| str.with_ascii_lowercased()

	## `str` with a to z in upper case.
	upper : Str -> Str
	upper = |str| str.with_ascii_uppercased()

	## A Roc string literal holding `text` exactly.
	roc_string : Str -> Str
	roc_string = |text| {
		bytes = text.to_utf8()
		var $out = List.with_capacity(bytes.len() + 2).append('"')
		var $i = 0
		while $i < bytes.len() {
			c = Text.at(bytes, $i)
			if c == '\\' {
				$out = $out.concat(['\\', '\\'])
			} else if c == '"' {
				$out = $out.concat(['\\', '"'])
			} else if c == '$' and Text.at(bytes, $i + 1) == '{' {
				$out = $out.concat(['\\', '$'])
			} else if c == '\n' {
				$out = $out.concat(['\\', 'n'])
			} else if c == '\r' {
				$out = $out.concat(['\\', 'r'])
			} else if c == '\t' {
				$out = $out.concat(['\\', 't'])
			} else if c < 0x20 or c == 0x7F {
				$out = $out.concat(['\\', 'u', '(']).concat(Text.hex(c.to_u32()).to_utf8()).append(')')
			} else {
				$out = $out.append(c)
			}
			$i = $i + 1
		}
		Str.from_utf8_lossy($out.append('"'))
	}

	## `text` as JavaScript's `JSON.stringify` writes a string.
	json_string : Str -> Str
	json_string = |text| {
		bytes = text.to_utf8()
		var $out = List.with_capacity(bytes.len() + 2).append('"')
		for c in bytes {
			if c == '\\' {
				$out = $out.concat(['\\', '\\'])
			} else if c == '"' {
				$out = $out.concat(['\\', '"'])
			} else if c == '\n' {
				$out = $out.concat(['\\', 'n'])
			} else if c == '\r' {
				$out = $out.concat(['\\', 'r'])
			} else if c == '\t' {
				$out = $out.concat(['\\', 't'])
			} else if c == 0x08 {
				$out = $out.concat(['\\', 'b'])
			} else if c == 0x0C {
				$out = $out.concat(['\\', 'f'])
			} else if c < 0x20 {
				digits = Text.hex(c.to_u32())
				$out = $out.concat(['\\', 'u']).concat("0000".to_utf8().take_first(4 - digits.to_utf8().len())).concat(digits.to_utf8())
			} else {
				$out = $out.append(c)
			}
		}
		Str.from_utf8_lossy($out.append('"'))
	}

	## A number in lower-case hexadecimal, no leading zeros (JavaScript's `toString(16)`).
	hex : U32 -> Str
	hex = |n| Text.in_base(n.to_u64(), 16)

	## A number in base `base` (up to 36), lower case, no leading zeros: JavaScript's `toString(base)`.
	in_base : U64, U64 -> Str
	in_base = |n, base| {
		digits = "0123456789abcdefghijklmnopqrstuvwxyz".to_utf8()
		if n == 0 {
			"0"
		} else {
			var $n = n
			var $out = []
			while $n > 0 {
				$out = $out.prepend(Text.at(digits, $n % base))
				$n = $n // base
			}
			Str.from_utf8_lossy($out)
		}
	}

	## The UTF-8 bytes of a code point (`String.fromCodePoint`).
	utf8 : U32 -> List(U8)
	utf8 = |code|
		if code < 0x80 {
			[code.to_u8_wrap()]
		} else if code < 0x800 {
			[(0xC0 + code // 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else if code < 0x10000 {
			[(0xE0 + code // 4096).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else {
			[(0xF0 + code // 262144).to_u8_wrap(), (0x80 + (code // 4096) % 64).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		}

	## The code points of `str`, in order.
	code_points : Str -> List(U32)
	code_points = |str| {
		bytes = str.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = Text.at(bytes, $i).to_u32()
			cont = |k| (Text.at(bytes, $i + k).to_u32() % 64)
			if b < 0x80 {
				$out = $out.append(b)
				$i = $i + 1
			} else if b < 0xE0 {
				$out = $out.append((b % 32) * 64 + cont(1))
				$i = $i + 2
			} else if b < 0xF0 {
				$out = $out.append((b % 16) * 4096 + cont(1) * 64 + cont(2))
				$i = $i + 3
			} else {
				$out = $out.append((b % 8) * 262144 + cont(1) * 4096 + cont(2) * 64 + cont(3))
				$i = $i + 4
			}
		}
		$out
	}

	## `str` padded with spaces at its end to `width` (JavaScript's `padEnd`).
	pad_end : Str, U64 -> Str
	pad_end = |str, width| {
		have = Text.length(str)
		if (have >= width) str else str.concat(" ".repeat(width - have))
	}

	## `str` padded with `fill` at its start to `width` characters (ASCII).
	pad_start : Str, U64, Str -> Str
	pad_start = |str, width, fill| {
		have = Text.length(str)
		if (have >= width) str else fill.repeat(width - have).concat(str)
	}

	## The order JavaScript's `sort()` puts two strings in (by code unit; by byte, for the strings rocx sorts).
	order : Str, Str -> [Before, Same, After]
	order = |a, b| Text.bytes_order(a.to_utf8(), b.to_utf8())

	bytes_order : List(U8), List(U8) -> [Before, Same, After]
	bytes_order = |x, y| {
		var $i = 0
		while $i < x.len() and $i < y.len() {
			p = Text.at(x, $i)
			q = Text.at(y, $i)
			if p < q {
				return Before
			} else if p > q {
				return After
			}
			$i = $i + 1
		}
		if (x.len() < y.len()) Before else if (x.len() > y.len()) After else Same
	}

	## `localeCompare`'s order for a route's path (lower-case letters, digits and `_-./[]`): Unicode's
	## collation, in which punctuation comes before digits and digits before letters.
	locale_order : Str, Str -> [Before, Same, After]
	locale_order = |a, b| {
		rank = |c| {
			punctuation = "_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".to_utf8()
			match Text.index_of_byte(punctuation, c, 0) {
				Ok(i) => i
				Err(_) => if (Text.is_digit(c)) 100 + c.to_u64() else if (Text.is_lower(c)) 200 + 2 * c.to_u64() else if (Text.is_upper(c)) 201 + 2 * (c.to_u64() + 32) else 600 + c.to_u64()
			}
		}
		x = a.to_utf8()
		y = b.to_utf8()
		var $i = 0
		while $i < x.len() and $i < y.len() {
			p = rank(Text.at(x, $i))
			q = rank(Text.at(y, $i))
			if p < q {
				return Before
			} else if p > q {
				return After
			}
			$i = $i + 1
		}
		if (x.len() < y.len()) Before else if (x.len() > y.len()) After else Same
	}

	## `list` with no two the same, the first of each kept.
	unique : List(Str) -> List(Str)
	unique = |list| list.fold([], |kept, item| if (kept.contains(item)) kept else kept.append(item))

	## `list` sorted as JavaScript's `sort()` sorts strings.
	sorted : List(Str) -> List(Str)
	sorted = |list| list.sort_with(Text.order)
}
