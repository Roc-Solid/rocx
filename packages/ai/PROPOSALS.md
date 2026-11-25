# packages/ai: proposals

What the package could do next, and what waits on someone. None of it is built.

## 1. The fallback request, against the API

On the models that take it, every request carries `"fallbacks": "default"` with `anthropic-beta:
server-side-fallback-2026-07-01` (D-085). The stand-in checks that it is sent; the API itself has
not seen it, as development used `claude-haiku-5-5`, which has no fallback. One call on
`claude-opus-5-5` checks the shape. Waits on the user's go (it costs a fraction of a cent).

## 2. Images and documents in a prompt

`Message.user(text)` is text alone. The API takes images and PDFs as content blocks (base64, or a
file uploaded once through the Files API). `Message.user_with([Text(…), Image(bytes, mime),
Pdf(bytes)])` would make them; a storage key (packages/storage) could be read in for one. Plate's
meal from a photo is the first use.

## 3. Batches, for jobs

The Message Batches API answers within a day at half the price: what a nightly job wants (tagging
every note, summing up yesterday's). `Ai.batch!(requests)` sends them and gives an id; a job
(packages/jobs) asks for the results later. Each result keyed by its `custom_id`, never by
position.

## 4. Counting tokens before asking

`POST /v1/messages/count_tokens` says what a request would cost without running it: `Ai.count!` for
an app that budgets per user, or that trims a long conversation before it goes.

## 5. A connection that breaks before anything was heard

`Http.fetch_chunks!` answers `HttpErr` without the state its step had, so the package can't tell a
connection that failed before the answer's head (safe to try again) from one that broke mid-stream
(text already on a page). Today neither is tried again. A platform change (`fetch_chunks!`'s `Err`
carrying the last state, or `Stopped`'s) would let the first be.

## 6. The model's thinking, shown

The current models' thinking comes back empty by default (`display: "omitted"`): a pause, then
text. `thinking: { display: "summarized" }` returns a summary of it, which a page could show as
it comes (`Heard.Thinking(piece)`).

## 7. Long conversations

A chat that outgrows the context window needs its start summed up (the API's compaction, beta) or
dropped. Until then, `max_tokens` and the app decide how much of a conversation goes.

## 8. Server tools

The API runs some tools itself: web search and web fetch (with sources), code execution. A
`Request.server_tools` list would add them; their result blocks are already kept as they come
(`Turn` passes unknown blocks through).

## 9. An agent's work, heard by its caller

An agent used as a tool (`as_tool`) works quietly: its caller hears `Calling(name)`, then the
answer. A page could show what the agent does meanwhile (`Calling(agent, tool)`, its text as it
comes) if a tool's run were given a listener, as MCP's `progress!` is given to its tools. The tool's
context could carry it (`McpHttp.Caller`'s `progress!` is one), or `Tool` could take one.

## 10. Agents that hand back and forth

`as_tool` is a call that returns: the calling agent stays in charge (Strands' agents as tools). A
handoff, where another agent takes the conversation over (Strands' swarm), or a graph of agents, is
a loop the app can write with `Agent.chat!` today; a package-level one waits for a use.

## 11. Another provider

Only if asked. A module of its own per provider, not a layer over them all (D-085's alternatives).
