import Host
import Server

## The page's query, as Solid Router's `useSearchParams` gives it (D-040): `Router.use_search_params!`
## makes one. A read (`get!`, `all!`) reads `Router.location!` underneath, so a hole or a memo that
## reads it runs again when the query changes, and only those; `set!` changes the query in place.
##
##     search = use_search_params!({})
##     days! = || search.get!("days") ?? "7"
##     report! = create_memo!(|| Endpoint.get!(stats.with_query("days=${Server.encode_segment(days!())}")))
##     <button aria-pressed={if (days!() == "30") "true" else "false"} on:click={|| search.set!([("days", "30")])}>30 days</button>
##
## A change of the query alone is made in place: the address changes (an entry pushed, Back goes
## back to the last query), the page and its layouts are kept, no document is fetched, and what read
## the query reads again (a read whose URL changed asks its endpoint, behind that endpoint's
## middleware, its last value shown meanwhile). A layout that read the location once, in its body, is
## made anew instead, and the page's document fetched for it.
Search :: [Here].{

	## The page's query (what `Router.use_search_params!` gives).
	here : Search
	here = Here

	## The first value of `name` in the query, decoded (`+` a space, `%XX` what it stands for);
	## `Err(Missing)` when the query has none. Tracked: what reads it follows the query.
	get! : Search, Str => Try(Str, [Missing])
	get! = |_search, name|
		match Search.pairs(Search.query!({})).find_first(|pair| pair.0 == name) {
			Ok(pair) => Ok(pair.1)
			Err(_) => Err(Missing)
		}

	## Every pair of the query, in order, decoded. Tracked, as `get!` is.
	all! : Search => List((Str, Str))
	all! = |_search| Search.pairs(Search.query!({}))

	## From a handler: the query with `changes` merged in (`Search.merged`), navigated to in place on
	## the page's own path, an entry pushed, the scroll left where it is (Solid Router's
	## `setSearchParams`). A value of `""` takes its name out. Queued with the handler's writes, as
	## `Router.navigate!` is; anywhere but a handler it fails.
	##
	##     search.set!([("days", "30"), ("page", "")])
	set! : Search, List((Str, Str)) => {}
	set! = |search, changes| search.set_with!(changes, { replace: Bool.False, scroll: Bool.False })

	## `set!`, saying whether the entry is replaced instead of a new one pushed, and whether the page
	## scrolls to its top.
	set_with! : Search, List((Str, Str)), { replace : Bool, scroll : Bool } => {}
	set_with! = |_search, changes, { replace, scroll }| {
		query = Search.text(Search.merged(Search.pairs(Search.query!({})), changes))
		path = Search.path!({})
		Host.navigate!(if (query.is_empty()) path else "${path}?${query}", replace, scroll)
	}

	## A query (`days=7&tag=a+b`, without its `?`) as its pairs, decoded, in order.
	pairs : Str -> List((Str, Str))
	pairs = |query| Server.form_fields(query).map(|field| (field.name, field.value))

	## A query's pairs with `changes` merged in, as `set!` merges them: each name `changes` gives
	## replaces every pair of that name, its values put where the first one was (after the others when
	## there was none), in the order `changes` has them; a value of `""` is none, so a name given only
	## `""` is taken out. The other pairs stay as they are.
	merged : List((Str, Str)), List((Str, Str)) -> List((Str, Str))
	merged = |given_pairs, changes| {
		names = changes.fold([], |seen, change| if (seen.contains(change.0)) seen else seen.append(change.0))
		given = |name| changes.keep_if(|change| change.0 == name and !change.1.is_empty())
		var $out = []
		var $placed = []
		for pair in given_pairs {
			if !names.contains(pair.0) {
				$out = $out.append(pair)
			} else if !$placed.contains(pair.0) {
				$out = $out.concat(given(pair.0))
				$placed = $placed.append(pair.0)
			}
		}
		for name in names {
			if !$placed.contains(name) {
				$out = $out.concat(given(name))
			}
		}
		$out
	}

	## Pairs as a query, without its `?`: each name and value encoded (`Server.encode_segment`).
	text : List((Str, Str)) -> Str
	text = |all| Str.join_with(all.map(|pair| "${Server.encode_segment(pair.0)}=${Server.encode_segment(pair.1)}"), "&")

	## The location's query (`Router.location!`'s), without its `?`: tracked.
	query! : {} => Str
	query! = |{}|
		match Host.location!({}).split_first("?") {
			Ok({ after, .. }) => after
			Err(_) => ""
		}

	## The location's path.
	path! : {} => Str
	path! = |{}|
		match Host.location!({}).split_first("?") {
			Ok({ before, .. }) => if (before.is_empty()) "/" else before
			Err(_) => Host.location!({})
		}
}

expect Search.pairs("days=7&tag=a+b&tag=c%26d&bare") == [("days", "7"), ("tag", "a b"), ("tag", "c&d"), ("bare", "")]
expect Search.pairs("") == []
expect Search.merged([("days", "7"), ("page", "2")], [("days", "30")]) == [("days", "30"), ("page", "2")]
expect Search.merged([("days", "7"), ("page", "2")], [("page", "")]) == [("days", "7")]
expect Search.merged([("tag", "a"), ("q", "x"), ("tag", "b")], [("tag", "c"), ("tag", "d")]) == [("tag", "c"), ("tag", "d"), ("q", "x")]
expect Search.merged([("q", "x")], [("card", "12")]) == [("q", "x"), ("card", "12")]
expect Search.merged([], [("gone", "")]) == []
expect Search.text([("q", "a b&c"), ("card", "12")]) == "q=a%20b%26c&card=12"
