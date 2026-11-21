## How a push service treats a message (RFC 8030, section 5): how long it keeps one for a browser
## that is offline (`ttl`, seconds; 0: deliver now or never), how soon it must arrive (`urgency`: a
## phone on battery may hold `VeryLow` and `Low` back), and its `topic`, by which a newer message
## replaces one still waiting (`"order-17"`: only the latest status arrives).
Options := { ttl : U64, urgency : [VeryLow, Low, Normal, High], topic : Str }.{

	## Whether two are the same options.
	is_eq : Options, Options -> Bool
	is_eq = |left, right| left.ttl == right.ttl and left.urgency == right.urgency and left.topic == right.topic

	## A day, `Normal`, no topic.
	defaults : Options
	defaults = { ttl: 86_400, urgency: Normal, topic: "" }

	## The longest a push service keeps a message (Chrome's, four weeks): a longer `ttl` is sent as
	## this.
	max_ttl : U64
	max_ttl = 2_419_200

	## The options, or `BadTopic` for a topic that isn't 32 characters at most of the URL-safe
	## Base64 alphabet (letters, digits, `-`, `_`), as RFC 8030 asks.
	check : Options -> Try(Options, [BadTopic])
	check = |options| {
		bytes = options.topic.to_utf8()
		if bytes.len() <= 32 and bytes.all(|each| (each >= 'A' and each <= 'Z') or (each >= 'a' and each <= 'z') or (each >= '0' and each <= '9') or each == '-' or each == '_') {
			Ok(options)
		} else {
			Err(BadTopic)
		}
	}

	## The request's headers: `TTL` and `Urgency` always, `Topic` when there is one.
	headers : Options -> List({ name : Str, value : Str })
	headers = |options| {
		urgency =
			match options.urgency {
				VeryLow => "very-low"
				Low => "low"
				Normal => "normal"
				High => "high"
			}
		[{ name: "TTL", value: U64.min(options.ttl, Options.max_ttl).to_str() }, { name: "Urgency", value: urgency }]
			.concat(if (options.topic.is_empty()) [] else [{ name: "Topic", value: options.topic }])
	}

	## The options for sending at `now_ms` a message queued at `queued_ms`: its `ttl` less the
	## whole seconds it has waited, so a retry never outlives the message. `Expired` once it has
	## waited longer than its `ttl` (one of 0 goes within its first second, or never).
	remaining : Options, U64, U64 -> Try(Options, [Expired])
	remaining = |options, queued_ms, now_ms| {
		waited = (if (now_ms > queued_ms) now_ms - queued_ms else 0) // 1000
		if waited > options.ttl {
			Err(Expired)
		} else {
			Ok({ ..options, ttl: options.ttl - waited })
		}
	}
}

expect Options.defaults.headers() == [{ name: "TTL", value: "86400" }, { name: "Urgency", value: "normal" }]
expect
	Options.headers({ ttl: 60, urgency: VeryLow, topic: "order-17" })
		== [{ name: "TTL", value: "60" }, { name: "Urgency", value: "very-low" }, { name: "Topic", value: "order-17" }]
expect { ..Options.defaults, urgency: High }.headers().get(1) == Ok({ name: "Urgency", value: "high" })
expect { ..Options.defaults, urgency: Low }.headers().get(1) == Ok({ name: "Urgency", value: "low" })
expect { ..Options.defaults, ttl: 99_999_999 }.headers().first() == Ok({ name: "TTL", value: "2419200" })
expect { ..Options.defaults, ttl: 0 }.headers().first() == Ok({ name: "TTL", value: "0" })

expect Options.check({ ..Options.defaults, topic: "order-17_a" }).is_ok()
expect Options.check({ ..Options.defaults, topic: Str.repeat("a", 32) }).is_ok()
expect Options.check({ ..Options.defaults, topic: Str.repeat("a", 33) }) == Err(BadTopic)
expect Options.check({ ..Options.defaults, topic: "order 17" }) == Err(BadTopic)
expect Options.check({ ..Options.defaults, topic: "order/17" }) == Err(BadTopic)
expect Options.check({ ..Options.defaults, topic: "é" }) == Err(BadTopic)

expect Options.remaining({ ..Options.defaults, ttl: 60 }, 1_000_000, 1_000_000) == Ok({ ..Options.defaults, ttl: 60 })
expect Options.remaining({ ..Options.defaults, ttl: 60 }, 1_000_000, 1_010_999) == Ok({ ..Options.defaults, ttl: 50 })
expect Options.remaining({ ..Options.defaults, ttl: 60 }, 1_000_000, 1_060_999) == Ok({ ..Options.defaults, ttl: 0 })
expect Options.remaining({ ..Options.defaults, ttl: 60 }, 1_000_000, 1_061_000) == Err(Expired)
expect Options.remaining({ ..Options.defaults, ttl: 0 }, 1_000_000, 1_000_999) == Ok({ ..Options.defaults, ttl: 0 })
expect Options.remaining({ ..Options.defaults, ttl: 0 }, 1_000_000, 1_001_000) == Err(Expired)
expect Options.remaining({ ..Options.defaults, ttl: 60 }, 2_000_000, 1_000_000) == Ok({ ..Options.defaults, ttl: 60 })
