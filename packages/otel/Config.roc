import Metric

## Where the sums go, and how often, from the environment variables every OpenTelemetry SDK reads:
##
## - `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` (the URL itself), or `OTEL_EXPORTER_OTLP_ENDPOINT` (a base,
##   `/v1/metrics` added). Neither: metrics are off, and cost nothing.
## - `OTEL_EXPORTER_OTLP_METRICS_HEADERS` or `OTEL_EXPORTER_OTLP_HEADERS`: `name=value,name=value`,
##   each value percent-decoded (`Authorization=Basic%20…`).
## - `OTEL_SERVICE_NAME`, and `OTEL_RESOURCE_ATTRIBUTES` (`key=value,key=value`).
## - `OTEL_METRIC_EXPORT_INTERVAL` (milliseconds, 60000) and `OTEL_METRIC_EXPORT_TIMEOUT` (30000).
## - `OTEL_SDK_DISABLED=true`, or `OTEL_METRICS_EXPORTER=none`: off.
Config := [].{

	Settings : {
		endpoint : Str,
		headers : List({ name : Str, value : Str }),
		resource : List(Metric.Attribute),
		interval_ms : U64,
		timeout_ms : U64,
	}

	## The variables `from` reads: the server reads each (`Env.var!`) and passes those it has.
	variables : List(Str)
	variables = [
		"OTEL_SDK_DISABLED",
		"OTEL_METRICS_EXPORTER",
		"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
		"OTEL_EXPORTER_OTLP_ENDPOINT",
		"OTEL_EXPORTER_OTLP_METRICS_HEADERS",
		"OTEL_EXPORTER_OTLP_HEADERS",
		"OTEL_SERVICE_NAME",
		"OTEL_RESOURCE_ATTRIBUTES",
		"OTEL_METRIC_EXPORT_INTERVAL",
		"OTEL_METRIC_EXPORT_TIMEOUT",
	]

	## The settings the variables in `found` (a name, its value) give, with `service` as the
	## service's name when they don't name one; `Err(Off)` when metrics are off.
	from : List((Str, Str)), Str -> Try(Settings, [Off])
	from = |found, service| {
		off = lookup(found, "OTEL_SDK_DISABLED").with_ascii_lowercased() == "true" or lookup(found, "OTEL_METRICS_EXPORTER").with_ascii_lowercased() == "none"
		own = lookup(found, "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
		base = lookup(found, "OTEL_EXPORTER_OTLP_ENDPOINT")
		endpoint =
			if !own.is_empty() {
				own
			} else if base.is_empty() {
				""
			} else {
				"${base.drop_suffix("/")}/v1/metrics"
			}
		if off or endpoint.is_empty() {
			Err(Off)
		} else {
			own_headers = lookup(found, "OTEL_EXPORTER_OTLP_METRICS_HEADERS")
			headers = pairs(if (own_headers.is_empty()) lookup(found, "OTEL_EXPORTER_OTLP_HEADERS") else own_headers).map(|(name, value)| { name: name, value: value })
			given = pairs(lookup(found, "OTEL_RESOURCE_ATTRIBUTES"))
			named = lookup(found, "OTEL_SERVICE_NAME")
			service_name =
				if !named.is_empty() {
					named
				} else {
					match given.find_first(|(key, _)| key == "service.name") {
						Ok((_, value)) => value
						Err(_) => service
					}
				}
			others = given.keep_if(|(key, _)| key != "service.name").map(|(key, value)| { key: key, value: value })
			Ok({
				endpoint: endpoint,
				headers: headers,
				resource: [{ key: "service.name", value: service_name }].concat(others),
				interval_ms: U64.max(number(lookup(found, "OTEL_METRIC_EXPORT_INTERVAL"), 60_000), 1_000),
				timeout_ms: number(lookup(found, "OTEL_METRIC_EXPORT_TIMEOUT"), 30_000),
			})
		}
	}
}

## The value of the variable `name` in `found`, trimmed, or "".
lookup : List((Str, Str)), Str -> Str
lookup = |found, name|
	match found.find_first(|(key, _)| key == name) {
		Ok((_, value)) => value.trim()
		Err(_) => ""
	}

## `name=value,name=value`, each part trimmed and each value percent-decoded; a part with no `=` or
## no name is skipped.
pairs : Str -> List((Str, Str))
pairs = |text|
	text.split_on(",").fold(
		[],
		|kept, part|
			match part.split_first("=") {
				Ok({ before, after }) =>
					if before.trim().is_empty() {
						kept
					} else {
						kept.append((before.trim(), decoded(after.trim())))
					}
				Err(_) => kept
			},
	)

## A whole number of milliseconds, or `default` when it isn't one.
number : Str, U64 -> U64
number = |text, default|
	match U64.from_str(text) {
		Ok(n) => n
		Err(_) => default
	}

## `text` with each `%XX` as the byte it stands for; one that isn't (`%G1`, a `%` at the end) is
## left as it is.
decoded : Str -> Str
decoded = |text| {
	bytes = text.to_utf8()
	go = |index, out|
		match bytes.get(index) {
			Err(_) => out
			Ok('%') =>
				match (bytes.get(index + 1).map_ok(hex), bytes.get(index + 2).map_ok(hex)) {
					(Ok(Ok(high)), Ok(Ok(low))) => go(index + 3, out.append(high * 16 + low))
					_ => go(index + 1, out.append('%'))
				}
			Ok(byte) => go(index + 1, out.append(byte))
		}
	Str.from_utf8_lossy(go(0, []))
}

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

expect Config.from([], "shop") == Err(Off)
expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318/")], "shop").map_ok(|s| s.endpoint) == Ok("http://collector:4318/v1/metrics")
expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318"), ("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "https://m.example/otlp/v1/metrics")], "shop").map_ok(|s| s.endpoint) == Ok("https://m.example/otlp/v1/metrics")
expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318"), ("OTEL_SDK_DISABLED", "TRUE")], "shop") == Err(Off)
expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318"), ("OTEL_METRICS_EXPORTER", "none")], "shop") == Err(Off)

expect {
	settings = Config.from(
		[
			("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c:4318"),
			("OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Basic%20abc%3D%3D, x-tenant = 7 ,broken"),
			("OTEL_RESOURCE_ATTRIBUTES", "service.name=from-resource,deployment.environment=prod"),
			("OTEL_METRIC_EXPORT_INTERVAL", "10"),
		],
		"shop",
	)
	settings
		== Ok({
			endpoint: "http://c:4318/v1/metrics",
			headers: [{ name: "Authorization", value: "Basic abc==" }, { name: "x-tenant", value: "7" }],
			resource: [{ key: "service.name", value: "from-resource" }, { key: "deployment.environment", value: "prod" }],
			interval_ms: 1_000,
			timeout_ms: 30_000,
		})
}

expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c"), ("OTEL_SERVICE_NAME", "named"), ("OTEL_RESOURCE_ATTRIBUTES", "service.name=other")], "shop").map_ok(|s| s.resource) == Ok([{ key: "service.name", value: "named" }])
expect Config.from([("OTEL_EXPORTER_OTLP_ENDPOINT", "http://c")], "shop").map_ok(|s| (s.resource, s.interval_ms)) == Ok(([{ key: "service.name", value: "shop" }], 60_000))
expect decoded("100%25%zz%4") == "100%%zz%4"
