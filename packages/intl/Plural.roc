## Plural rules: which of CLDR's categories (`Zero`, `One`, `Two`, `Few`, `Many`, `Other`) a number
## takes in a language, for counting (cardinal: "1 file", "2 files") and for ranking (ordinal: "1st",
## "2nd"). English has two cardinal categories, Polish four, Arabic all six, Japanese one. A rule looks
## at a number as it is written: "1" is `One` in English, "1.0" is `Other`.
Plural := [].{

	Category : [Zero, One, Two, Few, Many, Other]

	## A number as CLDR's rules see it: `n` its absolute value, `i` its integer digits, `v` how many
	## fraction digits are shown, `f` those digits as a number, `t` the same without trailing zeros.
	## "1.50" is `{ n: 1.5, i: 1, v: 2, f: 50, t: 5 }`.
	Operands : { n : Dec, i : U64, v : U64, f : U64, t : U64 }

	## Words for each category, `""` where a language doesn't use one (it falls back to `other`).
	Forms : { zero : Str, one : Str, two : Str, few : Str, many : Str, other : Str }

	## No words at all: spread it, `{ ..Plural.none, one: "# file", other: "# files" }`.
	none : Forms
	none = { zero: "", one: "", two: "", few: "", many: "", other: "" }

	## The words for `category`, or `other`'s when it has none.
	pick : Forms, Category -> Str
	pick = |forms, category| {
		chosen =
			match category {
				Zero => forms.zero
				One => forms.one
				Two => forms.two
				Few => forms.few
				Many => forms.many
				Other => forms.other
			}
		if (chosen == "") forms.other else chosen
	}

	## The operands of a number written in ASCII digits, as a formatter wrote it: `"-1.50"`, `"3"`.
	operands : Str -> Operands
	operands = |written| {
		text = written.drop_prefix("-")
		{ whole, fraction } =
			match text.split_first(".") {
				Ok({ before, after }) => { whole: before, fraction: after }
				Err(_) => { whole: text, fraction: "" }
			}
		short = without_trailing_zeros(fraction)
		{
			n: Dec.from_str(text) ?? 0,
			i: U64.from_str(whole) ?? 0,
			v: fraction.count_utf8_bytes(),
			f: U64.from_str(fraction) ?? 0,
			t: U64.from_str(short) ?? 0,
		}
	}

	## The operands of a `Dec` written with the digits it needs: 1.50 is "1.5", 3.0 is "3".
	of_dec : Dec -> Operands
	of_dec = |x| Plural.operands(Plural.shortest(x))

	## A `Dec` in ASCII digits, without trailing zeros: 2.50 is `"2.5"`, 3.0 is `"3"`, -0.0 is `"0"`.
	shortest : Dec -> Str
	shortest = |x| {
		text = x.to_str()
		if text.contains(".") {
			short = without_trailing_zeros(text).drop_suffix(".")
			if (short == "-0") "0" else short
		} else {
			text
		}
	}

	## A category's name in CLDR and in ICU messages: `"one"`.
	name : Category -> Str
	name = |category|
		match category {
			Zero => "zero"
			One => "one"
			Two => "two"
			Few => "few"
			Many => "many"
			Other => "other"
		}

	## The category a name in a message stands for.
	from_name : Str -> Try(Category, [UnknownCategory(Str)])
	from_name = |text|
		match text {
			"zero" => Ok(Zero)
			"one" => Ok(One)
			"two" => Ok(Two)
			"few" => Ok(Few)
			"many" => Ok(Many)
			"other" => Ok(Other)
			_ => Err(UnknownCategory(text))
		}

	## English and German (and Dutch, Swedish, Italian's one): `One` for "1", else `Other`.
	en : Operands -> Category
	en = |o| if (o.i == 1 and o.v == 0) One else Other

	## French: `One` for 0 and 1 and what is between ("0.5", "1.5"), `Many` for whole millions.
	fr : Operands -> Category
	fr = |o|
		if o.i == 0 or o.i == 1 {
			One
		} else if millions(o) {
			Many
		} else {
			Other
		}

	## Spanish: `One` for 1 (and "1.0"), `Many` for whole millions.
	es : Operands -> Category
	es = |o|
		if whole(o) and o.i == 1 {
			One
		} else if millions(o) {
			Many
		} else {
			Other
		}

	## Polish: `One` for 1, `Few` for 2–4, 22–24, 32–34…, `Many` for other whole numbers (5, 12,
	## 25…), `Other` for fractions.
	pl : Operands -> Category
	pl = |o| {
		ones = o.i % 10
		tens = o.i % 100
		if o.v != 0 {
			Other
		} else if o.i == 1 {
			One
		} else if ones >= 2 and ones <= 4 and (tens < 12 or tens > 14) {
			Few
		} else {
			Many
		}
	}

	## Czech (and Slovak): `One` for 1, `Few` for 2–4, `Many` for fractions, `Other` for the rest.
	cs : Operands -> Category
	cs = |o|
		if o.v != 0 {
			Many
		} else if o.i == 1 {
			One
		} else if o.i >= 2 and o.i <= 4 {
			Few
		} else {
			Other
		}

	## Russian (and Ukrainian): `One` for 1, 21, 31…, `Few` for 2–4, 22–24…, `Many` for the other
	## whole numbers, `Other` for fractions.
	ru : Operands -> Category
	ru = |o| {
		ones = o.i % 10
		tens = o.i % 100
		if o.v != 0 {
			Other
		} else if ones == 1 and tens != 11 {
			One
		} else if ones >= 2 and ones <= 4 and (tens < 12 or tens > 14) {
			Few
		} else {
			Many
		}
	}

	## Arabic: `Zero`, `One` and `Two` for 0, 1 and 2, `Few` for 3–10 (and 103–110…), `Many` for
	## 11–99 (and 111–199…), `Other` for the rest (100, 102, fractions).
	ar : Operands -> Category
	ar = |o| {
		tens = o.i % 100
		if !whole(o) {
			Other
		} else if o.i == 0 {
			Zero
		} else if o.i == 1 {
			One
		} else if o.i == 2 {
			Two
		} else if tens >= 3 and tens <= 10 {
			Few
		} else if tens >= 11 {
			Many
		} else {
			Other
		}
	}

	## Japanese, Chinese, Korean…: no plurals, `Other` always.
	only_other : Operands -> Category
	only_other = |_| Other

	## English ordinals: 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st…
	ordinal_en : Operands -> Category
	ordinal_en = |o| {
		ones = o.i % 10
		tens = o.i % 100
		if !whole(o) {
			Other
		} else if ones == 1 and tens != 11 {
			One
		} else if ones == 2 and tens != 12 {
			Two
		} else if ones == 3 and tens != 13 {
			Few
		} else {
			Other
		}
	}

	## French ordinals: 1er, 2e, 3e…
	ordinal_fr : Operands -> Category
	ordinal_fr = |o| if (whole(o) and o.i == 1) One else Other

	## Languages whose ordinals don't change with the number (German "1.", Polish "1.", Japanese).
	ordinal_only_other : Operands -> Category
	ordinal_only_other = |_| Other
}

## No fraction other than zeros: "1" and "1.0", not "1.5".
whole : Plural.Operands -> Bool
whole = |o| o.t == 0

## A whole number of millions, written without fraction digits (French and Spanish `Many`).
millions : Plural.Operands -> Bool
millions = |o| o.v == 0 and o.i != 0 and o.i % 1000000 == 0

without_trailing_zeros : Str -> Str
without_trailing_zeros = |text| {
	var $text = text
	while $text.ends_with("0") {
		$text = $text.drop_suffix("0")
	}
	$text
}

# --- Tests: each rule against Node's Intl.PluralRules (ICU 78, CLDR 48). A letter for each number:
# Z zero, O one, T two, F few, M many, X other.
letter : Plural.Category -> Str
letter = |category|
	match category {
		Zero => "Z"
		One => "O"
		Two => "T"
		Few => "F"
		Many => "M"
		Other => "X"
	}

sweep : (Plural.Operands -> Plural.Category), U64, U64 -> Str
sweep = |rule, from, to| {
	var $text = ""
	var $n = from
	while $n <= to {
		$text = $text.concat(letter(rule(Plural.operands($n.to_str()))))
		$n = $n + 1
	}
	$text
}

digits : (Plural.Operands -> Plural.Category), List(Str) -> Str
digits = |rule, numbers| Str.join_with(numbers.map(|written| letter(rule(Plural.operands(written)))), "")

decimals : List(Str)
decimals = ["0.0", "0.5", "1.0", "1.5", "2.0", "2.5", "3.0", "5.0", "11.0", "21.0", "1.10", "1000000.0", "102.0", "111.0"]

expect Plural.operands("1.50") == { n: 1.5, i: 1, v: 2, f: 50, t: 5 }
expect Plural.operands("-3") == { n: 3, i: 3, v: 0, f: 0, t: 0 }
expect Plural.of_dec(2.50) == Plural.operands("2.5")
expect Plural.shortest(3.0) == "3"
expect Plural.shortest(-0.0) == "0"
expect Plural.pick({ ..Plural.none, one: "plik", few: "pliki", other: "pliku" }, Many) == "pliku"
expect Plural.from_name("few") == Ok(Few)
expect Plural.from_name("lots") == Err(UnknownCategory("lots"))

expect sweep(Plural.en, 0, 30) == "XOXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.en, 100, 125) == "XXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.en, 1000000, 1000002) == "XXX"
expect digits(Plural.en, decimals) == "XXXXXXXXXXXXXX"
expect sweep(Plural.fr, 0, 30) == "OOXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.fr, 100, 125) == "XXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.fr, 1000000, 1000002) == "MXX"
expect digits(Plural.fr, decimals) == "OOOOXXXXXXOXXX"
expect sweep(Plural.es, 0, 30) == "XOXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.es, 100, 125) == "XXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.es, 1000000, 1000002) == "MXX"
expect digits(Plural.es, decimals) == "XXOXXXXXXXXXXX"
expect sweep(Plural.pl, 0, 30) == "MOFFFMMMMMMMMMMMMMMMMMFFFMMMMMM"
expect sweep(Plural.pl, 100, 125) == "MMFFFMMMMMMMMMMMMMMMMMFFFM"
expect sweep(Plural.pl, 1000000, 1000002) == "MMF"
expect digits(Plural.pl, decimals) == "XXXXXXXXXXXXXX"
expect sweep(Plural.cs, 0, 30) == "XOFFFXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.cs, 100, 125) == "XXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.cs, 1000000, 1000002) == "XXX"
expect digits(Plural.cs, decimals) == "MMMMMMMMMMMMMM"
expect sweep(Plural.ru, 0, 30) == "MOFFFMMMMMMMMMMMMMMMMOFFFMMMMMM"
expect sweep(Plural.ru, 100, 125) == "MOFFFMMMMMMMMMMMMMMMMOFFFM"
expect sweep(Plural.ru, 1000000, 1000002) == "MOF"
expect digits(Plural.ru, decimals) == "XXXXXXXXXXXXXX"
expect sweep(Plural.ar, 0, 30) == "ZOTFFFFFFFFMMMMMMMMMMMMMMMMMMMM"
expect sweep(Plural.ar, 100, 125) == "XXXFFFFFFFFMMMMMMMMMMMMMMM"
expect sweep(Plural.ar, 1000000, 1000002) == "XXX"
expect digits(Plural.ar, decimals) == "ZXOXTXFFMMXXXM"
expect sweep(Plural.only_other, 0, 30) == "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect digits(Plural.only_other, decimals) == "XXXXXXXXXXXXXX"
expect sweep(Plural.ordinal_en, 0, 30) == "XOTFXXXXXXXXXXXXXXXXXOTFXXXXXXX"
expect sweep(Plural.ordinal_en, 100, 125) == "XOTFXXXXXXXXXXXXXXXXXOTFXX"
expect sweep(Plural.ordinal_fr, 0, 30) == "XOXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.ordinal_fr, 100, 125) == "XXXXXXXXXXXXXXXXXXXXXXXXXX"
expect sweep(Plural.ordinal_only_other, 0, 30) == "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
