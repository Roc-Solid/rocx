# storage

Files for Roc Solid apps (D-047), in a bucket whose URL says where: any S3 (rustfs or MinIO in
development, R2, AWS or another in production), a directory beside the server, or the server's
memory (for tests). Objects put, read whole or a range at a time, looked at, deleted; multipart
uploads; signed URLs a browser uploads or downloads with; and an object of any size served as the
answer to a request, sent by the server and never read into Roc. The code is the same on every
backend: the URL picks it.

```roc
import pf.Env
import storage.Storage

bucket = Storage.from_url(Env.var!("STORAGE_URL") ?? "")?
Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
```

## Installing

Name the package in the server's header, beside the platform. It names the server platform itself
(the host keeps a directory's and memory's objects, and the plugin is a server's), so only an app on
it names this package.

```roc
app [program] { pf: platform "../server/platform/main.roc", storage: "../packages/storage/main.roc" }
```

It uses `packages/crypto` (SHA-256 and HMAC, for S3's signatures and the app's signed URLs), which it
names itself. For signed URLs on a directory or memory, list its plugin (below).

## A bucket

```
s3://KEY:SECRET@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no
s3://KEY:SECRET@<account>.r2.cloudflarestorage.com/uploads?region=auto
s3://KEY:SECRET@s3.eu-west-1.amazonaws.com/uploads?region=eu-west-1
file:data/uploads?secret=…
memory:
```

- **S3.** The bucket is the URL's path. `region` is what the keys sign for (`us-east-1` unless given,
  `auto` for R2). `style=path` puts the bucket in the path, as rustfs and MinIO want; without it the
  bucket is in the host name (virtual-hosted, as AWS and R2 prefer). `tls=no` is plain `http`. A
  character the URL would read otherwise is `%XX` (a `/` in the secret may stay). A parameter that
  isn't one of the three (`stlye=path`) is refused. Each operation is a request to S3, signed here.
- **A directory** (`file:<dir>`, from where the server starts; made when missing). An object's bytes
  are a file at its key (`data/uploads/videos/41`), written to a file of its own first and moved into
  its place, so a crash leaves the object as it was, never half of the new one. Its content type and
  ETag are kept beside it, in `<dir>/.storage/`. It suits an app on one server, as SQLite does (D-045);
  a volume keeps it in production.
- **Memory** (`memory:`, or `memory:<name>` for a bucket of its own): the server's, gone when it stops.
  For tests, which then need no S3.

A directory's and memory's URL may give `secret`: what the app's signed URLs are made with, so they
outlive a restart. Without it, the server draws one when it starts.

`Storage.from_url` reads the URL and asks nothing of the bucket yet; an empty one, or one that can't
be read, is `StorageErr` saying why. An app keeps the URL in its environment and makes its bucket where
it needs one:

```roc
## The app's bucket: the one its STORAGE_URL names.
files! : {} => Try(Storage.Bucket, [StorageErr(Str)])
files! = |{}| Storage.from_url(Env.var!("STORAGE_URL") ?? "")
```

## What it does

```roc
Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?      # Try({}, [S3Err(…), StorageErr(Str)])
cover = Storage.get!(bucket, "covers/${post}")?                                   # List(U8); NotFound
piece = Storage.get_range!(bucket, "videos/${id}", { offset: 0, length: 4_194_304 })?   # { bytes, size }
info = Storage.head!(bucket, "videos/${id}")?                                     # { size, content_type, etag }
Storage.delete!(bucket, "images/${id}")?                                          # gone already: Ok

upload = Storage.start_upload!(bucket, "videos/${id}", { content_type: "video/mp4" })?
etag = Storage.upload_part!(bucket, "videos/${id}", upload, 1, part)?             # on S3, 5 MiB or more, but the last
Storage.finish_upload!(bucket, "videos/${id}", upload, [{ number: 1, etag }])?    # or abort_upload!(bucket, key, upload)

link = Storage.signed_url!(bucket, "videos/${id}", { method: "GET", expires_s: 3600 })?   # a week at most: BadExpiry

Storage.serve!(bucket, "videos/${id}", request, { content_type: "video/mp4", cache_control: "private" })   # an answer

Storage.check!(bucket)?                                                           # does the bucket answer?
```

A key is an object's name in the bucket, `/`s and all (`videos/41`); bytes are `List(U8)`. A
directory's or memory's key is segments between `/`s, none empty, `.` or `..`, and not starting with
`.storage`: anything else is refused, so a key never reaches outside its directory.

- **Errors.** `NotFound` is no such object, or no such upload. `S3Err({ status, code, message })` is
  what S3's `<Error>` said: `AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`,
  `NoSuchBucket`, `EntityTooSmall`, `InvalidPart`, `InvalidRange`, … An answer to a HEAD has no body,
  so its code is empty, and a 404 is `NotFound`. `StorageErr(why)` means S3 didn't answer (or answered
  too late), a file couldn't be written, or the key isn't one. `Storage.said(refusal)` writes one as a
  line. Each operation lists only the tags it can give.
- **ETags.** A file put whole has its MD5 for an ETag, on every backend. A multipart object's is the
  MD5 of its parts' MD5s and how many there are (`…-3`), as S3 makes one.
- **Deleting twice is fine.** `delete!` and `abort_upload!` of what isn't there are `Ok`, so a
  cleanup may run again.
- **Multipart.** ETags come without their quotes; `finish_upload!` takes the parts in any order, and
  refuses one listed with an ETag that isn't the part's (`InvalidPart`). A part listed again replaces
  it. On S3 a `CompleteMultipartUpload` that fails after S3 has answered 200 says so in its body, and
  `finish_upload!` reads it as the error it is.
- **A range past an object's end** is no bytes, with its size, on a directory or memory; S3 refuses
  it (`InvalidRange`).
- **`check!`**: S3, whether it answers with these keys for this bucket (it asks for an object that
  isn't there, `rocx-storage-check`); a directory, whether it can be written; memory, always. Call it
  from a health check, so a wrong URL shows before the first upload.

## Signed URLs

`signed_url!(bucket, key, { method, expires_s })` is a link anyone holding it may use to make that
request (`GET` or `PUT`) until it expires: 1 second to a week, `BadExpiry` otherwise.

- On **S3** it is a presigned URL, S3's own: only the host is signed, so a PUT may send any content
  type, and the browser talks to S3 itself; the app's server never holds the bytes.
- On **a directory or memory** it is the app's own, at its public URL (`Env.public_url!`):
  `/__storage?method=PUT&key=…&expires=…&signature=…`, the signature an HMAC-SHA256 of the method, the
  key and the expiry, with the bucket's secret. The storage plugin answers it, so list it in the app's
  plugins:

```roc
program = App.program({ …, plugins: [Storage.plugin({})] })   # the bucket STORAGE_URL names (env: "…" for another)
```

The plugin's route checks the link's method (a HEAD may use a GET's), that it hasn't expired, and its
signature, then serves the object (as `serve!` does, ranges and all) or keeps the one the PUT sent,
with its content type; 403 for a link it didn't make, one changed, or one expired. A PUT is a
request's body, 16 MiB at most: a larger file goes in parts, from the server. For an S3 bucket the
route has nothing to answer (404): S3 answers its own links.

## Serving an object

`Storage.serve!` answers a request with an object of any size, never read into Roc. From S3 it is a
forward (the server platform's `Server.forward`): the server asks S3 for the object, signed for a GET
(a HEAD for a HEAD), and streams its body to the client as it comes. From a directory or memory it is
the object the server keeps (`Server.stored`), which it sends as it is. Either way the request's
`Range` and `If-None-Match` (and to S3 `If-Range` and `If-Modified-Since` too) are asked as the
request record has them: 200; 206 for a range; 416 for one past the end; 304 for a matching ETag; 404
for an object that isn't there. An app may drop or change a range before it asks, to send the whole
file, say:

```roc
whole = { ..request, headers: request.headers.drop_if(|header| header.name == "range") }
Storage.serve!(bucket, key, whole, { content_type: "video/mp4", cache_control: "private" })
```

With the answer come the object's length, range, ETag and last modified time, and `content_type`
(the object's, if empty) and `cache_control` (none, if empty). An empty key is a 404: no object has
one.

## How it works

`Storage` reads the URL and hands each operation to its backend. For S3, `S3` signs each request with
AWS Signature Version 4 (`SigV4`: its expects hold it to AWS's own worked examples and to botocore's
signatures) and sends it with the server platform's `Http.send!`, exactly as it was signed, not
following redirects. S3's flavour of SigV4: the path is encoded once and never normalised (`a//b` is a
key of its own), and every request states its body's SHA-256, or `UNSIGNED-PAYLOAD`. `put!` signs its
body's SHA-256, so S3 refuses it if anything changed on the way; a part goes as `UNSIGNED-PAYLOAD`, TLS
keeping it whole. Requests wait 30 s, or 5 minutes for one carrying an object or a part.

For a directory or memory, the host keeps the objects (the server platform's `Blobs`, its files read
and written on threads for blocking work, so a call waiting on one holds no Roc thread). A multipart
upload keeps its parts under `.uploads/<upload>/`, joined in order at its end and then deleted.

## Testing

`roc test packages/storage/main.roc` runs its expects: the URLs, S3's XML, SigV4 against AWS's
examples, the app's signatures. `server/test/server.test.mjs` runs the rest on memory and on a
directory always, and against a real S3 bucket when `STORAGE_URL` is set (rustfs in Docker, say, with
a bucket made): keeping, reading, ranges, multipart, signed URLs by Node's fetch, serving with ranges
and 304s, and S3's own refusals.

## Limits, for now

- Objects come into Roc whole (`serve!` sends one to a client without it).
- No listing of a bucket's keys; S3's static keys only (no session tokens).
- A directory is one server's: two servers don't share one (the platform runs one, D-045).
- An upload from a browser comes through the server whole, 16 MiB at most: for larger files, a signed
  PUT to S3, or a multipart upload in parts.
