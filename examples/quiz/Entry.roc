import pf.Endpoint
import pf.Random
import pf.Server
import forms.Issues
import Codes
import Game
import Generated/Paths
import Rooms
import Sets
import Visitor

## Coming into a room, on the server: joining one as a player (the front page's form, and a room's
## own page), and opening one as its host. The endpoints that do these are a few lines each; what
## they share is here. Server-only: it asks the rooms' actors, and reads the sets from Postgres.
Entry := [].{

	## The visitor joins room `code` as `name`, and is sent to its page (with their cookie, if they
	## had none). A room that won't have them is a refusal with the issue at the field it is about,
	## as the join forms show it.
	join! : Visitor.Context, Str, Str => Try({}, Endpoint.Refusal)
	join! = |context, code, name| {
		me = Visitor.id!(context)
		match Rooms.ask!(code, Join({ visitor: me.visitor, name })) {
			Joined(_) => Err(Answer(Visitor.remembered(Server.redirect(Paths.play_code({ code: code })), me)))
			Unjoined(why) => Err(Issues.refusal([Entry.issue(why)]))
			_ => Err(Status(503, "The room didn't answer. Try again."))
		}
	}

	## Why someone couldn't join, as an issue at the field it is about.
	issue : Game.Unjoined -> Issues.Issue
	issue = |why| {
		(field, message) =
			match why {
				Vacant => ("code", "There's no room with that code.")
				Over => ("code", "That room's game has finished.")
				Full => ("code", "That room is full.")
				NoName => ("name", "Pick a name to play under.")
				NameTaken => ("name", "Someone in that room has this name already.")
			}
		{ field, code: Custom("join", message), message }
	}

	## The visitor opens a room for set `set` (its id, as a form posts it) and is sent to its
	## screen. The room's code is new: four random letters, asked for again if a room has them.
	open! : Visitor.Context, Str => Try({}, Endpoint.Refusal)
	open! = |context, set| {
		id = I64.from_str(set) ?? 0
		match Sets.load!(id) {
			Ok(loaded) => {
				me = Visitor.id!(context)
				opening = Open({ title: loaded.title, questions: loaded.questions, timing: Rooms.timing!({}), host: me.visitor })
				var $code = ""
				var $tries = 0
				while $code.is_empty() and $tries < 10 {
					$tries = $tries + 1
					candidate = Codes.from_bytes(Random.bytes!(8))
					if Codes.parse(candidate).is_ok() {
						match Rooms.ask!(candidate, opening) {
							Done => {
								$code = candidate
							}
							_ => {}
						}
					}
				}
				if $code.is_empty() {
					Err(Status(503, "No room code was free. Try again."))
				} else {
					Err(Answer(Visitor.remembered(Server.redirect(Paths.host_code({ code: $code })), me)))
				}
			}
			Err(NotFound) => Err(BadRequest("There's no such set."))
			Err(_) => Err(Status(503, "The sets couldn't be read. Try again."))
		}
	}
}
