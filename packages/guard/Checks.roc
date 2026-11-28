import Ip

## Small checks on a request, each deciding whether it may go on or what to refuse it with: its
## method, its `Host`, its body's size, the address it came from, a site down for maintenance.
## The server's middleware (`Guard`) runs them; here they are plain functions of what they look
## at.
##
##     Checks.methods(["GET", "POST"], request.method)            # Err: 405, with `Allow`
##     Checks.hosts(["example.com", "*.example.com"], request.headers)
Checks := [].{

	## What a request is refused with: its status, headers and body (text).
	Refusal : { status : U16, headers : List({ name : Str, value : Str }), body : Str }

	## Allowed when its method is one of `allowed` (any case); else 405, with `Allow`.
	methods : List(Str), Str -> Try({}, Refusal)
	methods = |allowed, method| {
		upper = allowed.map(|each| each.with_ascii_uppercased())
		if upper.contains(method.with_ascii_uppercased()) {
			Ok({})
		} else {
			Err(refusal(405, [{ name: "allow", value: Str.join_with(upper, ", ") }], "${method} isn't allowed here: ${Str.join_with(upper, ", ")}"))
		}
	}

	## Allowed when its `Host` is one of `allowed`: a name (`example.com`), any subdomain of one
	## (`*.example.com`, not `example.com` itself), with a port only when the pattern has one
	## (`localhost:3000`). Else, or with no `Host`, 400. A server that answers any `Host` can be
	## made to write links and redirects to another site's name (DNS rebinding, poisoned caches).
	hosts : List(Str), List({ name : Str, value : Str }) -> Try({}, Refusal)
	hosts = |allowed, headers|
		match headers.find_first(|each| each.name == "host") {
			Ok(found) =>
				if allowed.any(|pattern| Checks.host_matches(pattern, found.value)) {
					Ok({})
				} else {
					Err(refusal(400, [], "This server doesn't answer for ${found.value}."))
				}
			Err(_) => Err(refusal(400, [], "The request has no Host."))
		}

	## Whether the host `host` (as `Host` sends it: maybe with a port) is what `pattern` names.
	host_matches : Str, Str -> Bool
	host_matches = |pattern, host| {
		wanted = pattern.trim().with_ascii_lowercased()
		given = host.trim().with_ascii_lowercased()
		compared = if (has_port(wanted)) given else without_port(given)
		if wanted.starts_with("*.") {
			suffix = wanted.drop_prefix("*")
			compared.ends_with(suffix) and compared.count_utf8_bytes() > suffix.count_utf8_bytes()
		} else {
			compared == wanted
		}
	}

	## Allowed when its body is at most `max` bytes: as `Content-Length` says, and as it came.
	## Else 413.
	body_size : U64, List({ name : Str, value : Str }), U64 -> Try({}, Refusal)
	body_size = |max, headers, length| {
		said =
			match headers.find_first(|each| each.name == "content-length") {
				Ok(found) => U64.from_str(found.value.trim()) ?? 0
				Err(_) => 0
			}
		if said > max or length > max {
			Err(refusal(413, [], "The request's body is larger than ${max.to_str()} bytes."))
		} else {
			Ok({})
		}
	}

	## Allowed unless its address is in `deny`; and, when `allow` lists any, only if it is in
	## `allow`. An address not known is let through a deny list alone, and refused by an allow
	## list. Refused, 403.
	ips : { allow : List(Ip.Cidr), deny : List(Ip.Cidr) }, Try(Ip, [Unknown]) -> Try({}, Refusal)
	ips = |{ allow, deny }, client| {
		refused = Err(refusal(403, [], "Requests from this address aren't allowed."))
		match client {
			Ok(ip) =>
				if Ip.within_any(ip, deny) {
					refused
				} else if allow.is_empty() or Ip.within_any(ip, allow) {
					Ok({})
				} else {
					refused
				}
			Err(Unknown) => if (allow.is_empty()) Ok({}) else refused
		}
	}

	## The answer while the site is down for maintenance: 503, `Retry-After` (seconds), and
	## `message`, as a small page for a browser (`html`) or as text.
	maintenance : Str, U64, Bool -> Refusal
	maintenance = |message, retry_after_s, html| {
		retry = { name: "retry-after", value: retry_after_s.to_str() }
		if html {
			page = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Down for maintenance</title><body style=\"font-family: system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem\"><h1>Down for maintenance</h1><p>${escaped(message)}</p></body></html>"
			{ status: 503, headers: [retry, { name: "content-type", value: "text/html; charset=utf-8" }, { name: "cache-control", value: "no-store" }], body: page }
		} else {
			refusal(503, [retry, { name: "cache-control", value: "no-store" }], message)
		}
	}
}

refusal : U16, List({ name : Str, value : Str }), Str -> Checks.Refusal
refusal = |status, headers, body| { status, headers: headers.append({ name: "content-type", value: "text/plain; charset=utf-8" }), body }

## Whether a host (as `Host` sends it) has a port: `example.com:8080`, `[::1]:3000`.
has_port : Str -> Bool
has_port = |host|
	if host.starts_with("[") {
		host.contains("]:")
	} else {
		host.contains(":")
	}

without_port : Str -> Str
without_port = |host|
	if host.starts_with("[") {
		match host.split_first("]") {
			Ok({ before, .. }) => "${before}]"
			Err(_) => host
		}
	} else {
		match host.split_first(":") {
			Ok({ before, .. }) => before
			Err(_) => host
		}
	}

## Text for HTML: `<`, `>`, `&` and quotes as entities.
escaped : Str -> Str
escaped = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;")

status : Try({}, Checks.Refusal) -> U16
status = |checked|
	match checked {
		Ok({}) => 200
		Err(refused) => refused.status
	}

host : Str -> List({ name : Str, value : Str })
host = |value| [{ name: "host", value }]

# Methods: any case; refused, 405 with what is allowed.
expect status(Checks.methods(["GET", "post"], "POST")) == 200
expect status(Checks.methods(["GET", "POST"], "DELETE")) == 405
expect Checks.methods(["get", "POST"], "PUT") == Err({ status: 405, headers: [{ name: "allow", value: "GET, POST" }, { name: "content-type", value: "text/plain; charset=utf-8" }], body: "PUT isn't allowed here: GET, POST" })

# Hosts: a name, with or without a port; subdomains by `*.`, not the name itself; nothing else.
expect status(Checks.hosts(["example.com"], host("example.com"))) == 200
expect status(Checks.hosts(["example.com"], host("Example.COM:443"))) == 200
expect status(Checks.hosts(["example.com"], host("evil.com"))) == 400
expect status(Checks.hosts(["example.com"], host("example.com.evil.com"))) == 400
expect status(Checks.hosts(["*.example.com"], host("app.example.com"))) == 200
expect status(Checks.hosts(["*.example.com"], host("example.com"))) == 400
expect status(Checks.hosts(["*.example.com"], host("badexample.com"))) == 400
expect status(Checks.hosts(["localhost:3000"], host("localhost:3000"))) == 200
expect status(Checks.hosts(["localhost:3000"], host("localhost:4000"))) == 400
expect status(Checks.hosts(["[::1]"], host("[::1]:3000"))) == 200
expect status(Checks.hosts(["example.com"], [])) == 400

# Body size: by what `Content-Length` says, and by what came.
expect status(Checks.body_size(10, [{ name: "content-length", value: "10" }], 10)) == 200
expect status(Checks.body_size(10, [{ name: "content-length", value: "11" }], 0)) == 413
expect status(Checks.body_size(10, [], 11)) == 413

# Addresses: deny wins; an allow list lets in only its own; an unknown address passes a deny list
# alone, not an allow list.
office = Ip.cidrs(["192.0.2.0/24"])

at : Str -> Try(Ip, [Unknown])
at = |text|
	match Ip.parse(text) {
		Ok(ip) => Ok(ip)
		Err(_) => Err(Unknown)
	}
expect status(Checks.ips({ allow: office, deny: Ip.cidrs(["192.0.2.66"]) }, at("192.0.2.7"))) == 200
expect status(Checks.ips({ allow: office, deny: Ip.cidrs(["192.0.2.66"]) }, at("192.0.2.66"))) == 403
expect status(Checks.ips({ allow: office, deny: [] }, at("198.51.100.1"))) == 403
expect status(Checks.ips({ allow: [], deny: office }, at("198.51.100.1"))) == 200
expect status(Checks.ips({ allow: [], deny: office }, Err(Unknown))) == 200
expect status(Checks.ips({ allow: office, deny: [] }, Err(Unknown))) == 403

# Maintenance: 503 with Retry-After; a page for a browser, its message escaped.
expect Checks.maintenance("Back at 3 pm.", 600, Bool.False) == { status: 503, headers: [{ name: "retry-after", value: "600" }, { name: "cache-control", value: "no-store" }, { name: "content-type", value: "text/plain; charset=utf-8" }], body: "Back at 3 pm." }
expect Checks.maintenance("<soon> & \"later\"", 60, Bool.True).body.contains("<p>&lt;soon&gt; &amp; &quot;later&quot;</p>")
