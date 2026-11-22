import intl.Date
import intl.Intl
import intl.Locales
import intl.Catalog

## The journal's two languages, and its words in each. A page's language is the first part of its
## path (`/en/…`, `/pl/…`). `I18n.intl(lang)` writes dates, numbers, plurals and the interface's
## words in it, with packages/intl. It is plain Roc, so the server's pages and the browser's
## islands (the search, the reactions) write the same text.
I18n := [].{

	## The languages the journal is written in, the default first. Only these are compiled in.
	supported : List(Locales.Data)
	supported = [Locales.en, Locales.pl]

	## Their tags, as paths have them.
	langs : List(Str)
	langs = ["en", "pl"]

	## Where a reader goes whose browser asks for neither language.
	default : Str
	default = "en"

	## Whether `lang` is one of the journal's languages.
	known : Str -> Bool
	known = |lang| I18n.langs.contains(lang)

	## The language a path is in: its first part, when that is one of the journal's, else the
	## default. The layout and the error page read it from the address.
	of_path : Str -> Str
	of_path = |path| {
		first = path.drop_prefix("/").split_on("/").first() ?? ""
		if (I18n.known(first)) first else I18n.default
	}

	## A language's name in itself, as the switcher shows it.
	name : Str -> Str
	name = |lang| if (lang == "pl") "Polski" else "English"

	## The journal's other languages than `lang`.
	others : Str -> List(Str)
	others = |lang| I18n.langs.drop_if(|other| other == lang)

	## How `lang` writes things, with the journal's words.
	intl : Str -> Intl
	intl = |lang| Intl.for_tag(I18n.supported, lang).with_catalog(I18n.catalog)

	## A day written `2026-02-08`, as `lang` writes it: "February 8, 2026", "8 lutego 2026".
	day : Str, Str -> Str
	day = |lang, iso|
		match Date.parse_iso(iso) {
			Ok(date) => I18n.intl(lang).day(date, Long)
			Err(_) => iso
		}

	## How long a post takes to read: "5 min read", "5 minut czytania".
	reading : Str, U64 -> Str
	reading = |lang, minutes| I18n.intl(lang).t("post.minutes", [("count", Int(minutes.to_i64_wrap()))])

	## `key`'s words in `lang`, with no arguments.
	t : Str, Str -> Str
	t = |lang, key| I18n.intl(lang).t(key, [])

	## The interface's words: one set for each language, the default's first. A key missing from
	## Polish would show the English (`Catalog.problems` says which; an expect below keeps it
	## empty). Plurals follow each language's rules: Polish has one, few and many.
	catalog : Catalog
	catalog = Catalog.new(
		"en",
		[
			(
				"en",
				[
					("site.tagline", "Notes on making things slowly"),
					("site.description", "A small journal about bread, bicycles, notebooks, tides and other slow things, in English and Polish."),
					("nav.label", "Main"),
					("nav.latest", "Latest"),
					("nav.tags", "Tags"),
					("nav.search", "Search"),
					("nav.search_label", "Search the journal"),
					("nav.language", "Language"),
					("skip", "Skip to the content"),
					("index.title", "Latest writing"),
					("index.page", "Page {page} of {pages}"),
					("index.numbered", "Page {page}"),
					("pager.label", "Pages"),
					("pager.newer", "Newer posts"),
					("pager.older", "Older posts"),
					("post.minutes", "{count, plural, one {# min read} other {# min read}}"),
					("post.words", "{count, plural, one {# word} other {# words}}"),
					("post.contents", "Contents"),
					("post.notes", "Notes"),
					("post.back", "Back to the text"),
					("post.newer", "Newer"),
					("post.older", "Older"),
					("post.around", "More from the journal"),
					("post.tags", "Tags"),
					("post.read_here", "Read it in English"),
					("posts.count", "{count, plural, one {# post} other {# posts}}"),
					("tags.title", "Tags"),
					("tags.lead", "Every subject the journal has written about, with how often."),
					("tag.title", "Posts tagged “{tag}”"),
					("author.title", "Writing by {name}"),
					("search.title", "Search"),
					("search.label", "Search titles and tags"),
					("search.button", "Search"),
					("search.all", "{count, plural, one {# post in the journal} other {All # posts in the journal}}"),
					("search.found", "{count, plural, =0 {Nothing matches “{query}”.} one {# post matches “{query}”.} other {# posts match “{query}”.}}"),
					("react.label", "Reactions"),
					("react.lead", "Did this one land?"),
					("react.clap", "Applause"),
					("react.heart", "Love it"),
					("react.idea", "Made me think"),
					("react.smile", "Made me smile"),
					("react.slow", "Easy there: try again in a minute."),
					("react.failed", "That didn't go through: {why}"),
					("react.dismiss", "Dismiss"),
					("notfound.title", "Nothing here"),
					("notfound.text", "There is no page at this address. It may have moved, or it was never written."),
					("notfound.home", "Back to the latest writing"),
					("failed.title", "Something went wrong"),
					("failed.text", "This page couldn't be shown. Try again in a moment."),
					("footer.about", "Acme Journal is a small publication about making things slowly, written in English and Polish."),
					("footer.feed", "Atom feed"),
					("footer.api", "JSON API"),
					("footer.made", "Made with Roc Solid"),
				],
			),
			(
				"pl",
				[
					("site.tagline", "Notatki o robieniu rzeczy powoli"),
					("site.description", "Mały dziennik o chlebie, rowerach, notesach, pływach i innych powolnych sprawach, po angielsku i po polsku."),
					("nav.label", "Główna"),
					("nav.latest", "Najnowsze"),
					("nav.tags", "Tagi"),
					("nav.search", "Szukaj"),
					("nav.search_label", "Szukaj w dzienniku"),
					("nav.language", "Język"),
					("skip", "Przejdź do treści"),
					("index.title", "Najnowsze teksty"),
					("index.page", "Strona {page} z {pages}"),
					("index.numbered", "Strona {page}"),
					("pager.label", "Strony"),
					("pager.newer", "Nowsze wpisy"),
					("pager.older", "Starsze wpisy"),
					("post.minutes", "{count, plural, one {# minuta czytania} few {# minuty czytania} many {# minut czytania} other {# minuty czytania}}"),
					("post.words", "{count, plural, one {# słowo} few {# słowa} many {# słów} other {# słowa}}"),
					("post.contents", "Spis treści"),
					("post.notes", "Przypisy"),
					("post.back", "Wróć do tekstu"),
					("post.newer", "Nowszy"),
					("post.older", "Starszy"),
					("post.around", "Więcej z dziennika"),
					("post.tags", "Tagi"),
					("post.read_here", "Czytaj po polsku"),
					("posts.count", "{count, plural, one {# wpis} few {# wpisy} many {# wpisów} other {# wpisu}}"),
					("tags.title", "Tagi"),
					("tags.lead", "Wszystkie tematy, o których pisaliśmy, i jak często."),
					("tag.title", "Wpisy z tagiem „{tag}”"),
					("author.title", "Teksty: {name}"),
					("search.title", "Szukaj"),
					("search.label", "Szukaj w tytułach i tagach"),
					("search.button", "Szukaj"),
					("search.all", "{count, plural, one {# wpis w dzienniku} few {Wszystkie # wpisy w dzienniku} many {Wszystkie # wpisów w dzienniku} other {Wszystkie # wpisu w dzienniku}}"),
					("search.found", "{count, plural, =0 {Nic nie pasuje do „{query}”.} one {# wpis pasuje do „{query}”.} few {# wpisy pasują do „{query}”.} many {# wpisów pasuje do „{query}”.} other {# wpisu pasuje do „{query}”.}}"),
					("react.label", "Reakcje"),
					("react.lead", "Jak się czytało?"),
					("react.clap", "Brawa"),
					("react.heart", "Uwielbiam"),
					("react.idea", "Daje do myślenia"),
					("react.smile", "Rozbawiło mnie"),
					("react.slow", "Spokojnie: spróbuj za minutę."),
					("react.failed", "Nie udało się: {why}"),
					("react.dismiss", "Zamknij"),
					("notfound.title", "Nic tu nie ma"),
					("notfound.text", "Pod tym adresem nie ma strony. Może się przeniosła, a może nigdy jej nie napisano."),
					("notfound.home", "Wróć do najnowszych tekstów"),
					("failed.title", "Coś poszło nie tak"),
					("failed.text", "Nie udało się pokazać tej strony. Spróbuj za chwilę."),
					("footer.about", "Acme Journal to mały dziennik o robieniu rzeczy powoli, pisany po angielsku i po polsku."),
					("footer.feed", "Kanał Atom"),
					("footer.api", "API JSON"),
					("footer.made", "Zrobione w Roc Solid"),
				],
			),
		],
	)
}

read_in : Str, U64 -> Str
read_in = |lang, count| I18n.reading(lang, count)

expect Catalog.problems(I18n.catalog) == []
expect I18n.of_path("/pl/posts/slow-bread") == "pl"
expect I18n.of_path("/de/posts/slow-bread") == "en"
expect I18n.of_path("/") == "en"

# "5 min read" and its translation: Polish says 1 minuta, 2 minuty, 5 minut, 22 minuty.
expect read_in("en", 1) == "1 min read"
expect read_in("en", 5) == "5 min read"
expect read_in("pl", 1) == "1 minuta czytania"
expect read_in("pl", 3) == "3 minuty czytania"
expect read_in("pl", 5) == "5 minut czytania"
expect read_in("pl", 22) == "22 minuty czytania"
expect I18n.day("en", "2026-02-08") == "February 8, 2026"
expect I18n.day("pl", "2026-02-08") == "8 lutego 2026"
expect I18n.intl("pl").t("posts.count", [("count", Int(12))]) == "12 wpisów"
expect I18n.intl("en").t("search.found", [("count", Int(0)), ("query", Text("kite"))]) == "Nothing matches “kite”."
