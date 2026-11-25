## Server-sent events, read from a stream's bytes as they come: what the Messages API answers a
## request with `"stream": true` (`Http.fetch_chunks!` hands it on a chunk at a time).
Sse := [].{

	## The events whose ends `chunk` brings, after the bytes left over from the chunks before
	## (`rest`): each event's data (its `data:` lines, joined by line breaks; an event with none is
	## skipped), and the bytes of an event whose end hasn't come yet. A chunk may end anywhere, in an
	## event or in a character.
	feed : List(U8), List(U8) -> { events : List(Str), rest : List(U8) }
	feed = |rest, chunk| {
		var $bytes = rest.concat(chunk.drop_if(|byte| byte == '\r'))
		var $events = []
		var $more = Bool.True
		while $more {
			match end_of_event($bytes) {
				Ok(at) => {
					$events =
						match data_of($bytes.sublist({ start: 0, len: at })) {
							Ok(data) => $events.append(data)
							Err(NoData) => $events
						}
					$bytes = $bytes.drop_first(at + 2)
				}
				Err(NotYet) => {
					$more = Bool.False
				}
			}
		}
		{ events: $events, rest: $bytes }
	}
}

## Where the first event ends: the first blank line (two line breaks).
end_of_event : List(U8) -> Try(U64, [NotYet])
end_of_event = |bytes| {
	var $at = 0
	while $at + 1 < bytes.len() {
		if bytes.get($at) == Ok('\n') and bytes.get($at + 1) == Ok('\n') {
			return Ok($at)
		}
		$at = $at + 1
	}
	Err(NotYet)
}

## An event's data: its `data:` lines (one space after the colon dropped), joined.
data_of : List(U8) -> Try(Str, [NoData])
data_of = |event| {
	lines = Str.from_utf8_lossy(event).split_on("\n")
	data = lines.keep_if(|line| line.starts_with("data:")).map(|line| line.drop_prefix("data:").drop_prefix(" "))
	if (data.is_empty()) Err(NoData) else Ok(Str.join_with(data, "\n"))
}

expect Sse.feed([], "event: ping\ndata: {\"type\":\"ping\"}\n\n".to_utf8()) == { events: ["{\"type\":\"ping\"}"], rest: [] }

# An event split across chunks, a comment line, and the start of the next event kept.
expect {
	first = Sse.feed([], "event: a\ndata: {\"x\"".to_utf8())
	second = Sse.feed(first.rest, ":1}\n\n: comment\n\ndata: {\"y\":".to_utf8())
	first.events == [] and second.events == ["{\"x\":1}"] and second.rest == "data: {\"y\":".to_utf8()
}

# CR LF line ends, and a character split in two.
expect {
	bytes = "data: \"é\"\r\n\r\n".to_utf8()
	first = Sse.feed([], bytes.take_first(8))
	second = Sse.feed(first.rest, bytes.drop_first(8))
	second.events == ["\"é\""]
}

# Data on two lines.
expect Sse.feed([], "data: a\ndata: b\n\n".to_utf8()).events == ["a\nb"]
