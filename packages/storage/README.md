# storage

Files for a Roc Solid app's server, kept in a bucket whose URL says where: any S3 (rustfs or MinIO
in development; R2, AWS or another in production), a directory beside the server, or the server's
memory (for tests). It puts, reads (whole or a range at a time), describes and deletes files; uploads
large ones in parts; makes signed URLs a browser uploads or downloads with; and serves a file of any
size as the answer to a request, without reading it into Roc. The URL picks the backend, and the
code is the same for each.

The user guide is the docs site's [Storage page](https://roc-solid.github.io/ecosystem/storage);
this file is the reference.

```roc
import pf.Env
import storage.Storage

bucket = Storage.from_url(Env.var!("STORAGE_URL") ?? "")?
Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
```

## Installing it

Name the package in the server's header, beside the platform:

```roc
app [program] { pf: platform "../server/platform/main.roc", storage: "../packages/storage/main.roc" }
```

The package names the server platform itself (the host keeps a directory's and memory's files),
so only an app on the server platform can use it; the browser's half never imports it. It uses
`packages/crypto` (SHA-256 and HMAC, for S3's signatures and the app's signed URLs), which it names
itself. It has no plugin.

For signed URLs on a directory or memory bucket, also add the route file that answers them (D-116),
at `/_storage`, where the links point:

```roc
# routes/_storage/+server.roc
import storage.Storage

respond! = |{ request, .. }| Storage.signed_route!(request, "STORAGE_URL")   # the bucket STORAGE_URL names
```

## A bucket

```
s3://KEY:SECRET@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no   # rustfs or MinIO
s3://KEY:SECRET@<account>.r2.cloudflarestorage.com/uploads?region=auto       # R2
s3://KEY:SECRET@s3.eu-west-1.amazonaws.com/uploads?region=eu-west-1          # AWS
file:data/uploads?secret=…                                                    # a directory
memory:                                                                       # the server's memory
```

- **S3** (`s3://`). The URL's path is the bucket. `region` is the region the keys sign for
  (`us-east-1` if not given, `auto` for R2). `style=path` puts the bucket in the path
  (`HOST/BUCKET/KEY`), as rustfs and MinIO want; without it the bucket is in the host name
  (`BUCKET.HOST/KEY`, virtual-hosted), as AWS and R2 prefer. `tls=no` uses plain `http`. Write a
  character the URL would otherwise misread as `%XX` (a `/` in the secret may stay as it is). Any
  other parameter is refused (`stlye=path` fails at once).
- **A directory** (`file:<dir>`, relative to where the server starts; created if missing). A file's
  bytes are a file at its key (`data/uploads/videos/41`). Each is written to a file of its own first
  and then moved into place, so a crash leaves the old file, never half of the new one. Its content
  type and ETag are kept beside it, in `<dir>/.storage/`. It suits an app on one server, as SQLite
  does; in production, put it on a volume.
- **Memory** (`memory:`, or `memory:<name>` for a separate bucket). Gone when the server stops. For
  tests, which then need no S3.

A directory or memory URL may give `secret`, the key the app's signed URLs are made with, so they
keep working after a restart. Without it, the server draws a random one when it first needs it.

`Storage.from_url` reads the URL and asks nothing of the bucket. An empty URL, or one it can't read,
is a `StorageErr` saying why. An app keeps the URL in its environment and makes its bucket where it
needs one:

```roc
## The app's bucket: the one its STORAGE_URL names.
files! : {} => Try(Storage.Bucket, [StorageErr(Str)])
files! = |{}| Storage.from_url(Env.var!("STORAGE_URL") ?? "")
```

## API

Everything is in the `Storage` module. A key is a file's name in the bucket, `/`s included
(`videos/41`); bytes are `List(U8)`.

| Function | Answers | Errors |
|---|---|---|
| `from_url(url)` | `Bucket` | `StorageErr` |
| `put!(bucket, key, bytes, { content_type })` | `{}`; replaces what was there | `S3Err`, `StorageErr` |
| `put_upload!(bucket, key, upload)` | `{}`; a file a form sent (`Server.file(request, "photo")`), its type the browser's (`application/octet-stream` if it gave none) | `S3Err`, `StorageErr` |
| `get!(bucket, key)` | `List(U8)`, the whole file (on S3, 64 MiB at most: `StorageErr` beyond) | `NotFound`, `S3Err`, `StorageErr` |
| `get_range!(bucket, key, { offset, length })` | `{ bytes, size }`: up to `length` bytes from `offset`, and the file's whole size | `NotFound`, `S3Err`, `StorageErr` |
| `head!(bucket, key)` | `Info`: `{ size, content_type, etag }` (the ETag without quotes) | `NotFound`, `S3Err`, `StorageErr` |
| `delete!(bucket, key)` | `{}`; a file that isn't there is `Ok` | `S3Err`, `StorageErr` |
| `start_upload!(bucket, key, { content_type })` | the upload's id | `S3Err`, `StorageErr` |
| `upload_part!(bucket, key, upload, number, bytes)` | the part's ETag; `number` is 1 to 10,000, and sending a number again replaces that part | `NotFound`, `S3Err`, `StorageErr` |
| `finish_upload!(bucket, key, upload, [{ number, etag }, …])` | `{}`; the parts listed, in any order, joined by number; a part not listed is dropped | `NotFound`, `S3Err`, `StorageErr` |
| `abort_upload!(bucket, key, upload)` | `{}`; the upload and its parts gone; one that isn't there is `Ok` | `S3Err`, `StorageErr` |
| `signed_url!(bucket, key, { method, expires_s })` | a URL for that one request (`GET` or `PUT`), valid for 1 s to a week | `BadExpiry`, `StorageErr` |
| `serve!(bucket, key, request, { content_type, cache_control })` | a `Server.Response` (below) | none: a 404 for a missing file |
| `check!(bucket)` | `{}` if the bucket answers | `S3Err`, `StorageErr` |
| `said(refusal)` | an `S3Err`'s refusal as a line: `403 SignatureDoesNotMatch: …` | |
| `signed_route!(request, env)` | the answer to a signed URL of the directory or memory bucket whose URL is the environment variable `env` (`"STORAGE_URL"`), for `routes/_storage/+server.roc` | none: a 403 or a 405 (below) |

Types: `Bucket` (`[S3(S3.Bucket), Kept({ root, secret })]`), `Refusal` (`{ status, code, message }`),
`Info`.

### Details

- **Errors.** `NotFound` is no such file, or no such upload. `S3Err({ status, code, message })` is
  what S3's `<Error>` said: `AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`,
  `NoSuchBucket`, `EntityTooSmall`, `InvalidPart`, `InvalidRange`, … An answer to a HEAD has no
  body, so its code is empty, and a 404 to a HEAD is `NotFound` even when the bucket is what's
  missing (`check!` tells them apart). `StorageErr(why)` means S3 didn't answer (or answered too
  late), a file couldn't be written, or the key isn't one. A directory or memory bucket says in a
  `StorageErr` what S3 would say in an `S3Err` (`InvalidPart: part 2 of … isn't one sent with that
  ETag`).
- **Keys on a directory or memory.** A key is segments between `/`s, none empty, `.` or `..`, and
  the first not `.storage`. Anything else is refused, so a key never reaches outside its directory.
- **ETags.** A file put whole has its MD5 for an ETag, on every backend. A multipart file's ETag is
  the MD5 of its parts' MD5s and how many there are (`…-3`), as S3 makes one.
- **Deleting twice is fine.** `delete!` and `abort_upload!` of what isn't there are `Ok`, so a
  cleanup may run again.
- **Multipart.** ETags come without their quotes. `finish_upload!` refuses a part listed with an
  ETag that isn't that part's (`InvalidPart`). On S3, every part but the last must be 5 MiB or more
  (`EntityTooSmall` at `finish_upload!`), and a `CompleteMultipartUpload` that fails after S3 has
  answered 200 says so in its body, which `finish_upload!` reads as the error it is.
- **A range past a file's end** is no bytes, with the size, on a directory or memory; S3 refuses it
  (`InvalidRange`). A `length` of 0 is no bytes and the size, everywhere.
- **`check!`**: on S3, whether S3 answers with these keys for this bucket (it asks for a file that
  isn't there, `rocx-storage-check`); on a directory, whether it can be written; on memory, always.
  Call it from a health check, so a wrong URL shows before the first upload.

## Signed URLs

`signed_url!(bucket, key, { method, expires_s })` is a link anyone holding it may use to make that
request until it expires: 1 second to a week (604,800 s), `BadExpiry` otherwise.

- On **S3** it is S3's own presigned URL. Only the host is signed, so a PUT may send any content
  type. The browser talks to S3 itself; the app's server never holds the bytes.
- On **a directory or memory** it is the app's own, at its public URL (`Env.public_url!`):
  `/_storage?method=PUT&key=…&expires=…&signature=…`. The signature is an HMAC-SHA256 of the
  method, the key and the expiry, with the bucket's secret. The app's route answers it.

The route is the app's file, `routes/_storage/+server.roc`, calling `Storage.signed_route!` (D-116),
so the middleware of the folders it is in is around it; each link is signed, so it needs none, and
must be let through. Its path is fixed: `signed_url!` makes its links to `/_storage` (`/__storage`
before D-116). It reads the bucket from the environment variable it is given (`"STORAGE_URL"`, or
another for another bucket). It checks the link's method (a HEAD may use a GET's link), the
signature, and that the link hasn't expired. Then it serves the file (as `serve!` does, ranges
included) or keeps the one the PUT sent, with the request's content type. A link it didn't make, or one that was
changed, gets a 403, and so does one that has expired; a method other than GET, HEAD or PUT gets a
405. A PUT is an ordinary request body, 16 MiB at most unless the server's `--max-body` says more:
send a larger file in parts, from the server. For an S3 bucket the route has nothing to answer
(404), since S3 answers its own links.

## Serving a file

`Storage.serve!` answers a request with a file of any size, never read into Roc.

- From **S3** it is a forward (the server platform's `Server.forward`): the server asks S3 for the
  file, signed for a GET (a HEAD for a HEAD), and streams the body to the client as it comes.
- From **a directory or memory** it is the file the server keeps (`Server.stored`), which the host
  sends as it is.

Either way, the request's `Range` and `If-None-Match` headers (and, to S3, `If-Range` and
`If-Modified-Since` too) are passed on as the request record has them. The answer is 200; 206 for a
range; 416 for a range past the end; 304 for a matching ETag; 404 for a file that isn't there (and
for an empty key). It carries the file's length, range, ETag and last modified time, plus
`content_type` (the stored type, if empty) and `cache_control` (none, if empty). An app may change
the headers before it asks; this sends the whole file, whatever range was asked for:

```roc
whole = { ..request, headers: request.headers.drop_if(|header| header.name == "range") }
Storage.serve!(bucket, key, whole, { content_type: "video/mp4", cache_control: "private" })
```

## How it works

`Storage` reads the URL and hands each operation to its backend.

For S3, the `S3` module signs each request with AWS Signature Version 4 (`SigV4`, whose expects hold
it to AWS's own worked examples and to botocore's signatures) and sends it with the server platform's
`Http.send!`, exactly as signed and without following redirects. S3's flavour of SigV4 encodes the
path once and never normalises it (`a//b` is a key of its own), and every request states its body's
SHA-256, or `UNSIGNED-PAYLOAD`. `put!` signs its body's SHA-256, so S3 refuses it if anything changed
on the way; a part goes as `UNSIGNED-PAYLOAD`, with TLS keeping it whole. A request waits 30 s for
an answer, or 5 minutes for one that carries or reads a file.

For a directory or memory, the host keeps the files (the server platform's `Blobs` module). It reads
and writes them on its threads for blocking work, so a call waiting on a file holds no Roc thread. A
multipart upload keeps its parts under `.uploads/<upload>/`, joins them in order at the end, and
then deletes them.

## Testing

`roc test packages/storage/main.roc` runs the expects: the URLs, S3's XML, SigV4 against AWS's
examples, the app's signatures. `server/test/server.test.mjs` runs the rest on memory and on a
directory always, and against a real S3 bucket when `STORAGE_URL` is set (rustfs in Docker, say,
with a bucket made): keeping, reading, ranges, multipart, signed URLs fetched by Node, serving with
ranges and 304s, and S3's own refusals.

## Limits, for now

- Files come into Roc whole (`put!`, `get!`); `get_range!` reads a large one in pieces, and `serve!`
  sends one to a client without Roc.
- No listing of a bucket's keys, and no copying a file to another key.
- S3's static keys only: no session tokens.
- A directory belongs to one server: two servers can't share one.
- An upload from a browser through the app's server arrives whole, 16 MiB at most (`--max-body`). For
  larger files, use a signed PUT to S3, or a multipart upload.
