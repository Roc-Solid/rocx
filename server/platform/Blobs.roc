import Host

## Bytes kept by key, in a directory beside the server or in its memory, for packages/storage's
## `file:` and `memory:` buckets (D-047): what the host keeps for them, under a root, `file:<dir>`
## (made when missing; an object's bytes at `<dir>/<key>`, written whole or not at all) or
## `memory:<name>` (gone when the server stops). A key is segments between `/`s, none empty, `.` or
## `..`; anything else is refused (`BlobErr`), so a key never reaches outside its root. An object has
## its content type and its ETag (its MD5) beside it. `Server.stored(root, key, headers)` answers a
## request with one, sent by the host as it is.
Blobs := [].{

	## An object's size in bytes, its content type, and its ETag (no quotes).
	Info : { size : U64, content_type : Str, etag : Str }

	## Keeps `bytes` at `key`, with their content type, in place of what was there.
	put! : Str, Str, List(U8), Str => Try({}, [BlobErr(Str), ..others])
	put! = |root, key, bytes, content_type|
		match Host.blob_put!(root, key, bytes, content_type) {
			Ok({}) => Ok({})
			Err(why) => Err(BlobErr(why))
		}

	## The bytes at `key`, whole.
	get! : Str, Str => Try(List(U8), [NotFound, BlobErr(Str), ..others])
	get! = |root, key|
		match Host.blob_get!(root, key) {
			Ok(bytes) => Ok(bytes)
			Err(why) => Err(failed(why))
		}

	## `length` bytes at `key` from `offset` (fewer at its end; none past it), and its size.
	range! : Str, Str, { offset : U64, length : U64 } => Try({ bytes : List(U8), size : U64 }, [NotFound, BlobErr(Str), ..others])
	range! = |root, key, { offset, length }|
		match Host.blob_range!(root, key, offset, length) {
			Ok(found) => Ok(found)
			Err(why) => Err(failed(why))
		}

	## `key`'s size, content type and ETag.
	head! : Str, Str => Try(Info, [NotFound, BlobErr(Str), ..others])
	head! = |root, key|
		match Host.blob_head!(root, key) {
			Ok(info) => Ok(info)
			Err(why) => Err(failed(why))
		}

	## The bytes at `key` gone; none there is no problem.
	delete! : Str, Str => Try({}, [BlobErr(Str), ..others])
	delete! = |root, key|
		match Host.blob_delete!(root, key) {
			Ok({}) => Ok({})
			Err(why) => Err(BlobErr(why))
		}

	## The bytes at `parts`, joined in order, kept at `key` with a content type (the parts stay).
	compose! : Str, List(Str), Str, Str => Try({}, [NotFound, BlobErr(Str), ..others])
	compose! = |root, parts, key, content_type|
		match Host.blob_compose!(root, parts, key, content_type) {
			Ok({}) => Ok({})
			Err(why) => Err(failed(why))
		}

	## The keys that start with `prefix`, in order (all of them, for "").
	keys! : Str, Str => Try(List(Str), [BlobErr(Str), ..others])
	keys! = |root, prefix|
		match Host.blob_keys!(root, prefix) {
			Ok(found) => Ok(found)
			Err(why) => Err(BlobErr(why))
		}

	## Whether the root can be written: a directory made, written to and cleaned when missing.
	check! : Str => Try({}, [BlobErr(Str), ..others])
	check! = |root|
		match Host.blob_check!(root) {
			Ok({}) => Ok({})
			Err(why) => Err(BlobErr(why))
		}

	## The secret a root's signed URLs are made with when its URL gives none: drawn when first asked
	## for, and kept while the server runs (its URLs end with it).
	secret! : Str => Str
	secret! = |root| Host.blob_secret!(root)
}

## The host's "NotFound" as `NotFound`; any other text as why it failed.
failed : Str -> [NotFound, BlobErr(Str), ..others]
failed = |why| if (why == "NotFound") NotFound else BlobErr(why)
