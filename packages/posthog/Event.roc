## Errors as PostHog takes them: each an `$exception` event, sent many at once to its batch
## endpoint (`POST <host>/batch/`, with the project's key). An error nobody known had is sent with
## its own id as its distinct id and `$process_person_profile` false, so it makes no person.
Event := [].{

	## What the package keeps of one error until it is sent.
	##
	## - `kind`: the exception's type (`ServerError`, `Error`, `JobFailed`, a browser's `TypeError`).
	## - `handled`: whether the app dealt with it (`capture!`) or it ended something (a 5xx answer, a
	##   job failed for good, an error nothing caught in a browser).
	## - `source`: `server`, `browser` or `job`.
	## - `place`: the route's pattern, the page's path or the job's kind; "" for none.
	## - `method` ("" for none) and `status` (the answer's; 0 for none).
	## - `user`: who, as the app names them; "" for nobody known.
	## - `fields`: the app's fields, a JSON object.
	## - `stack`: a browser's stack, as it gave it; "" for none.
	## - `id`: the event's own id (a UUID).
	Problem : {
		kind : Str,
		message : Str,
		handled : Bool,
		source : Str,
		place : Str,
		method : Str,
		status : U16,
		user : Str,
		fields : Str,
		stack : Str,
		fingerprint : Str,
		at_ms : U64,
		id : Str,
	}

	## The batch endpoint's body: the project's `key`, and each problem an event. `release` (the
	## app's version, a commit) goes on each, when there is one.
	batch : Str, Str, List(Problem) -> Str
	batch = |key, release, problems| {
		events = problems.map(|problem| Event.exception(release, problem))
		"{\"api_key\":${quoted(key)},\"historical_migration\":false,\"batch\":[${Str.join_with(events, ",")}]}"
	}

	## One problem as an `$exception` event.
	exception : Str, Problem -> Str
	exception = |release, problem| {
		nobody = problem.user.is_empty()
		who = if (nobody) problem.id else problem.user
		mechanism = "{\"handled\":${bool(problem.handled)},\"synthetic\":false}"
		frame =
			if problem.place.is_empty() {
				""
			} else {
				function = if (problem.method.is_empty()) problem.place else "${problem.method} ${problem.place}"
				lang = if (problem.source == "browser") "javascript" else "roc"
				",\"stacktrace\":{\"type\":\"raw\",\"frames\":[{\"platform\":\"custom\",\"lang\":${quoted(lang)},\"function\":${quoted(function)},\"filename\":${quoted(problem.place)},\"in_app\":true}]}"
			}
		exception_list = "[{\"type\":${quoted(problem.kind)},\"value\":${quoted(problem.message)},\"mechanism\":${mechanism}${frame}}]"
		properties =
			[
				Ok("\"distinct_id\":${quoted(who)}"),
				if (nobody) Ok("\"$process_person_profile\":false") else Err(None),
				Ok("\"$exception_list\":${exception_list}"),
				Ok("\"$exception_fingerprint\":${quoted(problem.fingerprint)}"),
				Ok("\"$lib\":\"rocx-posthog\""),
				Ok("\"source\":${quoted(problem.source)}"),
				property("place", problem.place),
				property("method", problem.method),
				if (problem.status == 0) Err(None) else Ok("\"status\":${problem.status.to_str()}"),
				property("release", release),
				if (problem.fields == "{}" or problem.fields.is_empty()) Err(None) else Ok("\"fields\":${problem.fields}"),
				property("stack", problem.stack),
			].keep_oks(|each| each)
		"{\"event\":\"$exception\",\"uuid\":${quoted(problem.id)},\"timestamp\":${quoted(Event.timestamp(problem.at_ms))},\"properties\":{${Str.join_with(properties, ",")}}}"
	}

	## Milliseconds since the Unix epoch as ISO 8601, in UTC: `2026-11-22T13:03:12.345Z`.
	timestamp : U64 -> Str
	timestamp = |ms| {
		days = (ms // 86_400_000).to_i64_wrap()
		in_day = ms % 86_400_000
		date = civil(days)
		"${padded(date.year.to_str(), 4)}-${padded(date.month.to_str(), 2)}-${padded(date.day.to_str(), 2)}T${padded((in_day // 3_600_000).to_str(), 2)}:${padded((in_day // 60_000 % 60).to_str(), 2)}:${padded((in_day // 1_000 % 60).to_str(), 2)}.${padded((in_day % 1_000).to_str(), 3)}Z"
	}

	## A version 4 UUID from 16 random bytes (`Random.bytes!(16)`): `3f2a9c1e-8b7d-4e2a-9c1e-0b7d4e2a9c1e`.
	uuid : List(U8) -> Str
	uuid = |bytes| {
		var $out = []
		var $at = 0
		for each in bytes.take_first(16) {
			byte =
				if $at == 6 {
					each.bitwise_and(0x0f).bitwise_or(0x40)
				} else if $at == 8 {
					each.bitwise_and(0x3f).bitwise_or(0x80)
				} else {
					each
				}
			$out = if ($at == 4 or $at == 6 or $at == 8 or $at == 10) $out.append('-') else $out
			$out = $out.append(hex_digit(byte // 16)).append(hex_digit(byte % 16))
			$at = $at + 1
		}
		Str.from_utf8_lossy($out)
	}
}

## A JSON string.
quoted : Str -> Str
quoted = |text| Json.to_str(text)

bool : Bool -> Str
bool = |value| if (value) "true" else "false"

## A property holding `value`, or none when it is "".
property : Str, Str -> Try(Str, [None])
property = |name, value| if (value.is_empty()) Err(None) else Ok("${quoted(name)}:${quoted(value)}")

padded : Str, U64 -> Str
padded = |digits, width| {
	short = width - U64.min(width, digits.count_utf8_bytes())
	"${Str.repeat("0", short)}${digits}"
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

## The year, month and day of a day counted from 1970-01-01 (Howard Hinnant's algorithm).
civil : I64 -> { year : I64, month : I64, day : I64 }
civil = |days| {
	z = days + 719468
	era = (if (z >= 0) z else z - 146096) // 146097
	doe = z - era * 146097
	yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	mp = (5 * doy + 2) // 153
	day = doy - (153 * mp + 2) // 5 + 1
	month = if (mp < 10) mp + 3 else mp - 9
	year = yoe + era * 400
	{ year: if (month <= 2) year + 1 else year, month: month, day: day }
}

sample : Event.Problem
sample = {
	kind: "ServerError",
	message: "answered 500: row 42 is locked",
	handled: Bool.False,
	source: "server",
	place: "/posts/[id]",
	method: "GET",
	status: 500,
	user: "",
	fields: "{}",
	stack: "",
	fingerprint: "server | ServerError | /posts/[id] | answered <n>: row <n> is locked",
	at_ms: 1_795_352_592_345,
	id: "3f2a9c1e-8b7d-4e2a-9c1e-0b7d4e2a9c1e",
}

expect Event.timestamp(0) == "1970-01-01T00:00:00.000Z"
expect Event.timestamp(1_795_352_592_345) == "2026-11-22T13:03:12.345Z"
expect Event.timestamp(1_709_164_800_007) == "2024-02-29T00:00:00.007Z"

expect Event.uuid(List.repeat(0xff, 16)) == "ffffffff-ffff-4fff-bfff-ffffffffffff"
expect Event.uuid(List.repeat(0, 16)) == "00000000-0000-4000-8000-000000000000"

# Nobody known: the event's id is its distinct id, and it makes no person.
expect
	Event.exception("abc123", sample)
		== "{\"event\":\"$exception\",\"uuid\":\"3f2a9c1e-8b7d-4e2a-9c1e-0b7d4e2a9c1e\",\"timestamp\":\"2026-11-22T13:03:12.345Z\",\"properties\":{\"distinct_id\":\"3f2a9c1e-8b7d-4e2a-9c1e-0b7d4e2a9c1e\",\"$process_person_profile\":false,\"$exception_list\":[{\"type\":\"ServerError\",\"value\":\"answered 500: row 42 is locked\",\"mechanism\":{\"handled\":false,\"synthetic\":false},\"stacktrace\":{\"type\":\"raw\",\"frames\":[{\"platform\":\"custom\",\"lang\":\"roc\",\"function\":\"GET /posts/[id]\",\"filename\":\"/posts/[id]\",\"in_app\":true}]}}],\"$exception_fingerprint\":\"server | ServerError | /posts/[id] | answered <n>: row <n> is locked\",\"$lib\":\"rocx-posthog\",\"source\":\"server\",\"place\":\"/posts/[id]\",\"method\":\"GET\",\"status\":500,\"release\":\"abc123\"}}"

# Someone known, the app's fields, no place: no frame, no release.
expect {
	written = Event.exception("", { ..sample, user: "member-7", place: "", method: "", status: 0, handled: Bool.True, fields: "{\"order\":12}" })
	written.contains("\"distinct_id\":\"member-7\",\"$exception_list\"")
		and !written.contains("$process_person_profile")
		and !written.contains("stacktrace")
		and !written.contains("release")
		and written.contains("\"mechanism\":{\"handled\":true,")
		and written.ends_with("\"source\":\"server\",\"fields\":{\"order\":12}}}")
}

# Quotes and new lines in a message stay JSON.
expect Event.exception("", { ..sample, message: "a \"b\"\nc" }).contains("\"value\":\"a \\\"b\\\"\\nc\"")

expect Event.batch("phc_key", "", []) == "{\"api_key\":\"phc_key\",\"historical_migration\":false,\"batch\":[]}"
expect Event.batch("phc_key", "", [sample, sample]).starts_with("{\"api_key\":\"phc_key\",\"historical_migration\":false,\"batch\":[{\"event\":\"$exception\"")
