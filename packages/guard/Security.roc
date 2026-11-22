## The headers that tell a browser to be careful with the site's pages: what may load and run in
## them (`Content-Security-Policy`), that the site is HTTPS only (`Strict-Transport-Security`),
## not to guess a file's type, what to say about where a visitor came from, and who may frame it.
##
##     Security.headers(Security.defaults, { dev: Bool.False })
##     { ..Security.defaults, content_security_policy: Security.csp(Security.directive(Security.directives, "img-src", ["'self'", "https://images.example.com"])) }
##
## The defaults fit a Roc Solid app: its scripts and its WebAssembly from its own origin (a CSP
## must allow `'wasm-unsafe-eval'` for a page to start wasm), the answers a page is rendered with
## in a JSON script (which a CSP doesn't block: it doesn't run), its calls to its own server.
Security := [].{

	## Each header's value; `""` leaves it out.
	Config : {
		content_security_policy : Str,
		strict_transport_security : Str,
		content_type_options : Str,
		referrer_policy : Str,
		frame_options : Str,
		cross_origin_opener_policy : Str,
	}

	## The Content-Security-Policy's directives, as `defaults` has them: everything from the
	## site's own origin; images also as `data:` URLs; styles also inline (`style="…"`, as
	## components write them); scripts also WebAssembly (`'wasm-unsafe-eval'`); no plugins
	## (`object-src 'none'`); `<base>`, forms and frames only to and from the site.
	directives : List((Str, List(Str)))
	directives = [
		("default-src", ["'self'"]),
		("script-src", ["'self'", "'wasm-unsafe-eval'"]),
		("style-src", ["'self'", "'unsafe-inline'"]),
		("img-src", ["'self'", "data:"]),
		("connect-src", ["'self'"]),
		("font-src", ["'self'"]),
		("object-src", ["'none'"]),
		("base-uri", ["'self'"]),
		("form-action", ["'self'"]),
		("frame-ancestors", ["'self'"]),
	]

	## The directives with `name` set to `sources` (in place of what it was, or added).
	directive : List((Str, List(Str))), Str, List(Str) -> List((Str, List(Str)))
	directive = |given, name, sources| {
		replaced = given.map(|(each, was)| if (each == name) (each, sources) else (each, was))
		if (given.any(|(each, _)| each == name)) replaced else given.append((name, sources))
	}

	## Directives as a Content-Security-Policy's value: `default-src 'self'; img-src 'self' data:`.
	csp : List((Str, List(Str))) -> Str
	csp = |given| Str.join_with(given.map(|(name, sources)| if (sources.is_empty()) name else "${name} ${Str.join_with(sources, " ")}"), "; ")

	## Sane defaults: the CSP of `directives`; HTTPS only, for a year (add `; includeSubDomains`
	## once every subdomain is HTTPS too); `nosniff`; the origin alone sent to other sites
	## (`strict-origin-when-cross-origin`); framed only by the site itself; a window it opens to
	## another site can't reach back (`Cross-Origin-Opener-Policy: same-origin`).
	defaults : Config
	defaults = {
		content_security_policy: Security.csp(Security.directives),
		strict_transport_security: "max-age=31536000",
		content_type_options: "nosniff",
		referrer_policy: "strict-origin-when-cross-origin",
		frame_options: "SAMEORIGIN",
		cross_origin_opener_policy: "same-origin",
	}

	## The headers `config` says. Under `dev` (a server started with `--dev`), no
	## `Strict-Transport-Security` (a browser would hold localhost to HTTPS), and the CSP only
	## reports (`Content-Security-Policy-Report-Only`): while you work, a violation shows in the
	## console instead of breaking the page. (The dev server's reload script is a file of the
	## site's own, `/__reload.js`, so it is no violation.)
	headers : Config, { dev : Bool } -> List({ name : Str, value : Str })
	headers = |config, { dev }|
		[
			{ name: if (dev) "content-security-policy-report-only" else "content-security-policy", value: config.content_security_policy },
			{ name: "strict-transport-security", value: if (dev) "" else config.strict_transport_security },
			{ name: "x-content-type-options", value: config.content_type_options },
			{ name: "referrer-policy", value: config.referrer_policy },
			{ name: "x-frame-options", value: config.frame_options },
			{ name: "cross-origin-opener-policy", value: config.cross_origin_opener_policy },
		].keep_if(|each| !each.value.is_empty())

	## `adding`, after `answered`, but not one `answered` has already (any case): an answer that
	## sets its own (a page with a stricter CSP) keeps it.
	added : List({ name : Str, value : Str }), List({ name : Str, value : Str }) -> List({ name : Str, value : Str })
	added = |answered, adding| {
		present = |name| answered.any(|each| each.name.with_ascii_lowercased() == name.with_ascii_lowercased())
		answered.concat(adding.keep_if(|each| !present(each.name)))
	}
}

named : List({ name : Str, value : Str }), Str -> Str
named = |headers, name|
	match headers.find_first(|each| each.name == name) {
		Ok(found) => found.value
		Err(_) => ""
	}

expect Security.csp([("default-src", ["'self'"]), ("upgrade-insecure-requests", [])]) == "default-src 'self'; upgrade-insecure-requests"
expect named(Security.headers(Security.defaults, { dev: Bool.False }), "content-security-policy") == "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
expect Security.headers(Security.defaults, { dev: Bool.False }).len() == 6
expect named(Security.headers(Security.defaults, { dev: Bool.False }), "strict-transport-security") == "max-age=31536000"
# Under dev: no HSTS; the CSP only reports.
expect named(Security.headers(Security.defaults, { dev: Bool.True }), "strict-transport-security") == ""
expect named(Security.headers(Security.defaults, { dev: Bool.True }), "content-security-policy") == ""
expect named(Security.headers(Security.defaults, { dev: Bool.True }), "content-security-policy-report-only") == Security.defaults.content_security_policy
# "" leaves a header out.
expect Security.headers({ ..Security.defaults, frame_options: "", content_security_policy: "" }, { dev: Bool.False }).len() == 4
# A directive changed, or added.
expect Security.csp(Security.directive([("img-src", ["'self'"])], "img-src", ["'self'", "https://images.example.com"])) == "img-src 'self' https://images.example.com"
expect Security.csp(Security.directive([("img-src", ["'self'"])], "media-src", ["'self'"])) == "img-src 'self'; media-src 'self'"
# An answer's own header stays; the rest are added.
expect Security.added([{ name: "Content-Security-Policy", value: "default-src 'none'" }], [{ name: "content-security-policy", value: "x" }, { name: "x-content-type-options", value: "nosniff" }]) == [{ name: "Content-Security-Policy", value: "default-src 'none'" }, { name: "x-content-type-options", value: "nosniff" }]
