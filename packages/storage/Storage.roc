import pf.Blobs
import pf.Env
import pf.Http
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import crypto.Hex
import crypto.Hmac
import S3

## Files for a Roc Solid app (D-047): objects kept by key in a bucket, whose URL says where, its
## scheme the backend:
##
## - `s3://KEY:SECRET@HOST/BUCKET?region=…&style=path&tls=no`: any S3 (rustfs or MinIO, R2, AWS),
##   each operation a request to it, signed (`S3`, `SigV4`).
## - `file:<dir>` (`file:data/uploads`, from where the server starts; made when missing): files
##   beside the server, which the host keeps (`Blobs`), each written whole or not at all.
## - `memory:<name>` (`memory:` alone too): the server's memory, gone when it stops: for tests.
##
## A `file:` or `memory:` URL may give the secret its signed URLs are made with (`?secret=…`), so
## they outlive a restart; without one the server draws one when it starts.
##
##     bucket = Storage.from_url(Env.var!("STORAGE_URL") ?? "")?
##     Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
##
## A key is an object's name in the bucket, `/`s and all (`videos/41`); bytes are `List(U8)`, read
## and sent whole: `get_range!` reads a large object a piece at a time, and `serve!` answers a request
## with one of any size, sent by the server, never read into Roc. An operation may fail with `S3Err`
## (S3 answered, refusing: its status and its `<Error>`'s code and message) or `StorageErr` (no
## answer, a file that can't be written, a key that isn't one).
Storage := [].{

	## A bucket: an S3's, or one the host keeps (`file:`, `memory:`), with the secret its signed
	## URLs are made with ("": the server's own, drawn when it starts).
	Bucket : [S3(S3.Bucket), Kept({ root : Str, secret : Str })]

	## What S3 said when it refused: its status, and its `<Error>`'s code and message.
	Refusal : S3.Refusal

	## An object's size in bytes, its content type, and its ETag (without its quotes).
	Info : { size : U64, content_type : Str, etag : Str }

	## The bucket the URL `url` names (above). `StorageErr` says what is wrong with it (an empty one
	## too: no storage). Nothing is asked of it yet: `check!` asks.
	from_url : Str -> Try(Bucket, [StorageErr(Str)])
	from_url = |url| {
		(kind, _) = url.split_first(":").map_ok(|parts| (parts.before, parts.after)) ?? ("", "")
		match kind {
			"s3" =>
				match S3.from_url(url, { send!: Http.send!, now!: Time.now_millis! }) {
					Ok(bucket) => Ok(S3(bucket))
					Err(StorageErr(why)) => Err(StorageErr(why))
				}
			"file" | "memory" => {
				(root, query) = url.split_first("?").map_ok(|parts| (parts.before, parts.after)) ?? (url, "")
				if kind == "file" and (root == "file:" or root == "file://") {
					Err(StorageErr("file: needs a directory: file:data/uploads"))
				} else {
					Ok(Kept({ root, secret: param(query, "secret") }))
				}
			}
			"" => Err(StorageErr("no storage: no bucket URL (s3://…, file:<dir>, or memory:)"))
			_ => Err(StorageErr("a bucket's URL is s3://…, file:<dir> or memory:<name>, not ${kind}:…"))
		}
	}

	## Keeps `bytes` as the object `key`, replacing any there was.
	put! : Bucket, Str, List(U8), { content_type : Str } => Try({}, [S3Err(Refusal), StorageErr(Str)])
	put! = |bucket, key, bytes, opts|
		match bucket {
			S3(s3) => S3.put!(s3, key, bytes, opts)
			Kept(kept) => {
				located(key)?
				blob(Blobs.put!(kept.root, key, bytes, opts.content_type))
			}
		}

	## Keeps a file a form sent (`Server.file`, D-054) as the object `key`, its type the browser's
	## (`application/octet-stream` when it gave none). The platform reads a request's body whole
	## (`--max-body`), so the file is in memory; should the host one day keep a large one aside as it
	## comes, this is where it would be copied from there, and an app's call stays as it is.
	##
	##     match Server.file(request, "photo") {
	##         Ok(upload) => Storage.put_upload!(bucket, "photos/${id}", upload)?
	##         Err(NoFile) => return Err(BadRequest("no photo"))
	##     }
	put_upload! : Bucket, Str, Server.Upload => Try({}, [S3Err(Refusal), StorageErr(Str)])
	put_upload! = |bucket, key, upload| Storage.put!(bucket, key, upload.bytes, { content_type: if (upload.type.is_empty()) "application/octet-stream" else upload.type })

	## The object `key`, whole; `NotFound` if there is none.
	get! : Bucket, Str => Try(List(U8), [NotFound, S3Err(Refusal), StorageErr(Str)])
	get! = |bucket, key|
		match bucket {
			S3(s3) => S3.get!(s3, key)
			Kept(kept) => {
				located(key)?
				found(Blobs.get!(kept.root, key))
			}
		}

	## `length` bytes of the object `key` from `offset` (fewer at its end, none past it), and its
	## whole size; `NotFound` if there is none.
	get_range! : Bucket, Str, { offset : U64, length : U64 } => Try({ bytes : List(U8), size : U64 }, [NotFound, S3Err(Refusal), StorageErr(Str)])
	get_range! = |bucket, key, wanted|
		match bucket {
			S3(s3) => S3.get_range!(s3, key, wanted)
			Kept(kept) => {
				located(key)?
				found(Blobs.range!(kept.root, key, wanted))
			}
		}

	## The object `key`'s size, content type and ETag; `NotFound` if there is none.
	head! : Bucket, Str => Try(Info, [NotFound, S3Err(Refusal), StorageErr(Str)])
	head! = |bucket, key|
		match bucket {
			S3(s3) => S3.head!(s3, key)
			Kept(kept) => {
				located(key)?
				found(Blobs.head!(kept.root, key))
			}
		}

	## The object `key` gone; one that isn't there is `Ok`.
	delete! : Bucket, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	delete! = |bucket, key|
		match bucket {
			S3(s3) => S3.delete!(s3, key)
			Kept(kept) => {
				located(key)?
				blob(Blobs.delete!(kept.root, key))
			}
		}

	## Starts a multipart upload of the object `key`: its upload id. Its parts are sent with
	## `upload_part!`, then `finish_upload!` makes them the object, or `abort_upload!` forgets them.
	## (On S3, every part but the last must be 5 MiB or more.)
	start_upload! : Bucket, Str, { content_type : Str } => Try(Str, [S3Err(Refusal), StorageErr(Str)])
	start_upload! = |bucket, key, opts|
		match bucket {
			S3(s3) => S3.start_upload!(s3, key, opts)
			Kept(kept) => {
				located(key)?
				upload = Hex.encode(Random.bytes!(12))
				# What the upload is of, kept with its parts, for `finish_upload!`.
				blob(Blobs.put!(kept.root, part_key(upload, 0), "${key}\n${opts.content_type}".to_utf8(), "text/plain"))?
				Ok(upload)
			}
		}

	## Sends part `number` (1 to 10,000) of the upload `upload` of `key`: its ETag, for
	## `finish_upload!`. Sending a number again replaces that part. `NotFound` if there is no such
	## upload (finished, aborted, or never started).
	upload_part! : Bucket, Str, Str, U64, List(U8) => Try(Str, [NotFound, S3Err(Refusal), StorageErr(Str)])
	upload_part! = |bucket, key, upload, number, bytes|
		match bucket {
			S3(s3) => S3.upload_part!(s3, key, upload, number, bytes)
			Kept(kept) => {
				_ = started!(kept.root, upload, key)?
				blob(Blobs.put!(kept.root, part_key(upload, number), bytes, "application/octet-stream"))?
				info = found(Blobs.head!(kept.root, part_key(upload, number)))?
				Ok(info.etag)
			}
		}

	## Makes the parts listed (each its number and the ETag `upload_part!` gave; in any order) the
	## object `key`; a part not listed is dropped. `NotFound` if there is no such upload.
	finish_upload! : Bucket, Str, Str, List({ number : U64, etag : Str }) => Try({}, [NotFound, S3Err(Refusal), StorageErr(Str)])
	finish_upload! = |bucket, key, upload, parts|
		match bucket {
			S3(s3) => S3.finish_upload!(s3, key, upload, parts)
			Kept(kept) => {
				content_type = started!(kept.root, upload, key)?
				sorted = parts.sort_with(|one, other| if (one.number < other.number) Before else if (one.number > other.number) After else Same)
				# Each part listed is the one sent with that number, as S3 checks (`InvalidPart`).
				for part in sorted {
					match Blobs.head!(kept.root, part_key(upload, part.number)) {
						Ok(info) if info.etag == part.etag => {}
						Ok(_) | Err(NotFound) => return Err(StorageErr("InvalidPart: part ${part.number.to_str()} of ${key} isn't one sent with that ETag"))
						Err(BlobErr(why)) => return Err(StorageErr(why))
					}
				}
				found(Blobs.compose!(kept.root, sorted.map(|part| part_key(upload, part.number)), key, content_type))?
				forgotten!(kept.root, upload)
			}
		}

	## Forgets the upload `upload` of `key` and the parts sent so far. One that isn't there
	## (finished, aborted already) is `Ok`, as `delete!` is.
	abort_upload! : Bucket, Str, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])
	abort_upload! = |bucket, key, upload|
		match bucket {
			S3(s3) => S3.abort_upload!(s3, key, upload)
			Kept(kept) => forgotten!(kept.root, upload)
		}

	## The object `key` as the answer to `request`, sent by the server, never read into Roc, so it
	## may be any size: 200, 206 for the request's `Range`, 304 for one it has, 404 for an object that
	## isn't there; with its length, ETag and last modified time, and `content_type` (the object's,
	## if empty) and `cache_control` (none, if empty). From S3, the server fetches it and sends it on
	## (`Server.forward`); from `file:` and `memory:`, it sends what it keeps (`Server.stored`).
	serve! : Bucket, Str, Server.Request, { content_type : Str, cache_control : Str } => Server.Response
	serve! = |bucket, key, request, opts|
		match bucket {
			S3(s3) => {
				answer = S3.serve!(s3, key, request, opts)
				match answer.body {
					Forward(upstream) => Server.forward(upstream, answer.headers)
					Text(text) => Server.response(answer.status, answer.headers, text)
				}
			}
			Kept(kept) =>
				if key.is_empty() {
					Server.response(404, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "Not found.")
				} else {
					given = [{ name: "content-type", value: opts.content_type }, { name: "cache-control", value: opts.cache_control }]
					Server.stored(kept.root, key, request, given.keep_if(|each| !each.value.is_empty()))
				}
		}

	## A URL anyone may use, until `expires_s` seconds from now, to make the request `method` (`GET`
	## or `PUT`) of the object `key`. On S3 it is S3's (presigned: only the host is signed, so a PUT
	## may send any content type). On `file:` and `memory:` it is the app's, at its public URL
	## (`/__storage`), which the storage plugin answers (`Storage.plugin`): its key, its expiry and
	## an HMAC-SHA256 of them with the bucket's secret. A PUT there is a request's body, 16 MiB at
	## most unless the server's `--max-body` says more. `BadExpiry` unless `expires_s` is 1 to 604,800 (a week).
	signed_url! : Bucket, Str, { method : Str, expires_s : U64 } => Try(Str, [BadExpiry, StorageErr(Str)])
	signed_url! = |bucket, key, opts|
		match bucket {
			S3(s3) => S3.signed_url!(s3, key, opts)
			Kept(kept) =>
				if opts.expires_s < 1 or opts.expires_s > 604_800 {
					Err(BadExpiry)
				} else if key.is_empty() {
					Err(StorageErr("an object's key can't be empty"))
				} else {
					expires = Time.now_millis!({}) // 1000 + opts.expires_s
					method = opts.method.with_ascii_uppercased()
					signature = signed(secret!(kept), method, key, expires)
					Ok("${Env.public_url!({})}${plugin_path}?method=${method}&key=${escaped(key)}&expires=${expires.to_str()}&signature=${signature}")
				}
		}

	## Whether the bucket answers: S3 with these keys, for this bucket (it asks for an object that
	## isn't there); a directory, written to (made when missing); memory, always.
	check! : Bucket => Try({}, [S3Err(Refusal), StorageErr(Str)])
	check! = |bucket|
		match bucket {
			S3(s3) => S3.check!(s3)
			Kept(kept) => blob(Blobs.check!(kept.root))
		}

	## A refusal as one line: `403 SignatureDoesNotMatch: …`.
	said : Refusal -> Str
	said = |refused| S3.said(refused)

	## The storage plugin's options: the environment variable that is the bucket's URL.
	Options := { env : Str ?? "STORAGE_URL" }

	## The plugin that answers the signed URLs of the app's `file:` or `memory:` bucket (whose URL
	## is the environment variable `env`, `STORAGE_URL` unless it says): `GET`, `HEAD` or `PUT`
	## `/__storage?method=…&key=…&expires=…&signature=…`, the object served or kept, if the URL is
	## one `signed_url!` made for that method, and hasn't expired; 403 if not. For an S3 bucket it has
	## nothing to answer (404): S3 answers its own.
	plugin : Options -> Plugin.Value(ctx)
	plugin = |options| {
		named = options.env
		{
			name: "storage",
			routes: [{ method: "*", path: plugin_path, kind: Endpoint, answer!: |request, _context| answered!(named, request) }],
		}
	}
}

## Where the plugin answers signed URLs.
plugin_path : Str
plugin_path = "/__storage"

## The answer to a signed URL (`Storage.plugin`).
answered! : Str, Server.Request => Server.Response
answered! = |named, request| {
	plain = |status, text| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], text)
	match Storage.from_url(Env.var!(named) ?? "") {
		Ok(Kept(kept)) => {
			method = param(request.query, "method")
			key = param(request.query, "key")
			expires = U64.from_str(param(request.query, "expires")) ?? 0
			asked = if (request.method == "HEAD") "GET" else request.method
			expected = signed(secret!(kept), method, key, expires)
			if key.is_empty() or method != asked or !Hmac.equal(expected.to_utf8(), param(request.query, "signature").to_utf8()) {
				plain(403, "This link isn't one the app made for this.")
			} else if expires < Time.now_millis!({}) // 1000 {
				plain(403, "This link has expired.")
			} else if asked == "GET" {
				Server.stored(kept.root, key, request, [])
			} else if asked == "PUT" {
				content_type = Server.header(request, "content-type") ?? "application/octet-stream"
				match Blobs.put!(kept.root, key, request.body, content_type) {
					Ok({}) => plain(200, "")
					Err(BlobErr(why)) => plain(400, why)
				}
			} else {
				plain(405, "A signed link is for GET or PUT.")
			}
		}
		Ok(S3(_)) => plain(404, "The bucket is S3's: its links are S3's to answer.")
		Err(StorageErr(why)) => plain(503, why)
	}
}

## The secret a kept bucket's signed URLs are made with: its URL's, or the server's own for it.
secret! : { root : Str, secret : Str } => Str
secret! = |kept| if (kept.secret.is_empty()) Blobs.secret!(kept.root) else kept.secret

## A signed URL's signature: HMAC-SHA256 of its method, key and expiry, with the secret, as hex.
signed : Str, Str, Str, U64 -> Str
signed = |secret, method, key, expires| Hex.encode(Hmac.sha256(secret.to_utf8(), "${method}\n${key}\n${expires.to_str()}".to_utf8()))

## A key a bucket the host keeps can have: not empty (the host refuses the rest, saying why).
located : Str -> Try({}, [StorageErr(Str), ..others])
located = |key| if (key.is_empty()) Err(StorageErr("an object's key can't be empty")) else Ok({})

## A host's answer as the bucket's: why it failed as a `StorageErr`.
blob : Try(a, [BlobErr(Str)]) -> Try(a, [StorageErr(Str), ..others])
blob = |result|
	match result {
		Ok(value) => Ok(value)
		Err(BlobErr(why)) => Err(StorageErr(why))
	}

## A host's answer as the bucket's, with `NotFound` as it is.
found : Try(a, [NotFound, BlobErr(Str)]) -> Try(a, [NotFound, StorageErr(Str), ..others])
found = |result|
	match result {
		Ok(value) => Ok(value)
		Err(NotFound) => Err(NotFound)
		Err(BlobErr(why)) => Err(StorageErr(why))
	}

## Where an upload's part `number` is kept (0: what the upload is of), out of the way of the app's
## keys.
part_key : Str, U64 -> Str
part_key = |upload, number| ".uploads/${upload}/${number.to_str()}"

## The upload `upload` of `key`, if it is one: its content type. `NotFound` if there is no such
## upload, or it is of another key.
started! : Str, Str, Str => Try(Str, [NotFound, StorageErr(Str), ..others])
started! = |root, upload, key| {
	said_of = found(Blobs.get!(root, part_key(upload, 0)))?
	match Str.from_utf8_lossy(said_of).split_first("\n") {
		Ok({ before, after }) if before == key => Ok(after)
		_ => Err(NotFound)
	}
}

## An upload's parts and what it is of, gone.
forgotten! : Str, Str => Try({}, [StorageErr(Str), ..others])
forgotten! = |root, upload| {
	for part in blob(Blobs.keys!(root, ".uploads/${upload}/"))? {
		blob(Blobs.delete!(root, part))?
	}
	Ok({})
}

## A query's parameter (`key=a%2Fb`), decoded, or "".
param : Str, Str -> Str
param = |query, name| {
	var $found = ""
	for pair in query.split_on("&") {
		match pair.split_first("=") {
			Ok({ before, after }) if before == name => {
				$found = Server.decode_segment(after)
			}
			_ => {}
		}
	}
	$found
}

## A text as a query's parameter writes it: letters, digits and `-._~` as they are, the rest
## percent-encoded, byte by byte.
escaped : Str -> Str
escaped = |text| {
	digits = "0123456789ABCDEF".to_utf8()
	bytes = text.to_utf8().join_map(
		|byte|
			if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~' {
				[byte]
			} else {
				['%', digits.get((byte // 16).to_u64()) ?? '0', digits.get((byte % 16).to_u64()) ?? '0']
			},
	)
	Str.from_utf8_lossy(bytes)
}

expect escaped("videos/a b+ł.mp4") == "videos%2Fa%20b%2B%C5%82.mp4"
expect param("method=PUT&key=videos%2Fa%20b&expires=9", "key") == "videos/a b"
expect signed("s", "PUT", "a/b", 10) == signed("s", "PUT", "a/b", 10) and signed("s", "PUT", "a/b", 10) != signed("s", "GET", "a/b", 10)

## Where a bucket keeps its objects, if the host does: its root and secret.
kept_of : Try(Storage.Bucket, [StorageErr(Str)]) -> Try({ root : Str, secret : Str }, [NotKept])
kept_of = |bucket|
	match bucket {
		Ok(Kept(kept)) => Ok(kept)
		_ => Err(NotKept)
	}

expect kept_of(Storage.from_url("memory:")) == Ok({ root: "memory:", secret: "" })
expect kept_of(Storage.from_url("file:data/uploads?secret=abc")) == Ok({ root: "file:data/uploads", secret: "abc" })
expect Storage.from_url("file:").is_err()
expect Storage.from_url("ftp://x").is_err()
expect Storage.from_url("").is_err()
