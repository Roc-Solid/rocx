import pf.Server

## A URL's query read (`?day=2026-11-22&meal=lunch&q=green+beans`), as an endpoint reads its
## request's and a page its location's. Plain Roc, with its `expect`s.
Query := [].{

	## The first value given for `name`, decoded (`+` is a space), or `""`.
	value : Str, Str -> Str
	value = |query, name|
		query
			.split_on("&")
			.keep_if(|pair| pair.starts_with("${name}="))
			.map(|pair| Server.decode_segment(pair.drop_prefix("${name}=").replace_each("+", " ")))
			.first()
			?? ""

	## A query of the pairs whose value isn't empty: `day=2026-11-22&meal=lunch`.
	of : List((Str, Str)) -> Str
	of = |pairs| Str.join_with(pairs.keep_if(|(_, said)| !said.is_empty()).map(|(key, said)| "${key}=${Server.encode_segment(said)}"), "&")

	## A path with a query, or the path alone when the query is empty.
	link : Str, Str -> Str
	link = |path, query| if (query.is_empty()) path else "${path}?${query}"
}

expect Query.value("day=2026-11-22&q=green+beans", "q") == "green beans"
expect Query.value("q=caf%C3%A9", "q") == "café"
expect Query.value("", "q") == ""
expect Query.of([("day", "2026-11-22"), ("meal", ""), ("q", "a b")]) == "day=2026-11-22&q=a%20b"
expect Query.link("/add", "") == "/add"
expect Query.link("/add", "meal=lunch") == "/add?meal=lunch"
