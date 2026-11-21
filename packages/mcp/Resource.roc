import Base64
import JsonValue

## What an agent can read from the app, by URI (`notes://index`): reading one gives its contents,
## text or bytes. A family of them, whose URIs a template matches, is a `Template`.
##
##     index = Resource.text("notes://index", "index", "text/markdown", |_| Ok(Notes.index_md!({})))
Resource(ctx) := {
	uri : Str,
	name : Str,
	title : Str,
	description : Str,
	mime : Str,
	read : ctx => Try(List(Contents), Str),
}.{

	## A resource: its URI, its name, and what reading it gives (or why it can't be read).
	new : Str, Str, (ctx => Try(List(Contents), Str)) -> Resource(ctx)
	new = |uri, name, read!| { uri: uri, name: name, title: "", description: "", mime: "", read: read! }

	## A resource that is text of one type (`text/markdown`): what reading it gives.
	text : Str, Str, Str, (ctx => Try(Str, Str)) -> Resource(ctx)
	text = |uri, name, mime, read!| {
		uri: uri,
		name: name,
		title: "",
		description: "",
		mime: mime,
		read: |ctx| read!(ctx).map_ok(|said| [{ uri: uri, mime: mime, body: Text(said) }]),
	}

	## The resource, with a title for people.
	titled : Resource(ctx), Str -> Resource(ctx)
	titled = |resource, title| { ..resource, title: title }

	## The resource, with what it is, for the model.
	described : Resource(ctx), Str -> Resource(ctx)
	described = |resource, description| { ..resource, description: description }

	## The resource, with its type (`application/json`).
	typed : Resource(ctx), Str -> Resource(ctx)
	typed = |resource, mime| { ..resource, mime: mime }

	## One of what reading a resource gives: its URI, its type, and its text or bytes.
	contents : Str, Str, [Text(Str), Blob(List(U8))] -> Contents
	contents = |uri, mime, body| { uri: uri, mime: mime, body: body }

	## The resource as `resources/list` lists it.
	to_json : Resource(ctx) -> JsonValue
	to_json = |resource|
		JsonValue.object_of([
			("uri", Ok(String(resource.uri))),
			("name", Ok(String(resource.name))),
			("title", JsonValue.text_unless_empty(resource.title)),
			("description", JsonValue.text_unless_empty(resource.description)),
			("mimeType", JsonValue.text_unless_empty(resource.mime)),
		])

	## What reading a resource gives (`Resource.contents`).
	Contents : { uri : Str, mime : Str, body : [Text(Str), Blob(List(U8))] }

	## Contents as `resources/read` (and an embedded resource) writes them: text, or bytes as Base64.
	contents_json : Contents -> JsonValue
	contents_json = |read| {
		body =
			match read.body {
				Text(said) => ("text", String(said))
				Blob(bytes) => ("blob", String(Base64.encode(bytes)))
			}
		JsonValue.object_of([("uri", Ok(String(read.uri))), ("mimeType", JsonValue.text_unless_empty(read.mime)), (body.0, Ok(body.1))])
	}
}

expect Resource.contents_json({ uri: "notes://index", mime: "text/markdown", body: Text("# Notes") }) == Object([("uri", String("notes://index")), ("mimeType", String("text/markdown")), ("text", String("# Notes"))])
expect Resource.contents_json({ uri: "pics://dot", mime: "", body: Blob([0, 255]) }) == Object([("uri", String("pics://dot")), ("blob", String("AP8="))])
