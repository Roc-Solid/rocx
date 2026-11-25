import tools.JsonValue

## A message of a conversation with the model: who says it (`User`, or the model, `Assistant`) and
## its content blocks, as the Messages API has them (text, the model's thinking, a tool's use and its
## result). The model's own messages are kept exactly as they came, thinking and all: the API reads
## them again in the next turn of the conversation, and refuses some that were changed.
##
## A conversation is a `List(Message)`; `save` writes one as JSON text to keep (in `Kv`, a table),
## `load` reads it back.
Message := { role : [User, Assistant], content : List(JsonValue) }.{
	is_eq : _

	## The user's message: `text`.
	user : Str -> Message
	user = |said| { role: User, content: [text_block(said)] }

	## A message of the model's, of text alone: an earlier answer, written by the app.
	assistant : Str -> Message
	assistant = |said| { role: Assistant, content: [text_block(said)] }

	## A message of its content blocks, as the API writes them.
	of_blocks : [User, Assistant], List(JsonValue) -> Message
	of_blocks = |role, content| { role: role, content: content }

	## Who says the message.
	role_of : Message -> [User, Assistant]
	role_of = |message| message.role

	## Its content blocks, as the API writes them.
	blocks : Message -> List(JsonValue)
	blocks = |message| message.content

	## Its text: its text blocks' text, joined, without the model's thinking or its tools' use.
	text : Message -> Str
	text = |message|
		Str.join_with(
			message.content.keep_oks(
				|block|
					if block.get("type") == Ok(String("text")) {
						block.get("text")?.to_text().map_err(|_| Missing)
					} else {
						Err(Missing)
					},
			),
			"",
		)

	## The message as the API takes it: `{"role":"user","content":[…]}`.
	to_json : Message -> JsonValue
	to_json = |message| {
		role =
			match message.role {
				User => "user"
				Assistant => "assistant"
			}
		Object([("role", String(role)), ("content", Array(message.content))])
	}

	## A message the API (or `to_json`) wrote. Content that is text alone (`"content":"Hi"`) is one
	## text block.
	from_json : JsonValue -> Try(Message, [InvalidJson(Str)])
	from_json = |value| {
		role =
			match value.get("role") {
				Ok(String("user")) => User
				Ok(String("assistant")) => Assistant
				_ => return Err(InvalidJson("a message's role is user or assistant"))
			}
		match value.get("content") {
			Ok(Array(content)) => Ok({ role: role, content: content })
			Ok(String(said)) => Ok({ role: role, content: [text_block(said)] })
			_ => Err(InvalidJson("a message's content is a list of blocks, or text"))
		}
	}

	## A conversation as JSON text, to keep.
	save : List(Message) -> Str
	save = |messages| JsonValue.to_str(Array(messages.map(Message.to_json)))

	## A conversation `save` wrote.
	load : Str -> Try(List(Message), [InvalidJson(Str)])
	load = |kept_text|
		match JsonValue.parse(kept_text)? {
			Array(items) => {
				var $messages = []
				for item in items {
					$messages = $messages.append(Message.from_json(item)?)
				}
				Ok($messages)
			}
			_ => Err(InvalidJson("a conversation is a list of messages"))
		}
}

## A text block.
text_block : Str -> JsonValue
text_block = |said| Object([("type", String("text")), ("text", String(said))])

expect Message.text(Message.user("Hi")) == "Hi"

expect JsonValue.to_str(Message.to_json(Message.user("Hi"))) == "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Hi\"}]}"

# Thinking and a tool's use aren't its text; two text blocks are.
expect {
	blocks = [
		Object([("type", String("thinking")), ("thinking", String("hmm")), ("signature", String("s"))]),
		text_block("Let me look. "),
		Object([("type", String("tool_use")), ("id", String("t1")), ("name", String("find")), ("input", Object([]))]),
		text_block("Found it."),
	]
	Message.text(Message.of_blocks(Assistant, blocks)) == "Let me look. Found it."
}

# A conversation saved and loaded is the same, exactly.
expect {
	thinking = Object([("type", String("thinking")), ("thinking", String("")), ("signature", String("EqQBCgIYAhIM"))])
	conversation = [Message.user("Hi"), Message.of_blocks(Assistant, [thinking, text_block("Hello")])]
	Message.load(Message.save(conversation)) == Ok(conversation)
}

expect Message.from_json(Object([("role", String("user")), ("content", String("Hi"))])) == Ok(Message.user("Hi"))
