# intl

Internationalisation for Roc Solid apps: numbers, money, dates and relative times as each locale
writes them, plural rules, translated messages with plurals and selects, and the reader's locale,
chosen from a cookie or `Accept-Language`. It is plain Roc on no platform, so a page the server
renders and a component in the browser write the same text, and hydration finds what the server
wrote.

The docs site's intl page (`/ecosystem/intl`) is the guide: a live demo (a picker over numbers,
money and dates) and, written as the site is built, what each starter locale writes and the
messages. `example/` is a small app that uses the package on both platforms; the page's listings
are picked from it. This README is the reference.

## Installing it

Name the package in the app's header (`main.roc`), by its directory's name:

```roc
app [program] { intl: "../packages/intl/main.roc", pf: platform "…/server/platform/main.roc" }
```

Any file of either half of the app, or a test, imports the modules as they are
(`import intl.Intl`). `rocx build` copies the one component, `components/Language.rocx`, into the
app (`Generated/intl/Language.roc`), as every package's components are copied, and
`import intl.Language` imports that copy.

```roc
import intl.Intl
import intl.Locales
import intl.Catalog

words = Catalog.new(
	"en",
	[
		("en", [("cart.items", "{count, plural, =0 {Your cart is empty} one {# item} other {# items}}")]),
		("pl", [("cart.items", "{count, plural, =0 {Koszyk jest pusty} one {# produkt} few {# produkty} other {# produktów}}")]),
	],
)

intl = Intl.new(Locales.pl).with_catalog(words)

intl.number(12345.5)                             # "12 345,5"
intl.currency(1234.5, "PLN")                     # "1234,50 zł"
intl.date(moment, Long)                          # "21 listopada 2026"
intl.relative(-2, Hour)                          # "2 godziny temu"
intl.t("cart.items", [("count", Int(3))])        # "3 produkty"
```

## What is in it

| Module | What it does |
|---|---|
| `Intl` | One locale's way of writing things, and its messages. Made with `new`, `choose` or `for_tag`; the functions are under [Formatting](#formatting) and [Messages](#messages). |
| `Locale` | A BCP 47 tag: `parse` (`Locale.parse("EN_us")` is `en-US`), `of` (a literal; crashes on a bad one), `tag`, `language_of`, `region_of`, `direction`; `fallbacks` (`pl-PL`, then `pl`); `accept_language(header)`; `best(wanted, supported, default)` and `lookup(wanted, supported)`; `wanted(request, cookie)`, what a request asks for |
| `Locales` | Each starter locale's data, from CLDR 48: `en`, `en_gb`, `de`, `fr`, `es`, `pl`, `cs`, `ru`, `ar`, `ja`, and `all`. A `Locales.Data` holds a locale's tag, its name in its own language, its number symbols, date names and patterns, relative-time words, and its plural rules (`cardinal`, `ordinal`). |
| `Plural` | CLDR's categories (`Category : [Zero, One, Two, Few, Many, Other]`), each language's cardinal and ordinal rules, `operands` (a number's digits, as plural rules read them), `Forms` (a word for each category) and `pick`, `name`, `from_name` |
| `NumberFormat` | Numbers by a locale's `Symbols`: `format` with `Options` (`{ min_fraction, max_fraction, grouping }`, `defaults` up to three fraction digits, grouped), `percent`, `compact`, `currency`, `currency_digits`, `digits` |
| `Date` | A day on the calendar: `ymd(2026, 11, 21)`, `of_millis(ms, offset_minutes)`, `from_days`/`to_days` (days since 1970), `weekday` (Sunday is 0), `add_days`, `add_months`, `days_between`, `days_in_month`, `is_leap_year`, `parse_iso`, `to_iso` |
| `DateFormat` | Dates and times by CLDR's patterns (`d MMMM y`), in four styles (`Style : [Short, Medium, Long, Full]`) |
| `RelativeTime` | "in 3 days", "3 dni temu" (`Unit : [Second, Minute, Hour, Day, Week, Month, Year]`); `between(ms)`, the unit a difference is said in |
| `Message` | The ICU MessageFormat subset under [Messages](#messages): `parse`, `format`, `names`, `literal`, and `Arg : [Text(Str), Int(I64), Num(Dec), Moment(I64)]` |
| `Catalog` | Translated messages, a set for each locale, with fallback to the default: `new`, `empty`, `add`, `merge`, `find`, `has_key`, `keys`, `locales`, `default_locale`, `missing`, `problems`, `explain` |
| `Validation` | `catalog`: the words for packages/forms' issues (`too_short`, `not_email`, …) in every starter locale |
| `components/Language.rocx` | The reader's `Intl` as a Solid context, and `<Language>`, a picker that switches the page in place |

`roc test packages/intl/main.roc` runs the package's `expect`s. Every locale's numbers, money,
dates, times and relative times are checked against what JavaScript's `Intl` writes (Node 24's ICU
78, CLDR 48) for the same input, and every plural rule against `Intl.PluralRules`, number by
number.

## The reader's locale

An app lists the locales it supports, its default first, and its messages, in a module of its own:

```roc
# I18n.rocx
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
				("pl", [("title", "Twój koszyk"), ("items", "{count, plural, =0 {Jeszcze nic} one {# rzecz} few {# rzeczy} many {# rzeczy} other {# rzeczy}}")]),
				("ar", [("title", "سلتك"), ("items", "{count, plural, zero {لا شيء بعد} one {شيء واحد} two {شيئان} few {# أشياء} many {# شيئًا} other {# شيء}}")]),
			],
		),
	)
}
```

Only the locales an app names are compiled into it.

A request is read in the locale its `locale` cookie names (the reader's own choice, kept), else
the one its `Accept-Language` asks for, else the default. `Locale.wanted(request, "locale")` reads
both, most wanted first, and `Intl.choose` (by `Locale.best`) takes the closest supported locale:
`pl-PL` gets `pl`; `en-US` gets `en-GB` rather than another language when there is no plain `en`;
`en-AU` gets `en`.

The request's locale is a GET endpoint's answer. The root layout reads it as the page renders, so
the page carries it and the browser hydrates in the locale the server chose:

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

`Locale.wanted` takes the platform's `Server.Request` (or any record with its `headers`), so the
package needs no platform. A middleware can call it too, and hand the tag on in its context.

## In components: `Language`

The root layout makes the store and provides it as a context. `<html lang dir>` follow it, so the
page turns right to left for Arabic:

```roc
# routes/+layout.rocx
import pf.Html
import pf.Context
import pf.Endpoint
import intl.Language
import ../I18n
import ../Generated/Styles
import ../Generated/Api

view! = |{ children, .. }| {
	# A reader's pick is kept in the `locale` cookie (POST /locale), so the next page is in it too.
	remember! = |tag| {
		_kept = Api.post_locale({}).send!({ tag: tag })
		{}
	}
	# The reader's locale: GET /locale, answered as the server renders the page, carried in it.
	tag = Api.get_locale({}).read!()
	store = Language.store!({ supported: I18n.supported, catalog: I18n.catalog, tag, remember! })
	{ intl!, .. } = store
	<>
		<!doctype html>
		<html lang={intl!().tag()} dir={intl!().direction()}>
			<head>
				<meta charset="utf-8" />
				{Styles.style}
			</head>
			<body>
				<LanguageContext value={store}>{...children}</LanguageContext>
			</body>
		</html>
	</>
}
```

A component reads the store with `use_context!`. When the reader picks another locale, each hole
that calls `intl!()` is written again; nothing else runs:

```roc
# Basket.rocx, shortened
import pf.Html
import pf.Solid exposing [create_signal!, use_context!]
import intl.Language

Basket := [].{
	view! : {} => Html
	view! = |{}| {
		{ intl!, .. } = use_context!(Language.language_context)
		(count!, set_count!) = create_signal!(3)
		<section class="basket">
			<Language label="Language" />
			<h1>{intl!().t("title", [])}</h1>
			<p>{intl!().t("items", [("count", Int(count!()))])}</p>
			<button on:click={|| set_count!(count!() + 1)}>+</button>
		</section>
	}
}
```

`<Language label="…" />` is a `<select>` of the supported locales, each named in its own language
("English", "polski", "العربية"). Picking one switches the page at once, then calls `remember!`.
The endpoint that keeps the choice is the app's own:

```roc
# routes/locale/+server.roc
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
| `Store : { intl! : () => Intl, choose! : Str => {}, supported : List(Locales.Data) }` | What the context holds: the reader's `Intl`, a way to choose another, and the choices. |
| `language_context` | The context: `<LanguageContext value={store}>` provides it, `use_context!(Language.language_context)` reads it. |
| `store!({ supported, catalog, tag, remember! })` | A store in `tag`'s locale (the closest supported one; a string that isn't a tag gets the default). Its `choose!(tag)` switches it and calls `remember!(tag)`. |
| `<Language label={…} />` | The picker. `label` names it for screen readers; its class is `language`. |

## Formatting

| `Intl` | English | Polish |
|---|---|---|
| `number(-1234567.891)` | `-1,234,567.891` | `-1 234 567,891` |
| `number(1234.5)` | `1,234.5` | `1234,5` (Polish groups from five digits) |
| `fixed(2.5, 2)` | `2.50` | `2,50` |
| `int(12345)` | `12,345` | `12 345` |
| `number_with(1234.5678, { ..NumberFormat.defaults, max_fraction: 2 })` | `1,234.57` | `1234,57` |
| `percent(0.256, 1)` | `25.6%` | `25,6%` |
| `compact(1234)`, `compact(12345678)` | `1.2K`, `12M` | `1,2 tys.`, `12 mln` |
| `currency(-1234.5, "EUR")` | `-€1,234.50` | `-1234,50 €` |
| `date(ms, Short \| Medium \| Long \| Full)` | `11/21/26`, `Nov 21, 2026`, `November 21, 2026`, `Saturday, November 21, 2026` | `21.11.2026`, `21 lis 2026`, `21 listopada 2026`, `sobota, 21 listopada 2026` |
| `time(ms, Short)`, `time(ms, Medium)` | `3:04 PM`, `3:04:05 PM` | `15:04`, `15:04:05` |
| `date_time(ms, Long, Short)` | `November 21, 2026 at 3:04 PM` | `21 listopada 2026 15:04` |
| `day(Date.ymd(2026, 1, 5), Long)`, a day with no time | `January 5, 2026` | `5 stycznia 2026` |
| `month_year(date)`, `month_name(11)`, `weekday_name(6)` | `November 2026`, `November`, `Saturday` | `listopad 2026`, `listopad`, `sobota` |
| `relative(-3, Day)`, `relative(2, Hour)` | `3 days ago`, `in 2 hours` | `3 dni temu`, `za 2 godziny` |
| `relative_day(-1)` | `yesterday` | `wczoraj` |
| `ago(moment, now)`, five minutes apart | `5 minutes ago` | `5 minut temu` |
| `plural(22)`, `ordinal(23)` | `Other`, `Few` ("23rd") | `Few`, `Other` |
| `tag()`, `name()`, `direction()` | `en`, `English`, `ltr` | `pl`, `polski`, `ltr` |

`locale()` is the `Locale`, and `catalog()` the messages `t` looks in.

A moment is milliseconds since the epoch (`Time.now_millis!({}).to_i64_wrap()` on the server).
Dates are written in UTC, or at a fixed offset: `intl.in_offset(60)` for Central European winter
time. `ago` says a difference in the unit that suits it: seconds under a minute, then minutes,
hours, days (under a week), weeks (under 30 days), months (under a year) and years, rounded half
away from zero.

Arabic is written as CLDR 48 writes it: Latin digits, invisible marks that keep right-to-left text
in order (`‏1,234.50 €`), and its dual without a digit (`خلال ساعتين`, "in two hours").
`intl.direction()` is `"rtl"` for it.

## Messages

A catalog holds a set of keyed messages for each locale; one locale is the default.
`intl.t(key, args)` looks a key up in the reader's locale, then in what it falls back to (`pl-PL`,
then `pl`), then in the default. So a regional set (`en-GB`) holds only what it says differently,
and a missing translation shows the default's words. A key that no set has is shown as itself, so
you see it and fix it. `intl.translated(key)` says whether the locale has its own words for a key,
and `intl.format(message, args)` formats a message given inline rather than from the catalog.

Catalogs are Roc: a list of `(key, message)` pairs for each locale, each message read once, when
the catalog is made. A message that can't be read is shown as written, and `problems` reports it.

| Message | |
|---|---|
| `Hello, {name}!` | An argument: text as it is, a number as the locale writes it. |
| `{count, plural, =0 {No files} one {# file} other {# files}}` | The case for the number's plural category (`zero`, `one`, `two`, `few`, `many`, `other`). `=0` is that exact number, tried first; `#` is the number; `other` is required. |
| `{guests, plural, offset:1 =0 {Nobody} =1 {{host}} one {{host} and # other} other {{host} and # others}}` | `offset:` takes that much off `#` and the category, not off `=N`. |
| `{place, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}` | The ordinal's category. |
| `{role, select, admin {Administrator} other {Member}}` | The case named by the argument's text. |
| `{total, number}`, `{n, number, integer}`, `{share, number, percent}` | A number; rounded to a whole one; as a percentage. |
| `{when, date, short\|medium\|long\|full}`, `{when, time, short\|medium}` | A moment's date or time. |
| `It''s '{literal}'` | ICU's apostrophes: `''` is one, and `'{` starts quoted text; any other apostrophe is itself (`l'heure`). |

Arguments are a list of names and values:
`[("name", Text("Ada")), ("count", Int(3)), ("price", Num(9.99)), ("when", Moment(ms))]`. `Message.Arg`
is a plain tag union, so a package that doesn't depend on this one can build them. A `Text` of
ASCII digits counts as a number in a plural or `number`, and an ISO date as a day in `date`.

`Catalog.problems(catalog)` lists what a translator still has to do, and `Catalog.explain` says
each in a sentence. Put `expect Catalog.problems(I18n.catalog) == []` in the app's tests. For a
catalog with mistakes in it:

```roc
typos = Catalog.new(
	"en",
	[
		("en", [("title", "Shop"), ("cart", "{count, plural, one {# item} other {# items}}"), ("hello", "Hello, {name}!"), ("colour", "Colour")]),
		("pl", [("title", "Sklep"), ("cart", "{count, plural, one {# produkt} few {# produkty} other {# produktów}"), ("hello", "Cześć, {imie}!"), ("extra", "Nadmiar")]),
	],
)

Catalog.problems(typos).map(Catalog.explain)
# ["pl has no \"colour\" yet (the default's is shown)",
#  "pl's \"hello\" reads {imie} where the default's reads {name}",
#  "pl's \"extra\" isn't a key of the default's: misspelt, or no longer used?",
#  "pl's \"cart\" can't be read, so it is shown as written: at 69, `count`'s plural is never closed"]
```

`catalog.missing("pl")` lists the keys still to translate. `Catalog.merge(base, top)` puts one
catalog's messages over another's (the app's over a package's).

## packages/forms' issues

packages/forms gives each issue a key and its parameters (`Issues.key(code)` is `"too_short"`,
`Issues.params(code)` is `[{ name: "min", value: "3" }]`). `intl.issue(key, params)` says them in
the reader's language, from `Validation.catalog`, which has words for all nineteen of forms' keys in
every starter locale, in forms' voice ("Use at least 3 characters"):

```roc
intl = Intl.choose(I18n.supported, wanted).with_catalog(Catalog.merge(Validation.catalog, I18n.catalog))

intl.issue(Issues.key(issue.code), Issues.params(issue.code))     # "Wpisz co najmniej 3 znaki"
```

A number in the params picks the plural and is written as the locale writes numbers (`1.500,5`); a
day (`too_early`, `too_late`) as the locale writes dates. To change a sentence, or to word a
`Custom("not_postcode", …)` issue, put `validation.<key>` in the app's catalog.
`intl.error({ code, args })` is the same lookup with `Message.Arg`s, for a validator other than
forms.

| Key | Params |
|---|---|
| `required`, `unchecked` | |
| `too_short`, `too_long` | `min`, `max`: a count of characters |
| `no_match`, `not_email`, `not_url`, `not_date`, `not_one_of`, `not_integer`, `not_number` | |
| `too_small`, `too_large` | `min`, `max`: a number |
| `not_step` | `below`, `above`: the nearest numbers allowed |
| `too_early`, `too_late` | `min`, `max`: a day (`2026-01-31`) |
| `too_few`, `too_many` | `min`, `max`: a count of items |
| `not_same` | |

## Locale data and size

`Locales.roc` is written by `tools/locales.mjs` from the CLDR in Node's ICU: decimal and grouping
marks, percent and money patterns, currency symbols, compact patterns, month and weekday names,
date and time patterns in each style, and relative-time words for each plural category. Plural
rules are code, in `Plural.roc`. To add a locale, add it to the script's list (and its plural
rules, if its language is new), run it, and format the package:

```sh
node packages/intl/tools/locales.mjs > packages/intl/Locales.roc
rocx fmt packages/intl
```

An app's wasm holds only the locales it names. Measured on 2026-11-21 on a small app in the browser
(`--opt=size`, brotli), and not measured again since the browser's host moved to Rust (D-090):

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
- Plural rules see a `Dec` as its shortest digits: `plural(1.0)` is `One` in English. For visible
  zeros (`"1.0 files"`), give the locale's rule (`Locales.en.cardinal`) the digits as written,
  `Plural.operands("1.0")`: that is `Other`.
- Time is UTC or a fixed offset, not a named time zone, so summer time isn't followed.
- Relative time has no quarters, and has words for "yesterday", "today" and "tomorrow" only
  (`relative_day`). Compact numbers have only the short form.
- A locale's fallbacks are its tag, shortened (`zh-Hant-TW`, `zh-Hant`, `zh`), without CLDR's parent
  locales (`en-AU` → `en-001`).

## Status

Works today, and tested: locales and how one is chosen, plural rules, numbers, money, compact
numbers, dates and times, relative times, messages and catalogs, and forms' issues, for the ten
starter locales; the `Language` context and picker. The example app renders its page in Polish for
`Accept-Language: pl` and in Arabic (`dir="rtl"`) for a `locale=ar` cookie, hydrates without a
warning, switches language in place, keeps the choice through `POST /locale`, and is in it again
after a reload.

Not yet (each has a proposal in `PROPOSALS.md`): a middleware and an endpoint shipped by the
package (today the app writes the dozen lines above); message keys checked by the compiler; named
time zones; fuller CLDR data.
