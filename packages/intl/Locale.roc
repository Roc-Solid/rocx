## A locale: the language a reader reads, and where (`en-GB`, `pl`, `zh-Hant-TW`), as a BCP 47 tag.
## `Locale.parse` reads a tag in any case, with `-` or `_`, and writes it as BCP 47 does
## (`EN_us` is `en-US`). `Locale.best` picks, from the locales an app supports, the one closest to
## what a reader wants: `pl-PL` takes `pl`, `en-US` takes `en-GB` over another language, and with
## nothing close, the app's default. `Locale.wanted` reads what a request wants, from a cookie and
## its `Accept-Language`.
Locale := { language : Str, script : Str, region : Str }.{

	## The locale a tag names, or why it can't be one. Variants and extensions (`de-DE-1996`,
	## `en-US-u-ca-gregory`) are read and dropped; a POSIX locale's encoding (`en_US.UTF-8`) too.
	parse : Str -> Try(Locale, [InvalidTag(Str)])
	parse = |text| {
		cut = before_any(text.trim(), [".", "@"])
		parts = cut.replace_each("_", "-").split_on("-")
		language = (parts.first() ?? "").with_ascii_lowercased()
		if !(letters(language) and (language.count_utf8_bytes() == 2 or language.count_utf8_bytes() == 3)) {
			Err(InvalidTag(text))
		} else {
			rest = parts.drop_first(1)
			second = rest.first() ?? ""
			{ script, after_script } =
				if letters(second) and second.count_utf8_bytes() == 4 {
					{ script: title_case(second), after_script: rest.drop_first(1) }
				} else {
					{ script: "", after_script: rest }
				}
			candidate = after_script.first() ?? ""
			region =
				if letters(candidate) and candidate.count_utf8_bytes() == 2 {
					candidate.with_ascii_uppercased()
				} else if all_digits(candidate) and candidate.count_utf8_bytes() == 3 {
					candidate
				} else {
					""
				}
			Ok({ language, script, region })
		}
	}

	## A locale from a tag known to be good, such as a literal in the app (`Locale.of("en-GB")`);
	## a bad one crashes.
	of : Str -> Locale
	of = |text|
		match Locale.parse(text) {
			Ok(locale) => locale
			Err(_) => crash "Locale.of: \"${text}\" isn't a language tag"
		}

	## The tag, as BCP 47 writes it: `en-GB`, `zh-Hant-TW`.
	tag : Locale -> Str
	tag = |locale| Str.join_with([locale.language, locale.script, locale.region].keep_if(|part| part != ""), "-")

	## The language alone: `"en"` for `en-GB`.
	language_of : Locale -> Str
	language_of = |locale| locale.language

	## The region, `""` when the tag names none: `"GB"` for `en-GB`.
	region_of : Locale -> Str
	region_of = |locale| locale.region

	is_eq : Locale, Locale -> Bool
	is_eq = |a, b| a.language == b.language and a.script == b.script and a.region == b.region

	## The locale, then the ones it falls back to, the most specific first: `zh-Hant-TW` is
	## `[zh-Hant-TW, zh-Hant, zh]`, `pl-PL` is `[pl-PL, pl]`.
	fallbacks : Locale -> List(Locale)
	fallbacks = |locale| {
		bare = { language: locale.language, script: "", region: "" }
		with_script = { ..bare, script: locale.script }
		chain = [locale, with_script, bare]
		chain.fold([], |kept, each| if (kept.contains(each)) kept else kept.append(each))
	}

	## Text written from right to left (Arabic, Hebrew, Persian, Urdu…): `"rtl"`, else `"ltr"`, for
	## the page's `dir`.
	direction : Locale -> Str
	direction = |locale|
		if ["ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ckb"].contains(locale.language) and locale.script != "Latn" {
			"rtl"
		} else {
			"ltr"
		}

	## The locales an `Accept-Language` header asks for, the most wanted first: `"pl-PL,pl;q=0.9,
	## en;q=0.5"` is `[pl-PL, pl, en]`. `*`, a `q=0` and what isn't a tag are left out; equal
	## weights keep their order.
	accept_language : Str -> List(Locale)
	accept_language = |header| {
		weighted =
			header.split_on(",").keep_oks(
				|item| {
					fields = item.split_on(";")
					locale = Locale.parse(fields.first() ?? "")?
					weight = fields.drop_first(1).fold(1.0, |found, field| weight_of(field) ?? found)
					if (weight > 0.0) Ok({ locale, weight }) else Err(Unwanted)
				},
			)
		weighted.sort_with(|a, b| if (a.weight > b.weight) Before else if (a.weight < b.weight) After else Same).map(|each| each.locale)
	}

	## The supported locale closest to what is wanted (in order of preference), or `default`. For each
	## wanted locale in turn: itself or a fallback of it (`pl-PL`, then `pl`) if supported, then any
	## supported locale of its language (`en-US` takes `en-GB`). So a reader who asks for
	## `en-US, de` and an app with `en-GB` and `de` gets `en-GB`.
	best : List(Locale), List(Locale), Locale -> Locale
	best = |wants, supported, default|
		match Locale.lookup(wants, supported) {
			Ok(found) => found
			Err(NoMatch) => default
		}

	## As `best`, with no default: `Err(NoMatch)` when nothing supported is close.
	lookup : List(Locale), List(Locale) -> Try(Locale, [NoMatch])
	lookup = |wants, supported| {
		find = |want| {
			exact = want.fallbacks().find_first(|each| supported.contains(each))
			match exact {
				Ok(found) => Ok(found)
				Err(_) => supported.find_first(|each| each.language == want.language)
			}
		}
		wants.fold_until(
			Err(NoMatch),
			|_, want|
				match find(want) {
					Ok(found) => Break(Ok(found))
					Err(_) => Continue(Err(NoMatch))
				},
		)
	}

	## What a request wants, the most wanted first: the locale in the cookie named `cookie` (a
	## reader's own choice, kept), then its `Accept-Language`'s. Takes the platform's
	## `Server.Request` (or any record with its `headers`). A `cookie` of `""` reads no cookie.
	wanted : { headers : List({ name : Str, value : Str }), ..others }, Str -> List(Locale)
	wanted = |request, cookie| {
		header = |name| request.headers.find_first(|each| each.name.with_ascii_lowercased() == name).map_ok(|each| each.value) ?? ""
		chosen =
			if cookie == "" {
				[]
			} else {
				match cookie_value(header("cookie"), cookie) {
					Ok(value) =>
						match Locale.parse(value) {
							Ok(locale) => [locale]
							Err(_) => []
						}
					Err(_) => []
				}
			}
		chosen.concat(Locale.accept_language(header("accept-language")))
	}
}

before_any : Str, List(Str) -> Str
before_any = |text, stops|
	stops.fold(
		text,
		|cut, stop|
			match cut.split_first(stop) {
				Ok({ before, .. }) => before
				Err(_) => cut
			},
	)

letters : Str -> Bool
letters = |text| !text.is_empty() and text.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z'))

all_digits : Str -> Bool
all_digits = |text| !text.is_empty() and text.to_utf8().all(|b| b >= '0' and b <= '9')

title_case : Str -> Str
title_case = |text| {
	lower = text.with_ascii_lowercased().to_utf8()
	first = lower.take_first(1).map(|b| if (b >= 'a' and b <= 'z') b - 32 else b)
	Str.from_utf8_lossy(first.concat(lower.drop_first(1)))
}

## `q=0.8` → 0.8; anything else isn't a weight.
weight_of : Str -> Try(Dec, [NotAWeight])
weight_of = |field|
	match field.trim().split_first("=") {
		Ok({ before, after }) if before.trim().with_ascii_lowercased() == "q" =>
			match Dec.from_str(after.trim()) {
				Ok(weight) if weight >= 0.0 and weight <= 1.0 => Ok(weight)
				_ => Err(NotAWeight)
			}
		_ => Err(NotAWeight)
	}

cookie_value : Str, Str -> Try(Str, [Missing])
cookie_value = |cookies, wanted|
	cookies.split_on(";").fold(
		Err(Missing),
		|found, pair|
			match found {
				Ok(_) => found
				Err(_) =>
					match pair.trim().split_first("=") {
						Ok({ before, after }) => if (before == wanted) Ok(after.trim()) else found
						Err(_) => found
					}
			},
	)

tags : List(Locale) -> List(Str)
tags = |locales| locales.map(|locale| locale.tag())

expect Locale.parse("en-GB").map_ok(|l| l.tag()) == Ok("en-GB")
expect Locale.parse("EN_us").map_ok(|l| l.tag()) == Ok("en-US")
expect Locale.parse("zh-hant-tw").map_ok(|l| l.tag()) == Ok("zh-Hant-TW")
expect Locale.parse("es-419").map_ok(|l| l.tag()) == Ok("es-419")
expect Locale.parse("de-DE-1996").map_ok(|l| l.tag()) == Ok("de-DE")
expect Locale.parse("en-US-u-ca-gregory").map_ok(|l| l.tag()) == Ok("en-US")
expect Locale.parse("pl_PL.UTF-8").map_ok(|l| l.tag()) == Ok("pl-PL")
expect Locale.parse(" pl ").map_ok(|l| l.tag()) == Ok("pl")
expect Locale.parse("*") == Err(InvalidTag("*"))
expect Locale.parse("") == Err(InvalidTag(""))
expect Locale.parse("x-private") == Err(InvalidTag("x-private"))
expect Locale.parse("english") == Err(InvalidTag("english"))
expect Locale.parse("PL") == Locale.parse("pl")
expect Locale.of("en-GB").language_of() == "en"
expect Locale.of("en-GB").region_of() == "GB"
expect tags(Locale.of("zh-Hant-TW").fallbacks()) == ["zh-Hant-TW", "zh-Hant", "zh"]
expect tags(Locale.of("pl-PL").fallbacks()) == ["pl-PL", "pl"]
expect tags(Locale.of("pl").fallbacks()) == ["pl"]
expect Locale.of("ar-EG").direction() == "rtl"
expect Locale.of("pl").direction() == "ltr"

expect tags(Locale.accept_language("pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7")) == ["pl-PL", "pl", "en-US", "en"]
expect tags(Locale.accept_language("en;q=0.5, de, *;q=0.1, fr;q=0")) == ["de", "en"]
expect tags(Locale.accept_language("da, en-gb;q=0.8, en;q=0.8")) == ["da", "en-GB", "en"]
expect tags(Locale.accept_language("")) == []
expect tags(Locale.accept_language("fr;q=bad, it")) == ["fr", "it"]

app_locales : List(Locale)
app_locales = [Locale.of("en"), Locale.of("en-GB"), Locale.of("pl"), Locale.of("de")]

expect Locale.best([Locale.of("pl-PL")], app_locales, Locale.of("en")).tag() == "pl"
expect Locale.best([Locale.of("en-GB")], app_locales, Locale.of("en")).tag() == "en-GB"
expect Locale.best([Locale.of("en-AU")], app_locales, Locale.of("de")).tag() == "en"
expect Locale.best([Locale.of("fr"), Locale.of("de-AT")], app_locales, Locale.of("en")).tag() == "de"
expect Locale.best([Locale.of("ja")], app_locales, Locale.of("en")).tag() == "en"
expect Locale.best([Locale.of("en-US"), Locale.of("de")], [Locale.of("en-GB"), Locale.of("de")], Locale.of("de")).tag() == "en-GB"
expect Locale.best([], app_locales, Locale.of("pl")).tag() == "pl"
expect Locale.lookup([Locale.of("ja")], app_locales) == Err(NoMatch)

expect {
	request = { method: "GET", headers: [{ name: "accept-language", value: "de-AT,de;q=0.9" }, { name: "cookie", value: "theme=dark; locale=pl" }] }
	tags(Locale.wanted(request, "locale")) == ["pl", "de-AT", "de"]
}

expect {
	request = { headers: [{ name: "Accept-Language", value: "fr" }, { name: "cookie", value: "locale=nonsense!" }] }
	tags(Locale.wanted(request, "locale")) == ["fr"]
}

expect tags(Locale.wanted({ headers: [] }, "")) == []
