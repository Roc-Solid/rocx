// Writes packages/intl/Locales.roc: each starter locale's data (number symbols, compact patterns,
// currency symbols, month and weekday names, date and time patterns, relative-time patterns), read
// from this Node's ICU (CLDR), so the tables are CLDR's and not typed by hand. Plural rules are code
// (Plural.roc), named here by language.
//
//     node packages/intl/tools/locales.mjs > packages/intl/Locales.roc
//     ROC=.tools/roc-active bin/rocx fmt packages/intl
//
// Run it only to add a locale or move to a newer CLDR; the output is checked in, and the package's
// expects say what it must give.

const starter = ["en", "en-GB", "de", "fr", "es", "pl", "cs", "ru", "ar", "ja"];
const locales = process.argv.slice(2).length ? process.argv.slice(2) : starter;

// The plural rules each language uses, by Plural.roc's names.
const rules = { en: "en", de: "en", fr: "fr", es: "es", pl: "pl", cs: "cs", ru: "ru", ar: "ar", ja: "only_other" };
const ordinals = { en: "en", fr: "fr", de: "only_other", es: "only_other", pl: "only_other", cs: "only_other", ru: "only_other", ar: "only_other", ja: "only_other" };
const currencies = ["USD", "EUR", "GBP", "JPY", "CHF", "CNY", "INR", "CAD", "AUD", "PLN", "CZK", "RUB", "UAH", "SEK", "NOK", "DKK", "BRL", "MXN", "KRW", "TRY", "ILS", "AED", "SAR", "EGP"];
const units = ["second", "minute", "hour", "day", "week", "month", "year"];
const categories = ["zero", "one", "two", "few", "many", "other"];

const utc = (y, m, d, h = 12, min = 0, s = 0) => new Date(Date.UTC(y, m - 1, d, h, min, s));

// A Roc string literal: the invisible characters written as escapes, so the source shows them.
const roc = (text) =>
	'"' +
	[...text]
		.map((c) => {
			const code = c.codePointAt(0);
			if (c === '"' || c === "\\") return "\\" + c;
			if (c === "$") return "\\$";
			if (code < 0x20 || [0xa0, 0x202f, 0x200e, 0x200f, 0x061c, 0x2009].includes(code)) return `\\u(${code.toString(16).toUpperCase()})`;
			return c;
		})
		.join("") +
	'"';
const list = (items) => `[${items.map(roc).join(", ")}]`;

function numbers(l) {
	const parts = new Intl.NumberFormat(l).formatToParts(-1234567.891);
	const decimal = parts.find((p) => p.type === "decimal").value;
	const group = parts.find((p) => p.type === "group").value;
	const minus = parts.slice(0, parts.findIndex((p) => p.type === "minusSign") + 1).map((p) => p.value).join("");
	const four = new Intl.NumberFormat(l).formatToParts(1234);
	const min_grouping = four.some((p) => p.type === "group") ? 1 : 2;
	// A pattern: `{-}` where the sign goes (and what stands before it), `{0}` the number, `¤` the currency.
	const pattern = (options, value) => {
		const ps = new Intl.NumberFormat(l, options).formatToParts(value);
		let out = "";
		let inNumber = false;
		for (const p of ps) {
			if (["integer", "group", "decimal", "fraction"].includes(p.type)) {
				if (!inNumber) out += "{0}";
				inNumber = true;
				continue;
			}
			inNumber = false;
			if (p.type === "minusSign") out += "{-}";
			else if (p.type === "currency") out += "¤";
			else out += p.value;
		}
		return out;
	};
	const percentNeg = pattern({ style: "percent" }, -0.25);
	const currencyNeg = pattern({ style: "currency", currency: "EUR" }, -1234.5);
	const plainNeg = pattern({}, -1);
	// What the minus is, inside its pattern: plain numbers' prefix (`‎-` in Arabic).
	const percent = percentNeg.replace(plainNeg.replace("{0}", ""), "{-}").replace("{-}{-}", "{-}");
	const currency = currencyNeg.replace(plainNeg.replace("{0}", ""), "{-}").replace("{-}{-}", "{-}");
	const compact = [];
	for (let power = 3; power <= 14; power++) {
		const ps = new Intl.NumberFormat(l, { notation: "compact" }).formatToParts(10 ** power);
		if (!ps.some((p) => p.type === "compact")) {
			compact.push("0");
			continue;
		}
		let out = "";
		for (const p of ps) {
			if (p.type === "integer") out += "0".repeat(p.value.length);
			else out += p.value;
		}
		compact.push(out);
	}
	// A currency's symbol is what stands where the pattern has ¤, with what ICU writes around it
	// (Arabic-script symbols end in U+200F, as a part of their own).
	const [before, after] = currency.replace("{-}", "").split("¤");
	const symbols = [];
	for (const code of currencies) {
		const written = pattern({ style: "currency", currency: code }, 1).replace("{-}", "").replace("¤", new Intl.NumberFormat(l, { style: "currency", currency: code }).formatToParts(1).find((p) => p.type === "currency").value);
		// Less the space currency spacing puts between a letter and a digit, which NumberFormat adds.
		const symbol = written.startsWith(before) && written.endsWith(after) ? written.slice(before.length, written.length - after.length).replace(/^\u00a0|\u00a0$/g, "") : code;
		if (symbol !== code) symbols.push([code, symbol]);
	}
	return { decimal, group, min_grouping, minus, percent, currency, compact, symbols };
}

function names(l) {
	const part = (options, date, type) => new Intl.DateTimeFormat(l, { timeZone: "UTC", ...options }).formatToParts(date).find((p) => p.type === type).value;
	const months = [], months_short = [], standalone = [];
	for (let m = 1; m <= 12; m++) {
		const date = utc(2026, m, 15);
		months.push(part({ day: "numeric", month: "long", year: "numeric" }, date, "month"));
		months_short.push(part({ day: "numeric", month: "short", year: "numeric" }, date, "month"));
		standalone.push(part({ month: "long" }, date, "month"));
	}
	const weekdays = [], weekdays_short = [];
	for (let d = 0; d < 7; d++) {
		const date = utc(2026, 11, 22 + d); // 2026-11-22 is a Sunday
		weekdays.push(part({ weekday: "long", day: "numeric", month: "long" }, date, "weekday"));
		weekdays_short.push(part({ weekday: "short", day: "numeric", month: "short" }, date, "weekday"));
	}
	const am = part({ hour: "numeric", hour12: true }, utc(2026, 1, 5, 9), "dayPeriod").replaceAll("\u202f", " ");
	const pm = part({ hour: "numeric", hour12: true }, utc(2026, 1, 5, 15), "dayPeriod").replaceAll("\u202f", " ");
	return { months, months_short, months_standalone: standalone.join() === months.join() ? [] : standalone, weekdays, weekdays_short, am, pm };
}

// A CLDR-style pattern (`d MMM y`, `h:mm a`) for what Intl writes with `options`, read from its parts
// for a day and an hour of one digit each, so a zero in front shows.
function datePattern(l, options, n) {
	const ps = new Intl.DateTimeFormat(l, { timeZone: "UTC", ...options }).formatToParts(utc(2026, 1, 5, 9, 7, 3));
	const twelve = ps.some((p) => p.type === "dayPeriod");
	let out = "";
	for (const p of ps) {
		const v = p.value;
		switch (p.type) {
			case "day": out += v.length === 2 ? "dd" : "d"; break;
			case "month":
				if (/^\d+$/.test(v)) out += v.length === 2 ? "MM" : "M";
				else if (v === n.months[0]) out += "MMMM";
				else if (v === n.months_short[0]) out += "MMM";
				else if (n.months_standalone.length && v === n.months_standalone[0]) out += "LLLL";
				else throw new Error(`${l}: month ${v}`);
				break;
			case "year": out += v.length === 2 ? "yy" : "y"; break;
			case "weekday":
				if (v === n.weekdays[1]) out += "EEEE";
				else if (v === n.weekdays_short[1]) out += "EEE";
				else throw new Error(`${l}: weekday ${v}`);
				break;
			case "hour": out += twelve ? (v.length === 2 ? "hh" : "h") : v.length === 2 ? "HH" : "H"; break;
			case "minute": out += "mm"; break;
			case "second": out += "ss"; break;
			case "dayPeriod": out += "a"; break;
			// Intl's format() (as browsers') writes a plain space where CLDR has U+202F ("3:04 PM",
			// "21 нояб. 2026 г."); formatToParts doesn't.
			case "literal": {
				const text = v.replaceAll("\u202f", " ");
				out += /[A-Za-z']/.test(text) ? `'${text.replaceAll("'", "''")}'` : text;
				break;
			}
			default: throw new Error(`${l}: part ${p.type}`);
		}
	}
	return out;
}

function glue(l, style) {
	const date = utc(2026, 11, 21, 15, 4, 5);
	const both = new Intl.DateTimeFormat(l, { timeZone: "UTC", dateStyle: style, timeStyle: "short" }).format(date);
	const d = new Intl.DateTimeFormat(l, { timeZone: "UTC", dateStyle: style }).format(date);
	const t = new Intl.DateTimeFormat(l, { timeZone: "UTC", timeStyle: "short" }).format(date);
	if (!both.includes(d) || !both.includes(t)) throw new Error(`${l}: glue ${both}`);
	return both.replace(d, "{1}").replace(t, "{0}");
}

function dates(l) {
	const n = names(l);
	return {
		...n,
		date: Object.fromEntries(["short", "medium", "long", "full"].map((s) => [s, datePattern(l, { dateStyle: s }, n)])),
		time: Object.fromEntries(["short", "medium"].map((s) => [s, datePattern(l, { timeStyle: s }, n)])),
		date_time: Object.fromEntries(["short", "medium", "long", "full"].map((s) => [s, glue(l, s)])),
		month_year: datePattern(l, { year: "numeric", month: "long" }, n),
	};
}

function relative(l) {
	const plural = new Intl.PluralRules(l);
	const present = plural.resolvedOptions().pluralCategories;
	const samples = {};
	for (let i = 0; i <= 1000 && Object.keys(samples).length < present.length; i++) samples[plural.select(i)] ??= i;
	for (const x of [1.5, 0.5, 2.5, 0.1, 1.1]) samples[plural.select(x)] ??= x;
	const rtf = new Intl.RelativeTimeFormat(l);
	const pattern = (value, unit) => {
		let out = "";
		let inNumber = false;
		for (const p of rtf.formatToParts(value, unit)) {
			if (p.type === "literal") {
				out += p.value;
				inNumber = false;
			} else if (!inNumber) {
				out += "{0}";
				inNumber = true;
			}
		}
		return out;
	};
	const forms = (sign, unit) => Object.fromEntries(categories.map((c) => [c, c in samples ? pattern(sign * samples[c], unit) : ""]));
	const auto = new Intl.RelativeTimeFormat(l, { numeric: "auto" });
	const out = { yesterday: auto.format(-1, "day"), today: auto.format(0, "day"), tomorrow: auto.format(1, "day"), now: auto.format(0, "second") };
	for (const unit of units) out[unit] = { future: forms(1, unit), past: forms(-1, unit) };
	return out;
}

const ident = (l) => l.toLowerCase().replace("-", "_");

// The forms a category has, beside `other`, where they differ from it.
const formsRoc = (forms) => {
	const set = categories.filter((c) => forms[c] !== "" && (c === "other" || forms[c] !== forms.other));
	return `{ ..Plural.none, ${set.map((c) => `${c}: ${roc(forms[c])}`).join(", ")} }`;
};

const out = [];
out.push(`import Plural
import NumberFormat
import DateFormat
import RelativeTime

## Each locale's data: its plural rules, how it writes numbers, money and dates, and its words for
## relative times. Written by \`tools/locales.mjs\` from CLDR ${process.versions.cldr} (Node's ICU ${process.versions.icu}); add a
## locale there, not here. An app names the ones it supports (\`[Locales.en, Locales.pl]\`), and only
## those are compiled into it.
Locales := [].{

	## What a locale needs to format: \`Intl.new(Locales.pl)\`.
	Data : {
		tag : Str,
		name : Str,
		cardinal : Plural.Operands -> Plural.Category,
		ordinal : Plural.Operands -> Plural.Category,
		number : NumberFormat.Symbols,
		dates : DateFormat.Names,
		relative : RelativeTime.Words,
	}

	## Every locale this package has data for.
	all : List(Data)
	all = [${locales.map(ident).join(", ")}]
`);
for (const l of locales) {
	const lang = l.split("-")[0];
	const n = numbers(l);
	const d = dates(l);
	const r = relative(l);
	out.push(`	${ident(l)} : Data
	${ident(l)} = {
		tag: ${roc(l)},
		name: ${roc(new Intl.DisplayNames(l, { type: "language" }).of(l))},
		cardinal: Plural.${rules[lang]},
		ordinal: Plural.ordinal_${ordinals[lang]},
		number: {
			decimal: ${roc(n.decimal)},
			group: ${roc(n.group)},
			min_grouping: ${n.min_grouping},
			minus: ${roc(n.minus)},
			percent: ${roc(n.percent)},
			currency: ${roc(n.currency)},
			currency_symbols: [${n.symbols.map(([c, s]) => `(${roc(c)}, ${roc(s)})`).join(", ")}],
			compact: ${list(n.compact)},
		},
		dates: {
			months: ${list(d.months)},
			months_short: ${list(d.months_short)},
			months_standalone: ${list(d.months_standalone)},
			weekdays: ${list(d.weekdays)},
			weekdays_short: ${list(d.weekdays_short)},
			am: ${roc(d.am)},
			pm: ${roc(d.pm)},
			date: { short: ${roc(d.date.short)}, medium: ${roc(d.date.medium)}, long: ${roc(d.date.long)}, full: ${roc(d.date.full)} },
			time: { short: ${roc(d.time.short)}, medium: ${roc(d.time.medium)} },
			date_time: { short: ${roc(d.date_time.short)}, medium: ${roc(d.date_time.medium)}, long: ${roc(d.date_time.long)}, full: ${roc(d.date_time.full)} },
			month_year: ${roc(d.month_year)},
		},
		relative: {
${units.map((u) => `			${u}: { future: ${formsRoc(r[u].future)}, past: ${formsRoc(r[u].past)} },`).join("\n")}
			yesterday: ${roc(r.yesterday)},
			today: ${roc(r.today)},
			tomorrow: ${roc(r.tomorrow)},
			now: ${roc(r.now)},
		},
	}
`);
}
out.push("}");
process.stdout.write(out.join("\n") + "\n");
