## packages/ai's example: a notes assistant. Its page has a chat with an assistant agent that hands
## work to two others, each a tool to it (`Team`: a notes keeper with three tools, `Notes.tools`, and
## a nutritionist), its answers streamed as they are written; a summary of the notes (`Ai.ask!`); and a
## meal described in words read into a typed record (`Ai.extract!`). The notes are in the server's
## memory (`Kv`), and so is each chat (`Chats`).
##
## ANTHROPIC_API_KEY from the environment; under `rocx dev` the model is claude-haiku-5-5 unless
## ANTHROPIC_MODEL names another. The tests run it against a stand-in for the API (test/stand-in.mjs).
app [program] { ai: "../main.roc", crypto: "../../crypto/main.roc", pf: platform "../../../server/platform/main.roc", tools: "../../tools/main.roc" }

import pf.Middleware
import ai.Ai
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middleware.same_origin({}),
	plugins: [Ai.plugin({})],
})
