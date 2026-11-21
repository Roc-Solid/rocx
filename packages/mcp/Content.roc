import crypto.Base64
import JsonValue
import Resource

## What a tool answers with, and what a prompt's message holds: text; an image or a sound, its bytes
## and their type; a link to a resource the agent can read (`resources/read`); or a resource's
## contents in full.
Content := [
	Text(Str),
	Image({ data : List(U8), mime : Str }),
	Audio({ data : List(U8), mime : Str }),
	Link({ uri : Str, name : Str, mime : Str, description : Str }),
	Embedded(Resource.Contents),
].{
	is_eq : _

	## Some text.
	text : Str -> Content
	text = |said| Text(said)

	## An image: its bytes, and their type (`image/png`).
	image : List(U8), Str -> Content
	image = |data, mime| Image({ data: data, mime: mime })

	## A link to a resource: its URI and its name.
	link : Str, Str -> Content
	link = |uri, name| Link({ uri: uri, name: name, mime: "", description: "" })

	## The content as MCP writes it (a `ContentBlock`).
	to_json : Content -> JsonValue
	to_json = |content|
		match content {
			Text(said) => Object([("type", String("text")), ("text", String(said))])
			Image(media) => Object([("type", String("image")), ("data", String(Base64.encode(media.data))), ("mimeType", String(media.mime))])
			Audio(media) => Object([("type", String("audio")), ("data", String(Base64.encode(media.data))), ("mimeType", String(media.mime))])
			Link(linked) =>
				JsonValue.object_of([
					("type", Ok(String("resource_link"))),
					("uri", Ok(String(linked.uri))),
					("name", Ok(String(linked.name))),
					("description", JsonValue.text_unless_empty(linked.description)),
					("mimeType", JsonValue.text_unless_empty(linked.mime)),
				])
			Embedded(contents) => Object([("type", String("resource")), ("resource", Resource.contents_json(contents))])
		}
}

expect Content.to_json(Content.text("hi")) == Object([("type", String("text")), ("text", String("hi"))])
expect Content.to_json(Content.image([1, 2, 3], "image/png")) == Object([("type", String("image")), ("data", String("AQID")), ("mimeType", String("image/png"))])
expect Content.to_json(Content.link("notes://note/1", "note 1")) == Object([("type", String("resource_link")), ("uri", String("notes://note/1")), ("name", String("note 1"))])
expect JsonValue.to_str(Content.to_json(Embedded({ uri: "notes://index", mime: "text/plain", body: Text("hi") }))) == "{\"type\":\"resource\",\"resource\":{\"uri\":\"notes://index\",\"mimeType\":\"text/plain\",\"text\":\"hi\"}}"
