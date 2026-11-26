# packages/intl: proposals

What the package would like from outside `packages/intl/`, one section each: the problem, the
options, the change recommended (sketched), what in the package depends on it, and how to undo it.
Nothing here is built for intl; the package compiles and its tests pass without any of it. What
proposal 1 asked of the platform has landed, in another form (D-033): see there.

## 1. Server-only modules in packages

**The platform's side landed (D-033), not as option 1 below.** A package may name the server
platform in its header, as an app does, with a `browser.roc` beside `main.roc` listing the modules
the browser's half can compile; packages/guard and packages/auth do, and their middleware is
imported as it is, with nothing copied. intl doesn't yet: its `main.roc` names no platform, so the
middleware and the endpoint below are still the app's own. What is left is intl's side: an
`IntlServer` module as sketched, under a header that names the server platform, and a `browser.roc`
for the pure modules. The rest of this section is the proposal as it was written.

**Problem.** Two pieces of intl's integration run only on the server and use platform modules: a
middleware that picks the request's locale and says on the answer which it was
(`Content-Language`, and `Vary: Accept-Language, Cookie` so a cache keeps one copy per language),
and the endpoint that keeps a reader's choice in a cookie (`POST /locale`). A Roc package can name
a platform only if it is the app's exact one, and a Roc Solid app is two apps, so a package can't
`import pf.Middleware`. Today `rocx build` copies only `components/*.rocx`, into both halves. So
the README has the app write both itself (about a dozen lines each), and intl's pure side takes the
platform's `Server.Request` structurally (`Locale.wanted(request, cookie)` asks only for a record
with `headers`), which needs no platform.

**Options.**
1. `rocx build` also copies a package's `server/` directory (`.roc` and `.rocx`) into the server
   half only, as `Generated/<alias>/server/…`, where `pf` is the server platform. App code that
   only the server half has (route `+server.roc` files, middleware modules, `main.roc`) imports it.
2. Leave it to the app: copy the glue by hand from the README (today's state).
3. Structural types only: the package exposes functions over plain records (`{ headers }` in,
   `{ name, value }` headers out) and the app wraps them in `Middleware.make`. It works for reading
   a request, but the package can't hand back a `Middleware` or an `Endpoint` value, whose types
   belong to the platform.
4. Packages that take the platform as a parameter (`package [..] { pf: platform }`): a compiler
   change, and the right one in the long run, but not ours to make.

**Recommended: 1.** A sketch:

```
packages/intl/server/IntlServer.roc     # copied to Generated/intl/server/IntlServer.roc, server half only
```

```roc
import pf.Middleware
import pf.Server
import intl.Intl
import intl.Locale
import intl.Locales

IntlServer := [].{
	## Picks the request's locale (its `cookie`, then Accept-Language, then the first supported),
	## hands its tag on through `with`, and says on the answer which language it is in.
	negotiate : List(Locales.Data), Str, (given, Str -> handed) -> Middleware(given, handed)
	negotiate = |supported, cookie, with|
		Middleware.make(|request, context, next!| {
			tag = Intl.choose(supported, Locale.wanted(request, cookie)).tag()
			answer = next!(request, with(context, tag))
			{ ..answer, headers: answer.headers.concat([{ name: "content-language", value: tag }, { name: "vary", value: "accept-language, cookie" }]) }
		})

	## An endpoint's `post!` that keeps `{ tag }` in `cookie` for a year: 204 for the picker, a 303
	## back for a plain form.
	remember! : Str, Server.Request, Str => Server.Response
}
```

```roc
# the app's Middlewares.roc
default = Middleware.same_origin({}).then(IntlServer.negotiate(I18n.supported, "locale", |context, tag| { facts: context.facts, locale: tag }))
```

rocx's side: in `componentPackages`, look for `server/` beside `components/`; in `build`, write
those files under `Generated/<alias>/server/` for the server half and leave them out of the
`--client` copy (as it leaves out a route file's middleware). An import of
`intl.server.IntlServer` (or `import intl.IntlServer` when the module is under `server/`) becomes
the relative import of the copy, as `linkComponents` does for components. A file the browser's
copy keeps that imports a server module fails the client build, at its line.

**Depends on it.** The README's middleware and endpoint, which the app now writes itself.
`Content-Language` and `Vary` aren't sent unless the app adds them.
**Undo.** Delete the copy step. The app keeps its own copies, as today.

## 2. Components that import their package's other components

**Problem.** In a copied component, `rocx build` renames the package's own imports
(`import intl.X` when the directory is `intl`) but doesn't point an import of another component of
the same package at its copy. `components/LocaleSelect.rocx` can't `import intl.Language`: in the
app's copy, `intl.Language` names a module the package doesn't have ("package module is private").
So the context, the store and the picker share one module, and the picker is `<Language />`.

**Options.** 1. Run the same rewrite on the copies that app files get: `linkComponents` with the
copy's own path. 2. Keep a package's components in one file (today).

**Recommended: 1.** In `build`'s loop over `pkg.paths`, after the rename:

```js
source = linkComponents(source, out, dir, packages);   // out: Generated/<alias>/<Name>.roc
```

so `import intl.Language` in `Generated/intl/LocaleSelect.roc` becomes `import Language`.

**Depends on it.** With it, intl would split into `IntlContext.rocx` (the context and store) and
`LocaleSelect.rocx` (the picker). **Undo.** One line.

## 3. Message keys the compiler checks (generated by `rocx build`)

**Problem.** `intl.t("cart.itmes", [("count", Int(3))])` compiles. At run time it shows the key,
and `Catalog.problems()` finds translations that differ from the default, but neither finds a key
misspelt in the code, or an argument left out or misnamed at the call.

**Options.**
1. Messages as Roc functions, written by hand (`cart_items : Intl, { count : I64 } -> Str` in each
   locale's record). Checked, but translators then edit Roc, and plurals become code.
2. Message files, read by `rocx build`: `messages/en.json`, `messages/pl.json` (key to ICU
   message), from which it writes `Generated/Messages.roc`: the catalog, and a function for each
   key whose arguments come from the default's message (`plural` and `number` give a number,
   `select` and plain ones text, `date` and `time` a moment).
3. Keep keys as strings (today), and check them in tests: `expect Catalog.problems(…) == []`.

**Recommended: 2**, once apps have enough messages to need it. Catalogs stay Roc lists for now:
they need no tooling, and the same `Catalog` takes a generated list later. A sketch of what
`rocx build` would write:

```roc
## Generated from messages/*.json: don't edit.
Messages := [].{
	catalog : Catalog
	catalog = Catalog.new("en", [("en", [("cart.items", "{count, plural, one {# item} other {# items}}"), …]), ("pl", […])])

	cart_items : Intl, { count : I64 } -> Str
	cart_items = |intl, { count }| intl.t("cart.items", [("count", Int(count))])

	hello : Intl, { name : Str } -> Str
	hello = |intl, { name }| intl.t("hello", [("name", Text(name))])
}
```

```roc
<p>{Messages.cart_items(intl!(), { count: count!() })}</p>
```

The build would fail on a message the default can't parse, and report `Catalog.problems` for the
other locales, at the file and key. JSON (key to message) is what translators' tools exchange most
often; ICU messages need no other format.

**Depends on it.** Nothing yet. **Undo.** Delete the generated module; `t` keeps working.

## 4. Fuller CLDR data without growing the browser's wasm

**Problem.** The ten starter locales are written into `Locales.roc` by `tools/locales.mjs`, from
what Node's `Intl` writes (CLDR 48). More locales and more data (parent locales, other numbering
systems, long compact forms, quarters) shouldn't cost apps that don't use them. The site's budget is
about 150 KB brotli.

What was measured, on a small app (`--opt=size`, brotli): unused locales aren't compiled in (one
locale 58.9 KB, three 61.1 KB, all ten 65.5 KB; about 1 KB a locale). intl's own code is the larger
part: +12.6 KB for numbers alone, +22.1 KB with dates and relative times, +34.5 KB with messages,
+4.6 KB more for `Validation.catalog` (nine languages).

**Options.**
1. Generate every CLDR locale into `Locales.roc`: unused ones cost nothing in the wasm, as
   measured, but the source grows to tens of thousands of lines and every app compiles it.
2. One module per locale (`Locales/Pl.roc`), generated for the locales an app names (a list beside
   its catalog, or `rocx intl add pl`), from cldr-json (`cldr-core`, `cldr-numbers-full`,
   `cldr-dates-full`), which has what `Intl` doesn't show: plural rules as text, parent locales,
   currency digits, numbering systems.
3. Locale data loaded at run time as JSON: one copy of the data, but a parser in the wasm, and a
   page that waits for it.

**Recommended: 2.** Keep the generator; move its source from Node's `Intl` to cldr-json, so it
can also write the plural rules from CLDR's rule text (`v = 0 and i % 10 = 2..4 and i % 100 != 12..14`
is a small grammar) instead of by hand, and the parent chains (`en-AU` → `en-001` → `en`). Write
one module per chosen locale; the app's `supported` list names them. Split `Validation.catalog` by
locale too, so an app with two languages carries two. For code size: keep `Message`'s parser out of
the browser when catalogs are generated (the generated catalog could hold parsed messages), and
measure which of `DateFormat`, `NumberFormat` and `Dict` dominate before shrinking anything.

**Depends on it.** `Locales.roc` (generated). **Undo.** Generated files; the generator stays.

## 5. Time zones

**Problem.** `intl.in_offset(minutes)` is a fixed offset. A reader's local time needs their zone
(`Europe/Warsaw`), whose offset changes with summer time, and the server doesn't know it. The
browser does (`Intl.DateTimeFormat().resolvedOptions().timeZone`), but the server renders first.

**Options.**
1. A host primitive on both platforms, `Zone.offset!(zone : Str, ms : I64) => I64` (minutes east of
   UTC), from the browser's `Intl.DateTimeFormat` with `timeZone`, and on the server from a time
   zone database in the Rust host (jiff with its bundled tzdb). The zone itself comes from a cookie
   (`tz`), set by the page once.
2. The tz database compiled into the wasm: correct offline, but 100–400 KB.
3. Fixed offsets only (today).

**Recommended: 1.** intl would add `intl.in_zone!(zone)` (or take the offset for each moment), and
keep `in_offset` for fixed ones. The first visit, before the cookie, renders UTC (or the
`Accept-Language`'s likely zone), and the page sets the cookie for the next.

**Depends on it.** `Intl.date`, `time`, `date_time` stay correct for UTC and fixed offsets.
**Undo.** The primitive is additive.

## 6. One copy of the date arithmetic

**Problem.** `server/platform/Calendar.roc` and intl's `Date.roc` both turn days since 1970 into
dates (Howard Hinnant's algorithm), about thirty lines each. The platform can't import a package,
and a package can't import the platform.

**Options.** 1. Keep both, each tested the same way (today: intl's expects include the platform's
own cases). 2. A pure `time` package that both use, if platforms can come to name packages.
3. Copy intl's `Date` into both platforms.

**Recommended: 1** for now; revisit if the platform gains a date type. forms also has a small
`Date` (a day, as `<input type="date">` sends it): forms could read into intl's `Date`, which has
the same fields, `parse_iso`, `to_iso` and day arithmetic, if forms is willing to depend on intl.

## 7. packages/forms

forms already gives what intl needs: `Issues.key(code)` (`"too_short"`) and `Issues.params(code)`
(`[{ name: "min", value: "3" }]`). `intl.issue(key, params)` takes them as they are, and
`Validation.catalog` has all nineteen keys in nine languages. Numbers in the params are read as
numbers (for the plural, and written the locale's way), ISO dates as days. Nothing more is needed
for today's issues. Three things would make the words better:

- **The field's label.** "Name is required" reads better than "Fill this in" in a summary at the
  top of a form. If an issue carried its field's label (or the app passed one), `validation.*`
  messages could use `{label}`. Today they don't, so the field's own label shows beside them.
- **`NotOneOf`'s options and `NoMatch`'s pattern** come as one joined text (`"a, b, c"`) and a
  regular expression. Neither is shown in the words: a list should be joined the locale's way
  (`a, b i c`), which needs list formatting (not in intl yet), and a pattern isn't for readers.
- **Its `Date`.** See 6: one day type for both packages would let forms' `TooEarly(min)` carry a
  day rather than text.

## Open questions

1. **Catalogs as Roc, or as files?** v1 writes catalogs as Roc lists of `(key, message)`.
   Translators' tools want files (JSON, XLIFF, PO). Is proposal 3 (files read by `rocx build`) the
   way to go, and which format?
2. **A missing key shows the key** (`cart.items`), so it is seen. Some apps would rather show
   nothing, or log it. Is the key right?
3. **`-0`.** A negative number that rounds to zero is written `"0"` (JavaScript's `Intl` writes
   `"-0"`). Keep it?
4. **The code's size** (proposal 4): about 35 KB brotli with messages. Worth it for the site, or
   should the site use only `NumberFormat` and `DateFormat` (12–22 KB)?
5. **forms' voice in other languages.** `Validation`'s words follow forms' English: short, second
   person. German, French, Czech and Russian use the polite form ("Geben Sie", "Saisissez",
   "Zadejte", "Введите"); Polish and Spanish the familiar one ("Wpisz", "Introduce"), as their apps
   usually do. Should a native speaker review them (cs, ru, ar and ja above all) before they ship?
