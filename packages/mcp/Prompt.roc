import Content
import JsonValue

## A message template an agent's user picks from a menu (a slash command, say): its name, the
## arguments it takes, and the messages it makes of them.
##
##     review = Prompt.new("review", "Reviews a note", [Prompt.argument("id", "The note's id")], |args, _| {
##         id = args.get("id") ?? ""
##         Ok({ description: "", messages: [Prompt.user("Review note ${id}: is it clear?")] })
##     })
Prompt(ctx) := {
	name : Str,
	title : Str,
	description : Str,
	arguments : List(Argument),
	get : Dict(Str, Str), ctx => Try(Got, Str),
}.{

	## A prompt: its name, what it is for, its arguments, and the messages it makes of them (or why
	## it can't, an argument it can't use, said to the client).
	new : Str, Str, List(Argument), (Dict(Str, Str), ctx => Try(Got, Str)) -> Prompt(ctx)
	new = |name, description, arguments, get!| { name: name, title: "", description: description, arguments: arguments, get: get! }

	## The prompt, with a title for people.
	titled : Prompt(ctx), Str -> Prompt(ctx)
	titled = |prompt, title| { ..prompt, title: title }

	## An argument the prompt can't do without: its name, and what it is.
	argument : Str, Str -> Argument
	argument = |name, description| { name: name, description: description, required: Bool.True }

	## An argument the prompt can do without.
	optional : Str, Str -> Argument
	optional = |name, description| { name: name, description: description, required: Bool.False }

	## A message from the user, of text.
	user : Str -> Message
	user = |said| { role: User, content: Text(said) }

	## A message from the assistant, of text.
	assistant : Str -> Message
	assistant = |said| { role: Assistant, content: Text(said) }

	## An argument (`Prompt.argument`, `Prompt.optional`).
	Argument : { name : Str, description : Str, required : Bool }

	## One of the messages a prompt makes: who says it, and what.
	Message : { role : [User, Assistant], content : Content }

	## What a prompt makes: a description, and its messages.
	Got : { description : Str, messages : List(Message) }

	## The prompt as `prompts/list` lists it.
	to_json : Prompt(ctx) -> JsonValue
	to_json = |prompt| {
		argument_json = |taken|
			JsonValue.object_of([
				("name", Ok(String(taken.name))),
				("description", JsonValue.text_unless_empty(taken.description)),
				("required", Ok(Boolean(taken.required))),
			])
		JsonValue.object_of([
			("name", Ok(String(prompt.name))),
			("title", JsonValue.text_unless_empty(prompt.title)),
			("description", JsonValue.text_unless_empty(prompt.description)),
			("arguments", if (prompt.arguments.is_empty()) Err(Absent) else Ok(Array(prompt.arguments.map(argument_json)))),
		])
	}

	## What a prompt made, as `prompts/get` answers it.
	got_json : Got -> List((Str, JsonValue))
	got_json = |got| {
		message_json = |message| {
			role =
				match message.role {
					User => "user"
					Assistant => "assistant"
				}
			Object([("role", String(role)), ("content", Content.to_json(message.content))])
		}
		described = if (got.description.is_empty()) [] else [("description", String(got.description))]
		described.append(("messages", Array(got.messages.map(message_json))))
	}

	## The arguments `prompts/get` was sent, as the prompt takes them: each a string; a required one
	## missing is refused.
	arguments_of : Prompt(ctx), JsonValue -> Try(Dict(Str, Str), Str)
	arguments_of = |prompt, given| {
		pairs =
			match given {
				Object(fields) => fields
				Null => []
				_ => return Err("A prompt's arguments are an object of strings")
			}
		var $taken = []
		for (key, value) in pairs {
			match value {
				String(said) => {
					$taken = $taken.append((key, said))
				}
				_ => return Err("The argument ${key} is a string")
			}
		}
		taken = Dict.from_list($taken)
		match prompt.arguments.find_first(|wanted| wanted.required and taken.get(wanted.name).is_err()) {
			Ok(missing) => Err("Missing required argument: ${missing.name}")
			Err(_) => Ok(taken)
		}
	}
}

nothing : Dict(Str, Str), {} => Try(Prompt.Got, Str)
nothing = |_, _| Ok({ description: "", messages: [] })

review : Prompt({})
review = Prompt.new("review", "Reviews a note", [Prompt.argument("id", "The note's id"), Prompt.optional("tone", "How blunt")], nothing).titled("Review a note")

expect
	JsonValue.to_str(Prompt.to_json(review))
		== "{\"name\":\"review\",\"title\":\"Review a note\",\"description\":\"Reviews a note\",\"arguments\":[{\"name\":\"id\",\"description\":\"The note's id\",\"required\":true},{\"name\":\"tone\",\"description\":\"How blunt\",\"required\":false}]}"

expect Prompt.arguments_of(review, Object([("id", String("7"))])).map_ok(|taken| taken.get("id")) == Ok(Ok("7"))
expect Prompt.arguments_of(review, Object([("tone", String("kind"))])) == Err("Missing required argument: id")
expect Prompt.arguments_of(review, Object([("id", Number("7"))])) == Err("The argument id is a string")
expect Prompt.arguments_of(review, Null) == Err("Missing required argument: id")

expect
	JsonValue.to_str(Object(Prompt.got_json({ description: "A review", messages: [Prompt.user("Review this"), Prompt.assistant("Sure")] })))
		== "{\"description\":\"A review\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Review this\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"Sure\"}}]}"
