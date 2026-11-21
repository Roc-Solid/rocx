## A room's presence, as the server keeps it: who is here, each with the app's metadata (`meta`: a
## name, a colour, a status), since when, and from which tabs. A member is here while one of their
## tabs is: two tabs are one member, who leaves when the last tab does.
##
## A tab stays while it beats (`heartbeat`); one that stops (its laptop shut, its network gone) is
## swept out once `timeout` has passed since it was last heard (`sweep`). A tab that leaves
## (`leave`: its stream ended) goes after `grace`, unless it is back by then: a page that reconnects
## doesn't flicker out and in. Every change that others should hear (`Joined`, `Left`, `Changed`)
## numbers the room's state: `version`, which a browser's copy (`Mirror`) follows.
##
## ```roc
## (room, changes) = Room.empty(Room.defaults).join({ key: "ann", tab: "t1", meta: { name: "Ann" }, now: 1000 })
## # changes == [Joined({ key: "ann", meta: { name: "Ann" }, since: 1000 })]
## ```
##
## Time is the caller's: milliseconds, `now`, from a clock it trusts (`Time.now_millis!` on the
## server; a fake one in tests).
Room(meta) := { members : List(Room.Member(meta)), version : U64, settings : Room.Settings }.{

	## How long a tab may go unheard before it is swept out (`timeout`), and how long one that left
	## is kept, in case it comes back (`grace`): milliseconds.
	Settings : { timeout : U64, grace : U64 }

	## Who is here, as others see them: their key (a member's id: the app's, never the browser's
	## say), their metadata, and when they came.
	Here(m) : { key : Str, meta : m, since : U64 }

	## What others hear: one came, one went (with the metadata they had), one's metadata changed.
	Change(m) : [Joined(Room.Here(m)), Left(Room.Here(m)), Changed(Room.Here(m))]

	## A tab: its id, when it was last heard, and whether it has left (and when).
	Tab : { id : Str, seen : U64, left : [Staying, LeftAt(U64)] }

	## A member, and their tabs.
	Member(m) : { key : Str, meta : m, since : U64, tabs : List(Room.Tab) }

	## What a room is told, as a message: the same as calling `join`, `heartbeat`, `leave` and
	## `update`, so a stream can hand on what it heard (`signal`).
	Signal(m) : [Join({ key : Str, tab : Str, meta : m }), Beat({ key : Str, tab : Str }), Leave({ key : Str, tab : Str }), Update({ key : Str, meta : m })]

	## A room as a plain record, which JSON can carry: what an actor keeps (`save`, `load`).
	Saved(m) : { members : List(Room.Member(m)), version : U64, settings : Room.Settings }

	## A tab unheard for 75 s is gone, and one that left and is back within 5 s never left. A page
	## beats every 15 s (`beat_every`), and a browser may hold a hidden tab's timers back to once a
	## minute: 75 s is that minute, and a beat to spare.
	defaults : Room.Settings
	defaults = { timeout: 75000, grace: 5000 }

	## A room with no one in it.
	empty : Room.Settings -> Room(meta)
	empty = |settings| { members: [], version: 0, settings }

	## `key`'s tab `tab` is here, with `meta`. Someone new is `Joined`; someone here already, from
	## another tab or this one, is only `Changed`, if `meta` is new (the latest tab's metadata is
	## the member's). A tab that had left and comes back within `grace` never left.
	join : Room(meta), { key : Str, tab : Str, meta : meta, now : U64 } -> (Room(meta), List(Room.Change(meta)))
		where [meta.is_eq : meta, meta -> Bool]
	join = |room, { key, tab, meta, now }|
		match room.members.find_first(|member| member.key == key) {
			Ok(member) => {
				tabs = member.tabs.drop_if(|other| other.id == tab).append({ id: tab, seen: now, left: Staying })
				if member.meta == meta {
					(room.with_member({ ..member, tabs }), [])
				} else {
					room.with_member({ ..member, meta, tabs }).changed(Changed({ key, meta, since: member.since }))
				}
			}
			Err(_) => {
				joined = { key, meta, since: now, tabs: [{ id: tab, seen: now, left: Staying }] }
				{ ..room, members: room.members.append(joined) }.changed(Joined({ key, meta, since: now }))
			}
		}

	## `key`'s metadata is now `meta` (their status, say): `Changed`, or nothing when it is the same,
	## or they aren't here.
	update : Room(meta), Str, meta -> (Room(meta), List(Room.Change(meta)))
		where [meta.is_eq : meta, meta -> Bool]
	update = |room, key, meta|
		match room.members.find_first(|member| member.key == key) {
			Ok(member) if member.meta != meta => room.with_member({ ..member, meta }).changed(Changed({ key, meta, since: member.since }))
			_ => (room, [])
		}

	## `key`'s tab `tab` was heard from at `now`: it stays (and, if it had left, it is back). A tab
	## the room doesn't know (it was swept out while its laptop slept) is `Err(Unknown)`: its page
	## should join again.
	heartbeat : Room(meta), Str, Str, U64 -> Try(Room(meta), [Unknown])
	heartbeat = |room, key, tab, now|
		match room.members.find_first(|member| member.key == key) {
			Ok(member) if member.tabs.any(|other| other.id == tab) => {
				tabs = member.tabs.map(|other| if (other.id == tab) { id: tab, seen: now, left: Staying } else other)
				Ok(room.with_member({ ..member, tabs }))
			}
			_ => Err(Unknown)
		}

	## `key`'s tab `tab` has left (its stream ended) at `now`. With no `grace`, it is gone at once,
	## and its member with it if it was their last tab (`Left`); otherwise it goes at the sweep after
	## `grace`, unless it is back by then.
	leave : Room(meta), Str, Str, U64 -> (Room(meta), List(Room.Change(meta)))
	leave = |room, key, tab, now|
		match room.members.find_first(|member| member.key == key) {
			Ok(member) if member.tabs.any(|other| other.id == tab) =>
				if room.settings.grace == 0 {
					room.without_tabs(member, |other| other.id == tab)
				} else {
					tabs = member.tabs.map(|other| if (other.id == tab) { ..other, left: LeftAt(now) } else other)
					(room.with_member({ ..member, tabs }), [])
				}
			_ => (room, [])
		}

	## The room at `now`: every tab unheard for longer than `timeout`, and every tab that left
	## `grace` ago or more, gone; and each member with no tab left, `Left`.
	sweep : Room(meta), U64 -> (Room(meta), List(Room.Change(meta)))
	sweep = |room, now| {
		var $room = room
		var $changes = []
		for member in room.members {
			(next, changes) = $room.without_tabs(member, |tab| Room.expired(room.settings, tab, now))
			$room = next
			$changes = $changes.concat(changes)
		}
		($room, $changes)
	}

	## What `signal` says, done: a stream hands on what it heard.
	signal : Room(meta), Room.Signal(meta), U64 -> (Room(meta), List(Room.Change(meta)))
		where [meta.is_eq : meta, meta -> Bool]
	signal = |room, said, now|
		match said {
			Join({ key, tab, meta }) => room.join({ key, tab, meta, now })
			Beat({ key, tab }) =>
				match room.heartbeat(key, tab, now) {
					Ok(next) => (next, [])
					Err(Unknown) => (room, [])
				}
			Leave({ key, tab }) => room.leave(key, tab, now)
			Update({ key, meta }) => room.update(key, meta)
		}

	## How often a page should beat: a fifth of `timeout`, so a tab survives four lost beats, or
	## one held back a minute.
	beat_every : Room.Settings -> U64
	beat_every = |settings| settings.timeout / 5

	## The room as a plain record, for JSON.
	save : Room(meta) -> Room.Saved(meta)
	save = |room| { members: room.members, version: room.version, settings: room.settings }

	## The room a saved one was.
	load : Room.Saved(meta) -> Room(meta)
	load = |saved| { members: saved.members, version: saved.version, settings: saved.settings }

	## Who is here, in the order they came.
	members : Room(meta) -> List(Room.Here(meta))
	members = |room| room.members.map(|member| { key: member.key, meta: member.meta, since: member.since })

	## How many are here.
	count : Room(meta) -> U64
	count = |room| room.members.len()

	## Whether `key` is here.
	is_here : Room(meta), Str -> Bool
	is_here = |room, key| room.members.any(|member| member.key == key)

	## The number of the room's state: one more with each change.
	version : Room(meta) -> U64
	version = |room| room.version

	## When the next sweep could find someone to sweep out: the earliest a tab could expire, or
	## `Err(Empty)` when no one is here. A stream waits until then, or for what it hears.
	deadline : Room(meta) -> Try(U64, [Empty])
	deadline = |room| {
		var $soonest = Err(Empty)
		for member in room.members {
			for tab in member.tabs {
				due = Room.expires(room.settings, tab)
				$soonest =
					match $soonest {
						Ok(at) => Ok(U64.min(at, due))
						Err(Empty) => Ok(due)
					}
			}
		}
		$soonest
	}

	## When `tab` expires: `timeout` after it was last heard, or `grace` after it left.
	expires : Room.Settings, Room.Tab -> U64
	expires = |settings, tab|
		match tab.left {
			Staying => tab.seen + settings.timeout + 1
			LeftAt(at) => at + settings.grace
		}

	## Whether `tab` has expired at `now`.
	expired : Room.Settings, Room.Tab, U64 -> Bool
	expired = |settings, tab, now| now >= Room.expires(settings, tab)

	## The room with `member` in place of the one with their key.
	with_member : Room(meta), Room.Member(meta) -> Room(meta)
	with_member = |room, member| { ..room, members: room.members.map(|other| if (other.key == member.key) member else other) }

	## The room with `member`'s tabs that `gone` says, gone: and `member` with them, `Left`, if no
	## tab is left.
	without_tabs : Room(meta), Room.Member(meta), (Room.Tab -> Bool) -> (Room(meta), List(Room.Change(meta)))
	without_tabs = |room, member, gone| {
		tabs = member.tabs.drop_if(gone)
		if tabs.is_empty() {
			{ ..room, members: room.members.drop_if(|other| other.key == member.key) }.changed(Left({ key: member.key, meta: member.meta, since: member.since }))
		} else if tabs.len() == member.tabs.len() {
			(room, [])
		} else {
			(room.with_member({ ..member, tabs }), [])
		}
	}

	## The room, one version on, and the change that made it.
	changed : Room(meta), Room.Change(meta) -> (Room(meta), List(Room.Change(meta)))
	changed = |room, change| ({ ..room, version: room.version + 1 }, [change])
}

Meta : { name : Str, status : Str }

ann : Meta
ann = { name: "Ann", status: "here" }

start : Room(Meta)
start = Room.empty(Room.defaults)

expect {
	(room, changes) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	changes == [Joined({ key: "ann", meta: ann, since: 1000 })] and room.count() == 1 and room.version() == 1
}

# A second tab is the same member: no one new joins.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(again, changes) = room.join({ key: "ann", tab: "a2", meta: ann, now: 2000 })
	changes == [] and again.count() == 1 and again.version() == 1
}

# A second tab with new metadata changes the member's.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(_, changes) = room.join({ key: "ann", tab: "a2", meta: { ..ann, status: "away" }, now: 2000 })
	changes == [Changed({ key: "ann", meta: { ..ann, status: "away" }, since: 1000 })]
}

expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(next, changes) = room.update("ann", { ..ann, status: "away" })
	changes == [Changed({ key: "ann", meta: { ..ann, status: "away" }, since: 1000 })] and next.version() == 2
}

# The same metadata again is no change; nor is someone who isn't here.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(_, same) = room.update("ann", ann)
	(_, nobody) = room.update("bo", ann)
	same == [] and nobody == []
}

# Leaving with no grace: gone at once.
expect {
	(room, _) = Room.empty({ timeout: 30000, grace: 0 }).join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(gone, changes) = room.leave("ann", "a1", 2000)
	changes == [Left({ key: "ann", meta: ann, since: 1000 })] and gone.count() == 0 and gone.version() == 2
}

# Leaving with grace: still here until the sweep after it.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(left, changes) = room.leave("ann", "a1", 2000)
	(early, before) = left.sweep(6999)
	(_, after) = early.sweep(7000)
	changes == [] and before == [] and after == [Left({ key: "ann", meta: ann, since: 1000 })]
}

# Back within the grace: never left.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(left, _) = room.leave("ann", "a1", 2000)
	(back, rejoined) = left.join({ key: "ann", tab: "a1", meta: ann, now: 3000 })
	(_, swept) = back.sweep(9000)
	rejoined == [] and swept == []
}

# One of two tabs leaving: the member stays.
expect {
	(one, _) = Room.empty({ timeout: 30000, grace: 0 }).join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(two, _) = one.join({ key: "ann", tab: "a2", meta: ann, now: 1000 })
	(left, changes) = two.leave("ann", "a1", 2000)
	(gone, last) = left.leave("ann", "a2", 3000)
	changes == [] and left.is_here("ann") and last == [Left({ key: "ann", meta: ann, since: 1000 })] and !gone.is_here("ann")
}

# A tab that stops beating is swept out after the timeout; one that beats stays.
expect {
	(one, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 0 })
	(two, _) = one.join({ key: "bo", tab: "b1", meta: { name: "Bo", status: "here" }, now: 0 })
	beaten = two.heartbeat("bo", "b1", 20000) ?? two
	(still, none) = beaten.sweep(75000)
	(after, swept) = still.sweep(75001)
	none == [] and swept == [Left({ key: "ann", meta: ann, since: 0 })] and after.members().map(|here| here.key) == ["bo"]
}

# A heartbeat from a tab the room doesn't know: join again.
expect start.heartbeat("ann", "a1", 1000).is_err()

# A heartbeat brings back a tab that had left.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(left, _) = room.leave("ann", "a1", 2000)
	back = left.heartbeat("ann", "a1", 3000) ?? left
	(_, swept) = back.sweep(9000)
	swept == []
}

# The deadline: the earliest a tab could expire.
expect start.deadline() == Err(Empty)
expect {
	(one, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 1000 })
	(two, _) = one.join({ key: "bo", tab: "b1", meta: ann, now: 2000 })
	(left, _) = two.leave("bo", "b1", 3000)
	one.deadline() == Ok(76001) and left.deadline() == Ok(8000)
}

# What a stream hears, handed on.
expect {
	(room, joined) = start.signal(Join({ key: "ann", tab: "a1", meta: ann }), 1000)
	(_, updated) = room.signal(Update({ key: "ann", meta: { ..ann, status: "away" } }), 2000)
	joined.len() == 1 and updated.len() == 1
}

# Versions number every change, and only changes.
expect {
	(one, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 0 })
	(two, _) = one.join({ key: "bo", tab: "b1", meta: ann, now: 0 })
	(three, _) = two.update("bo", { ..ann, name: "Bo" })
	beaten = three.heartbeat("ann", "a1", 10) ?? three
	beaten.version() == 3
}

expect Room.beat_every(Room.defaults) == 15000

# Saved as JSON and loaded, a room is the same room.
expect {
	(room, _) = start.join({ key: "ann", tab: "a1", meta: ann, now: 5 })
	(left, _) = room.leave("ann", "a1", 9)
	saved : Try(Room.Saved(Meta), [InvalidJson(Str)])
	saved = Json.parse(Json.to_str(left.save()))
	match saved {
		Ok(kept) => {
			back = Room.load(kept)
			back.members() == left.members() and back.deadline() == left.deadline() and back.version() == left.version()
		}
		Err(_) => Bool.False
	}
}
