import pf.Endpoint
import Middlewares
import Note
import Store

## What can be done with someone's notes, whoever asks: the pages' endpoints, the JSON API's and,
## through those, the MCP tools all call these, so a rule is written once. Each takes who is asking
## (`Middlewares.Me`), checks what was sent with Note.roc's rules, refuses a write to a read-only
## token, and answers with what the endpoint answers: a value, or a refusal (`Endpoint.Refusal`, a
## status and why).
Notebook := [].{

	## Someone's notes, pinned first: the archived ones, or the rest; only those with every tag in
	## `tags`.
	list! : Middlewares.Me, { archived : Bool, tags : List(Str) } => Try(List(Note.Summary), Endpoint.Refusal)
	list! = |me, asked| stored!(Store.notes!(me.person.id, asked))

	## Someone's notes that match a search box's text (`Note.query_of`: words, and `#tags`).
	search! : Middlewares.Me, Str => Try(List(Note.Summary), Endpoint.Refusal)
	search! = |me, text| stored!(Store.search!(me.person.id, Note.query_of(text)))

	## Someone's tags, with how many notes have each.
	tags! : Middlewares.Me => Try(List(Note.Tagged), Endpoint.Refusal)
	tags! = |me| stored!(Store.tags!(me.person.id))

	## One of someone's notes. Another person's is a 404, as one that isn't there.
	read! : Middlewares.Me, Str => Try(Note.Full, Endpoint.Refusal)
	read! = |me, id| stored!(Store.note!(me.person.id, id))

	## A new note: a title, Markdown, tags.
	create! : Middlewares.Me, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Endpoint.Refusal)
	create! = |me, given| {
		Notebook.writer(me)?
		note = checked(given)?
		stored!(Store.create!(me.person.id, note))
	}

	## A note's title, body and tags, changed.
	update! : Middlewares.Me, Str, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Endpoint.Refusal)
	update! = |me, id, given| {
		Notebook.writer(me)?
		note = checked(given)?
		stored!(Store.update!(me.person.id, id, note))
	}

	## Text added at a note's end, after a blank line: a log kept up by hand, or by an agent.
	append! : Middlewares.Me, Str, Str => Try(Note.Full, Endpoint.Refusal)
	append! = |me, id, given| {
		Notebook.writer(me)?
		text = Note.addition_of(given).map_err(|why| BadRequest(why))?
		note = Notebook.read!(me, id)?
		if note.body.count_utf8_bytes() + text.count_utf8_bytes() + 2 > 100_000 {
			Err(BadRequest("The note would be over 100,000 characters."))
		} else {
			stored!(Store.append!(me.person.id, id, text))
		}
	}

	## A note's tags: all of them, as given (`[]` for none).
	tag! : Middlewares.Me, Str, List(Str) => Try(Note.Full, Endpoint.Refusal)
	tag! = |me, id, given| {
		Notebook.writer(me)?
		tags = Note.tags_of(given).map_err(|why| BadRequest(why))?
		stored!(Store.set_tags!(me.person.id, id, tags))
	}

	## A note archived (out of the list, still found by search), or brought back. An archived note
	## isn't pinned.
	archive! : Middlewares.Me, Str, Bool => Try(Note.Full, Endpoint.Refusal)
	archive! = |me, id, archived| {
		Notebook.writer(me)?
		stored!(Store.set_archived!(me.person.id, id, archived))
	}

	## A note pinned to the top of the list, or let go. An archived note can't be pinned.
	pin! : Middlewares.Me, Str, Bool => Try(Note.Full, Endpoint.Refusal)
	pin! = |me, id, pinned| {
		Notebook.writer(me)?
		stored!(Store.set_pinned!(me.person.id, id, pinned))
	}

	## A note deleted for good.
	delete! : Middlewares.Me, Str => Try({}, Endpoint.Refusal)
	delete! = |me, id| {
		Notebook.writer(me)?
		stored!(Store.delete!(me.person.id, id))
	}

	## Whether who is asking may write: a session may, and a token unless it was made read-only
	## (403, saying so).
	writer : Middlewares.Me -> Try({}, Endpoint.Refusal)
	writer = |me| if (me.read_only) Err(Status(403, "This token can only read. Make one that may write in Settings.")) else Ok({})
}

## A note as given, checked: its title, body and tags as Note.roc reads them, or why not (400).
checked : { title : Str, body : Str, tags : List(Str) } -> Try({ title : Str, body : Str, tags : List(Str) }, Endpoint.Refusal)
checked = |given| {
	title = Note.title_of(given.title).map_err(|why| BadRequest(why))?
	body = Note.body_of(given.body).map_err(|why| BadRequest(why))?
	tags = Note.tags_of(given.tags).map_err(|why| BadRequest(why))?
	Ok({ title, body, tags })
}

## A query's answer, or the refusal its problem is (`Store.refused!`).
stored! : Try(a, Store.Problem) => Try(a, Endpoint.Refusal)
stored! = |done|
	match done {
		Ok(value) => Ok(value)
		Err(problem) => Err(Store.refused!(problem))
	}
