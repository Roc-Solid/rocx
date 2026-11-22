import pf.Server

## A URL's query read, as an endpoint reads one (`?q=deploy+%23work&tag=a&tag=b`). Plain Roc, with its
## `expect`s.
Query := [].{

	## Every value given for `name`, decoded (`+` is a space), in order.
	values : Str, Str -> List(Str)
	values = |query, name|
		query
			.split_on("&")
			.keep_if(|pair| pair.starts_with("${name}="))
			.map(|pair| Server.decode_segment(pair.drop_prefix("${name}=").replace_each("+", " ")))

	## The first value given for `name`, or `""`.
	value : Str, Str -> Str
	value = |query, name| Query.values(query, name).first() ?? ""

	## Whether `name` is given as `true` (or `1`, or `on`, as a checkbox sends it).
	flag : Str, Str -> Bool
	flag = |query, name| ["true", "1", "on"].contains(Query.value(query, name))
}

expect Query.values("q=deploy+%23work&tag=a&tag=b", "tag") == ["a", "b"]
expect Query.value("q=deploy+%23work&tag=a", "q") == "deploy #work"
expect Query.value("", "q") == ""
expect Query.flag("archived=true", "archived") and !Query.flag("archived=no", "archived") and !Query.flag("", "archived")
