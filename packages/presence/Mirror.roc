import Diff
import Room

## A browser's copy of a room: who is here, as the server last said, following what it sends. The
## server sends a `Snapshot` when a page starts listening (and again when it reconnects), then a
## `Delta` for each change, numbered as the room's state is (`Room.version`). A copy takes each
## change in order; an old one (sent before the snapshot it has) is no news, and one that skips a
## number means a change was missed (`Err(Gap)`): it should ask for a snapshot again.
Mirror(meta) := { members : List(Room.Here(meta)), version : U64, heard : Bool, synced : Bool }.{

	## What a presence stream sends.
	Message(m) : [Snapshot({ version : U64, members : List(Room.Here(m)) }), Delta({ version : U64, change : Room.Change(m) })]

	## A copy that hasn't heard yet: no one here, and changes ignored until a snapshot comes. (`heard`:
	## it has had one; `synced`: it has had one since it last lost track.)
	empty : {} -> Mirror(meta)
	empty = |{}| { members: [], version: 0, heard: Bool.False, synced: Bool.False }

	## The snapshot of `room`, for a page that starts listening.
	snapshot : Room(meta) -> Mirror.Message(meta)
	snapshot = |room| Snapshot({ version: room.version(), members: room.members() })

	## The messages for changes a room made: the first is one after the version it was at.
	deltas : Room(meta), List(Room.Change(meta)) -> List(Mirror.Message(meta))
	deltas = |room, changes| {
		first = room.version() + 1 - changes.len()
		changes.map_with_index(|change, i| Delta({ version: first + i, change }))
	}

	## The copy with `message` taken, and the changes it made. A first snapshot makes none (who was
	## here already didn't join); a snapshot after that, the changes since the last (`Diff`). A delta
	## before any snapshot, or older than the copy, is no news; one that skips a number is a gap.
	receive : Mirror(meta), Mirror.Message(meta) -> Try((Mirror(meta), List(Room.Change(meta))), [Gap])
		where [meta.is_eq : meta, meta -> Bool]
	receive = |mirror, message|
		match message {
			Snapshot(whole) => {
				changes = if (mirror.heard) Diff.between(mirror.members, whole.members) else []
				Ok(({ members: whole.members, version: whole.version, heard: Bool.True, synced: Bool.True }, changes))
			}
			Delta(delta) =>
				if !mirror.synced or delta.version <= mirror.version {
					Ok((mirror, []))
				} else if delta.version == mirror.version + 1 {
					Ok(({ ..mirror, members: Diff.apply(mirror.members, delta.change), version: delta.version }, [delta.change]))
				} else {
					Err(Gap)
				}
		}

	## The copy, waiting for a snapshot again: what it has stays on show, and changes are ignored
	## until it comes (after a gap, or when the stream drops).
	unsynced : Mirror(meta) -> Mirror(meta)
	unsynced = |mirror| { ..mirror, synced: Bool.False }

	## Who is here.
	members : Mirror(meta) -> List(Room.Here(meta))
	members = |mirror| mirror.members

	## How many are here.
	count : Mirror(meta) -> U64
	count = |mirror| mirror.members.len()

	## Whether the copy follows the server: it has a snapshot, and no gap since.
	is_synced : Mirror(meta) -> Bool
	is_synced = |mirror| mirror.synced
}

Meta : { name : Str }

here : Str, Str -> Room.Here(Meta)
here = |key, name| { key, meta: { name }, since: 0 }

fresh : Mirror(Meta)
fresh = Mirror.empty({})

took : Try((Mirror(Meta), List(Room.Change(Meta))), [Gap]) -> Mirror(Meta)
took = |received|
	match received {
		Ok((mirror, _)) => mirror
		Err(Gap) => fresh
	}

# A first snapshot: who is here, and no one joined.
expect {
	received = fresh.receive(Snapshot({ version: 4, members: [here("a", "Ann")] }))
	match received {
		Ok((mirror, changes)) => changes == [] and mirror.members() == [here("a", "Ann")] and mirror.is_synced()
		Err(Gap) => Bool.False
	}
}

# Changes before a snapshot are ignored.
expect {
	received = fresh.receive(Delta({ version: 1, change: Joined(here("a", "Ann")) }))
	match received {
		Ok((mirror, changes)) => changes == [] and mirror.count() == 0
		Err(Gap) => Bool.False
	}
}

# The next change is taken; an old one is no news; one that skips is a gap.
expect {
	synced = took(fresh.receive(Snapshot({ version: 4, members: [here("a", "Ann")] })))
	next = synced.receive(Delta({ version: 5, change: Joined(here("b", "Bo")) }))
	old = synced.receive(Delta({ version: 4, change: Left(here("a", "Ann")) }))
	skipped = synced.receive(Delta({ version: 6, change: Left(here("a", "Ann")) }))
	took(next).members() == [here("a", "Ann"), here("b", "Bo")] and took(old).members() == [here("a", "Ann")] and skipped.is_err()
}

# A snapshot after a reconnect: the changes since the last.
expect {
	synced = took(fresh.receive(Snapshot({ version: 4, members: [here("a", "Ann"), here("b", "Bo")] })))
	match synced.unsynced().receive(Snapshot({ version: 9, members: [here("b", "Bo"), here("c", "Cy")] })) {
		Ok((mirror, changes)) => changes == [Left(here("a", "Ann")), Joined(here("c", "Cy"))] and mirror.is_synced()
		Err(Gap) => Bool.False
	}
}

# What a room sends follows it: a snapshot, then each change numbered.
expect {
	(one, first) = Room.empty(Room.defaults).join({ key: "a", tab: "t", meta: { name: "Ann" }, now: 0 })
	(two, second) = one.join({ key: "b", tab: "t", meta: { name: "Bo" }, now: 0 })
	start = took(fresh.receive(Mirror.snapshot(one)))
	follows = Mirror.deltas(two, second).fold(start, |mirror, message| took(mirror.receive(message)))
	first.len() == 1 and Mirror.deltas(two, second) == [Delta({ version: 2, change: Joined({ key: "b", meta: { name: "Bo" }, since: 0 }) })] and follows.members() == two.members()
}
