# intl

Internationalisation for Roc Solid apps: numbers, money, dates and relative times as each locale
writes them, plural rules, translated messages with plurals and selects, and the reader's locale
chosen from a cookie or `Accept-Language`. It is plain Roc on no platform, so a page the server
renders and a component in the browser write the same text, and hydration finds what the server
wrote. The docs site's intl page (`/ecosystem/intl`) has a live demo, a picker over numbers, money
and dates, and, written as the site is built, messages and what each starter locale writes;
`example/` is a small app that uses the package on both platforms, and the page's listings are
picked from it.

```roc
import intl.Intl
import intl.Locales

intl = Intl.new(Locales.pl).with_catalog(I18n.catalog)

intl.number(12345.5)                             # "12 345,5"
intl.currency(1234.5, "PLN")                     # "1234,50 zł"
intl.date(moment, Long)                          # "21 listopada 2026"
intl.relative(-2, Hour)                          # "2 godziny temu"
intl.t("cart.items", [("count", Int(3))])        # "3 produkty"
```

## What is in it

| Module | What it does |
|---|---|
| `Intl` | one locale's way of writing things, and its messages: `Intl.choose(supported, wanted)`, `number`, `fixed`, `percent`, `compact`, `currency`, `date`, `time`, `date_time`, `day`, `month_year`, `relative`, `relative_day`, `ago`, `plural`, `ordinal`, `t`, `issue`; `tag`, `name`, `direction` for `<html lang dir>` |
| `Locale` | a BCP 47 tag: `Locale.parse("EN_us")` is `en-US`; `fallbacks` (`pl-PL`, then `pl`); `accept_language(header)`; `best(wanted, supported, default)`; `wanted(request, cookie)`, what a request asks for |
| `Locales` | each starter locale's data: `en`, `en_gb`, `de`, `fr`, `es`, `pl`, `cs`, `ru`, `ar`, `ja` (and `all`), from CLDR 48 |
| `Plural` | CLDR's categories (`Zero`, `One`, `Two`, `Few`, `Many`, `Other`), each language's cardinal and ordinal rules, `Forms` |
| `NumberFormat` | numbers with a locale's `Symbols`: grouping, fraction digits (`Options`, `defaults`), percent, compact, currency |
| `Date` | a day on the calendar (`Date.ymd(2026, 11, 21)`), days since 1970, weekdays, adding days and months, ISO 8601 |
| `DateFormat` | dates and times by CLDR patterns (`d MMMM y`), in four styles |
| `RelativeTime` | "in 3 days", "3 dni temu"; `between(ms)`, the unit a difference is said in |
| `Message` | an ICU MessageFormat subset: `{name}`, `{n, plural, …}`, `{n, selectordinal, …}`, `{x, select, …}`, `{n, number}`, `{d, date}`, `{d, time}` |
| `Catalog` | translated messages, a set for each locale, with fallback to the default, and `problems()`: what is missing or wrong |
| `Validation` | the words for packages/forms' issues (`too_short`, `not_email`, …) in every starter locale |
| `components/Language.rocx` | the reader's `Intl` as a Solid context, and `<Language>`, a picker that switches the page in place |

`roc test packages/intl/main.roc` runs the package's expects. Every locale's numbers, money,
dates, times and relative times are checked against what JavaScript's `Intl` writes (Node 24's ICU
78, CLDR 48) for the same input, and every plural rule against `Intl.PluralRules`, number by
number.

## The reader's locale

An app lists the locales it supports, the first being its default, and its messages. The locale a
request is read in comes from its `locale` cookie (the reader's own choice, kept), else its
`Accept-Language`, else the default. `Locale.best` takes the closest supported locale: `pl-PL`
takes `pl`, `en-US` takes `en-GB` rather than another language, and `en-AU, de` takes `en` when
both are supported.

```roc
# I18n.rocx, a module of the app's
import pf.Html
import intl.Locales
import intl.Catalog
import intl.Validation

I18n := [].{

	supported : List(Locales.Data)
	supported = [Locales.en, Locales.pl, Locales.ar]

	catalog : Catalog
	catalog = Catalog.merge(
		Validation.catalog,
		Catalog.new(
			"en",
			[
				("en", [("title", "Your basket"), ("items", "{count, plural, =0 {Nothing in it yet} one {# thing} other {# things}}")]),
				("pl", [("title", "Twój koszyk"), ("items", "{count, plural, =0 {Jeszcze nic} one {# rzecz} other {# rzeczy}}")]),
				("ar", [("title", "سلتك"), ("items", "{count, plural, zero {لا شيء بعد} one {شيء واحد} two {شيئان} few {# أشياء} many {# شيئًا} other {# شيء}}")]),
			],
		),
	)
}
```

The request's locale is a GET endpoint's answer, which the layout reads as the page renders, so
the browser hydrates in the one the server chose (D-023):

```roc
# routes/locale/+server.roc: GET /locale (beside its POST, which keeps a reader's pick)
import pf.Server
import pf.Endpoint
import intl.Intl
import intl.Locale
import ../../I18n

get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |{ request, .. }| Ok(Intl.choose(I18n.supported, Locale.wanted(request, "locale")).tag())
```

`Locale.wanted` takes the platform's `Server.Request` (or any record with its `headers`), so it
needs no platform itself. A middleware can call it as well, and hand the tag on in its context.

## In components: the `Language` context

Name the package in the app's header (`main.roc`), as charts is named:
`intl: "../packages/intl/main.roc"`. `rocx build` copies `components/Language.rocx` into the app
(as charts' components are copied). The root layout makes the store and provides it; `<html lang dir>` follow it:

```roc
# routes/+layout.rocx
import pf.Html
import pf.Context
import pf.Endpoint
import pf.Call
import intl.Language
import ../I18n
import ../Generated/Styles
import ../Generated/Api

view! = |{ children, .. }| {
	# A reader's pick is kept in the `locale` cookie (POST /locale), so the next page is in it too.
	remember! = |tag| {
		_kept = Endpoint.send!(Api.post_locale({}), { tag: tag }, Call.fetch!)
		{}
	}
	# The reader's locale: GET /locale, answered as the server renders the page, carried in it.
	tag = Endpoint.get!(Api.get_locale({}))
	store = Language.store!({ supported: I18n.supported, catalog: I18n.catalog, tag, remember! })
	{ intl!, .. } = store
	<>
		<!doctype html>
		<html lang={intl!().tag()} dir={intl!().direction()}>
			<head>
				<meta charset="utf-8" />
				{=Styles.style}
			</head>
			<body>
				<LanguageContext value={store}>{...children}</LanguageContext>
			</body>
		</html>
	</>
}
```

A component reads it with `use_context!`, and each hole that calls `intl!()` is written again when
the reader picks another locale; nothing else runs:

```roc
import pf.Html
import pf.Solid exposing [create_signal!, use_context!]
import intl.Language

Basket := [].{
	view! : {} => Html
	view! = |{}| {
		{ intl!, .. } = use_context!(Language.language_context)
		(count!, set_count!) = create_signal!(3)
		<section>
			<Language label="Language" />
			<h1>{intl!().t("title", [])}</h1>
			<p>{intl!().t("items", [("count", Int(count!()))])}</p>
			<button on:click={|| set_count!(count!() + 1)}>+</button>
		</section>
	}
}
```

`<Language label="…" />` is a `<select>` of the supported locales, each named in its own language
("English", "polski", "العربية"). Picking one switches the page at once, and calls `remember!`.
The endpoint that keeps the choice is the app's own:

```roc
# routes/locale/+server.roc
import pf.Server
import pf.Endpoint
import intl.Locale

## POST /locale, `tag=pl` (a form) or `{"tag":"pl"}` (the picker): the reader's choice, kept a year.
post! : { request : Server.Request, params : {}, context : c, body : { tag : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, body, .. }|
	match Locale.parse(body.tag) {
		Ok(locale) => {
			kept = |answer| Server.set_cookie(answer, "locale", locale.tag(), { ..Server.cookie_defaults, max_age_s: 365 * 86400 })
			if Server.wants_html(request) {
				Err(Answer(kept(Server.redirect(Server.header(request, "referer") ?? "/"))))
			} else {
				Err(Answer(kept(Server.response(204, [], ""))))
			}
		}
		Err(_) => Err(BadRequest("not a language tag: ${body.tag}"))
	}
```

| `Language` | |
|---|---|
| `Store : { intl! : () => Intl, choose! : Str => {}, supported : List(Locales.Data) }` | what the context holds |
| `language_context` | the context (`<LanguageContext value={store}>`, `use_context!(Language.language_context)`) |
| `store!({ supported, catalog, tag, remember! })` | a store in `tag`'s locale; `choose!(tag)` switches it and calls `remember!(tag)` |
| `<Language label={…} />` | the picker; its class is `language` |

## Formatting

| `Intl` | English | Polish |
|---|---|---|
| `number(-1234567.891)` | `-1,234,567.891` | `-1 234 567,891` |
| `number(1234.5)` | `1,234.5` | `1234,5` (Polish groups from five digits) |
| `fixed(2.5, 2)`, `int(n)`, `number_with(x, { ..NumberFormat.defaults, min_fraction: 1 })` | `2.50` | `2,50` |
| `percent(0.256, 1)` | `25.6%` | `25,6%` |
| `compact(1234)`, `compact(12345678)` | `1.2K`, `12M` | `1,2 tys.`, `12 mln` |
| `currency(-1234.5, "EUR")` | `-€1,234.50` | `-1234,50 €` |
| `date(ms, Short \| Medium \| Long \| Full)` | `11/21/26`, `Nov 21, 2026`, `November 21, 2026`, `Saturday, November 21, 2026` | `21.11.2026`, `21 lis 2026`, `21 listopada 2026`, `sobota, 21 listopada 2026` |
| `time(ms, Short \| Medium)` | `3:04 PM` | `15:04` |
| `date_time(ms, Long, Short)` | `November 21, 2026 at 3:04 PM` | `21 listopada 2026 15:04` |
| `day(Date.ymd(2026, 1, 5), Long)` | `January 5, 2026` | `5 stycznia 2026` |
| `month_year(date)`, `month_name(11)`, `weekday_name(6)` | `November 2026`, `November`, `Saturday` | `listopad 2026`, `listopad`, `sobota` |
| `relative(-3, Day)`, `relative(2, Hour)` | `3 days ago`, `in 2 hours` | `3 dni temu`, `za 2 godziny` |
| `relative_day(-1)` | `yesterday` | `wczoraj` |
| `ago(moment, now)` | `5 minutes ago` | `5 minut temu` |
| `plural(22)`, `ordinal(23)` | `Other`, `Few` ("23rd") | `Few`, `Other` |

A moment is milliseconds since the epoch (`Time.now_millis!({}).to_i64_wrap()` on the server).
Dates are written in UTC, or at a fixed offset: `intl.in_offset(60)` for Central European winter
time. `ago` says a difference in the unit that suits it: seconds under a minute, then minutes,
hours, days (under a week), weeks (under 30 days), months and years, rounded half away from zero.

Arabic is written as CLDR 48 writes it: Latin digits, its marks for right-to-left text
(`‏1,234.50 €`), and its dual without a digit (`خلال ساعتين`, "in two hours").
`intl.direction()` is `"rtl"` for it.

## Messages

A catalog holds a set of keyed messages for each locale; one locale is the default. A key is looked
up in the reader's locale, then in what it falls back to (`pl-PL`, then `pl`), then in the default,
so a regional set (`en-GB`) holds only what it says differently. A key no set has is shown as
itself, so it is seen. Catalogs are Roc: a list of `(key, message)` for each locale, read once
when the catalog is made (a build step that reads files instead is a proposal).

| Message | |
|---|---|
| `Hello, {name}!` | an argument: text as it is, a number as the locale writes it |
| `{count, plural, =0 {No files} one {# file} other {# files}}` | the case for the number's plural category (`zero`, `one`, `two`, `few`, `many`, `other`); `=0` is that exact number, tried first; `#` is the number; `other` is required |
| `{guests, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}` | `offset:` takes that much off `#` and the category, not off `=N` |
| `{place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}` | the ordinal's category |
| `{role, select, admin {Administrator} other {Member}}` | the case named by the argument's text |
| `{total, number}`, `{n, number, integer}`, `{share, number, percent}` | a number, rounded to a whole one, as a percentage |
| `{when, date, short\|medium\|long\|full}`, `{when, time, short\|medium}` | a moment's date or time |
| `It''s '{literal}'` | ICU's apostrophes: `''` is one, and `'{` starts quoted text; any other apostrophe is itself (`l'heure`) |

Arguments are `[("name", Text("Ada")), ("count", Int(3)), ("price", Num(9.99)), ("when", Moment(ms))]`.
A plain tag union (`Message.Arg`), so a package that doesn't depend on this one can build them. A
text in ASCII digits counts as a number in a plural or `number`, and an ISO date as a day in `date`.

```roc
expect Catalog.problems(I18n.catalog) == []

Catalog.problems(I18n.catalog).map(Catalog.explain)
# ["pl has no \"colour\" yet (the default's is shown)",
#  "pl's \"hello\" reads {imie} where the default's reads {name}",
#  "pl's \"extra\" isn't a key of the default's: misspelt, or no longer used?",
#  "pl's \"cart\" can't be read, so it is shown as written: at 69, `count`'s plural is never closed"]
```

`catalog.missing("pl")` lists the keys still to translate. `Catalog.merge(base, top)` puts the
app's messages over a package's.

## packages/forms' issues

forms gives each issue a key and its parameters (`Issues.key(code)` is `"too_short"`,
`Issues.params(code)` is `[{ name: "min", value: "3" }]`). `intl.issue` says them in the reader's
language, from `Validation.catalog`, which has words for all of forms' keys in every starter
locale, in forms' voice ("Use at least 3 characters"):

```roc
intl = Intl.choose(I18n.supported, wanted).with_catalog(Catalog.merge(Validation.catalog, I18n.catalog))

intl.issue(Issues.key(issue.code), Issues.params(issue.code))     # "Wpisz co najmniej 3 znaki"
```

A number in the params picks the plural and is written as the locale writes numbers (`1.500,5`); a
day (`too_early`) as the locale writes dates. To change a sentence, or to say a custom code's
(`Custom("not_postcode", …)`), put `validation.<key>` in the app's catalog.

## Locale data

`Locales.roc` is written by `tools/locales.mjs` from the CLDR in Node's ICU: decimal and grouping
marks, percent and money patterns, currency symbols, compact patterns, month and weekday names,
date and time patterns in each style, and relative-time words for each plural category. Plural
rules are code, in `Plural.roc`. To add a locale, add it to the script's list (and its plural
rules, if its language is new), run it, and `rocx fmt` the package:

```sh
node packages/intl/tools/locales.mjs > packages/intl/Locales.roc
```

An app's wasm holds only the locales it names. Measured on a small app in the browser
(`--opt=size`, brotli):

| | brotli |
|---|---|
| the app without intl | 19.8 KB |
| intl's numbers, one locale | +12.6 KB |
| all formatting (numbers, money, dates, relative times), one locale | +22.1 KB |
| and messages (`Message`, `Catalog`) | +34.5 KB |
| and `Validation.catalog` (nine languages) | +39.1 KB |
| each more locale | about +1 KB |

## Differences from JavaScript's `Intl`

- Numbers are `Dec`, rounded half away from zero, as `Intl` rounds. A negative number that rounds
  to zero is `"0"`, not `"-0"`.
- Plural rules see a `Dec` as its shortest digits: `plural(1.0)` is `One` in English. For the
  visible zeros (`"1.0 files"`), give the digits: `Plural.operands("1.0")`.
- Time is UTC or a fixed offset, not a named time zone, so summer time isn't followed.
- Relative time has no quarters, and words for "yesterday", "today" and "tomorrow" only
  (`relative_day`); compact numbers have only the short form.
- A locale's fallbacks are its tag, shortened (`zh-Hant-TW`, `zh-Hant`, `zh`), without CLDR's parent
  locales (`en-AU` → `en-001`).

## Status

Works today, and tested: locales, negotiation, plural rules, numbers, money, compact numbers,
dates and times, relative times, messages and catalogs, forms' issues, for the ten starter
locales; the `Language` context and picker. A scratch app on both platforms rendered its page in
Polish for `Accept-Language: pl` and in Arabic (`dir="rtl"`) for a `locale=ar` cookie, hydrated in
Chromium without a warning, switched language in place, kept the choice through `POST /locale`, and
was in it again after a reload.

Waiting on a proposal (`PROPOSALS.md`): a middleware and an endpoint shipped by the package (today
the app writes the dozen lines above); the picker as a component of its own; message keys checked
by the compiler; named time zones; fuller CLDR data.
