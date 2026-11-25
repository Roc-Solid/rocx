import pf.Kv
import ai.Message

## Each chat's conversation, kept in the server's memory for a day: as `Message.save` writes it,
## the model's thinking and its tools' use and all, so the next turn sends it back as it came.
Chats := [].{

	## The chat's conversation; none for a chat not seen before.
	load! : Str => List(Message)
	load! = |chat| {
		saved : Try(Str, [NotFound, BadValue(Str)])
		saved = Kv.get!(key_of(chat))
		match saved {
			Ok(text) => Message.load(text) ?? []
			Err(_) => []
		}
	}

	## Keeps the chat's conversation.
	save! : Str, List(Message) => {}
	save! = |chat, messages| Kv.set!(key_of(chat), Message.save(messages), { ttl_ms: 86_400_000 })
}

key_of : Str -> Str
key_of = |chat| "example:chat:${chat}"
