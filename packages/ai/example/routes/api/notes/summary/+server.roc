import pf.Server
import pf.Endpoint
import ai.Ai
import ../../../../Notes

## POST /api/notes/summary: the notes, summed up in a sentence or two (`Ai.ask!`).
post! : { request : Server.Request, params : {}, context : c, body : {} } => Try({ text : Str }, Endpoint.Refusal)
post! = |_input| {
	notes = Notes.all!({})
	if notes.is_empty() {
		Ok({ text: "There are no notes yet." })
	} else {
		listed = Str.join_with(notes.map(|note| "- ${note.text}"), "\n")
		match Ai.ask!({ system: "Sum up these notes for the person who wrote them, in one plain sentence that speaks to them as you.", prompt: listed, effort: Low }) {
			Ok(reply) => Ok({ text: reply.text })
			Err(problem) => Err(Status(502, Ai.explain(problem)))
		}
	}
}
