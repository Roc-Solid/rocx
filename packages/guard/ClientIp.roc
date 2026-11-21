import Ip

## Who sent a request: the client's address, as far as the app trusts what it is told. A client
## can write any `X-Forwarded-For` it likes, so the header is read only as far as the app says a
## proxy of its own wrote it.
##
##     ClientIp.of(Hops(1), peer, request.headers)    # behind one proxy (a load balancer, Caddy)
##     ClientIp.of(Header("fly-client-ip"), peer, request.headers)
##
## `peer` is the address the connection came from, as text; "" when it isn't known (see the
## package's PROPOSALS.md: the server platform doesn't pass it on yet).
ClientIp := [].{

	## Where the client's address comes from:
	##
	## - `Direct`: no proxy in front. The connection's address; headers are ignored.
	## - `Header(name)`: a proxy sets `name` to the client's address (`fly-client-ip`,
	##   `cf-connecting-ip`, `x-real-ip`), replacing what the client sent. The connection's
	##   address when it is missing.
	## - `Hops(count)`: `count` proxies in front, each adding the address it was sent from to
	##   `X-Forwarded-For`. The address `count` places from the right of that list, the
	##   connection's own at its end: what the outermost proxy saw.
	## - `Proxies(cidrs)`: proxies at those addresses (`Ip.cidrs(["10.0.0.0/8"])`, or
	##   `Ip.private`). From the right of `X-Forwarded-For` (the connection's address at its end),
	##   the first address that isn't one of them.
	Trust : [Direct, Header(Str), Hops(U64), Proxies(List(Ip.Cidr))]

	## The client's address, as `trust` says to find it, from the connection's address (`peer`,
	## "" if not known) and the request's headers. `Err(Unknown)` when it can't be told: no peer
	## and nothing trusted to say, or what is trusted isn't an address.
	of : Trust, Str, List({ name : Str, value : Str }) -> Try(Ip, [Unknown])
	of = |trust, peer, headers| {
		connected = address(peer)
		match trust {
			Direct => connected
			Header(name) => {
				lower = name.with_ascii_lowercased()
				match headers.find_first(|each| each.name == lower) {
					Ok(found) =>
						match found.value.split_first(",") {
							Ok({ before, .. }) => address(before)
							Err(_) => address(found.value)
						}
					Err(_) => connected
				}
			}
			Hops(count) => {
				chain = listed(headers).append(peer)
				# The connection's own address is at the end, `count` hops from the client's. A
				# shorter chain came through fewer proxies than that: its first address is the one
				# nearest the client that a proxy wrote (or the connection's own, with none).
				at = if (chain.len() > count) chain.len() - 1 - count else 0
				address(chain.get(at) ?? "")
			}
			Proxies(trusted) => {
				# From the right: the connection's address (if known), then what each proxy added.
				# The first that isn't a proxy of the app's is the client; all of them, the leftmost.
				chain = listed(headers)
				known = if (peer.trim().is_empty()) [] else [peer]
				hops = chain.concat(known)
				var $found = Err(Unknown)
				var $done = Bool.False
				var $at = hops.len()
				while !$done and $at > 0 {
					$at = $at - 1
					match address(hops.get($at) ?? "") {
						Ok(ip) => {
							$found = Ok(ip)
							$done = !Ip.within_any(ip, trusted)
						}
						Err(Unknown) => {
							$found = Err(Unknown)
							$done = Bool.True
						}
					}
				}
				$found
			}
		}
	}

	## The addresses in a request's `X-Forwarded-For` headers, left to right (the client's first,
	## as it claims it; each proxy's after), however many headers they came in.
	forwarded_for : List({ name : Str, value : Str }) -> List(Str)
	forwarded_for = |headers| listed(headers)
}

listed : List({ name : Str, value : Str }) -> List(Str)
listed = |headers|
	headers
		.keep_if(|each| each.name == "x-forwarded-for")
		.join_map(|each| each.value.split_on(","))
		.map(|each| each.trim())
		.keep_if(|each| !each.is_empty())

## An address as a header or the connection gives it: maybe with a port (`192.0.2.7:51234`), an
## IPv6 one in brackets (`[2001:db8::1]:443`), quoted (`"[2001:db8::1]"`, as `Forwarded` quotes).
address : Str -> Try(Ip, [Unknown])
address = |given| {
	text = given.trim().drop_prefix("\"").drop_suffix("\"")
	bare =
		if text.starts_with("[") {
			match text.drop_prefix("[").split_first("]") {
				Ok({ before, .. }) => before
				Err(_) => text
			}
		} else {
			match text.split_first(":") {
				# One colon: an IPv4 address and its port. More: IPv6, unbracketed.
				Ok({ before, after }) => if (after.contains(":")) text else before
				Err(_) => text
			}
		}
	match Ip.parse(bare) {
		Ok(ip) => Ok(ip)
		Err(BadIp) => Err(Unknown)
	}
}

xff : Str -> List({ name : Str, value : Str })
xff = |value| [{ name: "x-forwarded-for", value }]

seen : Try(Ip, [Unknown]) -> Str
seen = |found|
	match found {
		Ok(ip) => Ip.to_str(ip)
		Err(Unknown) => "unknown"
	}

# Direct: the connection's address, with or without its port; headers ignored.
expect seen(ClientIp.of(Direct, "203.0.113.7:51234", xff("1.1.1.1"))) == "203.0.113.7"
expect seen(ClientIp.of(Direct, "[2001:db8::1]:443", [])) == "2001:db8::1"
expect seen(ClientIp.of(Direct, "2001:db8::1", [])) == "2001:db8::1"
expect seen(ClientIp.of(Direct, "", xff("1.1.1.1"))) == "unknown"

# Header: the proxy's header, first address if it lists several; the peer without it.
expect seen(ClientIp.of(Header("Fly-Client-IP"), "10.0.0.2", [{ name: "fly-client-ip", value: "198.51.100.4" }])) == "198.51.100.4"
expect seen(ClientIp.of(Header("x-real-ip"), "10.0.0.2", [])) == "10.0.0.2"
expect seen(ClientIp.of(Header("x-real-ip"), "10.0.0.2", [{ name: "x-real-ip", value: "garbage" }])) == "unknown"

# Hops: one proxy (the peer) appends what it saw; a client's own entries to the left are ignored.
expect seen(ClientIp.of(Hops(1), "10.0.0.2", xff("198.51.100.4"))) == "198.51.100.4"
expect seen(ClientIp.of(Hops(1), "10.0.0.2", xff("6.6.6.6, 198.51.100.4"))) == "198.51.100.4"
expect seen(ClientIp.of(Hops(2), "10.0.0.2", xff("6.6.6.6, 198.51.100.4, 10.0.0.9"))) == "198.51.100.4"
# Split over two headers, as some proxies send them.
expect seen(ClientIp.of(Hops(1), "10.0.0.2", [{ name: "x-forwarded-for", value: "6.6.6.6" }, { name: "x-forwarded-for", value: "198.51.100.4" }])) == "198.51.100.4"
# No header: the request didn't come through the proxy; the connection's address.
expect seen(ClientIp.of(Hops(1), "203.0.113.7", [])) == "203.0.113.7"
# The peer not known (today's server platform): the proxy's entry is still the right one.
expect seen(ClientIp.of(Hops(1), "", xff("6.6.6.6, 198.51.100.4"))) == "198.51.100.4"
expect seen(ClientIp.of(Hops(1), "", [])) == "unknown"

# Proxies: from the right, skip the trusted; the first other is the client.
expect seen(ClientIp.of(Proxies(Ip.private), "10.0.0.2", xff("6.6.6.6, 198.51.100.4, 10.0.0.9"))) == "198.51.100.4"
# A peer that isn't a trusted proxy: it is the client, whatever it claims.
expect seen(ClientIp.of(Proxies(Ip.private), "203.0.113.7", xff("1.1.1.1"))) == "203.0.113.7"
# Every hop trusted: the leftmost.
expect seen(ClientIp.of(Proxies(Ip.private), "10.0.0.2", xff("192.168.1.5"))) == "192.168.1.5"
# Garbage where the client should be: unknown, not whatever is further left.
expect seen(ClientIp.of(Proxies(Ip.private), "10.0.0.2", xff("1.1.1.1, nonsense"))) == "unknown"
# The peer not known: the header alone, from the right.
expect seen(ClientIp.of(Proxies(Ip.cidrs(["10.0.0.0/8"])), "", xff("198.51.100.4, 10.1.1.1"))) == "198.51.100.4"
expect seen(ClientIp.of(Proxies(Ip.private), "10.0.0.2", xff("[2001:db8::7]:5000, 10.0.0.3"))) == "2001:db8::7"

expect ClientIp.forwarded_for(xff(" 1.1.1.1 ,, 2.2.2.2 ")) == ["1.1.1.1", "2.2.2.2"]
