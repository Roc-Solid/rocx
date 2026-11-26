# packages/ai: proposals

What the package could do next, and what waits on someone. None of it is built.

## 1. Images and documents in a prompt

`Message.user(text)` is text alone. The API takes images and PDFs as content blocks (base64, or a
file uploaded once through the Files API). `Message.user_with([Text(…), Image(bytes, mime),
Pdf(bytes)])` would make them; a storage key (packages/storage) could be read in for one. Plate's
meal from a photo is the first use.

## 2. Batches, for jobs

The Message Batches API answers within a day at half the price: what a nightly job wants (tagging
every note, summing up yesterday's). `Ai.batch!(requests)` sends them and gives an id; a job
(packages/jobs) asks for the results later. Each result keyed by its `custom_id`, never by
position.

## 3. Counting tokens before asking

`POST /v1/messages/count_tokens` says what a request would cost without running it: `Ai.count!` for
an app that budgets per user, or that trims a long conversation before it goes.

## 4. A connection that breaks before anything was heard

`Http.fetch_chunks!` answers `HttpErr` without the state its step had, so the package can't tell a
connection that failed before the answer's head (safe to try again) from one that broke mid-stream
(text already on a page). Today neither is tried again. A platform change (`fetch_chunks!`'s `Err`
carrying the last state, or `Stopped`'s) would let the first be.

## 5. The model's reasoning, shown

`updates` shows the model's progress notes and hides its reasoning (`display: "updates"`).
`display: "summarized"` returns a summary of its reasoning too, mixed with the notes: a page that
wants to show how the model thought could ask for that (`Heard.Thinking(piece)`).

## 6. Long conversations

A chat that outgrows the context window needs its start summed up (the API's compaction, beta) or
dropped. Until then, `max_tokens` and the app decide how much of a conversation goes.

## 7. Server tools

The API runs some tools itself: web search and web fetch (with sources), code execution. A
`Request.server_tools` list would add them; their result blocks are already kept as they come
(`Turn` passes unknown blocks through).

## 8. An agent's text, heard by its caller

With `updates`, an agent used as a tool passes its progress notes and its tools up (D-089); its
text doesn't go up, as its final text is the calling model's tool result, not the user's answer. A
page that wants to show a sub-agent's text as it is written (a long report a researcher agent
writes) would want it too (`Update(Text({ agent, piece }))`).

## 9. Agents that hand back and forth

`as_tool` is a call that returns: the calling agent stays in charge (Strands' agents as tools). A
handoff, where another agent takes the conversation over (Strands' swarm), or a graph of agents, is
a loop the app can write with `Agent.chat!` today; a package-level one waits for a use.

## 10. Another provider

Only if asked. A module of its own per provider, not a layer over them all (D-085's alternatives).
