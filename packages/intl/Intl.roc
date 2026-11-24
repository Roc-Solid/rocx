import Locale
import Locales
import Plural
import NumberFormat
import DateFormat
import RelativeTime
import Date
import Message
import Catalog

## One locale's way of writing things: its numbers, money, dates, relative times and plurals, and
## its translations of the app's messages. Made once for a request (or, in the browser, for the
## reader's choice), and handed to whatever renders, usually through a context:
##
##     intl = Intl.choose([Locales.en, Locales.pl], Locale.wanted(request, "locale")).with_catalog(Words.catalog)
##
##     intl.number(1234.5)                               # "1,234.5"      "1234,5"
##     intl.currency(19.99, "EUR")                       # "€19.99"       "19,99 €"
##     intl.date(moment, Long)                           # "November 21, 2026"   "21 listopada 2026"
##     intl.relative(-3, Day)                            # "3 days ago"   "3 dni temu"
##     intl.t("cart.items", [("count", Int(3))])         # "3 items"      "3 produkty"
##
## The server and the browser run the same Roc on the same data, so a page renders the same text
## in both, and hydrates without a difference.
Intl := { data : Locales.Data, catalog : Catalog, offset : I64 }.{

	## Formatting for one locale's data (`Locales.pl`), with no messages, in UTC.
	new : Locales.Data -> Intl
	new = |data| { data, catalog: Catalog.empty(data.tag), offset: 0 }

	## Formatting for the supported locale closest to what is wanted (`Locale.best`): `pl-PL` takes
	## `pl`, `en-US` takes `en-GB` when there is no `en`. The first supported locale is the default;
	## with none at all, English.
	choose : List(Locales.Data), List(Locale) -> Intl
	choose = |supported, wanted| {
		default = supported.first() ?? Locales.en
		picked = Locale.best(wanted, supported.map(|each| Locale.of(each.tag)), Locale.of(default.tag))
		Intl.new(supported.find_first(|each| Locale.of(each.tag) == picked) ?? default)
	}

	## As `choose`, for one tag (a cookie's, a link's `?lang=`); one that isn't a tag is the default.
	for_tag : List(Locales.Data), Str -> Intl
	for_tag = |supported, wanted_tag|
		Intl.choose(
			supported,
			match Locale.parse(wanted_tag) {
				Ok(found) => [found]
				Err(_) => []
			},
		)

	## The app's messages, translated: `t` looks keys up in it.
	with_catalog : Intl, Catalog -> Intl
	with_catalog = |intl, messages| { ..intl, catalog: messages }

	## Dates and times `offset_minutes` east of UTC (60 for Central European winter time, -300 for
	## New York's). The default is UTC. A fixed offset: summer time isn't followed (see README).
	in_offset : Intl, I64 -> Intl
	in_offset = |intl, offset_minutes| { ..intl, offset: offset_minutes }

	## The locale: `pl`.
	locale : Intl -> Locale
	locale = |intl| Locale.of(intl.data.tag)

	## Its tag, for `<html lang>`: `"pl"`.
	tag : Intl -> Str
	tag = |intl| intl.data.tag

	## Its name in its own language, for a language picker: `"polski"`, `"Deutsch"`, `"日本語"`.
	name : Intl -> Str
	name = |intl| intl.data.name

	## `"rtl"` for a language written from right to left (Arabic), else `"ltr"`: for `<html dir>`.
	direction : Intl -> Str
	direction = |intl| Locale.of(intl.data.tag).direction()

	## The messages `t` looks keys up in (an empty catalog until `with_catalog`).
	catalog : Intl -> Catalog
	catalog = |intl| intl.catalog

	## The plural category of a count: `intl.plural(3)` is `Few` in Polish.
	plural : Intl, Dec -> Plural.Category
	plural = |intl, count| (intl.data.cardinal)(Plural.of_dec(count))

	## The ordinal category of a rank: `intl.ordinal(2)` is `Two` in English ("2nd").
	ordinal : Intl, Dec -> Plural.Category
	ordinal = |intl, rank| (intl.data.ordinal)(Plural.of_dec(rank))

	## A number, to at most three fraction digits, grouped: `"1,234.5"`, `"1234,5"` (Polish
	## groups from five digits), `"1.234,5"`.
	number : Intl, Dec -> Str
	number = |intl, x| NumberFormat.format(intl.data.number, x, NumberFormat.defaults)

	## A number, rounded and padded as `options` say (`NumberFormat.Options`).
	number_with : Intl, Dec, NumberFormat.Options -> Str
	number_with = |intl, x, options| NumberFormat.format(intl.data.number, x, options)

	## A whole number: `intl.int(12345)` is `"12,345"`.
	int : Intl, I64 -> Str
	int = |intl, n| NumberFormat.format(intl.data.number, n.to_dec(), NumberFormat.defaults)

	## Exactly `places` fraction digits: `intl.fixed(2.5, 2)` is `"2.50"`.
	fixed : Intl, Dec, U64 -> Str
	fixed = |intl, x, places| NumberFormat.format(intl.data.number, x, { min_fraction: places, max_fraction: places, grouping: Bool.True })

	## A share as a percentage, to at most `places` fraction digits: 0.256 is `"25.6%"`, `"25,6%"`.
	percent : Intl, Dec, U64 -> Str
	percent = |intl, x, places| NumberFormat.percent(intl.data.number, x, places)

	## Short: `"1.2K"`, `"1,2 tys."`, `"1.2万"`.
	compact : Intl, Dec -> Str
	compact = |intl, x| NumberFormat.compact(intl.data.number, x)

	## Money in the currency `code` (`"EUR"`): `"€1,234.50"`, `"1234,50 €"`, `"￥1,235"`.
	currency : Intl, Dec, Str -> Str
	currency = |intl, amount, code| NumberFormat.currency(intl.data.number, amount, code)

	## The date of a moment (milliseconds since the epoch): Short `"11/21/26"`, Medium
	## `"Nov 21, 2026"`, Long `"November 21, 2026"`, Full `"Saturday, November 21, 2026"`.
	date : Intl, I64, DateFormat.Style -> Str
	date = |intl, ms, style| DateFormat.date(intl.data.dates, DateFormat.fields(ms, intl.offset), style)

	## The time of a moment: Short `"3:04 PM"` (`"15:04"`), Medium with seconds.
	time : Intl, I64, [Short, Medium] -> Str
	time = |intl, ms, style| DateFormat.time(intl.data.dates, DateFormat.fields(ms, intl.offset), style)

	## Both, joined as the locale joins them: `"Nov 21, 2026, 3:04 PM"`.
	date_time : Intl, I64, DateFormat.Style, [Short, Medium] -> Str
	date_time = |intl, ms, date_style, time_style| DateFormat.date_time(intl.data.dates, DateFormat.fields(ms, intl.offset), date_style, time_style)

	## A day on the calendar (no time, no zone): `intl.day(Date.ymd(2026, 11, 21), Long)`.
	day : Intl, Date, DateFormat.Style -> Str
	day = |intl, civil, style| DateFormat.date(intl.data.dates, DateFormat.of_date(civil), style)

	## A month of a year, as a calendar's heading: `"November 2026"`, `"listopad 2026"`.
	month_year : Intl, Date -> Str
	month_year = |intl, civil| DateFormat.month_year(intl.data.dates, DateFormat.of_date(civil))

	## A month's name standing alone, January being 1: `"listopad"`.
	month_name : Intl, I64 -> Str
	month_name = |intl, month| {
		names = intl.data.dates
		standalone = if (names.months_standalone.is_empty()) names.months else names.months_standalone
		standalone.get((month - 1).to_u64_wrap()) ?? "?"
	}

	## A weekday's name, Sunday being 0: `"sobota"` for 6.
	weekday_name : Intl, I64 -> Str
	weekday_name = |intl, weekday| intl.data.dates.weekdays.get(weekday.to_u64_wrap()) ?? "?"

	## `amount` of `unit` from now: `intl.relative(-3, Day)` is `"3 days ago"`, `"3 dni temu"`;
	## `intl.relative(2, Hour)` is `"in 2 hours"`, `"za 2 godziny"`.
	relative : Intl, I64, RelativeTime.Unit -> Str
	relative = |intl, amount, unit| RelativeTime.format(intl.data.relative, intl.data.cardinal, intl.data.number, amount, unit)

	## Days from today, in words where the locale has them: `"yesterday"`, `"today"`, `"tomorrow"`,
	## else `"in 3 days"`.
	relative_day : Intl, I64 -> Str
	relative_day = |intl, days| RelativeTime.days(intl.data.relative, intl.data.cardinal, intl.data.number, days)

	## How long before or after `now` a moment is, in the unit that suits it (`RelativeTime.between`):
	## `"5 minutes ago"`, `"in 2 days"`, `"3 months ago"`. Both in milliseconds since the epoch.
	ago : Intl, I64, I64 -> Str
	ago = |intl, moment, now| {
		{ amount, unit } = RelativeTime.between(moment - now)
		Intl.relative(intl, amount, unit)
	}

	## The catalog's message for `key`, in this locale (or what it falls back to, or the default),
	## with `args` put in. A key no set has is shown as itself, so it is seen and fixed.
	t : Intl, Str, List((Str, Message.Arg)) -> Str
	t = |intl, key, args|
		match intl.catalog.find(Locale.of(intl.data.tag), key) {
			Ok(message) => Message.format(message, intl.data, intl.offset, args)
			Err(Missing) => key
		}

	## Whether this locale has its own words for `key` (not the default's).
	translated : Intl, Str -> Bool
	translated = |intl, key| intl.catalog.has_key(Locale.of(intl.data.tag), key)

	## An ICU message given here, not from the catalog: `intl.format("{n, plural, one {# day} other {# days}}", [("n", Int(2))])`.
	## One that can't be read is shown as written.
	format : Intl, Str, List((Str, Message.Arg)) -> Str
	format = |intl, source, args|
		match Message.parse(source) {
			Ok(message) => Message.format(message, intl.data, intl.offset, args)
			Err(_) => source
		}

	## A validation error's words: `t("validation.${code}", args)`. The contract with
	## `packages/forms` (or any validator): an error is a code and its arguments, and
	## `Validation.catalog` has the words for the common codes.
	error : Intl, { code : Str, args : List((Str, Message.Arg)) } -> Str
	error = |intl, problem| Intl.t(intl, "validation.${problem.code}", problem.args)

	## A form's issue in this locale, from packages/forms' `Issues.key(code)` and
	## `Issues.params(code)`: `intl.issue("too_short", [{ name: "min", value: "3" }])` is
	## `"Wpisz co najmniej 3 znaki"` in Polish. Numbers in the params are read as numbers (for
	## plurals, and written as the locale writes them), ISO dates as days.
	issue : Intl, Str, List({ name : Str, value : Str }) -> Str
	issue = |intl, key, params| Intl.error(intl, { code: key, args: params.map(|param| (param.name, Text(param.value))) })
}

# --- Tests: each locale against Node's Intl (ICU 78, CLDR 48) with the same inputs.

# 2026-11-21 15:04:05 UTC (a Saturday) and 2026-01-05 09:07:03 UTC (a Monday).
late : I64
late = 1795273445000

early : I64
early = 1767604023000

numbers : Locales.Data -> List(Str)
numbers = |data| {
	intl = Intl.new(data)
	[intl.number(-1234567.891), intl.number(1234.5), intl.number(0.5), intl.fixed(1234.5, 2), intl.percent(0.256, 1), intl.compact(1234), intl.compact(12345678), intl.compact(999950)]
}

money : Locales.Data, Str -> List(Str)
money = |data, local| {
	intl = Intl.new(data)
	[intl.currency(-1234.5, "EUR"), intl.currency(1234.5, "USD"), intl.currency(1234.5, "JPY"), intl.currency(1234.5, local)]
}

dates : Locales.Data -> List(Str)
dates = |data| {
	intl = Intl.new(data)
	[late, early].join_map(|ms| [intl.date(ms, Short), intl.date(ms, Medium), intl.date(ms, Long), intl.date(ms, Full)])
}

times : Locales.Data -> List(Str)
times = |data| {
	intl = Intl.new(data)
	[intl.time(late, Short), intl.time(early, Medium), intl.date_time(late, Medium, Short), intl.date_time(late, Long, Short), intl.month_year(Date.of_millis(late, 0))]
}

relatives : Locales.Data -> List(Str)
relatives = |data| {
	intl = Intl.new(data)
	[intl.relative(3, Day), intl.relative(-3, Day), intl.relative(2, Hour), intl.relative(-1, Minute), intl.relative(-5, Year), intl.relative(21, Second), intl.relative(-22, Week), intl.relative(1000, Month), intl.relative_day(-1), intl.relative_day(1)]
}

expect numbers(Locales.en) == ["-1,234,567.891", "1,234.5", "0.5", "1,234.50", "25.6%", "1.2K", "12M", "1M"]
expect money(Locales.en, "USD") == ["-€1,234.50", "\$1,234.50", "¥1,235", "\$1,234.50"]
expect dates(Locales.en) == ["11/21/26", "Nov 21, 2026", "November 21, 2026", "Saturday, November 21, 2026", "1/5/26", "Jan 5, 2026", "January 5, 2026", "Monday, January 5, 2026"]
expect times(Locales.en) == ["3:04 PM", "9:07:03 AM", "Nov 21, 2026, 3:04 PM", "November 21, 2026 at 3:04 PM", "November 2026"]
expect relatives(Locales.en) == ["in 3 days", "3 days ago", "in 2 hours", "1 minute ago", "5 years ago", "in 21 seconds", "22 weeks ago", "in 1,000 months", "yesterday", "tomorrow"]
expect numbers(Locales.en_gb) == ["-1,234,567.891", "1,234.5", "0.5", "1,234.50", "25.6%", "1.2k", "12m", "1m"]
expect money(Locales.en_gb, "GBP") == ["-€1,234.50", "US\$1,234.50", "JP¥1,235", "£1,234.50"]
expect dates(Locales.en_gb) == ["21/11/2026", "21 Nov 2026", "21 November 2026", "Saturday, 21 November 2026", "05/01/2026", "5 Jan 2026", "5 January 2026", "Monday, 5 January 2026"]
expect times(Locales.en_gb) == ["15:04", "09:07:03", "21 Nov 2026, 15:04", "21 November 2026 at 15:04", "November 2026"]
expect relatives(Locales.en_gb) == ["in 3 days", "3 days ago", "in 2 hours", "1 minute ago", "5 years ago", "in 21 seconds", "22 weeks ago", "in 1,000 months", "yesterday", "tomorrow"]
expect numbers(Locales.de) == ["-1.234.567,891", "1.234,5", "0,5", "1.234,50", "25,6\u(A0)%", "1234", "12\u(A0)Mio.", "999.950"]
expect money(Locales.de, "EUR") == ["-1.234,50\u(A0)€", "1.234,50\u(A0)\$", "1.235\u(A0)¥", "1.234,50\u(A0)€"]
expect dates(Locales.de) == ["21.11.26", "21.11.2026", "21. November 2026", "Samstag, 21. November 2026", "05.01.26", "05.01.2026", "5. Januar 2026", "Montag, 5. Januar 2026"]
expect times(Locales.de) == ["15:04", "09:07:03", "21.11.2026, 15:04", "21. November 2026 um 15:04", "November 2026"]
expect relatives(Locales.de) == ["in 3 Tagen", "vor 3 Tagen", "in 2 Stunden", "vor 1 Minute", "vor 5 Jahren", "in 21 Sekunden", "vor 22 Wochen", "in 1.000 Monaten", "gestern", "morgen"]
expect numbers(Locales.fr) == ["-1\u(202F)234\u(202F)567,891", "1\u(202F)234,5", "0,5", "1\u(202F)234,50", "25,6\u(A0)%", "1,2\u(A0)k", "12\u(A0)M", "1\u(A0)M"]
expect money(Locales.fr, "EUR") == ["-1\u(202F)234,50\u(A0)€", "1\u(202F)234,50\u(A0)\$US", "1\u(202F)235\u(A0)JPY", "1\u(202F)234,50\u(A0)€"]
expect dates(Locales.fr) == ["21/11/2026", "21 nov. 2026", "21 novembre 2026", "samedi 21 novembre 2026", "05/01/2026", "5 janv. 2026", "5 janvier 2026", "lundi 5 janvier 2026"]
expect times(Locales.fr) == ["15:04", "09:07:03", "21 nov. 2026, 15:04", "21 novembre 2026 à 15:04", "novembre 2026"]
expect relatives(Locales.fr) == ["dans 3 jours", "il y a 3 jours", "dans 2 heures", "il y a 1 minute", "il y a 5 ans", "dans 21 secondes", "il y a 22 semaines", "dans 1\u(202F)000 mois", "hier", "demain"]
expect numbers(Locales.es) == ["-1.234.567,891", "1234,5", "0,5", "1234,50", "25,6\u(A0)%", "1,2\u(A0)mil", "12\u(A0)M", "1\u(A0)M"]
expect money(Locales.es, "EUR") == ["-1234,50\u(A0)€", "1234,50\u(A0)US\$", "1235\u(A0)JPY", "1234,50\u(A0)€"]
expect dates(Locales.es) == ["21/11/26", "21 nov 2026", "21 de noviembre de 2026", "sábado, 21 de noviembre de 2026", "5/1/26", "5 ene 2026", "5 de enero de 2026", "lunes, 5 de enero de 2026"]
expect times(Locales.es) == ["15:04", "9:07:03", "21 nov 2026, 15:04", "21 de noviembre de 2026 a las 15:04", "noviembre de 2026"]
expect relatives(Locales.es) == ["dentro de 3 días", "hace 3 días", "dentro de 2 horas", "hace 1 minuto", "hace 5 años", "dentro de 21 segundos", "hace 22 semanas", "dentro de 1000 meses", "ayer", "mañana"]
expect numbers(Locales.pl) == ["-1\u(A0)234\u(A0)567,891", "1234,5", "0,5", "1234,50", "25,6%", "1,2\u(A0)tys.", "12\u(A0)mln", "1\u(A0)mln"]
expect money(Locales.pl, "PLN") == ["-1234,50\u(A0)€", "1234,50\u(A0)USD", "1235\u(A0)JPY", "1234,50\u(A0)zł"]
expect dates(Locales.pl) == ["21.11.2026", "21 lis 2026", "21 listopada 2026", "sobota, 21 listopada 2026", "5.01.2026", "5 sty 2026", "5 stycznia 2026", "poniedziałek, 5 stycznia 2026"]
expect times(Locales.pl) == ["15:04", "09:07:03", "21 lis 2026, 15:04", "21 listopada 2026 15:04", "listopad 2026"]
expect relatives(Locales.pl) == ["za 3 dni", "3 dni temu", "za 2 godziny", "1 minutę temu", "5 lat temu", "za 21 sekund", "22 tygodnie temu", "za 1000 miesięcy", "wczoraj", "jutro"]
expect numbers(Locales.cs) == ["-1\u(A0)234\u(A0)567,891", "1\u(A0)234,5", "0,5", "1\u(A0)234,50", "25,6\u(A0)%", "1,2\u(A0)tis.", "12\u(A0)mil.", "1\u(A0)mil."]
expect money(Locales.cs, "CZK") == ["-1\u(A0)234,50\u(A0)€", "1\u(A0)234,50\u(A0)US\$", "1\u(A0)235\u(A0)JP¥", "1\u(A0)234,50\u(A0)Kč"]
expect dates(Locales.cs) == ["21.11.26", "21. 11. 2026", "21. listopadu 2026", "sobota 21. listopadu 2026", "05.01.26", "5. 1. 2026", "5. ledna 2026", "pondělí 5. ledna 2026"]
expect times(Locales.cs) == ["15:04", "9:07:03", "21. 11. 2026 15:04", "21. listopadu 2026 v 15:04", "listopad 2026"]
expect relatives(Locales.cs) == ["za 3 dny", "před 3 dny", "za 2 hodiny", "před 1 minutou", "před 5 lety", "za 21 sekund", "před 22 týdny", "za 1\u(A0)000 měsíců", "včera", "zítra"]
expect numbers(Locales.ru) == ["-1\u(A0)234\u(A0)567,891", "1\u(A0)234,5", "0,5", "1\u(A0)234,50", "25,6\u(A0)%", "1,2\u(A0)тыс.", "12\u(A0)млн", "1\u(A0)млн"]
expect money(Locales.ru, "RUB") == ["-1\u(A0)234,50\u(A0)€", "1\u(A0)234,50\u(A0)\$", "1\u(A0)235\u(A0)¥", "1\u(A0)234,50\u(A0)₽"]
expect dates(Locales.ru) == ["21.11.2026", "21 нояб. 2026 г.", "21 ноября 2026 г.", "суббота, 21 ноября 2026 г.", "05.01.2026", "5 янв. 2026 г.", "5 января 2026 г.", "понедельник, 5 января 2026 г."]
expect times(Locales.ru) == ["15:04", "09:07:03", "21 нояб. 2026 г., 15:04", "21 ноября 2026 г. в 15:04", "ноябрь 2026 г."]
expect relatives(Locales.ru) == ["через 3 дня", "3 дня назад", "через 2 часа", "1 минуту назад", "5 лет назад", "через 21 секунду", "22 недели назад", "через 1\u(A0)000 месяцев", "вчера", "завтра"]
expect numbers(Locales.ar) == ["\u(200E)-1,234,567.891", "1,234.5", "0.5", "1,234.50", "25.6\u(200E)%\u(200E)", "1.2\u(A0)ألف", "12\u(A0)مليون", "1\u(A0)مليون"]
expect money(Locales.ar, "EGP") == ["\u(200F)\u(200E)-1,234.50\u(A0)€", "\u(200F)1,234.50\u(A0)US\$", "\u(200F)1,235\u(A0)JP¥", "\u(200F)1,234.50\u(A0)ج.م.\u(200F)"]
expect dates(Locales.ar) == ["21\u(200F)/11\u(200F)/2026", "21\u(200F)/11\u(200F)/2026", "21 نوفمبر 2026", "السبت، 21 نوفمبر 2026", "5\u(200F)/1\u(200F)/2026", "05\u(200F)/01\u(200F)/2026", "5 يناير 2026", "الاثنين، 5 يناير 2026"]
expect times(Locales.ar) == ["3:04 م", "9:07:03 ص", "21\u(200F)/11\u(200F)/2026، 3:04 م", "21 نوفمبر 2026 في 3:04 م", "نوفمبر 2026"]
expect relatives(Locales.ar) == ["خلال 3 أيام", "قبل 3 أيام", "خلال ساعتين", "قبل دقيقة واحدة", "قبل 5 سنوات", "خلال 21 ثانية", "قبل 22 أسبوعًا", "خلال 1,000 شهر", "أمس", "غدًا"]
expect numbers(Locales.ja) == ["-1,234,567.891", "1,234.5", "0.5", "1,234.50", "25.6%", "1234", "1235万", "100万"]
expect money(Locales.ja, "JPY") == ["-€1,234.50", "\$1,234.50", "￥1,235", "￥1,235"]
expect dates(Locales.ja) == ["2026/11/21", "2026/11/21", "2026年11月21日", "2026年11月21日土曜日", "2026/01/05", "2026/01/05", "2026年1月5日", "2026年1月5日月曜日"]
expect times(Locales.ja) == ["15:04", "9:07:03", "2026/11/21 15:04", "2026年11月21日 15:04", "2026年11月"]
expect relatives(Locales.ja) == ["3 日後", "3 日前", "2 時間後", "1 分前", "5 年前", "21 秒後", "22 週間前", "1,000 か月後", "昨日", "明日"]

supported : List(Locales.Data)
supported = [Locales.en, Locales.en_gb, Locales.pl, Locales.de]

expect Intl.choose(supported, [Locale.of("pl-PL")]).tag() == "pl"
expect Intl.choose(supported, [Locale.of("en-AU")]).tag() == "en"
expect Intl.choose(supported, [Locale.of("fr"), Locale.of("de-CH")]).tag() == "de"
expect Intl.choose(supported, [Locale.of("ja")]).tag() == "en"
expect Intl.choose([], [Locale.of("pl")]).tag() == "en"
expect Intl.choose(supported, Locale.accept_language("en-GB,en;q=0.8")).tag() == "en-GB"
expect Intl.for_tag(supported, "PL").tag() == "pl"
expect Intl.for_tag(supported, "not a tag").tag() == "en"
expect Intl.new(Locales.pl).name() == "polski"
expect Intl.new(Locales.ar).direction() == "rtl"
expect Intl.new(Locales.ja).direction() == "ltr"
expect Intl.new(Locales.pl).plural(22) == Few
expect Intl.new(Locales.pl).plural(1.5) == Other
expect Intl.new(Locales.en).ordinal(23) == Few
expect Intl.new(Locales.en).int(-12345) == "-12,345"
expect Intl.new(Locales.en).number_with(1234.5678, { min_fraction: 1, max_fraction: 2, grouping: Bool.False }) == "1234.57"
expect Intl.new(Locales.pl).day(Date.ymd(2026, 1, 5), Long) == "5 stycznia 2026"
expect Intl.new(Locales.pl).month_year(Date.ymd(2026, 11, 1)) == "listopad 2026"
expect Intl.new(Locales.pl).month_name(11) == "listopad"
expect Intl.new(Locales.ru).month_name(11) == "ноябрь"
expect Intl.new(Locales.de).weekday_name(6) == "Samstag"
expect Intl.new(Locales.en).in_offset(-300).time(late, Short) == "10:04 AM"
expect Intl.new(Locales.de).in_offset(600).date(late, Medium) == "22.11.2026"
expect Intl.new(Locales.en).ago(late - 5 * 60000, late) == "5 minutes ago"
expect Intl.new(Locales.pl).ago(late + 2 * 86400000, late) == "za 2 dni"
expect Intl.new(Locales.pl).ago(late - 5 * 60000, late) == "5 minut temu"
expect Intl.new(Locales.pl).fixed(2.5, 2) == "2,50"
expect Intl.new(Locales.pl).ago(late - 3 * 3600000, late) == "3 godziny temu"
expect Intl.new(Locales.cs).relative(-2, Hour) == "před 2 hodinami"
expect Intl.new(Locales.ar).relative(2, Hour) == "خلال ساعتين"
expect Intl.new(Locales.fr).relative_day(0) == "aujourd’hui"
expect Intl.new(Locales.en).format("{n, plural, one {# day} other {# days}} left", [("n", Int(2))]) == "2 days left"
expect Intl.new(Locales.en).format("{broken", []) == "{broken"

words : Catalog
words = Catalog.new(
	"en",
	[
		("en", [("cart.items", "{count, plural, =0 {Your cart is empty} one {# item} other {# items}}"), ("colour", "Color")]),
		("en-GB", [("colour", "Colour")]),
		("pl", [("cart.items", "{count, plural, =0 {Koszyk jest pusty} one {# produkt} few {# produkty} other {# produktów}}")]),
	],
)

expect Intl.choose(supported, [Locale.of("pl-PL")]).with_catalog(words).t("cart.items", [("count", Int(3))]) == "3 produkty"
expect Intl.choose(supported, [Locale.of("pl-PL")]).with_catalog(words).t("cart.items", [("count", Int(25))]) == "25 produktów"
expect Intl.new(Locales.en).with_catalog(words).t("cart.items", [("count", Int(0))]) == "Your cart is empty"
expect Intl.new(Locales.en_gb).with_catalog(words).t("colour", []) == "Colour"
expect Intl.new(Locales.en_gb).with_catalog(words).t("cart.items", [("count", Int(1))]) == "1 item"
expect Intl.new(Locales.pl).with_catalog(words).t("colour", []) == "Color"
expect Intl.new(Locales.de).with_catalog(words).t("no.such.key", []) == "no.such.key"
expect Intl.new(Locales.pl).with_catalog(words).translated("cart.items")
expect !Intl.new(Locales.pl).with_catalog(words).translated("colour")
expect Intl.new(Locales.en).t("cart.items", []) == "cart.items"
