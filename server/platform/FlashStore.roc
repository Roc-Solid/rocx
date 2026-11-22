import Host

## Where a plain form's flash waits between its post and the page it goes back to
## (`Server.flash_back!`, `Server.flash!`): in the server's memory (the store `Kv` keeps), for a
## minute, under a random id, which is all the browser's cookie holds. The first page that reads it
## takes it. The browser's platform has its own (web/platform/FlashStore.roc): the flash its page
## came with.
FlashStore := [].{

	## Keeps a flash for a minute under a new random id: the headers its post's 303 sets. The cookie
	## `rocx-flash` holds the id. With `--debug` or `--dev`, `x-rocx-flash` says what the flash says
	## (its URL, status and body, `%XX`-encoded JSON; never the fields as typed), for tests
	## (packages/testing's `flash`).
	keep! : { url : Str, input : Str, status : U16, body : Str } => List({ name : Str, value : Str })
	keep! = |posted| {
		id = hex(Host.random_bytes!(16))
		Host.kv_set!("${key_prefix}${id}", Json.to_str(posted), 60_000)
		cookie = { name: "set-cookie", value: "${cookie_name}=${id}; Path=/; Max-Age=60; HttpOnly; SameSite=Lax" }
		if Host.setting!("debug").is_empty() and Host.setting!("dev").is_empty() {
			[cookie]
		} else {
			told = Json.to_str({ url: posted.url, status: posted.status, body: posted.body })
			[cookie, { name: "x-rocx-flash", value: encoded(told) }]
		}
	}

	## The flash the cookie's id names, as JSON; "" with none. The first read while a page renders
	## takes it from the store, so it is read once, and the host notes it for the page (a script
	## hydration reads); a read after that in the same render is given the note.
	read! : Str => Str
	read! = |id| {
		noted = Host.flash!("")
		if !noted.is_empty() or id.is_empty() {
			noted
		} else {
			match Host.kv_take!("${key_prefix}${id}") {
				Ok(json) => Host.flash!(json)
				Err(_) => ""
			}
		}
	}
}

## The cookie the id is in (`Server.flash!` reads it).
cookie_name : Str
cookie_name = "rocx-flash"

## The store's keys for flashes: the platform's, never an app's.
key_prefix : Str
key_prefix = "rocx:flash:"

## Bytes as lowercase hex.
hex : List(U8) -> Str
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	Str.from_utf8_lossy(bytes.join_map(|byte| [digits.get((byte // 16).to_u64()) ?? '0', digits.get((byte % 16).to_u64()) ?? '0']))
}

## Text as a header may carry it: anything but a letter, a digit or `-._~` as `%XX`.
encoded : Str -> Str
encoded = |text| {
	upper = "0123456789ABCDEF".to_utf8()
	var $out = []
	for byte in text.to_utf8() {
		$out =
			if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~' {
				$out.append(byte)
			} else {
				$out.concat(['%', upper.get((byte // 16).to_u64()) ?? '0', upper.get((byte % 16).to_u64()) ?? '0'])
			}
	}
	Str.from_utf8_lossy($out)
}

expect hex([0, 15, 16, 255]) == "000f10ff"
expect encoded("{\"a\":\"é\"}") == "%7B%22a%22%3A%22%C3%A9%22%7D"
