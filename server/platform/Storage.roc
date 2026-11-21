import Http
import Log
import S3Sign
import Server
import Setting
import Time

## Files kept in S3: rustfs or MinIO in development, R2, AWS or any other S3 in production. Where,
## and with which keys, is the server's `--storage-url` (or `STORAGE_URL`):
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
## Requests are signed here (SigV4, `S3Sign`) and sent with `Http`, waiting on the call's thread.
## A key is an object's name in the bucket, `/`s and all (`videos/41`); bytes are `List(U8)`, read
## and sent whole: `get_range!` reads a large object a piece at a time, and `serve!` answers a
## request with one of any size, streamed by the server, never read into Roc. Every operation but
## `signed_url!` is a request to S3, and may fail with `S3Err` (S3 answered, refusing: its status
## and its `<Error>`'s code and message) or `StorageErr` (no answer, or no `--storage-url`).
Storage := [].{

	## What S3 said when it refused: its status, and its `<Error>`'s `Code` and `Message`
	## (`AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`, `NoSuchBucket`,
	## `EntityTooSmall`, `InvalidPart`, …). An answer without one (a HEAD's, a proxy's) has an empty
	## code, and a message saying what came.
	Refusal : { status : U16, code : Str, message : Str }

	## An object's size in bytes, its content type, and its ETag (without its quotes).
	Info : { size : U64, content_type : Str, etag : Str }

	## Keeps `bytes` as the object `key`, replacing any there was (PutObject). Its SHA-256 is
	## signed, so S3 refuses it if anything changed on the way.
	put! : Str, List(U8), { content_type : Str } => Try({}, [S3Err(Refusal), StorageErr(Str)])
	put! = |key, bytes, opts| {
		config = configured!(key)?
		answer = exchange!(config, { method: "PUT", key, query: [], headers: [{ name: "content-type", value: opts.content_type }], body: bytes, hashed: Bool.True }, sending)?
		if (succeeded(answer)) Ok({}) else Err(S3Err(refusal(answer)))
	}

	## The object `key`, whole (GetObject): 64 MiB at most (`StorageErr` beyond; `get_range!`
	## reads it in pieces). `NotFound` if there is none.
	get! : Str => Try(List(U8), [NotFound, S3Err(Refusal), StorageErr(Str)])
	get! = |key| {
		config = configured!(key)?
		answer = exchange!(config, asked("GET", key), reading)?
		if (succeeded(answer)) Ok(answer.body) else Err(not_found_or(refusal(answer)))
	}

	## `length` bytes of the object `key` from `offset` (fewer at its end), and its whole size
	## (GetObject with `Range`). An `offset` at or past its end is S3's `InvalidRange`; a `length`
	## of 0 is no bytes, and the size.
	get_range! : Str, { offset : U64, length : U64 } => Try({ bytes : List(U8), size : U64 }, [NotFound, S3Err(Refusal), StorageErr(Str)])
	get_range! = |key, range| {
		if range.length == 0 {
			info = Storage.head!(key)?
			return Ok({ bytes: [], size: info.size })
		}
		config = configured!(key)?
		wanted = "bytes=${range.offset.to_str()}-${(range.offset + (range.length - 1)).to_str()}"
		answer = exchange!(config, { ..asked("GET", key), headers: [{ name: "range", value: wanted }] }, { ..reading, max_bytes: U64.max(range.length, small.max_bytes) })?
		if answer.status == 206 {
			Ok({ bytes: answer.body, size: whole_size(Http.header(answer, "content-range") ?? "") ?? (range.offset + answer.body.len()) })
		} else if answer.status == 200 {
			# A server that ignored the range: the whole object came.
			Ok({ bytes: answer.body.drop_first(range.offset).take_first(range.length), size: answer.body.len() })
		} else {
			Err(not_found_or(refusal(answer)))
		}
	}

	## The object's size, content type and ETag, without its bytes (HeadObject). `NotFound` if
	## there is none; a HEAD's answer has no body, so a 404 is that even when it is the bucket
	## that's missing (the check at start says which).
	head! : Str => Try(Info, [NotFound, S3Err(Refusal), StorageErr(Str)])
	head! = |key| {
		config = configured!(key)?
		answer = exchange!(config, asked("HEAD", key), small)?
		if succeeded(answer) {
			Ok({
				size: U64.from_str(Http.header(answer, "content-length") ?? "") ?? 0,
				content_type: Http.header(answer, "content-type") ?? "",
				etag: unquoted(Http.header(answer, "etag") ?? ""),
			})
		} else if answer.status == 404 {
			Err(NotFound)
		} else {
			Err(S3Err(refusal(answer)))
		}
	}

	## Deletes the object `key` (DeleteObject). One that isn't there is deleted already: `Ok`.
	delete! : Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	delete! = |key| {
		config = configured!(key)?
		answer = exchange!(config, asked("DELETE", key), small)?
		if (succeeded(answer)) Ok({}) else Err(S3Err(refusal(answer)))
	}

	## Starts a multipart upload of the object `key` (CreateMultipartUpload): its upload id. Its
	## parts are sent with `upload_part!`, then `finish_upload!` makes them the object, or
	## `abort_upload!` forgets them. Until one of those, S3 keeps the parts (and may bill them).
	start_upload! : Str, { content_type : Str } => Try(Str, [S3Err(Refusal), StorageErr(Str)])
	start_upload! = |key, opts| {
		config = configured!(key)?
		answer = exchange!(config, { method: "POST", key, query: [{ name: "uploads", value: "" }], headers: [{ name: "content-type", value: opts.content_type }], body: [], hashed: Bool.True }, small)?
		if succeeded(answer) {
			match element(Http.text(answer), "UploadId") {
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
	upload_part! : Str, Str, U64, List(U8) => Try(Str, [NotFound, S3Err(Refusal), StorageErr(Str)])
	upload_part! = |key, upload, number, bytes| {
		config = configured!(key)?
		query = [{ name: "partNumber", value: number.to_str() }, { name: "uploadId", value: upload }]
		answer = exchange!(config, { method: "PUT", key, query, headers: [], body: bytes, hashed: Bool.False }, sending)?
		if succeeded(answer) {
			match Http.header(answer, "etag") {
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
	finish_upload! : Str, Str, List({ number : U64, etag : Str }) => Try({}, [NotFound, S3Err(Refusal), StorageErr(Str)])
	finish_upload! = |key, upload, parts| {
		config = configured!(key)?
		body = completion(parts).to_utf8()
		answer = exchange!(config, { method: "POST", key, query: [{ name: "uploadId", value: upload }], headers: [{ name: "content-type", value: "application/xml" }], body, hashed: Bool.True }, sending)?
		if succeeded(answer) and !Http.text(answer).contains("<Error>") {
			Ok({})
		} else {
			Err(not_found_or(refusal(answer)))
		}
	}

	## Forgets the upload `upload` of `key` and the parts sent so far (AbortMultipartUpload). One
	## that isn't there (finished, aborted already) is `Ok`, as `delete!` is.
	abort_upload! : Str, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	abort_upload! = |key, upload| {
		config = configured!(key)?
		answer = exchange!(config, { method: "DELETE", key, query: [{ name: "uploadId", value: upload }], headers: [], body: [], hashed: Bool.True }, small)?
		if succeeded(answer) or refusal(answer).code == "NoSuchUpload" {
			Ok({})
		} else {
			Err(S3Err(refusal(answer)))
		}
	}

	## The object `key` as the answer to `request`: the server fetches it from S3 and sends it on as
	## it comes, never through Roc (`Server.forward`), so it may be any size. S3's status is the
	## answer's: 200; 206 for the request's `Range`, which is passed on, with `If-Range`,
	## `If-None-Match` and `If-Modified-Since` (`Server.passed_on`: as the request record has them,
	## so an app may drop or change a range before it asks; with none, none are sent); 304; 404 for
	## an object that isn't there. With it come
	## the object's length, range, ETag and last modified time, and `content_type` (S3's, if empty)
	## and `cache_control` (none, if empty). A HEAD asks S3 for the headers alone. No
	## `--storage-url`, or an empty key, is a 500, and the log says why.
	serve! : Str, Server.Request, { content_type : Str, cache_control : Str } => Server.Response
	serve! = |key, request, opts|
		match configured!(key) {
			Err(StorageErr(why)) => {
				Log.line!("rocx storage: ${why}")
				Server.refused(500, "Something went wrong.")
			}
			Ok(config) => {
				method = if (request.method == "HEAD") "HEAD" else "GET"
				signed = S3Sign.sign(config.credentials, Time.now_millis!({}), { method, origin: config.origin, path: path_of(config, key), query: [], headers: [], payload: Signed([]) })
				given = [{ name: "content-type", value: opts.content_type }, { name: "cache-control", value: opts.cache_control }]
				Server.forward({ method, url: signed.url, headers: signed.headers.concat(Server.passed_on(request)) }, given.keep_if(|header| !header.value.is_empty()))
			}
		}

	## A URL anyone may use, until `expires_s` seconds from now, to make the request `method`
	## (`GET`, `PUT`, …) of the object `key`, with no keys of their own: a presigned URL (query
	## authentication). Only the host is signed, so a presigned PUT may send any content type.
	## `BadExpiry` unless `expires_s` is 1 to 604,800 (a week: S3's limit). Nothing is asked of S3.
	signed_url! : Str, { method : Str, expires_s : U64 } => Try(Str, [BadExpiry, StorageErr(Str)])
	signed_url! = |key, opts| {
		config = configured!(key)?
		presigned = S3Sign.presign(config.credentials, Time.now_millis!({}), { method: opts.method, origin: config.origin, path: path_of(config, key), query: [], expires_s: opts.expires_s })
		match presigned {
			Ok(url) => Ok(url)
			Err(BadExpiry) => Err(BadExpiry)
		}
	}

	## Says on the log whether S3 answers, with these keys, for this bucket (it asks for an object
	## that isn't there): a wrong `--storage-url` shows when the server starts, not at the first
	## upload.
	check! : {} => {}
	check! = |{}|
		match Storage.get!("rocx-storage-check") {
			Ok(_) | Err(NotFound) => Log.line!("rocx storage: S3 answers, and the bucket is there")
			Err(S3Err(refused)) => Log.line!("rocx storage: S3 refused: ${said(refused)}")
			Err(StorageErr(why)) => Log.line!("rocx storage: ${why}")
		}

	## `--storage-url` read: the keys and the region; the origin requests go to; the path an object's
	## key goes under (`/BUCKET` path-style, nothing virtual-hosted). Exposed for the expects.
	parse : Str -> Try({ credentials : S3Sign.Credentials, origin : Str, bucket_path : Str }, Str)
	parse = |text| {
		if !text.starts_with("s3://") {
			return Err("--storage-url: s3://KEY:SECRET@HOST/BUCKET?region=…")
		}
		rest = text.drop_prefix("s3://")
		# The secret may have a `/`, a `?` or an `@` in it: the keys end at the last `@`.
		(user_info, located) =
			match rest.split_last("@") {
				Ok({ before, after }) => (before, after)
				Err(_) => ("", rest)
			}
		(access_key, secret_key) =
			match user_info.split_first(":") {
				Ok({ before, after }) => (Server.decode_segment(before), Server.decode_segment(after))
				Err(_) => (Server.decode_segment(user_info), "")
			}
		(place, query) =
			match located.split_first("?") {
				Ok({ before, after }) => (before, after)
				Err(_) => (located, "")
			}
		(authority, bucket) =
			match place.split_first("/") {
				Ok({ before, after }) => (before, after.drop_suffix("/"))
				Err(_) => (place, "")
			}
		params = query.split_on("&").keep_if(|pair| !pair.is_empty()).map(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => { name: before, value: Server.decode_segment(after) }
					Err(_) => { name: pair, value: "" }
				},
		)
		match params.find_first(|param| !["region", "style", "tls"].contains(param.name)) {
			Ok(unknown) => return Err("--storage-url: ${unknown.name} isn't one of its parameters (region, style, tls)")
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
			return Err("--storage-url: no keys (s3://KEY:SECRET@HOST/BUCKET)")
		}
		if authority.is_empty() {
			return Err("--storage-url: no host")
		}
		if bucket.is_empty() or bucket.contains("/") {
			return Err("--storage-url: the path is the bucket, one name (s3://KEY:SECRET@HOST/BUCKET)")
		}
		scheme =
			match tls {
				"yes" => "https"
				"no" => "http"
				_ => return Err("--storage-url: tls is yes or no, not ${tls}")
			}
		credentials = { access_key, secret_key, region }
		match style {
			"path" => Ok({ credentials, origin: "${scheme}://${authority}", bucket_path: "/${bucket}" })
			"virtual" => Ok({ credentials, origin: "${scheme}://${bucket}.${authority}", bucket_path: "" })
			_ => Err("--storage-url: style is path or virtual, not ${style}")
		}
	}
}

## The server's storage, for a request about `key`.
configured! : Str => Try({ credentials : S3Sign.Credentials, origin : Str, bucket_path : Str }, [StorageErr(Str)])
configured! = |key| {
	given = Setting.text!("storage-url")
	if given.is_empty() {
		Err(StorageErr("no storage: start the server with --storage-url (or STORAGE_URL)"))
	} else if key.is_empty() {
		# `/BUCKET/` is the bucket itself: deleting it would be another request altogether.
		Err(StorageErr("an object's key can't be empty"))
	} else {
		match Storage.parse(given) {
			Ok(config) => Ok(config)
			Err(why) => Err(StorageErr(why))
		}
	}
}

path_of : { credentials : S3Sign.Credentials, origin : Str, bucket_path : Str }, Str -> Str
path_of = |config, key| "${config.bucket_path}/${key}"

## A request to S3 about an object: what is signed, and its body (its SHA-256 signed if `hashed`;
## `UNSIGNED-PAYLOAD` if not).
Exchange : { method : Str, key : Str, query : List(S3Sign.Pair), headers : List(S3Sign.Pair), body : List(U8), hashed : Bool }

asked : Str, Str -> Exchange
asked = |method, key| { method, key, query: [], headers: [], body: [], hashed: Bool.True }

## Signs `exchange` now and sends it, as `opts` allows: S3's answer, whatever its status.
exchange! : { credentials : S3Sign.Credentials, origin : Str, bucket_path : Str }, Exchange, Http.Opts => Try(Http.Response, [StorageErr(Str)])
exchange! = |config, request, opts| {
	signed = S3Sign.sign(
		config.credentials,
		Time.now_millis!({}),
		{
			method: request.method,
			origin: config.origin,
			path: path_of(config, request.key),
			query: request.query,
			headers: request.headers,
			payload: if (request.hashed) Signed(request.body) else Unsigned,
		},
	)
	doing = "${request.method} ${request.key}"
	match Http.send!({ method: request.method, url: signed.url, headers: signed.headers, body: request.body }, opts) {
		Ok(answer) => Ok(answer)
		Err(HttpErr(why)) => Err(StorageErr("${doing}: no answer from S3: ${why}"))
		Err(TimedOut) => Err(StorageErr("${doing}: S3 didn't answer within ${(opts.timeout_ms // 1000).to_str()} s"))
		Err(TooLarge) => Err(StorageErr("${doing}: S3's answer is larger than ${(opts.max_bytes // 1_048_576).to_str()} MiB"))
	}
}

## A request with no body to speak of, and a small answer: 30 s, 1 MiB.
small : Http.Opts
small = { timeout_ms: 30_000, max_bytes: 1_048_576, follow_redirects: Bool.False }

## A request that sends a body (an object, a part): 5 minutes.
sending : Http.Opts
sending = { ..small, timeout_ms: 300_000 }

## A request whose answer is an object: 5 minutes, 64 MiB.
reading : Http.Opts
reading = { ..sending, max_bytes: 67_108_864 }

succeeded : Http.Response -> Bool
succeeded = |answer| answer.status >= 200 and answer.status < 300

## What S3 said, from its `<Error>`; or, with none, what came.
refusal : Http.Response -> Storage.Refusal
refusal = |answer| {
	text = Http.text(answer)
	match element(text, "Code") {
		Ok(code) => { status: answer.status, code, message: element(text, "Message") ?? "" }
		Err(Missing) => {
			came = if (text.trim().is_empty()) "no body" else Str.from_utf8_lossy(text.to_utf8().take_first(200))
			{ status: answer.status, code: "", message: "HTTP ${answer.status.to_str()}, ${came}" }
		}
	}
}

## A refusal that says the object (or the upload) isn't there is `NotFound`.
not_found_or = |refused| if (refused.code == "NoSuchKey" or refused.code == "NoSuchUpload") NotFound else S3Err(refused)

said : Storage.Refusal -> Str
said = |refused| {
	code = if (refused.code.is_empty()) "" else " ${refused.code}"
	"${refused.status.to_str()}${code}: ${refused.message}"
}

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
unescaped = |text| text.replace_each("&lt;", "<").replace_each("&gt;", ">").replace_each("&quot;", "\"").replace_each("&apos;", "'").replace_each("&#34;", "\"").replace_each("&#39;", "'").replace_each("&amp;", "&")

escaped : Str -> Str
escaped = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;")

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

local : { credentials : S3Sign.Credentials, origin : Str, bucket_path : Str }
local = { credentials: { access_key: "rocx", secret_key: "secret/with+odd@chars", region: "us-east-1" }, origin: "http://127.0.0.1:9000", bucket_path: "/uploads" }

expect Storage.parse("s3://rocx:secret/with+odd@chars@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no") == Ok(local)
expect Storage.parse("s3://rocx:secret%2Fwith%2Bodd%40chars@127.0.0.1:9000/uploads/?style=path&tls=no") == Ok(local)
expect Storage.parse("s3://KEY:SECRET@acc.r2.cloudflarestorage.com/uploads?region=auto") == Ok({ credentials: { access_key: "KEY", secret_key: "SECRET", region: "auto" }, origin: "https://uploads.acc.r2.cloudflarestorage.com", bucket_path: "" })
expect Storage.parse("s3://KEY:SECRET@s3.eu-west-1.amazonaws.com/b?region=eu-west-1").map_ok(|config| config.origin) == Ok("https://b.s3.eu-west-1.amazonaws.com")
expect Storage.parse("https://KEY:SECRET@host/b").is_err()
expect Storage.parse("s3://KEY:SECRET@host/b?regoin=x") == Err("--storage-url: regoin isn't one of its parameters (region, style, tls)")
expect Storage.parse("s3://KEY:SECRET@host/b?tls=maybe").is_err()
expect Storage.parse("s3://KEY:SECRET@host/b?style=sideways").is_err()
expect Storage.parse("s3://KEY:SECRET@host").is_err()
expect Storage.parse("s3://KEY:SECRET@host/a/b").is_err()
expect Storage.parse("s3://host/b").is_err()
expect element("<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code><Message>The key &amp; &lt;all&gt;</Message></Error>", "Message") == Ok("The key & <all>")
expect element("<Error></Error>", "Code") == Err(Missing)
expect refusal({ status: 403, headers: [], body: "<Error><Code>SignatureDoesNotMatch</Code><Message>No.</Message></Error>".to_utf8() }) == { status: 403, code: "SignatureDoesNotMatch", message: "No." }
expect refusal({ status: 403, headers: [], body: [] }) == { status: 403, code: "", message: "HTTP 403, no body" }
expect not_found_or({ status: 404, code: "NoSuchKey", message: "" }) == NotFound
expect not_found_or({ status: 404, code: "NoSuchBucket", message: "" }) == S3Err({ status: 404, code: "NoSuchBucket", message: "" })
expect completion([{ number: 2, etag: "b" }, { number: 1, etag: "a" }]) == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"b\"</ETag></Part></CompleteMultipartUpload>"
expect unquoted("\"9b2cf535f27731c974343645a3985328\"") == "9b2cf535f27731c974343645a3985328"
expect whole_size("bytes 0-9/1234") == Ok(1234)
expect path_of(local, "videos/41") == "/uploads/videos/41"
