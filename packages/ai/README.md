# ai

Claude, from a Roc Solid app's server (D-085), through Anthropic's Messages API: a question answered
whole (`Ai.ask!`), an answer streamed to a page as it is written (`Ai.stream!`), an answer read into
a Roc type (`Ai.extract!`), a model that uses the app's own functions as tools until it is done
(`Ai.run!`), and agents: a model with its role and tools, which another agent can use as a tool
(`Agent`, as Strands Agents' agents as tools). Pure Roc on the server platform's
`Http.fetch_chunks!`: no platform change, no SDK.

The package keeps the parts that are easy to get wrong: the stream's events put back together into
the model's message, its thinking and signatures exactly as they came (the API checks them when a
conversation goes on); a rate limit, an overloaded API or a passing server error tried again after
the time the API asks for, but never once text has gone to a page; a refusal that the app must handle rather than empty text; the request
ended when the page that asked goes, so the model stops writing; a JSON Schema the API's structured
outputs accept, written from a Roc type; each turn's tokens on the log. The app keeps its prompts,
its tools and what it does with the answers.

The docs site's page, `/ecosystem/ai`, is the guide; this is the reference. `example/` is a notes
assistant (a chat with an assistant agent that hands notes to a notes keeper and meals to a
nutritionist, each an agent it uses as a tool; a summary; a meal read into a record),
and its tests (`example/test`) run it against a stand-in for the API (`example/test/stand-in.mjs`),
never the API itself.

## Installing it

1. Name the package in the app's header, with the two it uses (it names the server platform, so
   only the server's half of an app sees it), and list its plugin:

   ```roc
   app [program] { ai: "../packages/ai/main.roc", crypto: "../packages/crypto/main.roc", pf: platform "../server/platform/main.roc", tools: "../packages/tools/main.roc" }

   program = App.program({
       init!: |_started| Ok({}),
       middleware: Middleware.same_origin({}),
       plugins: [Ai.plugin({})],
   })
   ```

2. Give the server an API key (console.anthropic.com): `ANTHROPIC_API_KEY`, in the environment or
   in the file `--env-file` names (`rocx dev` names the `.env` where it runs; D-088, D-098).
   Outside `--dev` the server doesn't start without one; under `--dev` (as `rocx dev` starts it) it
   starts, and each call answers `NoKey`.

3. The model is `claude-opus-5-5`, and `claude-haiku-5-5` under `--dev`, where answers should
   come fast and cost little. `ANTHROPIC_MODEL`, or the plugin's `model`, names another for both;
   a request's `model` for one call. Once started, the server logs which it is (`ai.model`):

   ```text
   claude-haiku-5-5 (the model under --dev: ANTHROPIC_MODEL or the plugin's model names another), at https://api.anthropic.com
   ```

`Ai.plugin({ key, model, base_url })` takes each instead of the environment's
(`ANTHROPIC_BASE_URL` is where the API is: the tests point it at their stand-in).

## Asking

Every call takes an `Ai.Request`, a record whose fields all have defaults but one of `prompt` or
`messages`:

| Field | Default | What it is |
|---|---|---|
| `prompt` | `""` | The user's message, after `messages` |
| `messages` | `[]` | The conversation so far: an earlier reply's `messages`, or `Message.load`ed |
| `system` | `""` | How the model should go about it: its role, the rules, the app's facts |
| `model` | the plugin's | This call's model |
| `max_tokens` | `64_000` | How much the model may write, its thinking too |
| `effort` | `Medium` | `Low`, `Medium`, `High`, `XHigh`, `Max`: how hard it thinks; more costs more and takes longer |
| `cache` | `Bool.True` | Keep what is sent in the API's prompt cache, so the next call that starts the same reads it for a tenth |
| `max_turns` | `10` | How many turns `run!` takes at most |
| `label` | `""` | What the call is, on the log (`ai.turn`'s `label`: `"summary"`, an agent's name) |
| `updates` | `Bool.False` | Whether `run!` tells its listener what to show while the model works ([Updates](#updates)) |

```roc
reply = Ai.ask!({ system: "Answer in one sentence.", prompt: question, effort: Low })?
reply.text
```

The reply is `{ text, messages, stop, usage, model }`: its text; the conversation with it (to go
on with, or keep); why the model stopped (`EndTurn`, `MaxTokens` when the text is cut off,
`ToolUse`, ...); what it cost (`{ input, output, cache_read, cache_write }`, in tokens); and the
model that wrote it.

## Streaming to a page

`Ai.stream!(request, heard!)` gives `heard!` each piece of text as the model writes it. From an
endpoint's `events!`, each piece is an event the page listens to (`Endpoint.listen!`). When the page
goes, `send!` answers `Err(Gone)`, `heard!` passes it on, and the request to the API is closed: the
model stops writing, and stops costing.

```roc
events! = |{ params, .. }|
    Ok(Events.stream(|{ send!, .. }|
        match Ai.stream!({ prompt: params.question }, |text| send!({ text: text })) {
            Ok(_) => send!({ text: "" })
            Err(Stopped(Gone)) => Err(Gone)
            Err(problem) => send!({ text: Ai.explain(problem) })
        }))
```

`events!` takes no body: a page posts what it asks first (the example keeps a chat's conversation
in `Kv` under its id), then listens to the events of a path that names it.

## Typed answers

`Ai.extract!(request, Ai.schema(tags))` holds the model to the JSON Schema of the answer's type (the
API's structured outputs) and reads what it writes into that type with `Json`, as an endpoint reads
a body:

```roc
Meal : { items : List({ food : Str, grams : U32, kcal : U32 }), total_kcal : U32 }

meal : Meal
meal = Ai.extract!({ system: "Read the meal into its foods.", prompt: said }, Ai.schema([]))?
```

The schema is the platform's, as /openapi.json's (`OpenApi`); `tags` names the tags of the type's
unions (`["Breakfast", "Lunch"]`), as a union's parser doesn't say them. It is made the API's subset
on the way: every object closed (`additionalProperties: false`), `oneOf` as `anyOf`, and what the
API doesn't hold a model to (an integer's range, a string's length) left out, for `Json` to check as
the answer is read: an answer outside a `U32` is `InvalidJson`, not a wrong number. A type that
isn't a record is asked for as an object's `result` field. `Ai.schema` is given as a value so it is
made where the type is known (as `McpHttp.openapi({})` is).

## Tools

`Ai.run!(request, tools, context, heard!)` sends the model the tools; each turn that asks for some
has them run, in order, each given `context`, and their answers sent back, until the model stops
asking (or `max_turns`: `TooManyTurns(reply)`, what it had done, its `messages` and `usage`, to
keep and to bill: its tools ran). `heard!` (an `Ai.Heard`) is given `Text(piece)` as the
model writes and `Calling(name)` as it is about to use a tool; with `updates`, `Update(…)` too
([Updates](#updates)). A turn cut off at `max_tokens` (`stop: MaxTokens`) ends the run; a tool
call it was writing isn't run, and isn't in `messages`, so the conversation can be sent again.

A tool is packages/tools' `Tool`, which packages/mcp serves too, so one tool serves the app's own
model and its MCP server alike.
`Ai.tool` makes one from a function of the app's, its arguments' schema the platform's:

```roc
tools = [
    Ai.tool("add_note", "Adds a note of the text given. Answers the note, with its id.", add!, Ai.schema([])),
    Ai.tool("remove_note", "Removes the note with the id given.", remove!, Ai.schema([])),
]

add! : { text : Str }, {} => Try(Note, Str)
remove! : { id : U64 }, {} => Try({ left : U64 }, Str)
```

`McpHttp.endpoint`'s, `McpHttp.tool`'s and `Tool.typed`'s tools work too, with their own context
(an MCP tool's is `McpHttp.Caller(c)`: the request, the context, `progress!`). What the model gets
back:

- the tool's answer, as JSON text (`Tool.answer`);
- its `Err(why)`, as a tool error (`is_error`), which the model can read and act on;
- arguments that don't fit the tool's type, input that isn't JSON, and a tool it doesn't have, as
  tool errors too;
- a failure inside (`Failed`), as `"<name> failed."`, its reason logged (`ai.tool`) and not sent.

Each tool's input is streamed as the model writes it (`eager_input_streaming`), then read whole and
checked against its type before the tool runs; a turn cut off by `max_tokens` or a refusal never
runs its tools.

## Agents

An `Agent(ctx)` is a model with a role and its tools, made once as a plain value and asked as often
as needed:

```roc
keeper : Agent({})
keeper = {
    name: "notes_keeper",
    description: "Keeps the user's notes. Give it a task in words: add a note, say what is noted, or remove one.",
    system: "You keep the user's notes, with the tools list_notes, add_note and remove_note.",
    tools: Notes.tools,
    effort: Low,
}

reply = Agent.ask!(keeper, "What did I note about the dentist?", {}, |_| Ok({}))?
reply = Agent.chat!(keeper, conversation, {}, heard!)?
```

Its fields: `name` and `description` (what a model that uses it as a tool reads), `system`,
`tools` (`[]`), `model` (the plugin's), `effort` (`Medium`), `max_turns` (10), `max_tokens`
(64,000), `updates` (`Bool.False`, [Updates](#updates)) and `doing` (`""`: what a page shows while
another agent has it at work). `ask!` is a conversation of one message, `chat!` the next turn of one; both are `Ai.run!`
with the agent's settings, its turns logged under its name (`label`).

**Agents as tools.** `agent.as_tool()` is the agent as a packages/tools `Tool`: its name and
description are the tool's, and it takes one argument, `task`, the work it is handed in words. So a
team is plain values, specialists each with its own prompt and tools, and an agent that knows when
to ask which:

```roc
assistant : Agent({})
assistant = {
    name: "assistant",
    description: "The user's assistant.",
    system: "Hand anything about notes to notes_keeper, and anything about what a meal holds to nutritionist.",
    tools: [keeper.as_tool(), nutritionist.as_tool()],
}
```

A task is a conversation of its own: the agent sees nothing of the one it was called from, so the
calling model must put everything needed in the task (say so in its system prompt). The agent's
final text is the tool's result; what went wrong is a tool error (`"<name> couldn't do it: …"`), and
a call with no task one too, without asking the API. Every agent in a team gives its tools the
context it was given. An agent's text isn't streamed to its caller; with `updates`, its progress
notes and its tools are ([Updates](#updates)). Its turns are on the log under its name. Being a
`Tool`, an agent can be an MCP server's tool too.

## Updates

A request (or an agent) with `updates: Bool.True` tells its listener what a page can show while the
model works, as `Update(update)`, packages/tools' `Tool.Update`:

- `Progress({ agent, says })`: a note the model wrote between its tool calls ("I'll look through
  your notes first."). The package asks for them where the model writes them (Claude Opus 5.5,
  Sonnet 5.5, Fable and Mythos: `thinking: {"type": "adaptive", "display": "updates"}` with
  `anthropic-beta: thinking-display-updates-2026-08-18`; the model's reasoning stays hidden). Claude
  Haiku 5.5 writes them as text, which comes as `Text`, as without `updates`.
- `Using({ agent, tool, says })`: one of the app's tools as it starts to run, with what the tool says
  it is doing (`says`: its `doing`, `""` when it says nothing). A tool says it with
  `.doing("Looking for your info…")`; an agent used as a tool, with its `doing` field.
- From every agent the call uses as a tool, the same, each by the agent's name (`agent`): the
  agent is asked for its updates too, and passes them up (`Tool.with_listener`), so a team of
  agents is heard all the way down.

`agent` is the request's `label` (an agent's name), `""` for a call that has none. Where the
updates go is the app's: the listener is a function, so they can go out as an endpoint's events
(as the example's chat sends them) or be published on a channel, for a page that started the work
with a form and listens for its progress:

```roc
# routes/chats/[chat]/updates/+server.roc: the channel (`Generated/Api`'s channel_chats_chat_updates)
channel! : { request : Server.Request, params : { chat : Str }, context : Me } => Try(Channel(Str, Tool.Update, []), Endpoint.Refusal)

# where the work runs
Agent.chat!(Team.assistant, conversation, me, |heard|
    match heard {
        Update(update) => Ok(Endpoint.publish!(Api.channel_chats_chat_updates({ chat }), update))
        _ => Ok({})
    })
```

A progress note is a `thinking` block with text: it stays in the conversation, as the model wrote
it, and goes back to the API with it. Notes the model never wrote cost nothing; the ones it writes
are billed as output, whether or not `updates` shows them.

## Conversations

A conversation is a `List(Message)`. `Message.user(text)` is the user's; the model's are kept as the
API wrote them, thinking blocks and their signatures included, as the API needs them back. `reply.messages`
is the conversation after a call: give it as the next request's `messages`, with a new `prompt`.

`Message.save(messages)` writes one as JSON text to keep (in `Kv`, a table) and `Message.load(text)`
reads it back, exactly. `Message.text(message)` is a message's text, without its thinking or its
tools' use.

After a server-side fallback in the middle of a turn (another model took over where the first
declined), the first model's thinking and tool uses before the `fallback` block are left out of the
message, as the API asks; the `fallback` block stays where it was.

## What it costs

Each turn is on the log, with its tokens:

```json
{"msg":"ai.turn","label":"notes_keeper","model":"claude-haiku-5-5","stop":"tool_use","input":4,"cache_read":640,"cache_write":215,"output":112,"ms":878}
```

`label` is the request's (an agent's name), and is left out when it has none.

`input` is what was read without the cache, `cache_read` what came from it (a tenth of the price),
`cache_write` what was written to it (a quarter more, once). With `cache` on (the default) a
conversation's next turn reads all of the last one from the cache. A prompt shorter than the
model's minimum (512 to 4,096 tokens, by model) isn't cached, and costs nothing more for asking.

## What went wrong

`Ai.Problem(err)`, and `Ai.explain(problem)` says it in a sentence:

| Tag | When |
|---|---|
| `NoKey` | No `ANTHROPIC_API_KEY` (under `--dev`) |
| `Status(code, why)` | The API refused: 400 the request, 401 the key, 429 too many (still, after two tries), 529 overloaded |
| `Unreachable(why)`, `TimedOut`, `Broken(why)` | No whole answer came |
| `Refused(category)` | The model declined (the API's category, as `"cyber"`; often `""`) |
| `Truncated` | `extract!`'s answer reached `max_tokens` before its JSON ended |
| `InvalidJson(why)` | `extract!`'s answer didn't fit its type |
| `TooManyTurns(reply)` | `run!` took `max_turns` turns and the model still wanted its tools; `reply` is what it did (its `messages`, ending with the last tools' results, and every turn's `usage`) |
| `Stopped(err)` | `heard!` answered `Err(err)`: from an endpoint's `events!`, the page went (`Stopped(Gone)`) |

A 408, 409, 429, 500, 502, 503, 504 or 529 answer, or a stream whose error event stands for one of
them (overloaded, a rate limit, a timeout, the API's own error) before anything was heard, is tried
again, twice, after what `retry-after` says (a minute at most; else half a second, then a second);
each try is logged (`ai.retry`). Once text has been passed on, nothing is tried again. A connection
that fails (`Unreachable`) isn't tried again (PROPOSALS.md, 4).

## What it sends

`POST <base_url>/v1/messages` with `anthropic-version: 2026-10-21`, `x-api-key`, and `"stream":
true`: every call streams, so a long answer never times out (30 minutes at most). `output_config`
carries the effort (and `extract!`'s format); `cache_control` asks for the prompt cache. No sampling
parameters (`temperature` and the rest are refused on that version), no `thinking` (the current
models think as they need to, `effort` saying how much), and no forced `tool_choice` (Claude Opus 5.5
refuses it). `effort` is always sent, so the model must take it: Claude Opus 4.5 and every model
from the 4.6s on do; Claude Haiku 4.5 and Sonnet 4.5 refuse it (a 400). With `updates`, on the
models that write progress notes, `thinking` is `{"type": "adaptive", "display": "updates"}`, and
`anthropic-beta` lists `thinking-display-updates-2026-08-18` (beside the fallback's, comma
separated).

On the models that take it (`claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5-5`,
`claude-fable-5-2`, `claude-fable-5-1`, and Mythos 5.2 and 5.1) it sends `"fallbacks": "default"`
with `anthropic-beta: server-side-fallback-2026-07-01`: when the model's safety classifiers decline
a request, the API runs it again on the model it names for that kind of refusal, in the same call.
`claude-haiku-5-5` has no fallback, so a refusal there is `Refused`.

## Modules

| Module | What it is |
|---|---|
| `Ai` | `plugin` and its `Options`, `Request` and its `Effort`, `ask!`, `stream!`, `extract!` and `schema` (a `Schema`), `run!` and `tool`, `Heard`, `Reply`, `Problem`, `explain`, `without_calls` (a message without its tool calls, as `run!` keeps a turn cut off at `max_tokens`) |
| `Agent` | A model with its role and tools: `ask!`, `chat!`, `as_tool` |
| `Message` | A conversation's message: `user`, `assistant`, `of_blocks`, `role_of`, `blocks`, `text`, `to_json`, `from_json`, `save`, `load` |
| `Turn` | One turn put together from its stream's events: `start`, `step`, `stopped`, `stop_of`, `usage_of`, `model_of`, `message`, `calls`; `Heard`, `Stop`, `Usage` |
| `Sse` | Server-sent events read from a stream's bytes as they come: `feed` |

## Trying it against the API

`example/test/ai.test.mjs` never asks the API. To try the example against it, put your key in a
`.env` where you run `rocx dev`, which gives it to the server (D-098; `.env` is gitignored):

```sh
echo 'ANTHROPIC_API_KEY=sk-ant-…' >> .env
bin/rocx dev packages/ai/example --port 8095
```

Under `--dev` it asks `claude-haiku-5-5`. One chat message to the example's team asked the model six
times (the assistant three, the nutritionist once, the notes keeper twice): about 4,400 tokens read,
most from the cache, and 470 written, well under a tenth of a cent.
