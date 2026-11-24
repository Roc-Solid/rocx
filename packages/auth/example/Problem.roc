import pf.Server

## What the sign-in page says when a sign-in came back with `?error=` (packages/auth's codes), and
## the reason the plugin gave with it. Plain Roc, so the page reads it in the browser too.
Problem := [].{

	## The sentence for a sign-in page's query (`error=refused&reason=…`); "" when there is none.
	of : Str -> Str
	of = |query| {
		reason = Problem.field(query, "reason")
		match Problem.field(query, "error") {
			"" => ""
			"link" => "That sign-in link has been used or has expired. Ask for another."
			"refused" => reason
			"provider" => "Signing in there didn't work: ${reason}"
			"state" => "That sign-in took too long, or came from another browser. Try again."
			_ => "Signing in didn't work just now. Try again in a minute."
		}
	}

	## The value of `name` in a query, decoded (`+` is a space); "" when it isn't there.
	field : Str, Str -> Str
	field = |query, name|
		match query.split_on("&").find_first(|pair| pair.starts_with("${name}=")) {
			Ok(pair) => Server.decode_segment(pair.drop_prefix("${name}=").replace_each("+", " "))
			Err(_) => ""
		}
}

expect Problem.of("error=refused&reason=Not%20you") == "Not you"
expect Problem.of("error=link") == "That sign-in link has been used or has expired. Ask for another."
expect Problem.of("then=%2F") == ""
expect Problem.field("then=%2Fprivate&x=1", "then") == "/private"
