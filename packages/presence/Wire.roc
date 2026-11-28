import Cursors
import Mirror
import Room
import Stack

## What a room's channel carries, as JSON. To a page, one event a message: its own key and tab
## (`Welcome`, first), who is here (`Presence`: a snapshot, then each change), someone typing or
## stopping (`Typing`), a cursor that moved (`Moved`), and one whose pointer left the area (`Away`).
## From a page, what it says (`Said`): it is here, with its status; its member's `data` is new; it
## is typing; or where its cursor is. Who says it is the channel's check's say (`Member`), never the
## page's. The server's hooks and the browser's stores both read it, so they can't disagree.
##
## A member's metadata on the wire is `Wire.Meta(d)`: their name, picture and colour, which the
## channel's check gives, their status (`Stack.Status`), which the page says, and `data`, the app's
## own (a type of its choosing that JSON can carry: the card a person has open, a cursor's label;
## `{}` for none), which the check starts and the page may change (`Update`). The server's hooks and
## the stores are generic in it, so the app's type goes through `Room`, `Mirror` and the channel as
## it is.
Wire := [].{

	## A member's metadata, as the room carries it: a name, a picture's URL (`""` for none), a colour
	## (`""`: one from their key), a status (`Online`, `Away`, `Busy` or `Offline`), and the app's own
	## `data` (`{}` for none).
	Meta(d) : { name : Str, image : Str, color : Str, status : Stack.Status, data : d }

	## A room's event.
	Event(m) : [Welcome({ key : Str, tab : Str }), Presence(Mirror.Message(m)), Typing({ key : Str, typing : Bool }), Moved(Cursors.Move), Away(Str)]

	## Who is in a room, as its channel's check lets them in (`Channel.allow`): their key (the app's
	## id for them) and metadata, from the middleware's context.
	Member(d) : { key : Str, meta : Wire.Meta(d) }

	## What a page says on a room's channel: this tab is here (its beat, every `Room.beat_every`, and
	## whenever its status changes), its member's `data` is now this (`Update`: whenever the app says
	## so, and at a beat when the room has another), its member is typing or stopped, its cursor is at
	## (`x`, `y`), shares of the area, or its pointer left the area (`Away`).
	Said(d) : [Here({ status : Stack.Status }), Update(d), Typing(Bool), Moved({ x : Dec, y : Dec }), Away]

	## A member's metadata from their name and the app's `data` (`{}` for none): no picture (their
	## initials), a colour from their key, `Online`. A field of its own is a record update away:
	## `{ ..Wire.meta(name, {}), color: "#2e8fa3" }`.
	meta : Str, d -> Wire.Meta(d)
	meta = |called, data| { name: called, image: "", color: "", status: Online, data }

	## A member, as an avatar stack shows them.
	face : Room.Here(Wire.Meta(d)) -> Stack.Face
	face = |here| { key: here.key, name: here.meta.name, image: here.meta.image, color: here.meta.color, status: here.meta.status }

	## The names of `keys` (who is typing, say), as `members` has them: a key it doesn't have is its
	## own name.
	names : List(Room.Here(Wire.Meta(d))), List(Str) -> List(Str)
	names = |members, keys| keys.map(|key| Wire.name(members, key))

	## `key`'s name, as `members` has it, or `key` itself.
	name : List(Room.Here(Wire.Meta(d))), Str -> Str
	name = |members, key|
		match members.find_first(|member| member.key == key) {
			Ok(member) => member.meta.name
			Err(_) => key
		}

	## Cursors as `<LiveCursors>` draws them: each with its member's name and colour.
	pointers : List(Room.Here(Wire.Meta(d))), List(Cursors.Shown) -> List({ key : Str, name : Str, color : Str, x : Dec, y : Dec, idle : Bool })
	pointers = |members, cursors|
		cursors.map(
			|cursor| {
				(called, chosen) =
					match members.find_first(|member| member.key == cursor.key) {
						Ok(member) => (member.meta.name, member.meta.color)
						Err(_) => (cursor.key, "")
					}
				color = if (chosen.is_empty()) Stack.color(cursor.key) else chosen
				{ key: cursor.key, name: called, color, x: cursor.x, y: cursor.y, idle: cursor.idle }
			},
		)

	## A `Live` topic named for a room. Unused since rooms are channels: their events go on the
	## channel's own topic (`Endpoint.publish!`).
	topic : Str -> Str
	topic = |room| "presence:${room}"
}

expect Wire.topic("lobby") == "presence:lobby"

members : List(Room.Here(Wire.Meta({ team : Str })))
members = [{ key: "ann", meta: { ..Wire.meta("Ann", { team: "red" }), color: "#123456" }, since: 0 }]

expect Wire.names(members, ["ann", "bo"]) == ["Ann", "bo"]

expect
	Wire.pointers(members, [{ key: "ann", x: 0.5, y: 0.5, idle: Bool.False }, { key: "bo", x: 0.1, y: 0.2, idle: Bool.True }])
		== [{ key: "ann", name: "Ann", color: "#123456", x: 0.5, y: 0.5, idle: Bool.False }, { key: "bo", name: "bo", color: Stack.color("bo"), x: 0.1, y: 0.2, idle: Bool.True }]

expect Wire.face({ key: "ann", meta: { ..Wire.meta("Ann", {}), status: Away }, since: 0 }) == { key: "ann", name: "Ann", image: "", color: "", status: Away }

expect Wire.meta("Ann", { team: "red" }) == { name: "Ann", image: "", color: "", status: Online, data: { team: "red" } }

# The app's own metadata, through the room's events, both ways (R1).
expect {
	event : Wire.Event(Wire.Meta({ team : Str, score : U64 }))
	event = Presence(Snapshot({ version: 4, members: [{ key: "ann", meta: { ..Wire.meta("Ann", { team: "red", score: 3 }), status: Busy }, since: 10 }] }))
	parsed : Try(Wire.Event(Wire.Meta({ team : Str, score : U64 })), [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(event))
	parsed == Ok(event)
}

expect {
	event : Wire.Event({ name : Str })
	event = Typing({ key: "ann", typing: Bool.True })
	Json.to_str(event) == "{\"Typing\":{\"key\":\"ann\",\"typing\":true}}"
}

expect {
	event : Wire.Event({ name : Str })
	event = Moved({ key: "ann", x: 0.5, y: 0.25 })
	parsed : Try(Wire.Event({ name : Str }), [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(event))
	parsed == Ok(event)
}

expect {
	event : Wire.Event({ name : Str })
	event = Presence(Delta({ version: 3, change: Joined({ key: "ann", meta: { name: "Ann" }, since: 10 }) }))
	parsed : Try(Wire.Event({ name : Str }), [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(event))
	parsed == Ok(event)
}

# A status is its tag's name on the wire, and one that isn't a status isn't read.
expect {
	said : Wire.Said({})
	said = Here({ status: Away })
	parsed : Try(Wire.Said({}), [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(said))
	Json.to_str(said) == "{\"Here\":{\"status\":\"Away\"}}" and parsed == Ok(said)
}

expect {
	parsed : Try(Wire.Said({}), [InvalidJson(Str)])
	parsed = Json.parse("{\"Here\":{\"status\":\"card-12\"}}")
	parsed.is_err()
}

# The app's own data, said by a page, both ways.
expect {
	said : Wire.Said({ card : Str })
	said = Update({ card: "12" })
	parsed : Try(Wire.Said({ card : Str }), [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(said))
	Json.to_str(said) == "{\"Update\":{\"card\":\"12\"}}" and parsed == Ok(said)
}
