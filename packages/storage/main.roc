## Storage: files for a Roc Solid app's server (D-047), in a bucket whose URL's scheme is its
## backend: any S3 (`s3://…`: rustfs or MinIO in development, R2, AWS or another in production),
## files beside the server (`file:<dir>`), or the server's memory (`memory:`, for tests). Objects
## put, read whole or a range at a time, looked at, deleted; multipart uploads; signed URLs (S3's
## own, or the app's, which the storage plugin answers); and an object of any size served as the
## answer to a request, sent by the server and never read into Roc (`Storage`). S3's requests are
## signed with AWS Signature Version 4 (`SigV4`), checked against AWS's own worked examples.
##
## It names the server platform (the host keeps `file:` and `memory:` buckets' objects, and the
## plugin is a server's), so only an app on it names this package. See README.md.
package [Storage] { crypto: "../crypto/main.roc", pf: platform "../../server/platform/main.roc" }
