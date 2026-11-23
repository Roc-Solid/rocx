import Cursors
import Mirror
import Room
import Stack

## What a room's channel carries, as JSON. To a page, one event a message: its own key and tab
## (`Welcome`, first), who is here (`Presence`: a snapshot, then each change), someone typing or
## stopping (`Typing`), a cursor that moved (`Moved`), and one whose pointer left the area (`Away`).
## From a page, what it says (`Said`): it is here, with its status, or typing, or where its cursor
## is. Who says it is the channel's check's say (`Member`), never the page's. The server's hooks and
## the browser's stores both read it, so they can't disagree.
##
## A member's metadata on the wire is `Wire.Meta(d)`: their name, picture, colour and status, which
## the components read, and `data`, the app's own (a type of its choosing that JSON can carry: a
## team, a role, a cursor's label; `{}` for none). The server's hooks and the stores are generic in
## it, so the app's type goes through `Room`, `Mirror` and the channel as it is.
Wire := [].{

	## A member's metadata, as the room carries it: a name, a picture's URL (`""` for none), a colour
	## (`""`: one from their key), a status (`""`, `away`, `busy`: a word the app styles), and the
	## app's own `data` (`{}` for none).
	Meta(d) : { name : Str, image : Str, color : Str, status : Str, data : d }

	## A room's event.
	Event(m) : [Welcome({ key : Str, tab : Str }), Presence(Mirror.Message(m)), Typing({ key : Str, typing : Bool }), Moved(Cursors.Move), Away(Str)]

	## Who is in a room, as its channel's check lets them in (`Channel.allow`): their key (the app's
	## id for them) and metadata, from the middleware's context.
	Member(d) : { key : Str, meta : Wire.Meta(d) }

	## What a page says on a room's channel: this tab is here (its beat, every `Room.beat_every`, and
	## whenever its status changes: a word the app picks, `""` for none), its member is typing or
	## stopped, its cursor is at (`x`, `y`), shares of the area, or its pointer left the area.
	Said : [Here({ status : Str }), Typing(Bool), Moved({ x : Dec, y : Dec }), Away]

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

	## The `Live` topic a room's events are published on.
	topic : Str -> Str
	topic = |room| "presence:${room}"
}

expect Wire.topic("lobby") == "presence:lobby"

members : List(Room.Here(Wire.Meta({ team : Str })))
members = [{ key: "ann", meta: { name: "Ann", image: "", color: "#123456", status: "", data: { team: "red" } }, since: 0 }]

expect Wire.names(members, ["ann", "bo"]) == ["Ann", "bo"]

expect
	Wire.pointers(members, [{ key: "ann", x: 0.5, y: 0.5, idle: Bool.False }, { key: "bo", x: 0.1, y: 0.2, idle: Bool.True }])
		== [{ key: "ann", name: "Ann", color: "#123456", x: 0.5, y: 0.5, idle: Bool.False }, { key: "bo", name: "bo", color: Stack.color("bo"), x: 0.1, y: 0.2, idle: Bool.True }]

expect Wire.face({ key: "ann", meta: { name: "Ann", image: "", color: "", status: "away", data: {} }, since: 0 }) == { key: "ann", name: "Ann", image: "", color: "", status: "away" }

# The app's own metadata, through the room's events, both ways (R1).
expect {
	event : Wire.Event(Wire.Meta({ team : Str, score : U64 }))
	event = Presence(Snapshot({ version: 4, members: [{ key: "ann", meta: { name: "Ann", image: "", color: "", status: "", data: { team: "red", score: 3 } }, since: 10 }] }))
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

expect {
	said : Wire.Said
	said = Here({ status: "away" })
	parsed : Try(Wire.Said, [InvalidJson(Str)])
	parsed = Json.parse(Json.to_str(said))
	parsed == Ok(said)
}
