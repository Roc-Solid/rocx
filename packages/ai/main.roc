## Claude, from a Roc Solid app's server (D-085): a question answered (`Ai.ask!`), an answer streamed
## as it is written (`Ai.stream!`), an answer read into a Roc type (`Ai.extract!`), a model that uses
## the app's tools until it is done (`Ai.run!`, with packages/tools' `Tool`s, which an MCP server
## serves too), and agents, each a model with its role and tools, which other agents can use as
## tools (`Agent`). It names the server platform, so only an app on it names this package; the
## browser's half doesn't see it.
package [Agent, Ai, Message, Sse, Turn] { crypto: "../crypto/main.roc", pf: platform "../../server/platform/main.roc", tools: "../tools/main.roc" }
