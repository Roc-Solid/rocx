import pf.Kv
import ai.Ai
import tools.Tool

## The notes the assistant keeps, in the server's memory, and the tools that keep them: each a
## function of the app's (`add!`), made a tool in a line (`Ai.tool`), its arguments' schema the
## platform's. The same `Tool`s (packages/tools) could be an MCP server's (packages/mcp). Each says
## what a page shows while it runs (`doing`).
Notes := [].{

	## A note: its number, and what it says.
	Note : { id : U64, text : Str }

	## Every note, oldest first.
	all! : {} => List(Notes.Note)
	all! = |{}| Kv.get!(key) ?? []

	## The tools the chat's model has.
	tools : List(Tool({}))
	tools = [
		Ai.tool("list_notes", "Lists every note, oldest first: its id and its text.", listed!, Ai.schema([])).doing("Looking through your notes…"),
		Ai.tool("add_note", "Adds a note of the text given. Answers the note, with its id.", added!, Ai.schema([])).doing("Writing that down…"),
		Ai.tool("remove_note", "Removes the note with the id given. Answers how many notes are left.", removed!, Ai.schema([])).doing("Crossing it out…"),
	]

	## What the chat's model is told.
	guide : Str
	guide = "You keep the user's notes for them, with the tools list_notes, add_note and remove_note. When they tell you something to remember, add it as a note; when they ask what they noted, list the notes first. Answer in a sentence or two, plain text, no Markdown."
}

key : Str
key = "example:notes"

listed! : {}, {} => Try(List(Notes.Note), Str)
listed! = |{}, {}| Ok(Notes.all!({}))

added! : { text : Str }, {} => Try(Notes.Note, Str)
added! = |given, {}| {
	text = given.text.trim()
	if text.is_empty() {
		Err("A note needs some text.")
	} else {
		notes = Notes.all!({})
		id = notes.last().map_ok(|note| note.id + 1) ?? 1
		note = { id: id, text: text }
		Kv.set!(key, notes.append(note), {})
		Ok(note)
	}
}

removed! : { id : U64 }, {} => Try({ left : U64 }, Str)
removed! = |given, {}| {
	notes = Notes.all!({})
	if notes.any(|note| note.id == given.id) {
		left = notes.drop_if(|note| note.id == given.id)
		Kv.set!(key, left, {})
		Ok({ left: left.len() })
	} else {
		Err("There is no note ${given.id.to_str()}.")
	}
}
