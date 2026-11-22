## An email address, as signing in takes one. Plain Roc, with its `expect`s: the server checks every
## address with it before it mails a link or counts one against the limit.
Address := [].{

	## An address, its spaces gone and in lower case (so `Ada@Example.com` and `ada@example.com`
	## are one person, and one count for the limit on links): a name, an `@` and a domain with a dot
	## in it, no spaces, 254 characters at most.
	of : Str -> Try(Str, Str)
	of = |given| {
		address = given.trim().with_ascii_lowercased()
		problem = Err("That doesn't look like an email address.")
		match address.split_on("@") {
			[name, domain] =>
				if name.is_empty() or domain.is_empty() or address.count_utf8_bytes() > 254 {
					problem
				} else if address.contains(" ") or !domain.contains(".") or domain.starts_with(".") or domain.ends_with(".") {
					problem
				} else {
					Ok(address)
				}
			_ => problem
		}
	}
}

expect Address.of("  Ada@Example.com ") == Ok("ada@example.com")
expect Address.of("bo.lee+notes@mail.example.org") == Ok("bo.lee+notes@mail.example.org")
expect Address.of("ada").is_err()
expect Address.of("ada@example").is_err()
expect Address.of("@example.com").is_err()
expect Address.of("ada@@example.com").is_err()
expect Address.of("a da@example.com").is_err()
expect Address.of("ada@.example.com").is_err()
