import pf.Kv
import pf.Endpoint
import pf.Log
import pf.Time
import Grid
import Generated/Api

## The million boxes, in the server's memory (`Kv`): a key a chunk (`boxes:<n>`), each its version
## and its boxes as hex, and how many pages have the boxes' channel open (`boxes:online`). Nothing
## is written anywhere else: a restart clears them. A thousand small keys rather than one large
## one, so that two boxes checked at once in different chunks don't wait on each other, and one in
## the same chunk tries again (`Kv.swap!`): after three tries it waits a millisecond before each
## next one, so that a write others keep beating to the chunk isn't starved. Server-only (it imports `pf.Kv`): the routes' files
## import it, the page doesn't.
Store := [].{

	## A chunk as it is kept.
	Kept : { version : U64, bits : Str }

	## Box `index` checked, or not: its chunk written again, one version on, and every page told the
	## chunk (`Changed`, the latest of it kept for a page that is behind). Nothing changes, and nothing
	## is said, when the box already is.
	set! : U64, Bool => {}
	set! = |index, on| Store.written!(index, on, 0)

	## As `set!`, on its `tries`th try: a chunk another write changed since it was read is read again,
	## a thousand times at most (then the box isn't written, and the log says so).
	written! : U64, Bool, U64 => {}
	written! = |index, on, tries| {
		chunk = Grid.chunk_of(index)
		name = Store.key(chunk)
		at = index % Grid.chunk_size
		kept : Try(Store.Kept, [NotFound, BadValue(Str)])
		kept = Kv.get!(name)
		was = kept ?? { version: 0, bits: "" }
		bytes = Grid.decode(was.bits)
		if index >= Grid.size or Grid.bit(bytes, at) == on {
			return {}
		}
		if tries >= 1000 {
			Log.warn!("a box wasn't written: its chunk changed a thousand times while it tried", { index: index, chunk: chunk })
			return {}
		}
		now = { version: was.version + 1, bits: Grid.encode(Grid.with_bit(bytes, at, on)) }
		stored =
			match kept {
				Ok(_) =>
					match Kv.swap!(name, was, now, {}) {
						Ok({}) => Bool.True
						Err(Changed) => Bool.False
					}
				Err(NotFound) =>
					match Kv.add!(name, now, {}) {
						Ok({}) => Bool.True
						Err(Exists) => Bool.False
					}
				Err(BadValue(_)) => {
					Kv.set!(name, now, {})
					Bool.True
				}
			}
		if stored {
			Endpoint.publish_latest!(Api.channel_boxes({}), chunk.to_str(), Changed({ chunk: chunk, version: now.version, bits: now.bits }))
		} else {
			if (tries >= 3) Time.sleep!(1) else {}
			Store.written!(index, on, tries + 1)
		}
	}

	## Every chunk that has changed since the server started (the others have no box checked), and
	## how many pages are open.
	snapshot! : {} => Grid.Snapshot
	snapshot! = |{}| {
		var $chunks = []
		var $n = 0
		while $n < Grid.chunk_count {
			kept : Try(Store.Kept, [NotFound, BadValue(Str)])
			kept = Kv.get!(Store.key($n))
			$chunks =
				match kept {
					Ok(found) => $chunks.append({ chunk: $n, version: found.version, bits: found.bits })
					Err(_) => $chunks
				}
			$n = $n + 1
		}
		{ chunks: $chunks, online: Store.online!({}) }
	}

	## A page opened the channel: one more online, and every page told.
	opened! : {} => U64
	opened! = |{}| Store.counted!(1)

	## A page's channel closed: one fewer.
	closed! : {} => {}
	closed! = |{}| {
		_ = Store.counted!(-1)
		{}
	}

	## How many pages are open now.
	online! : {} => U64
	online! = |{}| {
		kept : Try(I64, [NotFound, BadValue(Str)])
		kept = Kv.get!("boxes:online")
		(kept ?? 0).to_u64_wrap()
	}

	## The pages open, `by` more (or fewer), told to every page.
	counted! : I64 => U64
	counted! = |by| {
		now =
			match Kv.increment!("boxes:online", by, {}) {
				Ok(n) => if (n < 0) 0 else n.to_u64_wrap()
				Err(_) => 0
			}
		Endpoint.publish_latest!(Api.channel_boxes({}), "online", Online(now))
		now
	}

	## The key chunk `n` is kept under.
	key : U64 -> Str
	key = |n| "boxes:${n.to_str()}"
}
