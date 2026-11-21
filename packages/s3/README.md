# s3

Files in any S3 for Roc Solid apps: rustfs or MinIO in development, R2, AWS or another in
production. Objects put, read whole or a range at a time, looked at, deleted; multipart uploads;
presigned URLs a browser uploads or downloads with; and an object of any size served as the answer
to a request, streamed by the server and never read into Roc.

```roc
import pf.Env
import pf.Http
import pf.Time
import s3.S3

bucket = S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })?
S3.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
```

## Installing

Name the package in the server's header, beside the platform: it is plain Roc, on no platform, so
nothing is copied into the app.

```roc
app [program] { pf: platform "../server/platform/main.roc", s3: "../packages/s3/main.roc" }
```

It uses `packages/crypto` (SHA-256 and HMAC, for the signatures), which it names itself.

## A bucket

A bucket is where S3 is, the keys to it, and the two effects the package needs to reach it, which
are the server platform's own: `Http.send!` for the requests, and `Time.now_millis!` for the time
each is signed at. `S3.from_url` reads the URL and checks it, and asks nothing of S3 yet. An app
keeps the URL in its environment (`STORAGE_URL`, say) and makes its bucket where it needs one:

```roc
## The app's bucket: the one its STORAGE_URL names.
files! : {} => Try(S3.Bucket, [StorageErr(Str)])
files! = |{}| S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })
```

The URL:

```
s3://KEY:SECRET@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no
s3://KEY:SECRET@<account>.r2.cloudflarestorage.com/uploads?region=auto
s3://KEY:SECRET@s3.eu-west-1.amazonaws.com/uploads?region=eu-west-1
```

The bucket is the URL's path. `region` is what the keys sign for (`us-east-1` unless given, `auto`
for R2). `style=path` puts the bucket in the path, as rustfs and MinIO want; without it the bucket is
in the host name (virtual-hosted, as AWS and R2 prefer). `tls=no` is plain `http`. A character the
URL would read otherwise is `%XX` (a `/` in the secret may stay). An empty URL, or one that can't be
read, is `StorageErr` saying why; a parameter that isn't one of the three (`stlye=path`) is refused.

## What it does

```roc
S3.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?      # Try({}, [S3Err(…), StorageErr(Str)])
cover = S3.get!(bucket, "covers/${post}")?                                   # List(U8); NotFound
piece = S3.get_range!(bucket, "videos/${id}", { offset: 0, length: 4_194_304 })?   # { bytes, size }
info = S3.head!(bucket, "videos/${id}")?                                     # { size, content_type, etag }
S3.delete!(bucket, "images/${id}")?                                          # gone already: Ok

upload = S3.start_upload!(bucket, "videos/${id}", { content_type: "video/mp4" })?
etag = S3.upload_part!(bucket, "videos/${id}", upload, 1, part)?             # 5 MiB or more, but the last
S3.finish_upload!(bucket, "videos/${id}", upload, [{ number: 1, etag }])?    # or abort_upload!(bucket, key, upload)

link = S3.signed_url!(bucket, "videos/${id}", { method: "GET", expires_s: 3600 })?   # a week at most: BadExpiry

S3.serve!(bucket, "videos/${id}", request, { content_type: "video/mp4", cache_control: "private" })   # an answer

S3.check!(bucket)?                                                           # does S3 answer, for this bucket?
```

A key is an object's name in the bucket, `/`s and all (`videos/41`); bytes are `List(U8)`.

- **Errors.** `NotFound` is no such object, or no such upload. `S3Err({ status, code, message })` is
  what S3's `<Error>` said: `AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`,
  `NoSuchBucket`, `EntityTooSmall`, `InvalidPart`, `InvalidRange`, … An answer to a HEAD has no body,
  so its code is empty, and a 404 is `NotFound`. `StorageErr(why)` means S3 didn't answer, or
  answered too late, or the key is empty. `S3.said(refusal)` writes one as a line. Each operation
  lists only the tags it can give.
- **Deleting twice is fine.** `delete!` and `abort_upload!` of what isn't there are `Ok`, so a
  cleanup may run again.
- **Multipart.** ETags come without their quotes; `finish_upload!` quotes them again and takes the
  parts in any order. A `CompleteMultipartUpload` that fails after S3 has answered 200 says so in its
  body, and `finish_upload!` reads it as the error it is.
- **Presigned URLs** sign only the host: anyone holding one may make that request until it expires,
  a PUT with any content type. 1 second to a week (S3's limit); `BadExpiry` otherwise. Nothing is
  asked of S3.
- **`check!`** asks for an object that isn't there (`rocx-storage-check`): `Ok` if S3 answers, with
  these keys, for this bucket; its refusal (`NoSuchBucket`, `SignatureDoesNotMatch`, …) if not. Call
  it from a health check, so a wrong URL shows before the first upload.

## Serving an object

`S3.serve!` answers a request with an object of any size. Its answer is a `Forward` (the server
platform's `Server.forward` makes the same): the server asks S3 for the object and streams its body
to the client as it comes, never through Roc. It signs a GET (a HEAD for a HEAD), and passes on the
request's `Range`, `If-Range`, `If-None-Match` and `If-Modified-Since` as the request record has
them. So S3's status is the answer's: 200; 206 for a range; 304 for a matching ETag; 404 for an
object that isn't there. An app may drop or change a range before it asks, to send the whole file,
say:

```roc
whole = { ..request, headers: request.headers.drop_if(|header| header.name == "range") }
S3.serve!(bucket, key, whole, { content_type: "video/mp4", cache_control: "private" })
```

With the answer come the object's length, range, ETag and last modified time, and `content_type`
(S3's, if empty) and `cache_control` (none, if empty). An empty key is a 404: no object has one.

## How it works

`S3` signs each request with AWS Signature Version 4 (`SigV4`, exposed too: its expects hold it to
AWS's own worked examples and to botocore's signatures) and sends it with the bucket's `send!`,
exactly as it was signed, not following redirects. S3's flavour of SigV4: the path is encoded once
and never normalised (`a//b` is a key of its own), and every request states its body's SHA-256, or
`UNSIGNED-PAYLOAD`.

`put!` signs its body's SHA-256 (8 MB: about 50 ms), so S3 refuses it if anything changed on the
way; a part goes as `UNSIGNED-PAYLOAD`, TLS keeping it whole. Bytes are read and sent whole: `get!`
reads 64 MiB at most, `get_range!` more, a piece at a time. Requests wait 30 s, or 5 minutes for one
carrying an object or a part.

## Testing

`roc test packages/s3/main.roc` runs its expects: the URL, S3's XML, and SigV4 against AWS's
examples. `server/test/server.test.mjs` runs the rest against a real bucket when `STORAGE_URL` is
set (rustfs in Docker, say, with a bucket made).

## Limits, for now

- Objects come into Roc whole (`serve!` streams one to a client without it).
- No listing; static keys only (no session tokens).
- An upload from a browser comes through the server whole, 16 MiB at most: for larger files, a
  presigned PUT, or a multipart upload in parts.
