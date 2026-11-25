## What a sign-in page says when a sign-in came back to it with `?error=` (packages/auth's codes),
## and the other fields the plugin puts in that query (`reason`, `email`, `then`). It names no
## platform, so a page reads it in the browser as on the server (`browser.roc` lists it).
SignInError := [].{

	## The sentence for a sign-in page's query (`error=refused&reason=…`); "" when there is none:
	## - `link`: the link has been used or has expired;
	## - `refused`: what `admit!` said (its `reason`);
	## - `provider`: the provider refused, couldn't be reached, or isn't set up (its `reason`);
	## - `state`: back from a provider too late, or in another browser;
	## - anything else (`unavailable`): it didn't work just then.
	message : Str -> Str
	message = |query| {
		reason = SignInError.field(query, "reason")
		match SignInError.field(query, "error") {
			"" => ""
			"link" => "That sign-in link has been used or has expired. Ask for another."
			"refused" => if (reason.is_empty()) "You can't sign in here." else reason
			"provider" => if (reason.is_empty()) "Signing in there didn't work." else "Signing in there didn't work: ${reason}"
			"state" => "That sign-in took too long, or came from another browser. Try again."
			_ => "Signing in didn't work just now. Try again in a minute."
		}
	}

	## The value of `name` in a query (`error=link&then=%2Fnotes`), decoded (`%XX`, and `+` as a
	## space); "" when it isn't there.
	field : Str, Str -> Str
	field = |query, name|
		match query.split_on("&").find_first(|pair| pair.starts_with("${name}=")) {
			Ok(pair) => decoded(pair.drop_prefix("${name}="))
			Err(_) => ""
		}
}

## `%XX` as the byte it stands for, and `+` as a space; anything else as it is.
decoded : Str -> Str
decoded = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $i = 0
	while $i < bytes.len() {
		byte = bytes.get($i) ?? 0
		if byte == '%' and $i + 2 < bytes.len() {
			match (hex(bytes.get($i + 1) ?? 0), hex(bytes.get($i + 2) ?? 0)) {
				(Ok(high), Ok(low)) => {
					$out = $out.append(high * 16 + low)
					$i = $i + 3
				}
				_ => {
					$out = $out.append(byte)
					$i = $i + 1
				}
			}
		} else {
			$out = $out.append(if (byte == '+') ' ' else byte)
			$i = $i + 1
		}
	}
	Str.from_utf8_lossy($out)
}

## A hex digit's value.
hex : U8 -> Try(U8, [NotHex])
hex = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

expect SignInError.message("error=refused&reason=Not%20on%20the%20list&email=a%40b.c") == "Not on the list"
expect SignInError.message("error=link&then=%2Fnotes") == "That sign-in link has been used or has expired. Ask for another."
expect SignInError.message("error=provider&reason=access_denied") == "Signing in there didn't work: access_denied"
expect SignInError.message("error=unavailable") == "Signing in didn't work just now. Try again in a minute."
expect SignInError.message("then=%2F") == ""
expect SignInError.field("error=link&then=%2Fnotes%3Fx%3D1", "then") == "/notes?x=1"
expect SignInError.field("reason=a+b%20c", "reason") == "a b c"
expect SignInError.field("x=%zz%4", "x") == "%zz%4"
expect SignInError.field("email=%C3%A9@x", "email") == "é@x"
