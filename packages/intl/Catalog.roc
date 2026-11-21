import Locale
import Message

## Translated messages: a set of keyed ICU messages (see `Message`) for each locale, one of them
## the default. A key is looked up in the locale's own set, then in the sets it falls back to
## (`pl-PL`, then `pl`), then in the default's, so a regional set (`en-GB`) holds only what it says
## differently, and a missing translation shows the default's words rather than nothing.
##
##     catalog = Catalog.new("en", [
##         ("en", [("cart.items", "{count, plural, =0 {Your cart is empty} one {# item} other {# items}}")]),
##         ("pl", [("cart.items", "{count, plural, =0 {Koszyk jest pusty} one {# produkt} few {# produkty} other {# produktów}}")]),
##     ])
##
## `catalog.problems()` lists what a translator still has to do (a key missing, one the default
## doesn't have, a message that can't be read, arguments that differ from the default's); an app
## can `expect catalog.problems() == []`, or show `Catalog.explain` for each.
Catalog := { default : Locale, sets : List({ locale : Locale, messages : Dict(Str, [Ready(Message), Broken({ source : Str, why : Str })]) }) }.{

	## Something to fix in a catalog, by the locale's tag and the message's key.
	Problem : [
		Missing({ locale : Str, key : Str }),
		Unknown({ locale : Str, key : Str }),
		Unreadable({ locale : Str, key : Str, why : Str }),
		Arguments({ locale : Str, key : Str, wanted : List(Str), found : List(Str) }),
	]

	## A catalog whose default locale is `default` (a tag, `"en"`), with a set of `(key, message)`
	## pairs for each locale. Each message is read once, here; one that can't be read is kept as
	## its text, shown as it is, and reported by `problems`. Tags are the app's literals: a bad
	## one crashes, as `Locale.of` does.
	new : Str, List((Str, List((Str, Str)))) -> Catalog
	new = |default, sets| sets.fold(Catalog.empty(default), |catalog, (tag, pairs)| catalog.add(tag, pairs))

	## A catalog with no messages yet.
	empty : Str -> Catalog
	empty = |default| { default: Locale.of(default), sets: [] }

	## More messages for the locale `tag`, replacing any with the same keys.
	add : Catalog, Str, List((Str, Str)) -> Catalog
	add = |catalog, tag, pairs| {
		locale = Locale.of(tag)
		read = pairs.fold(
			Dict.empty(),
			|messages, (key, source)|
				messages.insert(
					key,
					match Message.parse(source) {
						Ok(message) => Ready(message)
						Err(BadMessage({ at: offset, why })) => Broken({ source, why: "at ${offset.to_str()}, ${why}" })
					},
				),
		)
		match catalog.sets.find_first_index(|set| set.locale == locale) {
			Ok(index) => { ..catalog, sets: catalog.sets.update(index, |set| { ..set, messages: set.messages.insert_all(read) }) ?? catalog.sets }
			Err(_) => { ..catalog, sets: catalog.sets.append({ locale, messages: read }) }
		}
	}

	## Both catalogs' messages, `top`'s where both have a key; `top`'s default. How an app puts its
	## own words over a package's (`Catalog.merge(Validation.catalog, app)`).
	merge : Catalog, Catalog -> Catalog
	merge = |base, top| {
		sets = top.sets.fold(
			base.sets,
			|so_far, set|
				match so_far.find_first_index(|each| each.locale == set.locale) {
					Ok(index) => so_far.update(index, |each| { ..each, messages: each.messages.insert_all(set.messages) }) ?? so_far
					Err(_) => so_far.append(set)
				},
		)
		{ default: top.default, sets }
	}

	## The message for `key` in `locale`: its own, a fallback's, or the default's.
	find : Catalog, Locale, Str -> Try(Message, [Missing])
	find = |catalog, locale, key| {
		chain = locale.fallbacks().append(catalog.default)
		found = chain.fold_until(
			Err(Missing),
			|_, each|
				match catalog.sets.find_first(|set| set.locale == each) {
					Ok(set) =>
						match set.messages.get(key) {
							Ok(Ready(message)) => Break(Ok(message))
							Ok(Broken({ source, .. })) => Break(Ok(Message.literal(source)))
							Err(_) => Continue(Err(Missing))
						}
					Err(_) => Continue(Err(Missing))
				},
		)
		found
	}

	## Whether `locale` says `key` in its own words (or a fallback's), not the default's.
	has_key : Catalog, Locale, Str -> Bool
	has_key = |catalog, locale, key|
		locale.fallbacks().any(
			|each|
				match catalog.sets.find_first(|set| set.locale == each) {
					Ok(set) => set.messages.contains(key)
					Err(_) => Bool.False
				},
		)

	## The default locale.
	default_locale : Catalog -> Locale
	default_locale = |catalog| catalog.default

	## The locales with messages, in the order they were added.
	locales : Catalog -> List(Locale)
	locales = |catalog| catalog.sets.map(|set| set.locale)

	## The keys a locale's own set has.
	keys : Catalog, Str -> List(Str)
	keys = |catalog, tag| {
		locale = Locale.of(tag)
		match catalog.sets.find_first(|set| set.locale == locale) {
			Ok(set) => set.messages.keys()
			Err(_) => []
		}
	}

	## The default's keys that `tag` (and what it falls back to, short of the default) doesn't say:
	## what is left to translate.
	missing : Catalog, Str -> List(Str)
	missing = |catalog, tag| {
		locale = Locale.of(tag)
		if locale == catalog.default {
			[]
		} else {
			Catalog.keys(catalog, catalog.default.tag()).keep_if(|key| !(catalog.has_key(locale, key)))
		}
	}

	## Everything to fix, set by set, in the order the sets and keys were added: keys missing from
	## a locale, keys the default doesn't have, messages that can't be read, and messages whose
	## arguments aren't the default's (a `{name}` misspelt, or left out).
	problems : Catalog -> List(Problem)
	problems = |catalog| {
		defaults = catalog.sets.find_first(|set| set.locale == catalog.default) ?? { locale: catalog.default, messages: Dict.empty() }
		catalog.sets.join_map(
			|set| {
				tag = set.locale.tag()
				unreadable = set.messages.to_list().keep_oks(
					|(key, entry)|
						match entry {
							Broken({ why, .. }) => Ok(Unreadable({ locale: tag, key, why }))
							Ready(_) => Err(Fine)
						},
				)
				if set.locale == catalog.default {
					unreadable
				} else {
					absent = Catalog.missing(catalog, tag).map(|key| Missing({ locale: tag, key }))
					compared = set.messages.to_list().keep_oks(
						|(key, entry)|
							match (defaults.messages.get(key), entry) {
								(Err(_), _) => Ok(Unknown({ locale: tag, key }))
								(Ok(Ready(theirs)), Ready(ours)) => {
									wanted = Message.names(theirs)
									found = Message.names(ours)
									same = wanted.all(|name| found.contains(name)) and found.all(|name| wanted.contains(name))
									if (same) Err(Fine) else Ok(Arguments({ locale: tag, key, wanted, found }))
								}
								_ => Err(Fine)
							},
					)
					absent.concat(compared).concat(unreadable)
				}
			},
		)
	}

	## A problem in a sentence: `pl has no "cart.items" yet (en's is shown)`.
	explain : Problem -> Str
	explain = |problem| {
		braced = |names| Str.join_with(names.map(|name| "{${name}}"), ", ")
		match problem {
			Missing({ locale, key }) => "${locale} has no \"${key}\" yet (the default's is shown)"
			Unknown({ locale, key }) => "${locale}'s \"${key}\" isn't a key of the default's: misspelt, or no longer used?"
			Unreadable({ locale, key, why }) => "${locale}'s \"${key}\" can't be read, so it is shown as written: ${why}"
			Arguments({ locale, key, wanted, found }) => "${locale}'s \"${key}\" reads ${if (found.is_empty()) "no arguments" else braced(found)} where the default's reads ${if (wanted.is_empty()) "none" else braced(wanted)}"
		}
	}
}

shop : Catalog
shop = Catalog.new(
	"en",
	[
		("en", [("title", "Shop"), ("cart", "{count, plural, one {# item} other {# items}}"), ("hello", "Hello, {name}!"), ("colour", "Colour")]),
		("en-GB", [("colour", "Colour (GB)")]),
		("pl", [("title", "Sklep"), ("cart", "{count, plural, one {# produkt} few {# produkty} other {# produktów}"), ("hello", "Cześć, {imie}!"), ("extra", "Nadmiar")]),
	],
)

expect Catalog.find(shop, Locale.of("pl"), "title").map_ok(|m| Message.names(m)) == Ok([])
expect Catalog.has_key(shop, Locale.of("pl"), "title")
expect !Catalog.has_key(shop, Locale.of("pl"), "colour")
expect Catalog.has_key(shop, Locale.of("en-GB"), "colour")
expect Catalog.has_key(shop, Locale.of("pl-PL"), "title")
expect Catalog.find(shop, Locale.of("de"), "nope").is_err()
expect Catalog.keys(shop, "en") == ["title", "cart", "hello", "colour"]
expect Catalog.missing(shop, "pl") == ["colour"]
expect Catalog.missing(shop, "en-GB") == []
expect Catalog.missing(shop, "en") == []
expect Catalog.locales(shop).map(|l| l.tag()) == ["en", "en-GB", "pl"]
expect Catalog.default_locale(shop).tag() == "en"

expect {
	found = Catalog.problems(shop).map(Catalog.explain)
	found
		== [
			"pl has no \"colour\" yet (the default's is shown)",
			"pl's \"hello\" reads {imie} where the default's reads {name}",
			"pl's \"extra\" isn't a key of the default's: misspelt, or no longer used?",
			"pl's \"cart\" can't be read, so it is shown as written: at 69, `count`'s plural is never closed",
		]
}

expect {
	package_words = Catalog.new("en", [("en", [("a", "A"), ("b", "B")]), ("pl", [("a", "A-pl")])])
	app_words = Catalog.new("en", [("en", [("b", "Bee")]), ("de", [("a", "A-de")])])
	merged = Catalog.merge(package_words, app_words)
	Catalog.keys(merged, "en") == ["a", "b"] and Catalog.keys(merged, "de") == ["a"] and Catalog.keys(merged, "pl") == ["a"] and Catalog.problems(merged).len() == 2
}
