import crypto.Hex
import crypto.Hmac
import crypto.Sha256

## AWS Signature Version 4 as S3 wants it (rustfs, R2 and AWS alike): a request's `Authorization`
## header, and presigned URLs. Pure, so `S3` signs here and sends with the `send!` it was given (the
## server platform's `Http.send!`), and the expects below hold it to AWS's own worked examples.
##
## S3's flavour of SigV4: the path is encoded once and never normalised (`a//b` is a key of its
## own), its `/`s kept; every request states its body's SHA-256 in `x-amz-content-sha256`, or
## `UNSIGNED-PAYLOAD` (a multipart part isn't hashed in Roc).
SigV4 := [].{

	## The keys, and the region they sign for (`us-east-1` for rustfs and most S3s, `auto` for R2).
	Credentials : { access_key : Str, secret_key : Str, region : Str }

	## A header, or a query parameter: neither encoded.
	Pair : { name : Str, value : Str }

	## A request to sign. `origin` is the scheme and authority only (`http://localhost:9000`,
	## `https://examplebucket.s3.amazonaws.com`); `path` the object's path as it is, not encoded
	## (`/uploads/videos/1` path-style, `/videos/1` on the bucket's own host); `query` and
	## `headers` not encoded either. `headers` are sent and signed besides the three `sign` adds;
	## sign `range`, `content-type` and any `x-amz-*` you send.
	Request : {
		method : Str,
		origin : Str,
		path : Str,
		query : List(Pair),
		headers : List(Pair),
		payload : [Signed(List(U8)), Unsigned],
	}

	## What to send, exactly: the URL, encoded as it was signed, and every header but `host`
	## (the client derives it from the URL, as `host` says): the request's own, then
	## `x-amz-date`, `x-amz-content-sha256` and `authorization`.
	Signed : { url : Str, headers : List(Pair) }

	## A presigned URL's request: anyone holding the URL may make it until `expires_s` seconds
	## (1 to 604800, a week) after the signing time. Only `host` is signed, and the body isn't.
	Presign : { method : Str, origin : Str, path : Str, query : List(Pair), expires_s : U64 }

	## Signs `request` at `now_ms` (milliseconds since the epoch, as `Time.now_millis!` gives
	## them). A `host`, `x-amz-date`, `x-amz-content-sha256` or `authorization` among the
	## request's headers is replaced by the one signed.
	sign : Credentials, U64, Request -> Signed
	sign = |credentials, now_ms, request| {
		date_time = SigV4.amz_date(now_ms)
		day = amz_day(now_ms)
		payload_hash =
			match request.payload {
				Signed(bytes) => Sha256.hex(bytes)
				Unsigned => SigV4.unsigned_payload
			}
		kept = request.headers.drop_if(|header| replaced.contains(header.name.trim().with_ascii_lowercased()))
		sent = kept.concat([{ name: "x-amz-date", value: date_time }, { name: "x-amz-content-sha256", value: payload_hash }])
		signed = sent.append({ name: "host", value: SigV4.host(request.origin) })
		canonical = SigV4.canonical_request({ method: request.method, path: request.path, query: request.query, headers: signed, payload_hash: payload_hash })
		credential_scope = SigV4.scope(day, credentials.region)
		signed_with = SigV4.signature(SigV4.signing_key(credentials.secret_key, day, credentials.region), SigV4.string_to_sign(date_time, credential_scope, canonical))
		authorization = "${algorithm} Credential=${credentials.access_key}/${credential_scope},SignedHeaders=${SigV4.signed_headers(signed)},Signature=${signed_with}"
		{ url: url_of(request.origin, request.path, request.query), headers: sent.append({ name: "authorization", value: authorization }) }
	}

	## A presigned URL for `request`, signed at `now_ms`: query authentication, the payload
	## `UNSIGNED-PAYLOAD`. `Err(BadExpiry)` unless `expires_s` is 1 to 604800.
	presign : Credentials, U64, Presign -> Try(Str, [BadExpiry])
	presign = |credentials, now_ms, request| {
		if request.expires_s < 1 or request.expires_s > 604800 {
			return Err(BadExpiry)
		}
		date_time = SigV4.amz_date(now_ms)
		day = amz_day(now_ms)
		credential_scope = SigV4.scope(day, credentials.region)
		query = request.query.concat([
			{ name: "X-Amz-Algorithm", value: algorithm },
			{ name: "X-Amz-Credential", value: "${credentials.access_key}/${credential_scope}" },
			{ name: "X-Amz-Date", value: date_time },
			{ name: "X-Amz-Expires", value: request.expires_s.to_str() },
			{ name: "X-Amz-SignedHeaders", value: "host" },
		])
		headers = [{ name: "host", value: SigV4.host(request.origin) }]
		canonical = SigV4.canonical_request({ method: request.method, path: request.path, query: query, headers: headers, payload_hash: SigV4.unsigned_payload })
		signed_with = SigV4.signature(SigV4.signing_key(credentials.secret_key, day, credentials.region), SigV4.string_to_sign(date_time, credential_scope, canonical))
		Ok("${url_of(request.origin, request.path, query)}&X-Amz-Signature=${signed_with}")
	}

	## The payload hash of a body that isn't hashed.
	unsigned_payload : Str
	unsigned_payload = "UNSIGNED-PAYLOAD"

	## The steps, exposed for the expects and for reading S3's `SignatureDoesNotMatch` (its
	## answer holds the canonical request and string to sign it computed).
	##
	## S3's `UriEncode`: every byte but `A-Z a-z 0-9 - . _ ~` as `%XX`, in capitals; `/` too.
	encode : Str -> Str
	encode = |text| encoded(text, Bool.False)

	## `UriEncode` for an object's path: `/` kept. A path that doesn't start with `/` gets one.
	encode_path : Str -> Str
	encode_path = |path| encoded(if (path.starts_with("/")) path else "/${path}", Bool.True)

	## Names and values encoded, then sorted by name (and value, for a repeated name), each
	## `name=value` (`=` even when the value is empty: `?uploads` signs as `uploads=`).
	canonical_query : List(Pair) -> Str
	canonical_query = |query| {
		pairs = query.map(|pair| { name: SigV4.encode(pair.name), value: SigV4.encode(pair.value) })
		sorted = pairs.sort_with(
			|left, right|
				match order(left.name.to_utf8(), right.name.to_utf8()) {
					Same => order(left.value.to_utf8(), right.value.to_utf8())
					other => other
				},
		)
		Str.join_with(sorted.map(|pair| "${pair.name}=${pair.value}"), "&")
	}

	## The headers as signed: names lowercased and sorted, values trimmed with runs of spaces made
	## one, a repeated header's values joined with commas.
	canonical_headers : List(Pair) -> List(Pair)
	canonical_headers = |headers| {
		cleaned = headers.map(|header| { name: header.name.trim().with_ascii_lowercased(), value: squeezed(header.value) })
		names = unique(cleaned.map(|header| header.name).sort_with(|left, right| order(left.to_utf8(), right.to_utf8())))
		names.map(|name| { name: name, value: Str.join_with(cleaned.keep_if(|header| header.name == name).map(|header| header.value), ",") })
	}

	## The signed headers' names, sorted, joined with `;`.
	signed_headers : List(Pair) -> Str
	signed_headers = |headers| Str.join_with(SigV4.canonical_headers(headers).map(|header| header.name), ";")

	## The canonical request: method, path, query, headers (each line ending in a newline), signed
	## headers and payload hash, one a line.
	canonical_request : { method : Str, path : Str, query : List(Pair), headers : List(Pair), payload_hash : Str } -> Str
	canonical_request = |parts| {
		headers = SigV4.canonical_headers(parts.headers)
		lines = Str.join_with(headers.map(|header| "${header.name}:${header.value}\n"), "")
		names = Str.join_with(headers.map(|header| header.name), ";")
		Str.join_with([parts.method, SigV4.encode_path(parts.path), SigV4.canonical_query(parts.query), lines, names, parts.payload_hash], "\n")
	}

	## `20130524/us-east-1/s3/aws4_request`, from the day (`yyyymmdd`) and the region.
	scope : Str, Str -> Str
	scope = |day, region| "${day}/${region}/s3/aws4_request"

	## The string to sign: the algorithm, the time (`amz_date`), the scope, and the canonical
	## request's SHA-256.
	string_to_sign : Str, Str, Str -> Str
	string_to_sign = |date_time, credential_scope, canonical| "${algorithm}\n${date_time}\n${credential_scope}\n${Sha256.hex(canonical.to_utf8())}"

	## The signing key of a secret key, a day (`yyyymmdd`) and a region, for S3. It changes once a
	## day, so a caller may keep it.
	signing_key : Str, Str, Str -> List(U8)
	signing_key = |secret_key, day, region| {
		by_day = Hmac.sha256("AWS4${secret_key}".to_utf8(), day.to_utf8())
		by_region = Hmac.sha256(by_day, region.to_utf8())
		by_service = Hmac.sha256(by_region, "s3".to_utf8())
		Hmac.sha256(by_service, "aws4_request".to_utf8())
	}

	## The signature of a string to sign, in hex.
	signature : List(U8), Str -> Str
	signature = |key, text| Hex.encode(Hmac.sha256(key, text.to_utf8()))

	## A moment (milliseconds since the epoch) as SigV4 writes it: `20130524T000000Z`, in UTC.
	amz_date : U64 -> Str
	amz_date = |ms| {
		of_day = ms // 1000 % 86400
		"${amz_day(ms)}T${digits(of_day // 3600, 2)}${digits(of_day % 3600 // 60, 2)}${digits(of_day % 60, 2)}Z"
	}

	## The `host` header a client sends for `origin`: its authority, without the scheme's
	## default port (`:443` for https, `:80` for http), as hyper and browsers send it.
	host : Str -> Str
	host = |origin| {
		(scheme, rest) =
			match origin.split_first("://") {
				Ok({ before, after }) => (before.with_ascii_lowercased(), after)
				Err(_) => ("https", origin)
			}
		authority =
			match rest.split_first("/") {
				Ok({ before, after: _ }) => before
				Err(_) => rest
			}
		match authority.split_last(":") {
			Ok({ before, after }) =>
				if ((scheme == "https" and after == "443") or (scheme == "http" and after == "80")) before else authority
			Err(_) => authority
		}
	}
}

algorithm : Str
algorithm = "AWS4-HMAC-SHA256"

## Headers `sign` sets itself.
replaced : List(Str)
replaced = ["host", "x-amz-date", "x-amz-content-sha256", "authorization"]

url_of : Str, Str, List(SigV4.Pair) -> Str
url_of = |origin, path, query| {
	base = "${origin.drop_suffix("/")}${SigV4.encode_path(path)}"
	if (query.is_empty()) base else "${base}?${SigV4.canonical_query(query)}"
}

encoded : Str, Bool -> Str
encoded = |text, keep_slash| {
	var $out = []
	for each in text.to_utf8() {
		if unreserved(each) or (keep_slash and each == '/') {
			$out = $out.append(each)
		} else {
			$out = $out.append('%').append(upper_digit(each // 16)).append(upper_digit(each % 16))
		}
	}
	Str.from_utf8_lossy($out)
}

unreserved : U8 -> Bool
unreserved = |char|
	(char >= 'A' and char <= 'Z')
		or (char >= 'a' and char <= 'z')
		or (char >= '0' and char <= '9')
		or char == '-'
		or char == '.'
		or char == '_'
		or char == '~'

upper_digit : U8 -> U8
upper_digit = |nibble| if (nibble < 10) '0' + nibble else 'A' + nibble - 10

## Byte order, as SigV4 sorts (so `X-Amz-…` comes before `response-…`).
order : List(U8), List(U8) -> [Before, Same, After]
order = |left, right| {
	var $at = 0
	while $at < left.len() and $at < right.len() {
		l = left.get($at) ?? 0
		r = right.get($at) ?? 0
		if l < r {
			return Before
		}
		if l > r {
			return After
		}
		$at = $at + 1
	}
	if left.len() < right.len() {
		Before
	} else if left.len() > right.len() {
		After
	} else {
		Same
	}
}

## A sorted list without its repeats.
unique : List(Str) -> List(Str)
unique = |sorted| {
	var $out = []
	for each in sorted {
		if $out.last() != Ok(each) {
			$out = $out.append(each)
		}
	}
	$out
}

## Trimmed, with each run of spaces and tabs inside made one space.
squeezed : Str -> Str
squeezed = |text| {
	var $out = []
	var $space = Bool.False
	for each in text.trim().to_utf8() {
		if each == ' ' or each == '\t' {
			$space = Bool.True
		} else {
			if $space {
				$out = $out.append(' ')
			}
			$space = Bool.False
			$out = $out.append(each)
		}
	}
	Str.from_utf8_lossy($out)
}

amz_day : U64 -> Str
amz_day = |ms| {
	date = civil((ms // 1000 // 86400).to_i64_wrap())
	"${digits(date.year.to_u64_wrap(), 4)}${digits(date.month.to_u64_wrap(), 2)}${digits(date.day.to_u64_wrap(), 2)}"
}

## The year, month (1–12) and day (1–31) of a day counted from 1970-01-01, in the proleptic
## Gregorian calendar (Howard Hinnant's algorithm; the server platform's `Calendar` has the same).
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
	{ year: if (month <= 2) year + 1 else year, month, day }
}

## `value` in decimal, zero-padded to `width` digits.
digits : U64, U64 -> Str
digits = |value, width| {
	text = value.to_str()
	Str.concat(Str.repeat("0", width - U64.min(width, text.to_utf8().len())), text)
}

# ── AWS's worked examples ─────────────────────────────────────────────────────────────────────────
# From the S3 docs, "Examples: Signature Calculations" (developerguide/sig-v4-header-based-auth.html)
# and "An Example" (developerguide/sigv4-query-string-auth.html): the example keys, 2013-05-24
# 00:00:00 UTC, examplebucket on its own host, us-east-1. Every canonical request, string to sign,
# signature and header below is copied from them.

example : SigV4.Credentials
example = { access_key: "AKIAIOSFODNN7EXAMPLE", secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1" }

may_24 : U64
may_24 = 1369353600000

bucket : Str
bucket = "https://examplebucket.s3.amazonaws.com"

empty_sha : Str
empty_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

key_of_may_24 : List(U8)
key_of_may_24 = SigV4.signing_key(example.secret_key, "20130524", "us-east-1")

expect SigV4.amz_date(may_24) == "20130524T000000Z"
expect SigV4.scope("20130524", "us-east-1") == "20130524/us-east-1/s3/aws4_request"

# GET Object: the first 10 bytes of test.txt (`Range: bytes=0-9 `, its trailing space trimmed).
get_object_canonical : Str
get_object_canonical =
	"GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\nx-amz-content-sha256:${empty_sha}\nx-amz-date:20130524T000000Z\n\nhost;range;x-amz-content-sha256;x-amz-date\n${empty_sha}"

expect
	SigV4.canonical_request({
		method: "GET",
		path: "/test.txt",
		query: [],
		headers: [
			{ name: "Host", value: "examplebucket.s3.amazonaws.com" },
			{ name: "Range", value: "bytes=0-9 " },
			{ name: "x-amz-content-sha256", value: empty_sha },
			{ name: "x-amz-date", value: " 20130524T000000Z " },
		],
		payload_hash: empty_sha,
	})
		== get_object_canonical
expect
	SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", get_object_canonical)
		== "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
expect
	SigV4.signature(key_of_may_24, SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", get_object_canonical))
		== "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
expect
	SigV4.sign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], headers: [{ name: "Range", value: "bytes=0-9 " }], payload: Signed([]) })
		== {
			url: "https://examplebucket.s3.amazonaws.com/test.txt",
			headers: [
				{ name: "Range", value: "bytes=0-9 " },
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: empty_sha },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41" },
			],
		}

# PUT Object: test$file.text holding "Welcome to Amazon S3.", REDUCED_REDUNDANCY, with a `Date`.
put_object_canonical : Str
put_object_canonical =
	"PUT\n/test%24file.text\n\ndate:Fri, 24 May 2013 00:00:00 GMT\nhost:examplebucket.s3.amazonaws.com\nx-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072\nx-amz-date:20130524T000000Z\nx-amz-storage-class:REDUCED_REDUNDANCY\n\ndate;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class\n44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

put_object : SigV4.Request
put_object = {
	method: "PUT",
	origin: bucket,
	path: "test$file.text",
	query: [],
	headers: [{ name: "Date", value: "Fri, 24 May 2013 00:00:00 GMT" }, { name: "x-amz-storage-class", value: "REDUCED_REDUNDANCY" }],
	payload: Signed("Welcome to Amazon S3.".to_utf8()),
}

expect Sha256.hex("Welcome to Amazon S3.".to_utf8()) == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
expect
	SigV4.canonical_request({
		method: "PUT",
		path: "/test$file.text",
		query: [],
		headers: [
			{ name: "Host", value: "examplebucket.s3.amazonaws.com" },
			{ name: "Date", value: "Fri, 24 May 2013 00:00:00 GMT" },
			{ name: "x-amz-date", value: "20130524T000000Z" },
			{ name: "x-amz-storage-class", value: "REDUCED_REDUNDANCY" },
			{ name: "x-amz-content-sha256", value: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072" },
		],
		payload_hash: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
	})
		== put_object_canonical
expect
	SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", put_object_canonical)
		== "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"
expect
	SigV4.sign(example, may_24, put_object)
		== {
			url: "https://examplebucket.s3.amazonaws.com/test%24file.text",
			headers: [
				{ name: "Date", value: "Fri, 24 May 2013 00:00:00 GMT" },
				{ name: "x-amz-storage-class", value: "REDUCED_REDUNDANCY" },
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072" },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd" },
			],
		}
expect SigV4.sign(example, may_24, { ..put_object, path: "/test$file.text" }) == SigV4.sign(example, may_24, put_object)

# GET Bucket Lifecycle: a subresource, `?lifecycle`, signs as `lifecycle=`.
lifecycle_canonical : Str
lifecycle_canonical =
	"GET\n/\nlifecycle=\nhost:examplebucket.s3.amazonaws.com\nx-amz-content-sha256:${empty_sha}\nx-amz-date:20130524T000000Z\n\nhost;x-amz-content-sha256;x-amz-date\n${empty_sha}"

expect
	SigV4.canonical_request({
		method: "GET",
		path: "/",
		query: [{ name: "lifecycle", value: "" }],
		headers: [{ name: "Host", value: "examplebucket.s3.amazonaws.com" }, { name: "x-amz-date", value: "20130524T000000Z" }, { name: "x-amz-content-sha256", value: empty_sha }],
		payload_hash: empty_sha,
	})
		== lifecycle_canonical
expect
	SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", lifecycle_canonical)
		== "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n9766c798316ff2757b517bc739a67f6213b4ab36dd5da2f94eaebf79c77395ca"
expect
	SigV4.sign(example, may_24, { method: "GET", origin: bucket, path: "/", query: [{ name: "lifecycle", value: "" }], headers: [], payload: Signed([]) })
		== {
			url: "https://examplebucket.s3.amazonaws.com/?lifecycle=",
			headers: [
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: empty_sha },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543" },
			],
		}

# Get Bucket (List Objects): `?max-keys=2&prefix=J`, given here out of order.
list_canonical : Str
list_canonical =
	"GET\n/\nmax-keys=2&prefix=J\nhost:examplebucket.s3.amazonaws.com\nx-amz-content-sha256:${empty_sha}\nx-amz-date:20130524T000000Z\n\nhost;x-amz-content-sha256;x-amz-date\n${empty_sha}"

expect
	SigV4.canonical_request({
		method: "GET",
		path: "/",
		query: [{ name: "prefix", value: "J" }, { name: "max-keys", value: "2" }],
		headers: [{ name: "Host", value: "examplebucket.s3.amazonaws.com" }, { name: "x-amz-date", value: "20130524T000000Z" }, { name: "x-amz-content-sha256", value: empty_sha }],
		payload_hash: empty_sha,
	})
		== list_canonical
expect
	SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", list_canonical)
		== "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\ndf57d21db20da04d7fa30298dd4488ba3a2b47ca3a489c74750e0f1e7df1b9b7"
expect
	SigV4.sign(example, may_24, { method: "GET", origin: bucket, path: "", query: [{ name: "prefix", value: "J" }, { name: "max-keys", value: "2" }], headers: [], payload: Signed([]) })
		== {
			url: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J",
			headers: [
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: empty_sha },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7" },
			],
		}

# The presigned URL: GET test.txt for 24 hours.
presigned_canonical : Str
presigned_canonical =
	"GET\n/test.txt\nX-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host\nhost:examplebucket.s3.amazonaws.com\n\nhost\nUNSIGNED-PAYLOAD"

expect
	SigV4.canonical_request({
		method: "GET",
		path: "/test.txt",
		query: [
			{ name: "X-Amz-SignedHeaders", value: "host" },
			{ name: "X-Amz-Expires", value: "86400" },
			{ name: "X-Amz-Date", value: "20130524T000000Z" },
			{ name: "X-Amz-Credential", value: "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request" },
			{ name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256" },
		],
		headers: [{ name: "host", value: "examplebucket.s3.amazonaws.com" }],
		payload_hash: SigV4.unsigned_payload,
	})
		== presigned_canonical
expect
	SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", presigned_canonical)
		== "AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04"
expect
	SigV4.signature(key_of_may_24, SigV4.string_to_sign("20130524T000000Z", "20130524/us-east-1/s3/aws4_request", presigned_canonical))
		== "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
expect
	SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], expires_s: 86400 })
		== Ok("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")

# ── Cases AWS doesn't publish ─────────────────────────────────────────────────────────────────────
# Signatures from botocore 2.36 (the aws CLI's), its clock pinned to the same moment, with the same
# keys. That botocore gives AWS's own GET Object, List Objects and presigned signatures above was
# checked first.

# A presigned PUT for an hour.
expect
	SigV4.presign(example, may_24, { method: "PUT", origin: bucket, path: "/test.txt", query: [], expires_s: 3600 })
		== Ok("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=bd813e1bbd1dc21c323582d2bb1ba8b3051bc8991db4327cabb83e98af93bf6e")

# Path-style on rustfs (http, a port), a key with spaces, brackets, `+`, `ü` and `~`.
expect
	SigV4.presign(example, may_24, { method: "GET", origin: "http://localhost:9000", path: "/uploads/videos/My Clip (1)+ü~.mp4", query: [], expires_s: 600 })
		== Ok("http://localhost:9000/uploads/videos/My%20Clip%20%281%29%2B%C3%BC~.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=600&X-Amz-SignedHeaders=host&X-Amz-Signature=df9d9c0add0d65bd66a10906fe7438df2fc297a400f4cedfb5d66366a1f9aa8a")

# A presigned GET that names its download: the caller's parameter sorts after the `X-Amz-` ones.
expect
	SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [{ name: "response-content-disposition", value: "attachment; filename=\"a b.txt\"" }], expires_s: 300 })
		== Ok("https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&response-content-disposition=attachment%3B%20filename%3D%22a%20b.txt%22&X-Amz-Signature=0cec6da6f34ba9cb16fa2705efad59ebcc87f5c8202b6eec084340dc175c5736")

# UploadPart with `UNSIGNED-PAYLOAD`: the body isn't hashed, whatever it is.
upload_part : SigV4.Request
upload_part = {
	method: "PUT",
	origin: "http://localhost:9000",
	path: "/uploads/videos/v1",
	query: [{ name: "uploadId", value: "abc/def==" }, { name: "partNumber", value: "1" }],
	headers: [],
	payload: Unsigned,
}

expect
	SigV4.sign(example, may_24, upload_part)
		== {
			url: "http://localhost:9000/uploads/videos/v1?partNumber=1&uploadId=abc%2Fdef%3D%3D",
			headers: [
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: "UNSIGNED-PAYLOAD" },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=c73a1d10e73db6c3a62f2c1b017c28839175753477cea6e284adb6604497c954" },
			],
		}

# CreateMultipartUpload: `POST …?uploads`, an empty body.
expect
	SigV4.sign(example, may_24, { method: "POST", origin: "http://localhost:9000", path: "/uploads/videos/v1", query: [{ name: "uploads", value: "" }], headers: [], payload: Signed([]) }).headers.last()
		== Ok({ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=7847ddec2a00fa5f4447cbcfc07c0e302820b00bc442811dacaee32089c7dbee" })

# A path S3 doesn't normalise: `a//b/./c` is a key of its own.
expect
	SigV4.sign(example, may_24, { method: "GET", origin: "http://localhost:9000", path: "/uploads/a//b/./c", query: [], headers: [], payload: Signed([]) })
		== {
			url: "http://localhost:9000/uploads/a//b/./c",
			headers: [
				{ name: "x-amz-date", value: "20130524T000000Z" },
				{ name: "x-amz-content-sha256", value: empty_sha },
				{ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;x-amz-content-sha256;x-amz-date,Signature=5240dfc236fa2e22c4806e996431437bc8f144b28705dcd3850aceb7b5d980fc" },
			],
		}

# ── The rules, one by one ─────────────────────────────────────────────────────────────────────────

# UriEncode (the S3 docs' rules): unreserved bytes kept, the rest `%XX` in capitals, space as `%20`
# (never `+`), UTF-8 byte by byte, `/` kept only in a path.
expect SigV4.encode("AZaz09-._~") == "AZaz09-._~"
expect SigV4.encode("a b+c=d&e") == "a%20b%2Bc%3Dd%26e"
expect SigV4.encode("photos/Jan/sample.jpg") == "photos%2FJan%2Fsample.jpg"
expect SigV4.encode("100%*!'()$,;:@") == "100%25%2A%21%27%28%29%24%2C%3B%3A%40"
expect SigV4.encode("ü€") == "%C3%BC%E2%82%AC"
expect SigV4.encode("\u(0)\n") == "%00%0A"
expect SigV4.encode("") == ""
expect SigV4.encode_path("/photos/Jan/sample.jpg") == "/photos/Jan/sample.jpg"
expect SigV4.encode_path("photos/a b.jpg") == "/photos/a%20b.jpg"
expect SigV4.encode_path("") == "/"
expect SigV4.encode_path("/my-object//example//photo.user") == "/my-object//example//photo.user"

# The canonical query: the docs' `prefix`, `marker`, `max-keys` example; sorted after encoding,
# by byte; a repeated name by value.
expect SigV4.canonical_query([{ name: "prefix", value: "somePrefix" }, { name: "marker", value: "someMarker" }, { name: "max-keys", value: "20" }]) == "marker=someMarker&max-keys=20&prefix=somePrefix"
expect SigV4.canonical_query([{ name: "acl", value: "" }]) == "acl="
expect SigV4.canonical_query([]) == ""
expect SigV4.canonical_query([{ name: "b", value: "2" }, { name: "B", value: "1" }, { name: "a b", value: "x" }]) == "B=1&a%20b=x&b=2"
expect SigV4.canonical_query([{ name: "k", value: "b" }, { name: "k", value: "a" }]) == "k=a&k=b"

# Canonical headers: names lowercased and sorted, values trimmed and their space runs made one, a
# repeated header's values joined with commas in the order given.
expect
	SigV4.canonical_headers([{ name: "X-Amz-Meta-B", value: "  a   b \t c  " }, { name: "Host", value: "h" }, { name: "x-amz-meta-a", value: "2" }, { name: "X-AMZ-META-A", value: "1" }])
		== [{ name: "host", value: "h" }, { name: "x-amz-meta-a", value: "2,1" }, { name: "x-amz-meta-b", value: "a b c" }]
expect SigV4.signed_headers([{ name: "X-Amz-Date", value: "" }, { name: "Range", value: "" }, { name: "host", value: "" }]) == "host;range;x-amz-date"

# `sign` replaces what it sets, whatever case the caller wrote it in.
expect
	SigV4.sign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], headers: [{ name: "Range", value: "bytes=0-9 " }, { name: "X-Amz-Date", value: "19700101T000000Z" }, { name: "Host", value: "elsewhere" }, { name: "Authorization", value: "old" }], payload: Signed([]) })
		== SigV4.sign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], headers: [{ name: "Range", value: "bytes=0-9 " }], payload: Signed([]) })

# The host header: the scheme's default port left out, any other kept.
expect SigV4.host("https://examplebucket.s3.amazonaws.com") == "examplebucket.s3.amazonaws.com"
expect SigV4.host("http://localhost:9000") == "localhost:9000"
expect SigV4.host("http://localhost:9000/") == "localhost:9000"
expect SigV4.host("https://s3.example.com:443") == "s3.example.com"
expect SigV4.host("http://s3.example.com:80") == "s3.example.com"
expect SigV4.host("http://s3.example.com:8080") == "s3.example.com:8080"
expect SigV4.host("https://s3.example.com:80") == "s3.example.com:80"
expect SigV4.host("http://[::1]:9000") == "[::1]:9000"
expect SigV4.host("http://[::1]") == "[::1]"
expect SigV4.host("http://[::1]:80") == "[::1]"
expect
	SigV4.sign(example, may_24, { method: "GET", origin: "https://examplebucket.s3.amazonaws.com:443", path: "/test.txt", query: [], headers: [{ name: "Range", value: "bytes=0-9" }], payload: Signed([]) }).headers.last()
		== Ok({ name: "authorization", value: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41" })

# Times: milliseconds dropped, UTC, padded.
expect SigV4.amz_date(may_24 + 999) == "20130524T000000Z"
expect SigV4.amz_date(1795211647000) == "20261120T215407Z"
expect SigV4.amz_date(0) == "19700101T000000Z"
expect SigV4.amz_date(951782400000 + 86399000) == "20000229T235959Z"

# A presigned URL lives 1 second to 7 days.
expect SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], expires_s: 0 }) == Err(BadExpiry)
expect SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], expires_s: 604801 }) == Err(BadExpiry)
expect SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], expires_s: 1 }).is_ok()
expect SigV4.presign(example, may_24, { method: "GET", origin: bucket, path: "/test.txt", query: [], expires_s: 604800 }).is_ok()

# Another day, region or key signs differently.
expect SigV4.signing_key(example.secret_key, "20130525", "us-east-1") != key_of_may_24
expect SigV4.signing_key(example.secret_key, "20130524", "auto") != key_of_may_24
expect SigV4.signing_key("other", "20130524", "us-east-1") != key_of_may_24
expect key_of_may_24.len() == 32
