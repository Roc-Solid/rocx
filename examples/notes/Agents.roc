import pf.Endpoint
import pf.Middleware
import mcp.Mcp
import mcp.Prompt
import mcp.Resource
import mcp.Template
import Generated/Handlers
import McpHttp
import Middlewares
import Note
import Notebook

## Acme Notes for AI clients: an MCP server (packages/mcp) at `/mcp`, which Claude, an IDE or the
## MCP Inspector call with a personal access token. Its tools are the JSON API's endpoints, so what
## an agent may do is what a script may do, checked by the same code: each is an endpoint
## (`McpHttp.endpoint`), and a tool's arguments fill its path's params too (`read_note`'s `id`).
##
## The server is mounted from main.roc, the place for what sits in front of the routes: its tools
## run the endpoints' handlers (`Generated/Handlers`, D-037), which import every route file, so
## no module a route file imports may import them; main.roc, and this module, which only it
## imports, may.
Agents := [].{

	## What every tool, resource and prompt is given: the request, and who is asking
	## (`Middlewares.Me`: the token's person, and whether it may only read).
	Caller : McpHttp.Caller(Middlewares.Me)

	## What the server offers.
	server : Mcp.Server(Agents.Caller)
	server = {
		name: "acme-notes",
		version: "1.0.0",
		title: "Acme Notes",
		instructions: "Someone's personal notes, in Markdown, with tags. Find notes with search_notes (words, \"a phrase\", -without, #tag), then read one whole with read_note before changing it. Prefer append_to_note for adding to a note: it never overwrites. Archive a note rather than asking to delete it; archived notes are still found by search. A token may be read-only: then the tools that write are refused.",
		tools: [
			McpHttp.endpoint(Handlers.post_api_search, { name: "search_notes", title: "Search notes", description: "Finds notes by their words, best match first, archived ones too. The query takes words, \"an exact phrase\", or, -without, and #tag to look only at notes with that tag (\"#work\" alone lists them). Each result has the note's id, title, tags and the parts that matched." }, McpHttp.openapi({})).read_only(),
			McpHttp.endpoint(Handlers.get_api_notes_id, { name: "read_note", title: "Read a note", description: "A note whole, by its id: its title, its body in Markdown, its tags, and whether it is pinned or archived." }, McpHttp.openapi({})).read_only(),
			McpHttp.endpoint(Handlers.post_api_notes, { name: "create_note", title: "Create a note", description: "Writes a new note: a title (up to 200 characters), a body in Markdown, and tags (lower case letters, digits and dashes; up to 12; [] for none). Answers the note, with its id." }, McpHttp.openapi({})).additive(),
			McpHttp.endpoint(Handlers.post_api_notes_id_append, { name: "append_to_note", title: "Add to a note", description: "Adds text (Markdown) at the end of a note, after a blank line, keeping everything already there. Answers the note as it is now." }, McpHttp.openapi({})).additive(),
			McpHttp.endpoint(Handlers.put_api_notes_id_tags, { name: "tag_note", title: "Tag a note", description: "Sets a note's tags: all of them, so read the note first to keep the ones it has. Tags are lower case letters, digits and dashes; up to 12." }, McpHttp.openapi({})).idempotent(),
			McpHttp.endpoint(Handlers.put_api_notes_id_archived, { name: "archive_note", title: "Archive a note", description: "Archives a note (archived: true), which takes it out of the list but keeps it, still found by search; or brings it back (archived: false)." }, McpHttp.openapi({})).idempotent().additive(),
		],
		resources: [
			Resource.text("notes://index", "index", "text/markdown", index!).titled("Your notes").described("Every note that isn't archived, pinned first: its title, id, tags and when it last changed."),
		],
		templates: [
			Template.new("notes://note/{id}", "note", note!).titled("A note").described("A note as Markdown, by its id: its title as a heading, its tags, its body.").typed("text/markdown"),
		],
		prompts: [
			Prompt.new("summarize_note", "Summarizes a note in a few bullet points, and suggests tags for it.", [Prompt.argument("id", "The note's id")], summarize!).titled("Summarize a note"),
			Prompt.new("capture", "Turns rough text (a meeting's notes, a thought) into a tidy note, saved with create_note.", [Prompt.argument("text", "What to capture"), Prompt.optional("tags", "Tags it should have, separated by commas")], capture!).titled("Capture as a note"),
		],
	}

	## The MCP server at `/mcp`, as a middleware main.roc puts after the app's default: a request
	## there carries a personal access token (`Middlewares.agent`) and is counted against its limit
	## (`Middlewares.agent_limit`) before the server answers it, as the person the token is theirs;
	## every other request goes on to the app's routes.
	mount : Middleware({}, {})
	mount = Middleware.make(
		|request, context, next!|
			if request.path == "/mcp" {
				Middleware.run!(Middlewares.agent.then(Middlewares.agent_limit), request, {}, |asked, me| McpHttp.respond!(Agents.server, asked, me))
			} else {
				next!(request, context)
			},
	)
}

## `notes://index`: the notes that aren't archived, as a Markdown list.
index! : Agents.Caller => Try(Str, Str)
index! = |caller| {
	notes = Notebook.list!(caller.context, { archived: Bool.False, tags: [] }).map_err(told)?
	lines = notes.map(
		|note| {
			pin = if (note.pinned) " (pinned)" else ""
			tags = if (note.tags.is_empty()) "" else " ${Str.join_with(note.tags.map(|tag| "#${tag}"), " ")}"
			"- [${note.title}](notes://note/${note.id})${pin}${tags}, changed ${Note.day(note.updated)}"
		},
	)
	Ok(if (lines.is_empty()) "# Your notes\n\nNo notes yet.\n" else "# Your notes\n\n${Str.join_with(lines, "\n")}\n")
}

## `notes://note/{id}`: a note as Markdown.
note! : Dict(Str, Str), Str, Agents.Caller => Try(List(Resource.Contents), [NotFound, Failed(Str)])
note! = |names, uri, caller|
	match Notebook.read!(caller.context, names.get("id") ?? "") {
		Ok(found) => Ok([Resource.contents(uri, "text/markdown", Text(Note.markdown(found)))])
		Err(NotFound) => Err(NotFound)
		Err(refused) => Err(Failed(told(refused)))
	}

## `summarize_note`: the note, and what to do with it.
summarize! : Dict(Str, Str), Agents.Caller => Try(Prompt.Got, Str)
summarize! = |arguments, caller| {
	found = Notebook.read!(caller.context, arguments.get("id") ?? "").map_err(told)?
	Ok({
		description: "Summarize “${found.title}”",
		messages: [Prompt.user("Summarize this note of mine in three to five bullet points, then suggest up to three tags for it (lower case, dashes for spaces) that it doesn't have yet. If any would help, offer to add them with tag_note.\n\n${Note.markdown(found)}")],
	})
}

## `capture`: rough text, and how to make a note of it.
capture! : Dict(Str, Str), Agents.Caller => Try(Prompt.Got, Str)
capture! = |arguments, _caller| {
	text = arguments.get("text") ?? ""
	tags = arguments.get("tags") ?? ""
	wanted = if (tags.trim().is_empty()) "" else " It should have these tags: ${tags}."
	Ok({
		description: "Capture as a note",
		messages: [Prompt.user("Turn this into a tidy note: a short title, then the body in Markdown, with headings or lists where they help, keeping every fact and dropping filler.${wanted} Search my notes first (search_notes): if one is about the same thing, add to it with append_to_note rather than starting another. Otherwise save it with create_note.\n\n${text}")],
	})
}

## A refusal of Notebook's as text.
told : Endpoint.Refusal -> Str
told = |refusal| {
	(_, why) = Endpoint.refused(refusal)
	why
}

# Every tool, resource, template and prompt is one MCP takes: names it allows, none given twice,
# every schema JSON (packages/mcp's own check).
expect Mcp.problems(Agents.server) == []
