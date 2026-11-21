import Options
import WebPush

## Sending a message to a push service (RFC 8030, section 5): the request, and what its answer
## means for the message and for the subscription.
##
## | Answer | `outcome` | What a sender does |
## |---|---|---|
## | 2xx (201 Created) | `Delivered` | nothing more: the push service has it |
## | 404, 410 | `Gone` | deletes the subscription: the browser unsubscribed, or it expired |
## | 429, 503 with `Retry-After` | `RetryAfter(ms)` | sends it again then, if its TTL lasts |
## | 408, 429, 5xx | `Retry(why)` | sends it again later, waiting longer each time |
## | 400, 401, 403, 413, others | `Refused(why)` | gives up and says why: sending again won't help |
##
## A 403 doesn't delete the subscription: it is what a push service says when the VAPID keys are
## wrong, and every subscription would go for a mistake in the server's settings.
Delivery := [].{

	## A request, shaped as the server platform's `Http.Request`.
	Request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : List(U8) }

	## The POST to a subscription's endpoint: its `Authorization` (`Vapid.authorization`), the
	## encrypted message (`WebPush.body`; none for a push with no data) and the options' headers.
	request : { endpoint : Str, authorization : Str, body : List(U8), options : Options } -> Request
	request = |{ endpoint, authorization, body, options }| {
		content =
			if body.is_empty() {
				[]
			} else {
				[{ name: "Content-Encoding", value: "aes128gcm" }, { name: "Content-Type", value: "application/octet-stream" }]
			}
		{
			method: "POST",
			url: endpoint,
			headers: [{ name: "Authorization", value: authorization }].concat(options.headers()).concat(content),
			body,
		}
	}

	## What an answer means.
	Outcome : [Delivered, Gone, RetryAfter(U64), Retry(Str), Refused(Str)]

	## What the push service's answer means, at `now_ms` (for a `Retry-After` that is a date).
	outcome : { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) }, U64 -> Outcome
	outcome = |{ status, headers, body }, now_ms| {
		said = excerpt(body)
		why = if (said.is_empty()) "the push service answered ${status.to_str()}" else "the push service answered ${status.to_str()}: ${said}"
		later =
			match headers.find_first(|each| each.name.with_ascii_lowercased() == "retry-after") {
				Ok(header) => Delivery.retry_after(header.value, now_ms).map_err(|_| {})
				Err(_) => Err({})
			}
		if status >= 200 and status < 300 {
			Delivered
		} else if status == 404 or status == 410 {
			Gone
		} else if status == 429 or status == 408 or status >= 500 {
			match later {
				Ok(ms) => RetryAfter(ms)
				Err(_) => Retry(why)
			}
		} else if status == 401 or status == 403 {
			Refused("${why} (check VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY and VAPID_SUBJECT: a browser subscribed with another public key can't be sent to with this one)")
		} else if status == 413 {
			Refused("${why} (the message is too large: ${WebPush.max_data.to_str()} bytes of data at most)")
		} else {
			Refused(why)
		}
	}

	## How long a `Retry-After` header says to wait, in milliseconds: its seconds, or the time
	## until its date (an HTTP date, `Wed, 21 Oct 2015 07:28:00 GMT`; 0 when that has passed).
	retry_after : Str, U64 -> Try(U64, [BadRetryAfter])
	retry_after = |text, now_ms| {
		trimmed = text.trim()
		match U64.from_str(trimmed) {
			Ok(seconds) => Ok(seconds * 1000)
			Err(_) =>
				match Delivery.http_date(trimmed) {
					Ok(at) => Ok(if (at > now_ms) at - now_ms else 0)
					Err(_) => Err(BadRetryAfter)
				}
		}
	}

	## An HTTP date (RFC 9110's IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`) in milliseconds since
	## the epoch.
	http_date : Str -> Try(U64, [BadDate])
	http_date = |text|
		match text.split_on(" ") {
			[_weekday, day, month, year, time, "GMT"] =>
				match time.split_on(":") {
					[hours, minutes, seconds] => {
						d = number(day, 1, 31)?
						m = month_number(month)?
						y = number(year, 1970, 9999)?
						h = number(hours, 0, 23)?
						min = number(minutes, 0, 59)?
						s = number(seconds, 0, 60)?
						Ok(((days_from_civil(y, m, d) * 24 + h) * 3600 + min * 60 + s) * 1000)
					}
					_ => Err(BadDate)
				}
			_ => Err(BadDate)
		}
}

## The start of an answer's body, for a message: 200 bytes at most, on one line.
excerpt : List(U8) -> Str
excerpt = |body| Str.from_utf8_lossy(body.take_first(200).map(|each| if (each < ' ') ' ' else each)).trim()

number : Str, U64, U64 -> Try(U64, [BadDate])
number = |text, least, most|
	match U64.from_str(text) {
		Ok(value) if value >= least and value <= most => Ok(value)
		_ => Err(BadDate)
	}

month_number : Str -> Try(U64, [BadDate])
month_number = |name|
	match ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].find_first_index(|each| each == name) {
		Ok(at) => Ok(at + 1)
		Err(_) => Err(BadDate)
	}

## Days from 1970-01-01 to a date of 1970 or later (Howard Hinnant's `days_from_civil`).
days_from_civil : U64, U64, U64 -> U64
days_from_civil = |year, month, day| {
	y = if (month <= 2) year - 1 else year
	era = y // 400
	year_of_era = y - era * 400
	day_of_year = (153 * (if (month > 2) month - 3 else month + 9) + 2) // 5 + day - 1
	day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
	era * 146_097 + day_of_era - 719_468
}

answer : U16, List({ name : Str, value : Str }), Str -> { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) }
answer = |status, headers, body| { status, headers, body: body.to_utf8() }

# The request.
expect
	Delivery.request({ endpoint: "https://push.example.net/s/1", authorization: "vapid t=x, k=y", body: [1, 2], options: { ttl: 60, urgency: High, topic: "t1" } })
		== {
			method: "POST",
			url: "https://push.example.net/s/1",
			headers: [
				{ name: "Authorization", value: "vapid t=x, k=y" },
				{ name: "TTL", value: "60" },
				{ name: "Urgency", value: "high" },
				{ name: "Topic", value: "t1" },
				{ name: "Content-Encoding", value: "aes128gcm" },
				{ name: "Content-Type", value: "application/octet-stream" },
			],
			body: [1, 2],
		}
expect Delivery.request({ endpoint: "https://push.example.net/s/1", authorization: "vapid t=x, k=y", body: [], options: Options.defaults }).headers.len() == 3

# Answers.
expect Delivery.outcome(answer(201, [{ name: "Location", value: "https://push.example.net/m/1" }], ""), 0) == Delivered
expect Delivery.outcome(answer(200, [], ""), 0) == Delivered
expect Delivery.outcome(answer(202, [], ""), 0) == Delivered
expect Delivery.outcome(answer(404, [], ""), 0) == Gone
expect Delivery.outcome(answer(410, [], "push subscription has unsubscribed or expired."), 0) == Gone
expect Delivery.outcome(answer(429, [{ name: "Retry-After", value: "120" }], ""), 0) == RetryAfter(120_000)
expect Delivery.outcome(answer(503, [{ name: "retry-after", value: "Wed, 21 Oct 2015 07:28:00 GMT" }], ""), 1_445_412_470_000) == RetryAfter(10_000)
expect Delivery.outcome(answer(429, [], "slow down"), 0) == Retry("the push service answered 429: slow down")
expect Delivery.outcome(answer(429, [{ name: "Retry-After", value: "soon" }], ""), 0) == Retry("the push service answered 429")
expect Delivery.outcome(answer(500, [], ""), 0) == Retry("the push service answered 500")
expect Delivery.outcome(answer(502, [], "<html>\n\tbad gateway\n</html>"), 0) == Retry("the push service answered 502: <html>  bad gateway </html>")
expect Delivery.outcome(answer(408, [], ""), 0) == Retry("the push service answered 408")
expect Delivery.outcome(answer(400, [], "invalid TTL"), 0) == Refused("the push service answered 400: invalid TTL")
expect
	match Delivery.outcome(answer(403, [], ""), 0) {
		Refused(why) => why.starts_with("the push service answered 403 (check VAPID_PUBLIC_KEY")
		_ => Bool.False
	}
expect
	match Delivery.outcome(answer(401, [], ""), 0) {
		Refused(why) => why.contains("VAPID_PRIVATE_KEY")
		_ => Bool.False
	}
expect
	match Delivery.outcome(answer(413, [], ""), 0) {
		Refused(why) => why.contains("too large")
		_ => Bool.False
	}
expect Delivery.outcome(answer(301, [], ""), 0) == Refused("the push service answered 301")
expect
	match Delivery.outcome(answer(400, [], Str.repeat("x", 500)), 0) {
		Refused(why) => why == "the push service answered 400: ${Str.repeat("x", 200)}"
		_ => Bool.False
	}

# Retry-After, both ways, and HTTP dates (checked against Node's Date.parse).
expect Delivery.retry_after(" 30 ", 0) == Ok(30_000)
expect Delivery.retry_after("0", 0) == Ok(0)
expect Delivery.retry_after("Wed, 21 Oct 2015 07:28:00 GMT", 1_445_412_480_000) == Ok(0)
expect Delivery.retry_after("Wed, 21 Oct 2015 07:28:00 GMT", 1_500_000_000_000) == Ok(0)
expect Delivery.retry_after("-5", 0) == Err(BadRetryAfter)
expect Delivery.retry_after("", 0) == Err(BadRetryAfter)
expect Delivery.http_date("Wed, 21 Oct 2015 07:28:00 GMT") == Ok(1_445_412_480_000)
expect Delivery.http_date("Thu, 01 Jan 1970 00:00:00 GMT") == Ok(0)
expect Delivery.http_date("Sat, 29 Feb 2020 23:59:59 GMT") == Ok(1_583_020_799_000)
expect Delivery.http_date("Fri, 31 Dec 2100 12:00:00 GMT") == Ok(4_133_937_600_000)
expect Delivery.http_date("Wed, 21 Oct 2015 07:28:00 PST") == Err(BadDate)
expect Delivery.http_date("Wed, 21 Okt 2015 07:28:00 GMT") == Err(BadDate)
expect Delivery.http_date("Wed, 32 Oct 2015 07:28:00 GMT") == Err(BadDate)
expect Delivery.http_date("Wed, 21 Oct 2015 7:28 GMT") == Err(BadDate)
expect Delivery.http_date("Wednesday, 21-Oct-15 07:28:00 GMT") == Err(BadDate)
