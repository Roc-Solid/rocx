import pf.Endpoint
import pf.Env
import pf.Http
import pf.Log
import pf.OpenApi
import pf.Plugin
import pf.Time
import crypto.Base64
import tools.Content
import tools.JsonValue
import tools.Tool
import Message
import Sse
import Turn

## Claude, from the app's server, through Anthropic's Messages API: one effect for each way an app
## asks.
##
## - `ask!`: a question, its answer whole;
## - `stream!`: the answer passed on as it is written, a piece of text at a time (to a page, by an
##   endpoint's `events!`: when the page goes, the request ends, and the model stops writing);
## - `extract!`: the answer read into a Roc type, its JSON Schema the platform's (as
##   /openapi.json's), the model held to it;
## - `run!`: the model uses the app's tools (packages/tools' `Tool`s: one tool serves the app's MCP
##   server and its own model) until it is done.
##
## Each takes a `Request`: the prompt, or a conversation (`List(Message)`) to go on with, and what
## is left out has its default. Every call streams, so a long answer never times out; each turn is
## logged (`ai.turn`: the model, why it stopped, the tokens read, cached and written, how long it
## took). A rate limit, an overloaded API or a passing server error, before anything was heard, is
## tried again, twice, after the time the API
## asks for.
##
## ```roc
## plugins: [Ai.plugin({})]   # ANTHROPIC_API_KEY, and ANTHROPIC_MODEL if it isn't the default
##
## summary = Ai.ask!({ system: "Summarize in one sentence.", prompt: note.body })?.text
## ```
Ai := [].{

	## The API's key (`key`; "" for `ANTHROPIC_API_KEY`); the model (`model`; "" for
	## `ANTHROPIC_MODEL`, else `claude-opus-5-5`, or `claude-haiku-5-5` under `--dev`, where
	## answers should come fast and cost little); and where the API is (`base_url`; "" for
	## `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com`).
	Options := { key : Str ?? "", model : Str ?? "", base_url : Str ?? "" }

	## The AI plugin: its options, with the environment's where they leave something out, kept when
	## the server starts, and a look once started (`ai.model`: `default AI model: claude-opus-5-5`,
	## the model a call that names none is given; where the API is, when it isn't Anthropic's).
	## Outside `--dev` the server doesn't start without a key; under it, it starts, and each call
	## answers `NoKey`.
	plugin : Options -> Plugin.Value(context, ctx)
	plugin = |options| {
		given : Settings
		given = { key: options.key, model: options.model, base_url: options.base_url }
		{
			name: "ai",
			starts: [|_context| keep!(given)],
			checks: [{ name: "ai.model", run!: |_context| check!({}) }],
		}
	}

	## How hard the model thinks before it answers, and how much it writes: `Low` for a quick
	## answer (chat, a label), `Medium` (the default), `High` for work that needs care, then
	## `XHigh` and `Max`. More costs more tokens and takes longer.
	Effort : [Low, Medium, High, XHigh, Max]

	## What to ask:
	##
	## - `prompt`: the user's message, after `messages` (`""`: none, `messages` is the conversation);
	## - `messages`: the conversation so far (an earlier `Reply`'s `messages`, or `Message.load`ed);
	## - `system`: how the model should go about it: its role, the rules, the app's facts;
	## - `model`: this call's model (`""`: the plugin's);
	## - `max_tokens`: how much the model may write, its thinking too, at most (64,000);
	## - `effort`: `Medium`;
	## - `cache`: whether what is sent is kept in the API's prompt cache for the next call to read
	##   (yes: a conversation's next turn, or the same system prompt again, costs a tenth for what
	##   was kept);
	## - `max_turns`: how many turns `run!` takes at most (10);
	## - `label`: what the call is, on the log (`ai.turn`'s `label`: `"summary"`, an agent's name), so
	##   what each part of the app spends can be told apart;
	## - `updates`: whether `run!` tells its listener what to show while the model works (`Update`):
	##   the progress notes the model writes between tool calls (asked of the models that write them:
	##   Opus 5.5, Sonnet 5.5, Fable), each of the app's tools as it starts to run, with what it says
	##   it is doing, and the same from every agent it calls as a tool (no: only text and `Calling`).
	Request := {
		prompt : Str ?? "",
		messages : List(Message) ?? [],
		system : Str ?? "",
		model : Str ?? "",
		max_tokens : U64 ?? 64_000,
		effort : [Low, Medium, High, XHigh, Max] ?? Medium,
		cache : Bool ?? Bool.True,
		max_turns : U64 ?? 10,
		label : Str ?? "",
		updates : Bool ?? Bool.False,
	}

	## What `run!` tells its listener as the model works: its text as it is written (`Text`), each
	## tool's name as the model is about to use it (`Calling`), and, when the call asks for
	## `updates`, what a page can show meanwhile (`Update`: packages/tools' `Tool.Update`, a progress
	## note or a tool in use, from this call's model or an agent it called).
	Heard : [Text(Str), Calling(Str), Update(Tool.Update)]

	## The answer: its text, the conversation with it (to go on with, or to keep), why the model
	## stopped (`MaxTokens`: the text is cut off), what it cost (all of `run!`'s turns), and the
	## model that wrote it.
	Reply : { text : Str, messages : List(Message), stop : Turn.Stop, usage : Turn.Usage, model : Str }

	## What went wrong:
	##
	## - `NoKey`: no `ANTHROPIC_API_KEY`;
	## - `Status(code, why)`: the API refused (400: the request; 401: the key; 429: too many, still,
	##   after waiting; 529: overloaded);
	## - `Unreachable(why)`, `TimedOut`, `Broken(why)`: no whole answer came;
	## - `Refused(category)`: the model declined (the API's category, as `"cyber"`; often "");
	## - `Truncated`: `extract!`'s answer reached `max_tokens` before its JSON ended;
	## - `InvalidJson(why)`: `extract!`'s answer didn't fit its type;
	## - `TooManyTurns(reply)`: `run!` took `max_turns` turns and the model still wanted its tools:
	##   what it had done (its tools ran, perhaps changing things), as a `Reply` whose `messages`
	##   end with the last tools' results (so it can be kept, or gone on with) and whose `usage` is
	##   every turn's (to bill), `stop` `ToolUse`;
	## - `Stopped(why)`: the function given each piece of text said to stop.
	Problem(err) : [NoKey, Status(U16, Str), Unreachable(Str), TimedOut, Broken(Str), Refused(Str), Truncated, InvalidJson(Str), TooManyTurns(Reply), Stopped(err)]

	## The answer, whole.
	##
	##     reply = Ai.ask!({ system: "Answer in one sentence.", prompt: question })?
	##     reply.text
	ask! : Request => Try(Reply, Problem([]))
	ask! = |request| asked!(request, Err(NoFormat), |_| Ok({}))

	## The answer, each piece of text passed to `heard!` as the model writes it; then the whole.
	## An `Err` from `heard!` ends the request there (the model stops), as `Stopped`. From an
	## endpoint's `events!`, to a page:
	##
	##     Events.stream(|{ send!, .. }|
	##         match Ai.stream!({ prompt: params.question }, |text| send!({ text: text })) {
	##             Ok(_) => send!({ text: "" })
	##             Err(Stopped(Gone)) => Err(Gone)
	##             Err(problem) => send!({ text: Ai.explain(problem) })
	##         })
	stream! : Request, (Str => Try({}, err)) => Try(Reply, Problem(err))
	stream! = |request, heard!|
		asked!(
			request,
			Err(NoFormat),
			|heard|
				match heard {
					Text(said) => heard!(said)
					_ => Ok({})
				},
		)

	## How `extract!` and `tool` write the JSON Schema of a type (`a`; `r` is a tool's answer's): as
	## the platform writes /openapi.json's (`OpenApi`), trying `tags` for the names of its unions'
	## tags (`["Breakfast", "Lunch"]`; `[]` for a type with none).
	Schema(a, r) : { describe : Endpoint({}, a, r), List(Str) -> Str, tags : List(Str) }

	## The platform's schemas, for `extract!` and `tool` (given as a value, so it is made where the
	## type is known: `Ai.schema([])`).
	schema = |tags| { describe: OpenApi.body, tags: tags }

	## A function of the app's as a tool the model can use (packages/tools' `Tool`, so an MCP server
	## can offer it too): its name and what it does, for the model; the function, given the
	## arguments as its type and the context `run!` was given; and how the arguments' schema is
	## written (`Ai.schema([])`). Its `Err` goes back to the model as a tool error.
	##
	##     Ai.tool("add_note", "Adds a note, and answers it with its id", add!, Ai.schema([]))
	tool : Str, Str, (arg, ctx => Try(result, Str)), Schema(arg, result) -> Tool(ctx) where [arg.Json.Parseable([InvalidJson(Str)]), result.Json.Encodable(e)]
	tool = |name, description, handler!, wanted| {
		describe = wanted.describe
		Tool.typed(name, description, describe(tool_witness(handler!), wanted.tags), handler!)
	}

	## The answer, read into a Roc type: the model is held to its JSON Schema (the API's structured
	## outputs), and what it writes is read with `Json`, as an endpoint reads a body. A type that
	## isn't a record is asked for as an object's `result` field.
	##
	##     Meal : { items : List({ food : Str, grams : U32 }) }
	##     meal : Meal
	##     meal = Ai.extract!({ prompt: "two eggs and a slice of toast" }, Ai.schema([]))?
	##
	## The schema is the API's subset: a record's fields are all required, none other allowed, and
	## what the API doesn't hold a model to (a `U8`'s range) is checked as it is read.
	extract! : Request, Schema(a, {}) => Try(a, Problem([])) where [a.Json.Parseable([InvalidJson(Str)])]
	extract! = |request, wanted| {
		describe = wanted.describe
		written = describe(witness_for(wanted), wanted.tags)
		described =
			match JsonValue.parse(written) {
				Ok(parsed) => strict(parsed)
				Err(InvalidJson(why)) => return Err(Broken("the answer's schema isn't JSON: ${why}"))
			}
		wrapped = described.get("type") != Ok(String("object"))
		outer = if (wrapped) Object([("type", String("object")), ("properties", Object([("result", described)])), ("required", Array([String("result")])), ("additionalProperties", Boolean(Bool.False))]) else described
		format = Object([("type", String("json_schema")), ("schema", outer)])
		reply = asked!(request, Ok(format), |_| Ok({}))?
		if reply.stop == MaxTokens {
			return Err(Truncated)
		}
		answered =
			match JsonValue.parse(reply.text) {
				Ok(parsed) => parsed
				Err(InvalidJson(why)) => return Err(InvalidJson("the answer isn't JSON: ${why}"))
			}
		decode_for(wanted, if (wrapped) (answered.get("result") ?? Null) else answered)
	}

	## The model, with the app's tools: each turn that asks for tools has them run (each in turn,
	## given `context`), their answers sent back, and the model goes on, until it stops asking (or
	## `max_turns`). `heard!` is given its text as it is written, and each tool's name as the model
	## is about to use it (`Calling`); with `updates`, what to show meanwhile (`Update`, `Heard`). A
	## tool's refusal (`Err("No note 7")`), arguments that don't
	## fit its type, and a tool it doesn't have go back to the model as a tool error, which it can
	## act on; a failure inside (`Failed`) too, its reason logged (`ai.tool`) and not sent. A turn cut
	## off at `max_tokens` (`stop` `MaxTokens`) ends the run: a tool call it hadn't finished isn't
	## run, and isn't in `messages` (which the API would refuse to go on with: a `tool_use` needs its
	## `tool_result`). After `max_turns`, `TooManyTurns` holds what was done.
	##
	##     tools = [Tool.typed("find_notes", "Finds the notes that mention a word", schema, Notes.find!)]
	##     reply = Ai.run!({ prompt: question }, tools, {}, |_| Ok({}))?
	run! : Request, List(Tool(ctx)), ctx, (Heard => Try({}, err)) => Try(Reply, Problem(err))
	run! = |request, tools, context, heard!| {
		settings = settings!({})
		if settings.key.is_empty() {
			return Err(NoKey)
		}
		model = model_for(settings, request)
		described = tools.map(tool_json)
		betas = betas_for(model, request)
		# What the turn hears, passed on: with `updates`, its progress notes too.
		relay! = |heard|
			match heard {
				Text(said) => heard!(Text(said))
				Calling(name) => heard!(Calling(name))
				Progress(said) => if (request.updates) heard!(Update(Progress({ agent: request.label, says: said }))) else Ok({})
			}
		var $messages = conversation_of(request)
		var $usage = { input: 0, output: 0, cache_read: 0, cache_write: 0 }
		var $turns = 0
		var $text = ""
		var $model = model
		while $turns < request.max_turns {
			turn = turn!(settings, model, betas, request.label, body_of(model, request, $messages, described, Err(NoFormat)), relay!)?
			message = Turn.message(turn)
			$messages = $messages.append(message)
			$usage = added($usage, Turn.usage_of(turn))
			$turns = $turns + 1
			$text = Message.text(message)
			$model = Turn.model_of(turn)
			match Turn.stop_of(turn) {
				Refusal(category) => return Err(Refused(category))
				ToolUse => {
					var $results = []
					for call in Turn.calls(turn) {
						# With `updates`, each tool the app has as it starts to run, with what it says it does.
						if request.updates and tools.any(|each| each.name == call.name) {
							match heard!(Update(Using({ agent: request.label, tool: call.name, says: doing_for(tools, call.name) }))) {
								Ok({}) => {}
								Err(why) => return Err(Stopped(why))
							}
						}
						$results = $results.append(called!(tools, context, call, if (request.updates) Listening(heard!) else Quiet))
					}
					$messages = $messages.append(Message.of_blocks(User, $results))
				}
				PauseTurn => {}
				MaxTokens => {
					# Cut off: a tool call it was writing isn't whole, and isn't run; the message
					# without it (none, when nothing else is left), so the conversation can go on.
					cut = Ai.without_calls(message)
					kept = $messages.drop_last(1).concat(if (Message.blocks(cut).is_empty()) [] else [cut])
					return Ok({ text: Message.text(message), messages: kept, stop: MaxTokens, usage: $usage, model: Turn.model_of(turn) })
				}
				stop => return Ok({ text: Message.text(message), messages: $messages, stop: stop, usage: $usage, model: Turn.model_of(turn) })
			}
		}
		Err(TooManyTurns({ text: $text, messages: $messages, stop: ToolUse, usage: $usage, model: $model }))
	}

	## A message without its tool calls (`tool_use` blocks): what is left of a turn cut off at
	## `max_tokens`.
	without_calls : Message -> Message
	without_calls = |message| Message.of_blocks(Message.role_of(message), Message.blocks(message).drop_if(|block| block.get("type") == Ok(String("tool_use"))))

	## What went wrong, in a sentence: for the log, or a page.
	explain : Problem(err) -> Str
	explain = |problem|
		match problem {
			NoKey => "no ANTHROPIC_API_KEY"
			Status(code, why) => "the API answered ${code.to_str()}: ${why}"
			Unreachable(why) => "the API couldn't be reached: ${why}"
			TimedOut => "the API's answer took too long"
			Broken(why) => "the API's answer broke off: ${why}"
			Refused(category) => if (category.is_empty()) "the model declined" else "the model declined (${category})"
			Truncated => "the answer reached max_tokens before it ended"
			InvalidJson(why) => "the answer didn't fit its type: ${why}"
			TooManyTurns(_) => "the model still wanted its tools after max_turns turns"
			Stopped(_) => "stopped"
		}
}

## The API's version: what the request's shape is.
api_version : Str
api_version = "2026-10-21"

## The model when none is named, and under `--dev`.
default_model : Str
default_model = "claude-opus-5-5"

dev_model : Str
dev_model = "claude-haiku-5-5"

## The models that take `"fallbacks": "default"`: when one declines, the API runs the request
## again on the model it names for that refusal's category.
falls_back : Str -> Bool
falls_back = |model| ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-mythos-5-2", "claude-mythos-5-1"].contains(model)

## The beta that `fallbacks` needs.
fallback_beta : Str
fallback_beta = "server-side-fallback-2026-07-01"

## The models that write progress notes between tool calls, sent as text with `display: "updates"`
## and its beta: Opus 5.5, Sonnet 5.5, Fable and Mythos (not Haiku 5.5, whose notes come as text).
writes_updates : Str -> Bool
writes_updates = |model| ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-fable-5", "claude-mythos-5-2", "claude-mythos-5-1"].contains(model)

## The beta that `display: "updates"` needs.
updates_beta : Str
updates_beta = "thinking-display-updates-2026-08-18"

## The betas a request needs, as `anthropic-beta` lists them: the fallback's, and the progress
## notes'.
betas_for : Str, Ai.Request -> Str
betas_for = |model, request| {
	fallback = if (falls_back(model)) [fallback_beta] else []
	updates = if (request.updates and writes_updates(model)) [updates_beta] else []
	Str.join_with(fallback.concat(updates), ",")
}

## What a tool says it is doing while it runs ("" when it says nothing, or there is no such tool).
doing_for : List(Tool(ctx)), Str -> Str
doing_for = |tools, name|
	match tools.find_first(|tool| tool.name == name) {
		Ok(tool) => Tool.doing_of(tool)
		Err(_) => ""
	}

## Where the plugin keeps its settings.
settings_key : Str
settings_key = "ai:settings"

## The key, the default model (a call's own wins: `model_for`), and where the API is.
Settings : { key : Str, model : Str, base_url : Str }

## The options, with the environment's where they leave something out.
resolved! : Settings => Settings
resolved! = |given| {
	key = (if (given.key.is_empty()) (Env.var!("ANTHROPIC_API_KEY") ?? "") else given.key).trim()
	named = (if (given.model.is_empty()) (Env.var!("ANTHROPIC_MODEL") ?? "") else given.model).trim()
	dev = Env.dev!({})
	model = if (!named.is_empty()) named else if (dev) dev_model else default_model
	base = (if (given.base_url.is_empty()) (Env.var!("ANTHROPIC_BASE_URL") ?? "") else given.base_url).trim()
	{ key: key, model: model, base_url: if (base.is_empty()) anthropic else base.drop_suffix("/") }
}

## The plugin's start: its settings kept; outside `--dev`, none without a key.
keep! : Settings => Try({}, Str)
keep! = |given| {
	found = resolved!(given)
	if found.key.is_empty() and !Env.dev!({}) {
		Err("no ANTHROPIC_API_KEY: the AI plugin needs an Anthropic API key (console.anthropic.com), in the environment or as its key")
	} else {
		Plugin.keep!(settings_key, Json.to_str(found))
		Ok({})
	}
}

## The settings the plugin's start kept; the environment's, without the plugin.
settings! : {} => Settings
settings! = |{}| {
	none : Settings
	none = { key: "", model: "", base_url: "" }
	match Plugin.kept!(settings_key) {
		Ok(text) => {
			parsed : Try(Settings, [InvalidJson(Str)])
			parsed = Json.parse(text)
			parsed ?? resolved!(none)
		}
		Err(NotFound) => resolved!(none)
	}
}

## Said on the log once the server has started: the model a call that names none is given (each
## call may name its own), and where the API is when it isn't Anthropic's.
check! : {} => Try(Str, Str)
check! = |{}| {
	found = settings!({})
	if found.key.is_empty() {
		Ok("AI off: no ANTHROPIC_API_KEY (each call answers NoKey)")
	} else {
		Ok("default AI model: ${found.model}${if (found.base_url == anthropic) "" else ", at ${found.base_url}"}")
	}
}

## Anthropic's API, where a call goes unless `ANTHROPIC_BASE_URL` or the plugin's `base_url` says.
anthropic : Str
anthropic = "https://api.anthropic.com"

## The request's model, or the plugin's.
model_for : Settings, Ai.Request -> Str
model_for = |settings, request| if (request.model.is_empty()) settings.model else request.model

## The conversation the request sends: its messages, then its prompt.
conversation_of : Ai.Request -> List(Message)
conversation_of = |request| if (request.prompt.is_empty()) request.messages else request.messages.append(Message.user(request.prompt))

## One turn, for `ask!`, `stream!` and `extract!`: the reply, or the model's refusal.
asked! : Ai.Request, Try(JsonValue, [NoFormat]), (Turn.Heard => Try({}, err)) => Try(Ai.Reply, Ai.Problem(err))
asked! = |request, format, heard!| {
	settings = settings!({})
	if settings.key.is_empty() {
		return Err(NoKey)
	}
	model = model_for(settings, request)
	messages = conversation_of(request)
	turn = turn!(settings, model, betas_for(model, request), request.label, body_of(model, request, messages, [], format), heard!)?
	message = Turn.message(turn)
	match Turn.stop_of(turn) {
		Refusal(category) => Err(Refused(category))
		stop => Ok({ text: Message.text(message), messages: messages.append(message), stop: stop, usage: Turn.usage_of(turn), model: Turn.model_of(turn) })
	}
}

## The request's JSON: the model, the conversation, the tools, how hard to think, the answer's
## schema, the cache and fallback the model takes, and, for `updates`, the model's progress notes
## as text (`display: "updates"`; its reasoning stays hidden).
body_of : Str, Ai.Request, List(Message), List(JsonValue), Try(JsonValue, [NoFormat]) -> Str
body_of = |model, request, messages, tools, format| {
	output = JsonValue.object_of([("effort", Ok(String(effort_name(request.effort)))), ("format", format.map_err(|NoFormat| Absent))])
	JsonValue.to_str(
		JsonValue.object_of([
			("model", Ok(String(model))),
			("max_tokens", Ok(JsonValue.uint(request.max_tokens))),
			("stream", Ok(Boolean(Bool.True))),
			("system", JsonValue.text_unless_empty(request.system)),
			("messages", Ok(Array(messages.map(Message.to_json)))),
			("tools", if (tools.is_empty()) Err(Absent) else Ok(Array(tools))),
			("output_config", Ok(output)),
			("cache_control", if (request.cache) Ok(Object([("type", String("ephemeral"))])) else Err(Absent)),
			("fallbacks", if (falls_back(model)) Ok(String("default")) else Err(Absent)),
			("thinking", if (request.updates and writes_updates(model)) Ok(Object([("type", String("adaptive")), ("display", String("updates"))])) else Err(Absent)),
		]),
	)
}

effort_name : Ai.Effort -> Str
effort_name = |effort|
	match effort {
		Low => "low"
		Medium => "medium"
		High => "high"
		XHigh => "xhigh"
		Max => "max"
	}

## A tool as the API takes it: its name, what it does, its arguments' schema; its input streamed
## as the model writes it (`eager_input_streaming`), read whole and checked against its type
## before it runs.
tool_json : Tool(ctx) -> JsonValue
tool_json = |tool| {
	listed = Tool.to_json(tool)
	JsonValue.object_of([
		("name", listed.get("name").map_err(|_| Absent)),
		("description", listed.get("description").map_err(|_| Absent)),
		("input_schema", Ok(listed.get("inputSchema") ?? Object([("type", String("object"))]))),
		("eager_input_streaming", Ok(Boolean(Bool.True))),
	])
}

## A tool the model asked for, run: its result, as the next turn sends it back.
called! : List(Tool(ctx)), ctx, { id : Str, name : Str, input : Try(JsonValue, [InvalidJson(Str)]) }, [Listening(Ai.Heard => Try({}, err)), Quiet] => JsonValue
called! = |tools, context, call, listener| {
	answered = |content, error|
		JsonValue.object_of([
			("type", Ok(String("tool_result"))),
			("tool_use_id", Ok(String(call.id))),
			("content", Ok(Array(content))),
			("is_error", if (error) Ok(Boolean(Bool.True)) else Err(Absent)),
		])
	refused = |why| answered([text_block(why)], Bool.True)
	match tools.find_first(|tool| tool.name == call.name) {
		Err(_) => refused("There is no tool named ${call.name}.")
		Ok(tool) =>
			match call.input {
				Err(InvalidJson(raw)) => refused("The input for ${call.name} wasn't JSON: ${raw}")
				Ok(input) => {
					outcome =
						match (listener, Tool.listener_of(tool)) {
							# A tool that works as a model does (an agent), its updates passed on.
							(Listening(heard!), Ok(listening!)) =>
								listening!(
									input,
									context,
									|update|
										match heard!(Update(update)) {
											Ok({}) => Ok({})
											Err(_) => Err(Stopped)
										},
								)
							_ => {
								prepare = tool.prepare
								match prepare(input) {
									Err(why) => Refused(why)
									Ok(run_tool!) => run_tool!(context)
								}
							}
						}
					match outcome {
						Answered(done) => answered(done.content.map(content_json), Bool.False)
						Refused(why) => refused(why)
						Failed(why) => {
							Log.error!("ai.tool", { tool: call.name, failure: why })
							refused("${call.name} failed.")
						}
					}
				}
			}
	}
}

## A tool's content, as a tool result holds it: text, an image; anything else as MCP writes it.
content_json : Content -> JsonValue
content_json = |content|
	match content {
		Text(said) => text_block(said)
		Image({ data, mime }) => Object([("type", String("image")), ("source", Object([("type", String("base64")), ("media_type", String(mime)), ("data", String(Base64.encode(data)))]))])
		_ => text_block(JsonValue.to_str(Content.to_json(content)))
	}

text_block : Str -> JsonValue
text_block = |said| Object([("type", String("text")), ("text", String(said))])

## One turn: the request sent, its stream read into the turn (`heard!` given what it says as it
## comes), and logged. A 408, 409, 429, 500, 502, 503, 504 or 529, or an overloaded stream, before
## anything was heard, is tried again, twice, after what the API's `retry-after` says (a minute at
## most; else half a second, then a second).
turn! : Settings, Str, Str, Str, Str, (Turn.Heard => Try({}, err)) => Try(Turn, Ai.Problem(err))
turn! = |settings, model, betas, label, body, heard!| {
	var $attempt = 0
	var $last = Err(Broken("no attempt"))
	while $attempt <= 2 {
		began = Time.now_millis!({})
		match attempt!(settings, betas, body, heard!) {
			Ok(turn) => {
				logged!(turn, label, Time.now_millis!({}) - began)
				return Ok(turn)
			}
			Err(Final(problem)) => return Err(problem)
			Err(Again(code, why, hinted)) => {
				$last = Err(Status(code, why))
				if $attempt < 2 {
					waited = hinted ?? (500 * ($attempt + 1))
					Log.warn!("ai.retry", { model: model, status: code, why: why, wait_ms: waited })
					Time.sleep!(waited)
				}
				$attempt = $attempt + 1
			}
		}
	}
	$last
}

## A turn on the log: what the call is (its label, when it has one), its model, why it stopped, its
## tokens, how long it took.
logged! : Turn, Str, U64 => {}
logged! = |turn, label, ms| {
	usage = Turn.usage_of(turn)
	stop =
		match Turn.stop_of(turn) {
			EndTurn => "end_turn"
			MaxTokens => "max_tokens"
			StopSequence => "stop_sequence"
			ToolUse => "tool_use"
			PauseTurn => "pause_turn"
			Refusal(category) => "refusal ${category}"
			Other(reason) => reason
		}
	if label.is_empty() {
		Log.info!("ai.turn", { model: Turn.model_of(turn), stop: stop, input: usage.input, output: usage.output, cache_read: usage.cache_read, cache_write: usage.cache_write, ms: ms })
	} else {
		Log.info!("ai.turn", { label: label, model: Turn.model_of(turn), stop: stop, input: usage.input, output: usage.output, cache_read: usage.cache_read, cache_write: usage.cache_write, ms: ms })
	}
}

## What a stream says as it is read: the turn so far, the bytes of an event not yet whole, and
## the answer's status (and its body, when it isn't a stream but an error).
Reading : { status : U16, retry_after : Str, failure : List(U8), rest : List(U8), turn : Turn, heard : Bool }

## One request, its stream read; `Again` for a failure worth trying again.
attempt! : Settings, Str, Str, (Turn.Heard => Try({}, err)) => Try(Turn, [Final(Ai.Problem(err)), Again(U16, Str, Try(U64, [Unsaid]))])
attempt! = |settings, beta_list, body, heard!| {
	betas = if (beta_list.is_empty()) [] else [("anthropic-beta", beta_list)]
	init : Http.Init
	init = {
		method: Post,
		headers: [("x-api-key", settings.key), ("anthropic-version", api_version), ("content-type", "application/json")].concat(betas),
		body: Http.bytes(body.to_utf8()),
		timeout_ms: 1_800_000,
		max_bytes: 0,
	}
	start : Reading
	start = { status: 0, retry_after: "", failure: [], rest: [], turn: Turn.start, heard: Bool.False }
	step! = |reading, received|
		match received {
			Head(res) => Ok({ ..reading, status: res.status, retry_after: res.header("retry-after") ?? "" })
			Chunk(bytes) =>
				if reading.status < 200 or reading.status >= 300 {
					Ok({ ..reading, failure: if (reading.failure.len() > 65_536) reading.failure else reading.failure.concat(bytes) })
				} else {
					fed = Sse.feed(reading.rest, bytes)
					var $turn = reading.turn
					var $heard = reading.heard
					for data in fed.events {
						match Turn.step($turn, data) {
							Ok(next) => {
								$turn = next.turn
								for each in next.heard {
									match heard!(each) {
										Ok({}) => {
											$heard = Bool.True
										}
										Err(why) => return Err(Listener(why))
									}
								}
							}
							Err(Failed(kind, message)) => return Err(EventFailed(kind, message, $heard))
							Err(InvalidJson(why)) => return Err(BadEvent(why))
						}
					}
					Ok({ ..reading, rest: fed.rest, turn: $turn, heard: $heard })
				}
		}
	match Http.fetch_chunks!("${settings.base_url}/v1/messages", init, start, step!) {
		Ok(reading) =>
			if reading.status < 200 or reading.status >= 300 {
				why = error_message(reading.failure)
				if (retried(reading.status)) Err(Again(reading.status, why, wait_of(reading.retry_after))) else Err(Final(Status(reading.status, why)))
			} else if !Turn.stopped(reading.turn) {
				Err(Final(Broken("the stream ended before the turn did")))
			} else {
				Ok(reading.turn)
			}
		Err(Stopped(Listener(why))) => Err(Final(Stopped(why)))
		Err(Stopped(EventFailed(kind, message, heard))) => {
			code = status_of(kind)
			if (!heard and retried(code)) Err(Again(code, message, Err(Unsaid))) else Err(Final(Status(code, "${kind}: ${message}")))
		}
		Err(Stopped(BadEvent(why))) => Err(Final(Broken("an event that isn't JSON: ${why}")))
		Err(HttpErr(why)) => Err(Final(Unreachable(why)))
		Err(TimedOut) => Err(Final(TimedOut))
		Err(TooLarge) => Err(Final(Broken("too large")))
	}
}

## Whether a status is worth trying again.
retried : U16 -> Bool
retried = |code| [408, 409, 429, 500, 502, 503, 504, 529].contains(code)

## How long `retry-after` says to wait (seconds), in milliseconds: a minute at most; `Unsaid`
## when it says nothing.
wait_of : Str -> Try(U64, [Unsaid])
wait_of = |written|
	match U64.from_str(written.trim()) {
		Ok(seconds) => Ok(U64.min(seconds, 60) * 1000)
		Err(_) => Err(Unsaid)
	}

## The status an error event stands for.
status_of : Str -> U16
status_of = |kind|
	match kind {
		"overloaded_error" => 529
		"rate_limit_error" => 429
		"invalid_request_error" => 400
		"authentication_error" => 401
		"permission_error" => 403
		"not_found_error" => 404
		"request_too_large" => 413
		"timeout_error" => 504
		_ => 500
	}

## An error answer's message (`{"type":"error","error":{"type":…,"message":…}}`), or its text.
error_message : List(U8) -> Str
error_message = |bytes| {
	text = Str.from_utf8_lossy(bytes)
	match JsonValue.parse(text) {
		Ok(answer) =>
			match answer.get("error") {
				Ok(error) =>
					match (error.get("type"), error.get("message")) {
						(Ok(String(kind)), Ok(String(message))) => "${kind}: ${message}"
						_ => text
					}
				Err(_) => text
			}
		Err(_) => text
	}
}

## Two turns' usage, added.
added : Turn.Usage, Turn.Usage -> Turn.Usage
added = |a, b| { input: a.input + b.input, output: a.output + b.output, cache_read: a.cache_read + b.cache_read, cache_write: a.cache_write + b.cache_write }

## An endpoint of the answer's type, for `OpenApi` to write its schema: never run.
witness_for : Ai.Schema(a, {}) -> Endpoint({}, a, {})
witness_for = |_| Endpoint.local_json("POST", "/", |_, _, _| crash "Ai: a witness of an answer's type, never run")

## An endpoint of a tool's types, for `OpenApi` to write its arguments' schema: never run.
tool_witness : (arg, ctx => Try(result, Str)) -> Endpoint({}, arg, result)
tool_witness = |_| Endpoint.local_json("POST", "/", |_, _, _| crash "Ai: a witness of a tool's types, never run")

## The answer read into its type.
decode_for : Ai.Schema(a, {}), JsonValue -> Try(a, Ai.Problem([])) where [a.Json.Parseable([InvalidJson(Str)])]
decode_for = |_, value|
	match JsonValue.decode(value) {
		Ok(decoded) => Ok(decoded)
		Err(InvalidJson(why)) => Err(InvalidJson(why))
	}

## A schema as the API's structured outputs take it: every object closed
## (`additionalProperties: false`), `oneOf` as `anyOf`, and what it doesn't hold a model to (a
## number's range, a string's length, an integer's `format`) left out, for `Json` to check as the
## answer is read.
strict : JsonValue -> JsonValue
strict = |schema|
	match schema {
		Object(fields) => {
			kept = fields.keep_if(|(key, value)| kept_keyword(key, value)).map(|(key, value)| strict_field(key, value))
			closed = fields.any(|(key, value)| key == "type" and value == String("object")) and !kept.any(|(key, _)| key == "additionalProperties")
			Object(if (closed) kept.append(("additionalProperties", Boolean(Bool.False))) else kept)
		}
		_ => schema
	}

## Whether a keyword stays in a structured output's schema.
kept_keyword : Str, JsonValue -> Bool
kept_keyword = |key, value|
	if ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "minItems", "maxItems"].contains(key) {
		Bool.False
	} else if key == "format" {
		match value {
			String(format) => ["date-time", "time", "date", "duration", "email", "hostname", "uri", "ipv4", "ipv6", "uuid"].contains(format)
			_ => Bool.False
		}
	} else {
		Bool.True
	}

## A keyword with the schemas in it made strict too.
strict_field : Str, JsonValue -> (Str, JsonValue)
strict_field = |key, value|
	match key {
		"properties" | "$defs" | "definitions" =>
			match value {
				Object(named) => (key, Object(named.map(|(name, inner)| (name, strict(inner)))))
				_ => (key, value)
			}
		"items" | "additionalProperties" | "not" => (key, strict(value))
		"oneOf" => ("anyOf", strict_each(value))
		"anyOf" | "allOf" | "prefixItems" => (key, strict_each(value))
		_ => (key, value)
	}

strict_each : JsonValue -> JsonValue
strict_each = |value|
	match value {
		Array(items) => Array(items.map(strict))
		_ => value
	}

expect {
	given = JsonValue.parse("{\"type\":\"object\",\"properties\":{\"minimum\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255},\"when\":{\"type\":\"string\",\"format\":\"date\"},\"kind\":{\"oneOf\":[{\"type\":\"string\",\"enum\":[\"A\"]},{\"type\":\"object\",\"properties\":{\"B\":{\"type\":\"integer\",\"format\":\"int64\"}},\"required\":[\"B\"],\"additionalProperties\":false}]}},\"required\":[\"minimum\",\"when\",\"kind\"]}") ?? Null
	JsonValue.to_str(strict(given)) == "{\"type\":\"object\",\"properties\":{\"minimum\":{\"type\":\"integer\"},\"when\":{\"type\":\"string\",\"format\":\"date\"},\"kind\":{\"anyOf\":[{\"type\":\"string\",\"enum\":[\"A\"]},{\"type\":\"object\",\"properties\":{\"B\":{\"type\":\"integer\"}},\"required\":[\"B\"],\"additionalProperties\":false}]}},\"required\":[\"minimum\",\"when\",\"kind\"],\"additionalProperties\":false}"
}

expect wait_of("2") == Ok(2000) and wait_of("0") == Ok(0) and wait_of("") == Err(Unsaid) and wait_of("600") == Ok(60_000)

expect error_message("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens: too large\"}}".to_utf8()) == "invalid_request_error: max_tokens: too large"

expect {
	cut = Message.of_blocks(Assistant, [Object([("type", String("text")), ("text", String("Let me add "))]), Object([("type", String("tool_use")), ("id", String("toolu_1")), ("name", String("add_note")), ("input", Object([]))])])
	Message.blocks(Ai.without_calls(cut)) == [Object([("type", String("text")), ("text", String("Let me add "))])] and Message.role_of(Ai.without_calls(cut)) == Assistant
}
expect Message.blocks(Ai.without_calls(Message.of_blocks(Assistant, [Object([("type", String("tool_use")), ("id", String("toolu_1")), ("name", String("x")), ("input", Object([]))])]))).is_empty()
