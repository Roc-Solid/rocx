import SigV4

## Files kept in S3: rustfs or MinIO in development, R2, AWS or any other S3 in production. A
## bucket comes from a URL saying where it is and the keys to it (an app keeps it in an environment
## variable, `STORAGE_URL`), and from the two effects it needs, the server platform's own, passed
## in as they are:
##
##     bucket = S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })?
##     S3.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
##
## The URL:
##
##     s3://KEY:SECRET@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no
##     s3://KEY:SECRET@<account>.r2.cloudflarestorage.com/uploads?region=auto
##
## The bucket is the path. `region` is what the keys sign for (`us-east-1` if not given; `auto`
## for R2). `style=path` asks for `HOST/BUCKET/KEY`, as rustfs and MinIO want; without it the
## bucket is in the host name (`BUCKET.HOST/KEY`, virtual-hosted, as AWS and R2 prefer). `tls=no`
## speaks plain `http`; otherwise `https`. A character in the key or the secret that a URL would
## read otherwise is written `%XX` (a `/` in the secret may stay as it is).
##
## Requests are signed here (`SigV4`) and sent with the bucket's `send!`, waiting on the call's
## thread. A key is an object's name in the bucket, `/`s and all (`videos/41`); bytes are
## `List(U8)`, read and sent whole: `get_range!` reads a large object a piece at a time, and `serve!`
## answers a request with one of any size, streamed by the server, never read into Roc. Every
## operation but `signed_url!` is a request to S3, and may fail with `S3Err` (S3 answered, refusing:
## its status and its `<Error>`'s code and message) or `StorageErr` (no answer, or an empty key).
S3 := [].{

	## What a bucket asks of the platform: the server platform's `Http.send!` and
	## `Time.now_millis!`, given as they are.
	Effects : {
		send! : Request, Opts => Try(Response, [HttpErr(Str), TimedOut, TooLarge]),
		now! : {} => U64,
	}

	## A request to S3, as `Http.send!` takes one.
	Request : { method : Str, url : Str, headers : List(Pair), body : List(U8) }

	## S3's answer, as `Http.send!` gives one.
	Response : { status : U16, headers : List(Pair), body : List(U8) }

	## How long a request may take, how large its answer may be, and whether a redirect is followed,
	## as `Http.send!` takes them.
	Opts : { timeout_ms : U64, max_bytes : U64, follow_redirects : Bool }

	## A header, or a query parameter.
	Pair : { name : Str, value : Str }

	## Where the bucket is, read from its URL (`parse`): the keys and the region; the origin
	## requests go to; the path an object's key goes under (`/BUCKET` path-style, nothing
	## virtual-hosted).
	Config : { credentials : SigV4.Credentials, origin : Str, bucket_path : Str }

	## A bucket to keep objects in: where it is, and the effects that reach it (`S3.from_url`).
	Bucket : { config : Config, send! : Request, Opts => Try(Response, [HttpErr(Str), TimedOut, TooLarge]), now! : {} => U64 }

	## What S3 said when it refused: its status, and its `<Error>`'s `Code` and `Message`
	## (`AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`, `NoSuchBucket`,
	## `EntityTooSmall`, `InvalidPart`, …). An answer without one (a HEAD's, a proxy's) has an empty
	## code, and a message saying what came.
	Refusal : { status : U16, code : Str, message : Str }

	## An object's size in bytes, its content type, and its ETag (without its quotes).
	Info : { size : U64, content_type : Str, etag : Str }

	## The bucket the URL `url` names, reached with `effects`. `StorageErr` says what is wrong with
	## the URL (an empty one too: no storage). Nothing is asked of S3 yet: `check!` asks.
	from_url : Str, Effects -> Try(Bucket, [StorageErr(Str)])
	from_url = |url, effects| {
		if url.is_empty() {
			return Err(StorageErr("no storage: no S3 URL (s3://KEY:SECRET@HOST/BUCKET?region=…)"))
		}
		match S3.parse(url) {
			Ok(config) => Ok({ config, send!: effects.send!, now!: effects.now! })
			Err(why) => Err(StorageErr(why))
		}
	}

	## Keeps `bytes` as the object `key`, replacing any there was (PutObject). Its SHA-256 is
	## signed, so S3 refuses it if anything changed on the way.
	put! : Bucket, Str, List(U8), { content_type : Str } => Try({}, [S3Err(Refusal), StorageErr(Str)])
	put! = |bucket, key, bytes, opts| {
		answer = exchange!(bucket, { method: "PUT", key, query: [], headers: [{ name: "content-type", value: opts.content_type }], body: bytes, hashed: Bool.True }, sending)?
		if (succeeded(answer)) Ok({}) else Err(S3Err(refusal(answer)))
	}

	## The object `key`, whole (GetObject): 64 MiB at most (`StorageErr` beyond; `get_range!`
	## reads it in pieces). `NotFound` if there is none.
	get! : Bucket, Str => Try(List(U8), [NotFound, S3Err(Refusal), StorageErr(Str)])
	get! = |bucket, key| {
		answer = exchange!(bucket, asked("GET", key), reading)?
		if (succeeded(answer)) Ok(answer.body) else Err(not_found_or(refusal(answer)))
	}

	## `length` bytes of the object `key` from `offset` (fewer at its end), and its whole size
	## (GetObject with `Range`). An `offset` at or past its end is S3's `InvalidRange`; a `length`
	## of 0 is no bytes, and the size.
	get_range! : Bucket, Str, { offset : U64, length : U64 } => Try({ bytes : List(U8), size : U64 }, [NotFound, S3Err(Refusal), StorageErr(Str)])
	get_range! = |bucket, key, range| {
		if range.length == 0 {
			info = S3.head!(bucket, key)?
			return Ok({ bytes: [], size: info.size })
		}
		wanted = "bytes=${range.offset.to_str()}-${(range.offset + (range.length - 1)).to_str()}"
		answer = exchange!(bucket, { ..asked("GET", key), headers: [{ name: "range", value: wanted }] }, { ..reading, max_bytes: U64.max(range.length, small.max_bytes) })?
		if answer.status == 206 {
			Ok({ bytes: answer.body, size: whole_size(header(answer, "content-range") ?? "") ?? (range.offset + answer.body.len()) })
		} else if answer.status == 200 {
			# A server that ignored the range: the whole object came.
			Ok({ bytes: answer.body.drop_first(range.offset).take_first(range.length), size: answer.body.len() })
		} else {
			Err(not_found_or(refusal(answer)))
		}
	}

	## The object's size, content type and ETag, without its bytes (HeadObject). `NotFound` if
	## there is none; a HEAD's answer has no body, so a 404 is that even when it is the bucket
	## that's missing (`check!` says which).
	head! : Bucket, Str => Try(Info, [NotFound, S3Err(Refusal), StorageErr(Str)])
	head! = |bucket, key| {
		answer = exchange!(bucket, asked("HEAD", key), small)?
		if succeeded(answer) {
			Ok({
				size: U64.from_str(header(answer, "content-length") ?? "") ?? 0,
				content_type: header(answer, "content-type") ?? "",
				etag: unquoted(header(answer, "etag") ?? ""),
			})
		} else if answer.status == 404 {
			Err(NotFound)
		} else {
			Err(S3Err(refusal(answer)))
		}
	}

	## Deletes the object `key` (DeleteObject). One that isn't there is deleted already: `Ok`.
	delete! : Bucket, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	delete! = |bucket, key| {
		answer = exchange!(bucket, asked("DELETE", key), small)?
		if (succeeded(answer)) Ok({}) else Err(S3Err(refusal(answer)))
	}

	## Starts a multipart upload of the object `key` (CreateMultipartUpload): its upload id. Its
	## parts are sent with `upload_part!`, then `finish_upload!` makes them the object, or
	## `abort_upload!` forgets them. Until one of those, S3 keeps the parts (and may bill them).
	start_upload! : Bucket, Str, { content_type : Str } => Try(Str, [S3Err(Refusal), StorageErr(Str)])
	start_upload! = |bucket, key, opts| {
		answer = exchange!(bucket, { method: "POST", key, query: [{ name: "uploads", value: "" }], headers: [{ name: "content-type", value: opts.content_type }], body: [], hashed: Bool.True }, small)?
		if succeeded(answer) {
			match element(as_text(answer), "UploadId") {
				Ok(upload) if !upload.is_empty() => Ok(upload)
				_ => Err(StorageErr("S3 started an upload of ${key} without saying its id"))
			}
		} else {
			Err(S3Err(refusal(answer)))
		}
	}

	## Sends part `number` (1 to 10,000) of the upload `upload` of `key` (UploadPart): its ETag,
	## for `finish_upload!`. Every part but the last must be 5 MiB or more (S3 says so at
	## `finish_upload!`: `EntityTooSmall`); sending a number again replaces that part. The part
	## isn't hashed: it goes as `UNSIGNED-PAYLOAD` (TLS keeps it whole on the way). `NotFound` if
	## there is no such upload (finished, aborted, or never started).
	upload_part! : Bucket, Str, Str, U64, List(U8) => Try(Str, [NotFound, S3Err(Refusal), StorageErr(Str)])
	upload_part! = |bucket, key, upload, number, bytes| {
		query = [{ name: "partNumber", value: number.to_str() }, { name: "uploadId", value: upload }]
		answer = exchange!(bucket, { method: "PUT", key, query, headers: [], body: bytes, hashed: Bool.False }, sending)?
		if succeeded(answer) {
			match header(answer, "etag") {
				Ok(etag) => Ok(unquoted(etag))
				Err(Missing) => Err(StorageErr("S3 took part ${number.to_str()} of ${key} without giving its ETag"))
			}
		} else {
			Err(not_found_or(refusal(answer)))
		}
	}

	## Makes the parts listed (each its number and the ETag `upload_part!` gave; in any order) the
	## object `key` (CompleteMultipartUpload). A part not listed is dropped. An `<Error>` in S3's
	## 200 (it may fail after it has started answering) is an error like any other. `NotFound` if
	## there is no such upload.
	finish_upload! : Bucket, Str, Str, List({ number : U64, etag : Str }) => Try({}, [NotFound, S3Err(Refusal), StorageErr(Str)])
	finish_upload! = |bucket, key, upload, parts| {
		body = completion(parts).to_utf8()
		answer = exchange!(bucket, { method: "POST", key, query: [{ name: "uploadId", value: upload }], headers: [{ name: "content-type", value: "application/xml" }], body, hashed: Bool.True }, sending)?
		if succeeded(answer) and !as_text(answer).contains("<Error>") {
			Ok({})
		} else {
			Err(not_found_or(refusal(answer)))
		}
	}

	## Forgets the upload `upload` of `key` and the parts sent so far (AbortMultipartUpload). One
	## that isn't there (finished, aborted already) is `Ok`, as `delete!` is.
	abort_upload! : Bucket, Str, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	abort_upload! = |bucket, key, upload| {
		answer = exchange!(bucket, { method: "DELETE", key, query: [{ name: "uploadId", value: upload }], headers: [], body: [], hashed: Bool.True }, small)?
		if succeeded(answer) or refusal(answer).code == "NoSuchUpload" {
			Ok({})
		} else {
			Err(S3Err(refusal(answer)))
		}
	}

	## The object `key` as the answer to `request` (a `Server.Request`): the server fetches it from
	## S3 and sends it on as it comes, never through Roc (a `Forward`, as `Server.forward` makes),
	## so it may be any size. S3's status is the answer's: 200; 206 for the request's `Range`,
	## which is passed on, with `If-Range`, `If-None-Match` and `If-Modified-Since` (as the request
	## record has them, so an app may drop or change a range before it asks; with none, none are
	## sent); 304; 404 for an object that isn't there. With it come the object's length, range, ETag
	## and last modified time, and `content_type` (S3's, if empty) and `cache_control` (none, if
	## empty). A HEAD asks S3 for the headers alone. An empty key is a 404: no object has one.
	serve! : Bucket, Str, { method : Str, headers : List(Pair), ..request }, { content_type : Str, cache_control : Str } => { status : U16, headers : List(Pair), body : [Forward({ method : Str, url : Str, headers : List(Pair) }), Text(Str), ..others] }
	serve! = |bucket, key, request, opts| {
		if key.is_empty() {
			return { status: 404, headers: [{ name: "content-type", value: "text/plain; charset=utf-8" }], body: Text("Not found.") }
		}
		method = if (request.method == "HEAD") "HEAD" else "GET"
		signed = SigV4.sign(bucket.config.credentials, (bucket.now!)({}), { method, origin: bucket.config.origin, path: path_of(bucket.config, key), query: [], headers: [], payload: Signed([]) })
		given = [{ name: "content-type", value: opts.content_type }, { name: "cache-control", value: opts.cache_control }]
		upstream = { method, url: signed.url, headers: signed.headers.concat(passed_on(request.headers)) }
		{ status: 200, headers: given.keep_if(|each| !each.value.is_empty()), body: Forward(upstream) }
	}

	## A URL anyone may use, until `expires_s` seconds from now, to make the request `method`
	## (`GET`, `PUT`, …) of the object `key`, with no keys of their own: a presigned URL (query
	## authentication). Only the host is signed, so a presigned PUT may send any content type.
	## `BadExpiry` unless `expires_s` is 1 to 604,800 (a week: S3's limit). Nothing is asked of S3.
	signed_url! : Bucket, Str, { method : Str, expires_s : U64 } => Try(Str, [BadExpiry, StorageErr(Str)])
	signed_url! = |bucket, key, opts| {
		located(key)?
		presigned = SigV4.presign(bucket.config.credentials, (bucket.now!)({}), { method: opts.method, origin: bucket.config.origin, path: path_of(bucket.config, key), query: [], expires_s: opts.expires_s })
		match presigned {
			Ok(url) => Ok(url)
			Err(BadExpiry) => Err(BadExpiry)
		}
	}

	## Whether S3 answers, with these keys, for this bucket: it asks for an object that isn't there
	## (`rocx-storage-check`), so a wrong URL shows when an app starts, or in its health check, not
	## at the first upload. `Ok` if S3 answered (that there is no such object, or with it).
	check! : Bucket => Try({}, [S3Err(Refusal), StorageErr(Str)])
	check! = |bucket|
		match S3.get!(bucket, "rocx-storage-check") {
			Ok(_) | Err(NotFound) => Ok({})
			Err(S3Err(refused)) => Err(S3Err(refused))
			Err(StorageErr(why)) => Err(StorageErr(why))
		}

	## A refusal as one line: `403 SignatureDoesNotMatch: …`.
	said : Refusal -> Str
	said = |refused| {
		code = if (refused.code.is_empty()) "" else " ${refused.code}"
		"${refused.status.to_str()}${code}: ${refused.message}"
	}

	## The URL read (`from_url` reads it this way): exposed for the expects, and for an app that checks
	## its setting without making a bucket.
	parse : Str -> Try(Config, Str)
	parse = |text| {
		if !text.starts_with("s3://") {
			return Err("the S3 URL: s3://KEY:SECRET@HOST/BUCKET?region=…")
		}
		rest = text.drop_prefix("s3://")
		# The secret may have a `/`, a `?` or an `@` in it: the keys end at the last `@`.
		(user_info, located_at) =
			match rest.split_last("@") {
				Ok({ before, after }) => (before, after)
				Err(_) => ("", rest)
			}
		(access_key, secret_key) =
			match user_info.split_first(":") {
				Ok({ before, after }) => (percent_decoded(before), percent_decoded(after))
				Err(_) => (percent_decoded(user_info), "")
			}
		(place, query) =
			match located_at.split_first("?") {
				Ok({ before, after }) => (before, after)
				Err(_) => (located_at, "")
			}
		(authority, bucket_name) =
			match place.split_first("/") {
				Ok({ before, after }) => (before, after.drop_suffix("/"))
				Err(_) => (place, "")
			}
		params = query.split_on("&").keep_if(|pair| !pair.is_empty()).map(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => { name: before, value: percent_decoded(after) }
					Err(_) => { name: pair, value: "" }
				},
		)
		match params.find_first(|param| !["region", "style", "tls"].contains(param.name)) {
			Ok(unknown) => return Err("the S3 URL: ${unknown.name} isn't one of its parameters (region, style, tls)")
			Err(_) => {}
		}
		given = |name, default|
			match params.find_first(|param| param.name == name) {
				Ok(found) => found.value
				Err(_) => default
			}
		region = given("region", "us-east-1")
		style = given("style", "virtual")
		tls = given("tls", "yes")
		if access_key.is_empty() or secret_key.is_empty() {
			return Err("the S3 URL: no keys (s3://KEY:SECRET@HOST/BUCKET)")
		}
		if authority.is_empty() {
			return Err("the S3 URL: no host")
		}
		if bucket_name.is_empty() or bucket_name.contains("/") {
			return Err("the S3 URL: the path is the bucket, one name (s3://KEY:SECRET@HOST/BUCKET)")
		}
		scheme =
			match tls {
				"yes" => "https"
				"no" => "http"
				_ => return Err("the S3 URL: tls is yes or no, not ${tls}")
			}
		credentials = { access_key, secret_key, region }
		match style {
			"path" => Ok({ credentials, origin: "${scheme}://${authority}", bucket_path: "/${bucket_name}" })
			"virtual" => Ok({ credentials, origin: "${scheme}://${bucket_name}.${authority}", bucket_path: "" })
			_ => Err("the S3 URL: style is path or virtual, not ${style}")
		}
	}
}

## A key S3 can be asked about: `/BUCKET/` is the bucket itself, and deleting it would be another
## request altogether.
located : Str -> Try({}, [StorageErr(Str)])
located = |key| if (key.is_empty()) Err(StorageErr("an object's key can't be empty")) else Ok({})

path_of : S3.Config, Str -> Str
path_of = |config, key| "${config.bucket_path}/${key}"

## A request to S3 about an object: what is signed, and its body (its SHA-256 signed if `hashed`;
## `UNSIGNED-PAYLOAD` if not).
Exchange : { method : Str, key : Str, query : List(S3.Pair), headers : List(S3.Pair), body : List(U8), hashed : Bool }

asked : Str, Str -> Exchange
asked = |method, key| { method, key, query: [], headers: [], body: [], hashed: Bool.True }

## Signs `request` now and sends it, as `opts` allows: S3's answer, whatever its status.
exchange! : S3.Bucket, Exchange, S3.Opts => Try(S3.Response, [StorageErr(Str)])
exchange! = |bucket, request, opts| {
	located(request.key)?
	signed = SigV4.sign(
		bucket.config.credentials,
		(bucket.now!)({}),
		{
			method: request.method,
			origin: bucket.config.origin,
			path: path_of(bucket.config, request.key),
			query: request.query,
			headers: request.headers,
			payload: if (request.hashed) Signed(request.body) else Unsigned,
		},
	)
	doing = "${request.method} ${request.key}"
	match (bucket.send!)({ method: request.method, url: signed.url, headers: signed.headers, body: request.body }, opts) {
		Ok(answer) => Ok(answer)
		Err(HttpErr(why)) => Err(StorageErr("${doing}: no answer from S3: ${why}"))
		Err(TimedOut) => Err(StorageErr("${doing}: S3 didn't answer within ${(opts.timeout_ms // 1000).to_str()} s"))
		Err(TooLarge) => Err(StorageErr("${doing}: S3's answer is larger than ${(opts.max_bytes // 1_048_576).to_str()} MiB"))
	}
}

## A request with no body to speak of, and a small answer: 30 s, 1 MiB.
small : S3.Opts
small = { timeout_ms: 30_000, max_bytes: 1_048_576, follow_redirects: Bool.False }

## A request that sends a body (an object, a part): 5 minutes.
sending : S3.Opts
sending = { ..small, timeout_ms: 300_000 }

## A request whose answer is an object: 5 minutes, 64 MiB.
reading : S3.Opts
reading = { ..sending, max_bytes: 67_108_864 }

succeeded : S3.Response -> Bool
succeeded = |answer| answer.status >= 200 and answer.status < 300

## The first header called `name` (in any case).
header : S3.Response, Str -> Try(Str, [Missing])
header = |answer, name| {
	wanted = name.with_ascii_lowercased()
	match answer.headers.find_first(|each| each.name.with_ascii_lowercased() == wanted) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(Missing)
	}
}

## The body as UTF-8 (lossy).
as_text : S3.Response -> Str
as_text = |answer| Str.from_utf8_lossy(answer.body)

## What a forwarded GET or HEAD passes on of the request: its `Range`, `If-Range`, `If-None-Match`
## and `If-Modified-Since`, as the request has them (none it hasn't).
passed_on : List(S3.Pair) -> List(S3.Pair)
passed_on = |headers| headers.keep_if(|each| ["range", "if-range", "if-none-match", "if-modified-since"].contains(each.name.with_ascii_lowercased()))

## What S3 said, from its `<Error>`; or, with none, what came.
refusal : S3.Response -> S3.Refusal
refusal = |answer| {
	body = as_text(answer)
	match element(body, "Code") {
		Ok(code) => { status: answer.status, code, message: element(body, "Message") ?? "" }
		Err(Missing) => {
			came = if (body.trim().is_empty()) "no body" else Str.from_utf8_lossy(body.to_utf8().take_first(200))
			{ status: answer.status, code: "", message: "HTTP ${answer.status.to_str()}, ${came}" }
		}
	}
}

## A refusal that says the object (or the upload) isn't there is `NotFound`.
not_found_or = |refused| if (refused.code == "NoSuchKey" or refused.code == "NoSuchUpload") NotFound else S3Err(refused)

## The text of the first `<name>` element: what S3's XML answers are read for (`Code`, `Message`,
## `UploadId`).
element : Str, Str -> Try(Str, [Missing])
element = |xml, name|
	match xml.split_first("<${name}>") {
		Ok({ after, .. }) =>
			match after.split_first("</${name}>") {
				Ok({ before, .. }) => Ok(unescaped(before))
				Err(_) => Err(Missing)
			}
		Err(_) => Err(Missing)
	}

unescaped : Str -> Str
unescaped = |xml| xml.replace_each("&lt;", "<").replace_each("&gt;", ">").replace_each("&quot;", "\"").replace_each("&apos;", "'").replace_each("&#34;", "\"").replace_each("&#39;", "'").replace_each("&amp;", "&")

escaped : Str -> Str
escaped = |xml| xml.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;")

## CompleteMultipartUpload's body: the parts in order of their numbers.
completion : List({ number : U64, etag : Str }) -> Str
completion = |parts| {
	sorted = parts.sort_with(|left, right| if (left.number < right.number) Before else if (left.number > right.number) After else Same)
	listed = Str.join_with(sorted.map(|part| "<Part><PartNumber>${part.number.to_str()}</PartNumber><ETag>\"${escaped(part.etag)}\"</ETag></Part>"), "")
	"<CompleteMultipartUpload>${listed}</CompleteMultipartUpload>"
}

## An ETag without the quotes S3 puts around it.
unquoted : Str -> Str
unquoted = |etag| if (etag.starts_with("\"") and etag.ends_with("\"") and etag.count_utf8_bytes() >= 2) etag.drop_prefix("\"").drop_suffix("\"") else etag

## The whole size from a `content-range` (`bytes 0-9/1234`).
whole_size : Str -> Try(U64, [Unknown])
whole_size = |range|
	match range.split_last("/") {
		Ok({ after, .. }) =>
			match U64.from_str(after) {
				Ok(size) => Ok(size)
				Err(_) => Err(Unknown)
			}
		Err(_) => Err(Unknown)
	}

## A URL's part as the text it stands for: `%XX` decoded (anything else, `%` too, as it is).
percent_decoded : Str -> Str
percent_decoded = |encoded| {
	bytes = encoded.to_utf8()
	var $out = []
	var $at = 0.U64
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		decoded =
			if byte == '%' {
				match (hex_value(bytes.get($at + 1) ?? 0), hex_value(bytes.get($at + 2) ?? 0)) {
					(Ok(high), Ok(low)) => Ok(high * 16 + low)
					_ => Err(NotEscaped)
				}
			} else {
				Err(NotEscaped)
			}
		match decoded {
			Ok(value) => {
				$out = $out.append(value)
				$at = $at + 3
			}
			Err(_) => {
				$out = $out.append(byte)
				$at = $at + 1
			}
		}
	}
	Str.from_utf8_lossy($out)
}

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |digit|
	if digit >= '0' and digit <= '9' {
		Ok(digit - '0')
	} else if digit >= 'a' and digit <= 'f' {
		Ok(digit - 'a' + 10)
	} else if digit >= 'A' and digit <= 'F' {
		Ok(digit - 'A' + 10)
	} else {
		Err(NotHex)
	}

local : S3.Config
local = { credentials: { access_key: "rocx", secret_key: "secret/with+odd@chars", region: "us-east-1" }, origin: "http://127.0.0.1:9000", bucket_path: "/uploads" }

expect S3.parse("s3://rocx:secret/with+odd@chars@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no") == Ok(local)
expect S3.parse("s3://rocx:secret%2Fwith%2Bodd%40chars@127.0.0.1:9000/uploads/?style=path&tls=no") == Ok(local)
expect S3.parse("s3://KEY:SECRET@acc.r2.cloudflarestorage.com/uploads?region=auto") == Ok({ credentials: { access_key: "KEY", secret_key: "SECRET", region: "auto" }, origin: "https://uploads.acc.r2.cloudflarestorage.com", bucket_path: "" })
expect S3.parse("s3://KEY:SECRET@s3.eu-west-1.amazonaws.com/b?region=eu-west-1").map_ok(|config| config.origin) == Ok("https://b.s3.eu-west-1.amazonaws.com")
expect S3.parse("https://KEY:SECRET@host/b").is_err()
expect S3.parse("s3://KEY:SECRET@host/b?regoin=x") == Err("the S3 URL: regoin isn't one of its parameters (region, style, tls)")
expect S3.parse("s3://KEY:SECRET@host/b?tls=maybe").is_err()
expect S3.parse("s3://KEY:SECRET@host/b?style=sideways").is_err()
expect S3.parse("s3://KEY:SECRET@host").is_err()
expect S3.parse("s3://KEY:SECRET@host/a/b").is_err()
expect S3.parse("s3://host/b").is_err()
expect S3.from_url("", { send!: |_, _| Err(TimedOut), now!: |{}| 0 }).is_err()
expect S3.from_url("s3://KEY:SECRET@host/b?tls=maybe", { send!: |_, _| Err(TimedOut), now!: |{}| 0 }).map_ok(|made| made.config) == Err(StorageErr("the S3 URL: tls is yes or no, not maybe"))
expect element("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code><Message>The key &amp; &lt;all&gt;</Message></Error>", "Message") == Ok("The key & <all>")
expect element("<Error></Error>", "Code") == Err(Missing)
expect refusal({ status: 403, headers: [], body: "<Error><Code>SignatureDoesNotMatch</Code><Message>No.</Message></Error>".to_utf8() }) == { status: 403, code: "SignatureDoesNotMatch", message: "No." }
expect refusal({ status: 403, headers: [], body: [] }) == { status: 403, code: "", message: "HTTP 403, no body" }
expect not_found_or({ status: 404, code: "NoSuchKey", message: "" }) == NotFound
expect not_found_or({ status: 404, code: "NoSuchBucket", message: "" }) == S3Err({ status: 404, code: "NoSuchBucket", message: "" })
expect S3.said({ status: 403, code: "AccessDenied", message: "No." }) == "403 AccessDenied: No."
expect S3.said({ status: 502, code: "", message: "HTTP 502, no body" }) == "502: HTTP 502, no body"
expect completion([{ number: 2, etag: "b" }, { number: 1, etag: "a" }]) == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"b\"</ETag></Part></CompleteMultipartUpload>"
expect unquoted("\"9b2cf535f27731c974343645a3985328\"") == "9b2cf535f27731c974343645a3985328"
expect whole_size("bytes 0-9/1234") == Ok(1234)
expect path_of(local, "videos/41") == "/uploads/videos/41"
expect passed_on([{ name: "range", value: "bytes=0-9" }, { name: "Cookie", value: "a=b" }, { name: "If-None-Match", value: "\"x\"" }]) == [{ name: "range", value: "bytes=0-9" }, { name: "If-None-Match", value: "\"x\"" }]
expect percent_decoded("a%2Fb%zz%") == "a/b%zz%"
