## S3: files in any S3 (rustfs or MinIO in development, R2, AWS or another in production), from a
## Roc Solid server. Objects put, read whole or a range at a time, looked at, deleted; multipart
## uploads; presigned URLs; and an object of any size served as the answer to a request, streamed
## by the server and never read into Roc (`S3`). Requests are signed with AWS Signature Version 4
## (`SigV4`), checked against AWS's own worked examples.
##
## It is plain Roc, on no platform: an app makes a bucket from its URL and the server platform's
## `Http.send!` and `Time.now_millis!`, and the bucket makes its requests with them. See README.md.
package [S3, SigV4] { crypto: "../crypto/main.roc" }
