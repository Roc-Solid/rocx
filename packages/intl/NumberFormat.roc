## Numbers as a locale writes them: its decimal mark and grouping (`1,234.5`, `1.234,5`,
## `1 234,5`), percentages, money with its symbol where the locale puts it, and compact numbers
## (`1.2K`, `1,2 tys.`, `1.2万`). Numbers are `Dec`, rounded half away from zero, as `Intl` rounds.
## Most apps call these through `Intl` (`intl.number(x)`), which knows its locale's `Symbols`.
NumberFormat := [].{

	## How a locale writes numbers (`Locales.pl.number`). In `percent` and `currency`, `{0}` is the
	## number, `{-}` where its minus goes, and `¤` the currency's symbol.
	Symbols : {
		decimal : Str,
		group : Str,
		min_grouping : U64,
		minus : Str,
		percent : Str,
		currency : Str,
		currency_symbols : List((Str, Str)),
		compact : List(Str),
	}

	## How many fraction digits to show, and whether to group the integer's digits. `max_fraction`
	## rounds; `min_fraction` pads with zeros.
	Options : { min_fraction : U64, max_fraction : U64, grouping : Bool }

	## `Intl.NumberFormat`'s: up to three fraction digits, grouped. Spread it to change one:
	## `{ ..NumberFormat.defaults, min_fraction: 2, max_fraction: 2 }`.
	defaults : Options
	defaults = { min_fraction: 0, max_fraction: 3, grouping: Bool.True }

	## `x` rounded as `options` say, in ASCII digits, with a `-` when it is below zero once rounded:
	## `NumberFormat.digits(-1234.5, { ..defaults, min_fraction: 2 })` is `"-1234.50"`. What plural
	## rules are given, so "1.0" can be told from "1".
	digits : Dec, Options -> Str
	digits = |x, options| {
		max = U64.min(options.max_fraction, 18)
		rounded = Dec.round_to(x, { step: unit(max), ties: AwayFromZero })
		text = rounded.abs().to_str()
		{ whole, fraction } = split_point(text)
		shown = pad_zeros(trim_zeros(fraction), U64.min(options.min_fraction, max))
		body = if (shown == "") whole else "${whole}.${shown}"
		if (rounded < 0.0) "-${body}" else body
	}

	## `x` as `symbols`' locale writes it.
	format : Symbols, Dec, Options -> Str
	format = |symbols, x, options| {
		{ negative, body } = localized(symbols, NumberFormat.digits(x, options), options.grouping, symbols.min_grouping)
		if (negative) "${symbols.minus}${body}" else body
	}

	## A share as a percentage, to at most `places` fraction digits: 0.256 is `"25.6%"` in English,
	## `"25,6 %"` in German.
	percent : Symbols, Dec, U64 -> Str
	percent = |symbols, x, places| {
		options = { ..NumberFormat.defaults, max_fraction: places }
		{ negative, body } = localized(symbols, NumberFormat.digits(x * 100.0, options), Bool.True, symbols.min_grouping)
		fill(symbols.percent, if (negative) symbols.minus else "", body)
	}

	## Short for big numbers, as `Intl`'s compact notation writes them: 1234 is `"1.2K"` in English,
	## `"1,2 tys."` in Polish, `"1234"` in German (which shortens from a million), and 12345 is
	## `"1.2万"` in Japanese. Two significant digits below ten of a unit, whole units above.
	compact : Symbols, Dec -> Str
	compact = |symbols, x| {
		size = Dec.abs(x)
		{ negative, body } =
			if size < 1000.0 {
				localized(symbols, compact_digits(x), Bool.True, U64.max(symbols.min_grouping, 2))
			} else {
				shortened(symbols, x, magnitude(size))
			}
		if (negative) "${symbols.minus}${body}" else body
	}

	## An amount of money in the currency `code` (ISO 4217: `"EUR"`), with the locale's symbol for
	## it where the locale puts it, and the currency's fraction digits (two; none for yen):
	## `"-$1,234.50"` in English, `"1234,50 zł"` in Polish. A currency the locale has no symbol
	## for is written by its code: `"PLN 1,234.50"`.
	currency : Symbols, Dec, Str -> Str
	currency = |symbols, amount, code| {
		places = NumberFormat.currency_digits(code)
		options = { min_fraction: places, max_fraction: places, grouping: Bool.True }
		{ negative, body } = localized(symbols, NumberFormat.digits(amount, options), Bool.True, symbols.min_grouping)
		symbol =
			match symbols.currency_symbols.find_first(|(each, _)| each == code) {
				Ok((_, found)) => found
				Err(_) => code
			}
		# CLDR's currency spacing: a symbol that ends in a letter is kept apart from the digits.
		pattern =
			if ends_in_letter(symbol) {
				symbols.currency.replace_each("¤{0}", "¤\u(A0){0}")
			} else if starts_with_letter(symbol) {
				symbols.currency.replace_each("{0}¤", "{0}\u(A0)¤")
			} else {
				symbols.currency
			}
		fill(pattern.replace_each("¤", symbol), if (negative) symbols.minus else "", body)
	}

	## How many fraction digits an amount in `code` has: 0 for yen, won and a few others, else 2.
	currency_digits : Str -> U64
	currency_digits = |code| if (["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "XAF", "XOF", "XPF", "RWF", "KMF", "GNF", "DJF", "VUV"].contains(code)) 0 else 2
}

## 10 to the minus `places`.
unit : U64 -> Dec
unit = |places| {
	var $step = 1.0
	var $left = places
	while $left > 0 {
		$step = $step / 10.0
		$left = $left - 1
	}
	$step
}

## 10 to the `power`.
power_of_ten : U64 -> Dec
power_of_ten = |power| {
	var $value = 1.0
	var $left = power
	while $left > 0 {
		$value = $value * 10.0
		$left = $left - 1
	}
	$value
}

## How many digits a number at least 1 has before its point, less one: 1234 is 3.
magnitude : Dec -> U64
magnitude = |size| {
	var $power = 0
	var $limit = 10.0
	while size >= $limit and $power < 30 {
		$power = $power + 1
		$limit = $limit * 10.0
	}
	$power
}

split_point : Str -> { whole : Str, fraction : Str }
split_point = |text|
	match text.split_first(".") {
		Ok({ before, after }) => { whole: before, fraction: after }
		Err(_) => { whole: text, fraction: "" }
	}

trim_zeros : Str -> Str
trim_zeros = |text| {
	var $text = text
	while $text.ends_with("0") {
		$text = $text.drop_suffix("0")
	}
	$text
}

pad_zeros : Str, U64 -> Str
pad_zeros = |text, least| {
	length = text.count_utf8_bytes()
	if (length >= least) text else text.concat(Str.repeat("0", least - length))
}

## ASCII digits (`"-1234.5"`) with the locale's marks: its sign apart, its digits grouped in threes
## when there are at least `least_grouping` more than three.
localized : NumberFormat.Symbols, Str, Bool, U64 -> { negative : Bool, body : Str }
localized = |symbols, ascii, grouping, least_grouping| {
	negative = ascii.starts_with("-")
	{ whole, fraction } = split_point(ascii.drop_prefix("-"))
	grouped = if (grouping and whole.count_utf8_bytes() >= 3 + least_grouping) group(whole, symbols.group) else whole
	{ negative, body: if (fraction == "") grouped else "${grouped}${symbols.decimal}${fraction}" }
}

## `"1234567"` → `"1,234,567"`.
group : Str, Str -> Str
group = |digits_text, separator| {
	bytes = digits_text.to_utf8()
	count = bytes.len()
	first = count % 3
	var $parts = if (first > 0) [bytes.sublist({ start: 0, len: first })] else []
	var $at = first
	while $at < count {
		$parts = $parts.append(bytes.sublist({ start: $at, len: 3 }))
		$at = $at + 3
	}
	Str.join_with($parts.map(Str.from_utf8_lossy), separator)
}

## A pattern with its sign and number put in.
fill : Str, Str, Str -> Str
fill = |pattern, sign, body| pattern.replace_each("{-}", sign).replace_each("{0}", body)

## Below a thousand, as compact notation rounds: whole from ten up, one fraction digit from one,
## two significant digits below one.
compact_digits : Dec -> Str
compact_digits = |x| {
	size = Dec.abs(x)
	places =
		if size >= 10.0 {
			0
		} else if size >= 1.0 {
			1
		} else {
			var $places = 1
			var $scaled = size * 10.0
			while $scaled < 1.0 and $places < 17 and size > 0.0 {
				$scaled = $scaled * 10.0
				$places = $places + 1
			}
			$places + 1
		}
	NumberFormat.digits(x, { min_fraction: 0, max_fraction: places, grouping: Bool.False })
}

## `x`, at least 1000, by the compact pattern for its magnitude (`"00K"`: two digits, then K). A
## pattern of `"0"` means the locale doesn't shorten numbers that big. When rounding makes it a digit
## longer (999.95K), the next pattern takes it (1M).
shortened : NumberFormat.Symbols, Dec, U64 -> { negative : Bool, body : Str }
shortened = |symbols, x, power| {
	patterns = symbols.compact
	last = if (patterns.is_empty()) 0 else patterns.len() + 2
	clamped = U64.min(power, last)
	pattern = if (clamped >= 3) patterns.get(clamped - 3) ?? "0" else "0"
	zeros = pattern.to_utf8().count_if(|b| b == '0')
	if pattern == "0" or zeros == 0 {
		rounded = NumberFormat.digits(x, { min_fraction: 0, max_fraction: 0, grouping: Bool.False })
		if magnitude(Dec.abs(Dec.from_str(rounded) ?? 0.0)) > power and power < last {
			shortened(symbols, x, power + 1)
		} else {
			localized(symbols, rounded, Bool.True, U64.max(symbols.min_grouping, 2))
		}
	} else {
		shift = clamped + 1 - zeros
		scaled = x / power_of_ten(shift)
		places = if (Dec.abs(scaled) < 10.0) 1 else 0
		rounded = NumberFormat.digits(scaled, { min_fraction: 0, max_fraction: places, grouping: Bool.False })
		if Dec.abs(Dec.from_str(rounded) ?? 0.0) >= power_of_ten(zeros) and power < last {
			shortened(symbols, x, power + 1)
		} else {
			{ negative, body } = localized(symbols, rounded, Bool.True, U64.max(symbols.min_grouping, 2))
			{ negative, body: affixed(pattern, body) }
		}
	}
}

## The pattern's zeros replaced by the number: `"0\u(A0)tys."` and `"1,2"` is `"1,2 tys."`.
affixed : Str, Str -> Str
affixed = |pattern, body| {
	bytes = pattern.to_utf8()
	start = bytes.find_first_index(|b| b == '0') ?? 0
	end = (bytes.find_last_index(|b| b == '0') ?? 0) + 1
	Str.from_utf8_lossy(bytes.sublist({ start: 0, len: start })).concat(body).concat(Str.from_utf8_lossy(bytes.drop_first(end)))
}

is_ascii_letter : U8 -> Bool
is_ascii_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

ends_in_letter : Str -> Bool
ends_in_letter = |text|
	match text.to_utf8().last() {
		Ok(b) => is_ascii_letter(b)
		Err(_) => Bool.False
	}

starts_with_letter : Str -> Bool
starts_with_letter = |text|
	match text.to_utf8().first() {
		Ok(b) => is_ascii_letter(b)
		Err(_) => Bool.False
	}

en : NumberFormat.Symbols
en = {
	decimal: ".",
	group: ",",
	min_grouping: 1,
	minus: "-",
	percent: "{-}{0}%",
	currency: "{-}¤{0}",
	currency_symbols: [("USD", "\$"), ("EUR", "€")],
	compact: ["0K", "00K", "000K", "0M", "00M", "000M", "0B", "00B", "000B", "0T", "00T", "000T"],
}

pl : NumberFormat.Symbols
pl = {
	decimal: ",",
	group: "\u(A0)",
	min_grouping: 2,
	minus: "-",
	percent: "{-}{0}%",
	currency: "{-}{0}\u(A0)¤",
	currency_symbols: [("EUR", "€"), ("PLN", "zł")],
	compact: ["0\u(A0)tys.", "00\u(A0)tys.", "000\u(A0)tys.", "0\u(A0)mln", "00\u(A0)mln", "000\u(A0)mln", "0\u(A0)mld", "00\u(A0)mld", "000\u(A0)mld", "0\u(A0)bln", "00\u(A0)bln", "000\u(A0)bln"],
}

expect NumberFormat.digits(1234.5, NumberFormat.defaults) == "1234.5"
expect NumberFormat.digits(-1234.5, { ..NumberFormat.defaults, min_fraction: 2 }) == "-1234.50"
expect NumberFormat.digits(1.0005, NumberFormat.defaults) == "1.001"
expect NumberFormat.digits(-0.0004, NumberFormat.defaults) == "0"
expect NumberFormat.digits(2.5, { ..NumberFormat.defaults, max_fraction: 0 }) == "3"
expect NumberFormat.digits(-2.5, { ..NumberFormat.defaults, max_fraction: 0 }) == "-3"
expect NumberFormat.digits(7.0, { ..NumberFormat.defaults, min_fraction: 1 }) == "7.0"
expect NumberFormat.format(en, -1234567.891, NumberFormat.defaults) == "-1,234,567.891"
expect NumberFormat.format(en, 123.0, NumberFormat.defaults) == "123"
expect NumberFormat.format(en, 1234.0, { ..NumberFormat.defaults, grouping: Bool.False }) == "1234"
expect NumberFormat.format(pl, 1234.5, NumberFormat.defaults) == "1234,5"
expect NumberFormat.format(pl, 12345.5, NumberFormat.defaults) == "12\u(A0)345,5"
expect NumberFormat.format(pl, -1234567.891, NumberFormat.defaults) == "-1\u(A0)234\u(A0)567,891"
expect NumberFormat.percent(en, 0.256, 1) == "25.6%"
expect NumberFormat.percent(en, 0.5, 0) == "50%"
expect NumberFormat.percent(pl, -0.256, 1) == "-25,6%"
expect NumberFormat.compact(en, 1234.0) == "1.2K"
expect NumberFormat.compact(en, 12345.0) == "12K"
expect NumberFormat.compact(en, 999950.0) == "1M"
expect NumberFormat.compact(en, -1250.0) == "-1.3K"
expect NumberFormat.compact(en, 123.456) == "123"
expect NumberFormat.compact(en, 1.234) == "1.2"
expect NumberFormat.compact(en, 0.01234) == "0.012"
expect NumberFormat.compact(en, 0.0) == "0"
expect NumberFormat.compact(en, 1500000000000000.0) == "1500T"
expect NumberFormat.compact(pl, 1234.0) == "1,2\u(A0)tys."
expect NumberFormat.currency(en, -1234.5, "USD") == "-\$1,234.50"
expect NumberFormat.currency(en, 1234.5, "PLN") == "PLN\u(A0)1,234.50"
expect NumberFormat.currency(en, 1234.5, "JPY") == "JPY\u(A0)1,235"
expect NumberFormat.currency(pl, 1234.5, "PLN") == "1234,50\u(A0)zł"
expect NumberFormat.currency(pl, 1234.5, "USD") == "1234,50\u(A0)USD"
expect NumberFormat.compact({ ..en, compact: [] }, 1234567.0) == "1,234,567"
expect NumberFormat.compact({ ..en, compact: [] }, -12345.4) == "-12,345"
