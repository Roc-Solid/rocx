import tools.JsonValue
import Message

## One turn of the model's, put together from the events of its stream (`step`, an event's data at
## a time): its content blocks, why it stopped, and what it cost. While it comes, `step` says what
## there is to pass on: text as it is written (`Text`), a tool the model is about to use
## (`Calling`), and a progress note it wrote between tool calls (`Progress`).
##
## Each block is kept as the API wrote it, its deltas joined: a text block's text, a thinking block's
## thinking and signature (the API checks the signature when the conversation goes on), a tool use's
## input (its JSON, read once whole).
Turn := {
	id : Str,
	model : Str,
	blocks : List(Block),
	stop : Str,
	category : Str,
	usage : Usage,
}.{
	is_eq : _

	## What a turn cost: the tokens read (`input`; `cache_read` of them from the prompt cache, and
	## `cache_write` written to it) and the tokens written (`output`, thinking too).
	Usage : { input : U64, output : U64, cache_read : U64, cache_write : U64 }

	## What a turn says while it comes: text, as the model writes it; the name of a tool it is about
	## to use; and a progress note it wrote between its tool calls (a thinking block with text, which
	## the API sends when a call asks for `display: "updates"`).
	Heard : [Text(Str), Calling(Str), Progress(Str)]

	## Why a turn stopped: it was done (`EndTurn`); it reached `max_tokens` (`MaxTokens`); it wants
	## its tools used (`ToolUse`); it paused a long turn, to be sent again to go on (`PauseTurn`); it
	## declined (`Refusal`, with the API's category, "" for none); or another reason, as the API
	## names it.
	Stop : [EndTurn, MaxTokens, StopSequence, ToolUse, PauseTurn, Refusal(Str), Other(Str)]

	## A turn before its first event.
	start : Turn
	start = { id: "", model: "", blocks: [], stop: "", category: "", usage: { input: 0, output: 0, cache_read: 0, cache_write: 0 } }

	## The turn after one more event (its data), and what to pass on. An `error` event is `Failed`,
	## with the error's type (`overloaded_error`) and message.
	step : Turn, Str -> Try({ turn : Turn, heard : List(Turn.Heard) }, [Failed(Str, Str), InvalidJson(Str)])
	step = |turn, data| {
		event = JsonValue.parse(data)?
		quiet = |changed| Ok({ turn: changed, heard: [] })
		match event.get("type") {
			Ok(String("message_start")) => {
				started = event.get("message") ?? Null
				quiet({
					..turn,
					id: text_at(started, "id"),
					model: text_at(started, "model"),
					usage: counted(turn.usage, started.get("usage") ?? Null),
				})
			}
			Ok(String("content_block_start")) => {
				index = count_at(event, "index")
				given = event.get("content_block") ?? Null
				fields =
					match given {
						Object(each) => each
						_ => []
					}
				kind = text_at(given, "type")
				block = { start: fields, kind: kind, text: text_at(given, "text"), thinking: text_at(given, "thinking"), signature: text_at(given, "signature"), json: "" }
				blocks = if (index < turn.blocks.len()) replaced(turn.blocks, index, block) else turn.blocks.append(block)
				heard = if (kind == "tool_use") [Calling(text_at(given, "name"))] else []
				Ok({ turn: { ..turn, blocks: blocks }, heard: heard })
			}
			Ok(String("content_block_delta")) => {
				index = count_at(event, "index")
				delta = event.get("delta") ?? Null
				match turn.blocks.get(index) {
					Ok(block) =>
						match delta.get("type") {
							Ok(String("text_delta")) => {
								said = text_at(delta, "text")
								Ok({ turn: { ..turn, blocks: replaced(turn.blocks, index, { ..block, text: Str.concat(block.text, said) }) }, heard: if (said.is_empty()) [] else [Text(said)] })
							}
							Ok(String("thinking_delta")) => quiet({ ..turn, blocks: replaced(turn.blocks, index, { ..block, thinking: Str.concat(block.thinking, text_at(delta, "thinking")) }) })
							Ok(String("signature_delta")) => quiet({ ..turn, blocks: replaced(turn.blocks, index, { ..block, signature: Str.concat(block.signature, text_at(delta, "signature")) }) })
							Ok(String("input_json_delta")) => quiet({ ..turn, blocks: replaced(turn.blocks, index, { ..block, json: Str.concat(block.json, text_at(delta, "partial_json")) }) })
							_ => quiet(turn)
						}
					Err(_) => quiet(turn)
				}
			}
			Ok(String("content_block_stop")) => {
				index = count_at(event, "index")
				match turn.blocks.get(index) {
					Ok(block) if block.kind == "thinking" and is_progress(block.thinking) => Ok({ turn: turn, heard: [Progress(block.thinking.trim())] })
					_ => quiet(turn)
				}
			}
			Ok(String("message_delta")) => {
				delta = event.get("delta") ?? Null
				stop =
					match delta.get("stop_reason") {
						Ok(String(reason)) => reason
						_ => turn.stop
					}
				details = delta.get("stop_details") ?? (event.get("stop_details") ?? Null)
				quiet({ ..turn, stop: stop, category: text_at(details, "category"), usage: counted(turn.usage, event.get("usage") ?? Null) })
			}
			Ok(String("error")) => {
				error = event.get("error") ?? Null
				Err(Failed(text_at(error, "type"), text_at(error, "message")))
			}
			_ => quiet(turn)
		}
	}

	## Whether the turn has stopped: its `message_delta` said why. A stream that ends before then
	## broke off.
	stopped : Turn -> Bool
	stopped = |turn| !turn.stop.is_empty()

	## Why the turn stopped.
	stop_of : Turn -> Turn.Stop
	stop_of = |turn|
		match turn.stop {
			"end_turn" => EndTurn
			"max_tokens" => MaxTokens
			"stop_sequence" => StopSequence
			"tool_use" => ToolUse
			"pause_turn" => PauseTurn
			"refusal" => Refusal(turn.category)
			other => Other(other)
		}

	## What the turn cost.
	usage_of : Turn -> Turn.Usage
	usage_of = |turn| turn.usage

	## The model that wrote it, as the API names it (a fallback's, when one took over).
	model_of : Turn -> Str
	model_of = |turn| turn.model

	## The model's message: its content blocks, as the next turn sends them back. After a fallback
	## mid-turn (a `fallback` block, where another model took over), the thinking and tool uses
	## before it are left out, as the API asks; the `fallback` block stays where it was.
	message : Turn -> Message
	message = |turn| Message.of_blocks(Assistant, kept(turn).map(written))

	## The tools the model asked to use, in order: each use's id, the tool's name, and its input
	## (`InvalidJson` with the text the model wrote, when that isn't JSON).
	calls : Turn -> List({ id : Str, name : Str, input : Try(JsonValue, [InvalidJson(Str)]) })
	calls = |turn|
		kept(turn)
			.keep_if(|block| block.kind == "tool_use")
			.map(
				|block| {
					fields = Object(block.start)
					{ id: text_at(fields, "id"), name: text_at(fields, "name"), input: input_of(block) }
				},
			)
}

## A content block as it comes: the fields its start gave, and its deltas joined.
Block : { start : List((Str, JsonValue)), kind : Str, text : Str, thinking : Str, signature : Str, json : Str }

## The blocks the next turn is sent: after the last `fallback` block, all; before it, none of the
## declining model's thinking or tool uses.
kept : Turn -> List(Block)
kept = |turn| {
	var $last = Err(NoFallback)
	var $index = 0
	for block in turn.blocks {
		if block.kind == "fallback" {
			$last = Ok($index)
		}
		$index = $index + 1
	}
	match $last {
		Ok(boundary) => {
			var $kept = []
			var $at = 0
			for block in turn.blocks {
				dropped = $at < boundary and ["thinking", "redacted_thinking", "tool_use"].contains(block.kind)
				if !dropped {
					$kept = $kept.append(block)
				}
				$at = $at + 1
			}
			$kept
		}
		Err(NoFallback) => turn.blocks
	}
}

## Whether a thinking block's text is a progress note: any text, but the one the API puts where
## work was cut off (`max_tokens`), which says nothing a page should show.
is_progress : Str -> Bool
is_progress = |text| {
	said = text.trim()
	!said.is_empty() and said != interrupted
}

interrupted : Str
interrupted = "This part of the response was interrupted before it finished."

## A block as the API wrote it, its deltas in.
written : Block -> JsonValue
written = |block|
	match block.kind {
		"text" => Object(with_field(block.start, "text", String(block.text)))
		"thinking" => Object(with_field(with_field(block.start, "thinking", String(block.thinking)), "signature", String(block.signature)))
		"tool_use" | "server_tool_use" => Object(with_field(block.start, "input", input_of(block) ?? Object([])))
		_ => Object(block.start)
	}

## A tool use's input: its JSON, once whole; the start's (`{}`) when no delta came.
input_of : Block -> Try(JsonValue, [InvalidJson(Str)])
input_of = |block|
	if block.json.trim().is_empty() {
		Ok(object(block.start).get("input") ?? Object([]))
	} else {
		match JsonValue.parse(block.json) {
			Ok(input) => Ok(input)
			Err(_) => Err(InvalidJson(block.json))
		}
	}

## The fields with `key` set to `value`: in its place if it is there, else last.
with_field : List((Str, JsonValue)), Str, JsonValue -> List((Str, JsonValue))
with_field = |fields, key, value|
	if fields.any(|(name, _)| name == key) {
		fields.map(|(name, old)| if (name == key) (name, value) else (name, old))
	} else {
		fields.append((key, value))
	}

## A field that is text; "" if it isn't there, or isn't text.
text_at : JsonValue, Str -> Str
text_at = |value, key|
	match value.get(key) {
		Ok(String(said)) => said
		_ => ""
	}

## A field that is a count; 0 if it isn't there, or isn't one.
count_at : JsonValue, Str -> U64
count_at = |value, key|
	match value.get(key) {
		Ok(Number(written_as)) => U64.from_str(written_as) ?? 0
		_ => 0
	}

## The usage after a `usage` object: each count it gives replaces the one before (the API's
## counts are totals so far).
counted : Turn.Usage, JsonValue -> Turn.Usage
counted = |usage, given| {
	or_before = |key, before|
		match given.get(key) {
			Ok(Number(written_as)) => U64.from_str(written_as) ?? before
			_ => before
		}
	{
		input: or_before("input_tokens", usage.input),
		output: or_before("output_tokens", usage.output),
		cache_read: or_before("cache_read_input_tokens", usage.cache_read),
		cache_write: or_before("cache_creation_input_tokens", usage.cache_write),
	}
}

## Each event in turn, from the start.
played : List(Str) -> Try({ turn : Turn, heard : List(Turn.Heard) }, [Failed(Str, Str), InvalidJson(Str)])
played = |events| {
	var $turn = Turn.start
	var $heard = []
	for event in events {
		next = Turn.step($turn, event)?
		$turn = next.turn
		$heard = $heard.concat(next.heard)
	}
	Ok({ turn: $turn, heard: $heard })
}

# A turn of thinking, text and a tool's use, its deltas joined.
expect {
	events = [
		"{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-haiku-5-5\",\"content\":[],\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0,\"output_tokens\":1}}}",
		"{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
		"{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQB\"}}",
		"{\"type\":\"content_block_stop\",\"index\":0}",
		"{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
		"{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me \"}}",
		"{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"look.\"}}",
		"{\"type\":\"content_block_stop\",\"index\":1}",
		"{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"find\",\"input\":{}}}",
		"{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\": \\\"te\"}}",
		"{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"a\\\"}\"}}",
		"{\"type\":\"content_block_stop\",\"index\":2}",
		"{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":40}}",
		"{\"type\":\"message_stop\"}",
	]
	match played(events) {
		Ok({ turn, heard }) =>
			heard == [Text("Let me "), Text("look."), Calling("find")]
				and Turn.stop_of(turn) == ToolUse
				and Turn.usage_of(turn) == { input: 12, output: 40, cache_read: 0, cache_write: 0 }
				and Turn.model_of(turn) == "claude-haiku-5-5"
				and JsonValue.to_str(Message.to_json(Turn.message(turn))) == "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"EqQB\"},{\"type\":\"text\",\"text\":\"Let me look.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"find\",\"input\":{\"q\":\"tea\"}}]}"
				and Turn.calls(turn) == [{ id: "toolu_1", name: "find", input: JsonValue.parse("{\"q\":\"tea\"}") }]
		Err(_) => Bool.False
	}
}

# A refusal, with its category.
expect {
	events = [
		"{\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}",
		"{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"cyber\"}},\"usage\":{\"output_tokens\":0}}",
	]
	match played(events) {
		Ok({ turn, .. }) => Turn.stop_of(turn) == Refusal("cyber") and Turn.stopped(turn)
		Err(_) => Bool.False
	}
}

# An error event fails the turn.
expect Turn.step(Turn.start, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}") == Err(Failed("overloaded_error", "Overloaded"))

# A tool use whose input isn't JSON: its text kept for the model, `{}` in the message.
expect {
	events = [
		"{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"find\",\"input\":{}}}",
		"{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\": \"}}",
	]
	match played(events) {
		Ok({ turn, .. }) => Turn.calls(turn) == [{ id: "t", name: "find", input: Err(InvalidJson("{\"q\": ")) }]
		Err(_) => Bool.False
	}
}

# After a fallback mid-turn, the declining model's thinking goes; its text and the fallback stay.
expect {
	events = [
		"{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"a\"}}",
		"{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"Part\"}}",
		"{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"fallback\",\"from\":{\"model\":\"claude-opus-5-5\"},\"to\":{\"model\":\"claude-opus-5\"}}}",
		"{\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"text\",\"text\":\"ly\"}}",
		"{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
	]
	match played(events) {
		Ok({ turn, .. }) => Turn.message(turn).blocks().map(|block| block.get("type") ?? Null) == [String("text"), String("fallback"), String("text")]
		Err(_) => Bool.False
	}
}

## The list with its item at `index` replaced (as it was, if there is none there).
replaced : List(a), U64, a -> List(a)
replaced = |items, index, item| items.set(index, item) ?? items

## An object of these fields.
object : List((Str, JsonValue)) -> JsonValue
object = |fields| Object(fields)

# A progress note: a thinking block with text, heard when it ends; an empty one (reasoning, hidden)
# and the interrupted-work sentinel are not.
expect {
	events = [
		"{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
		"{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"a\"}}",
		"{\"type\":\"content_block_stop\",\"index\":0}",
		"{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
		"{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Looking through \"}}",
		"{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"your notes.\"}}",
		"{\"type\":\"content_block_stop\",\"index\":1}",
		"{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"This part of the response was interrupted before it finished.\",\"signature\":\"b\"}}",
		"{\"type\":\"content_block_stop\",\"index\":2}",
	]
	match played(events) {
		Ok({ heard, .. }) => heard == [Progress("Looking through your notes.")]
		Err(_) => Bool.False
	}
}
