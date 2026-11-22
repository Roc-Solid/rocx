## Notes: personal notes in Markdown, which AI clients can search, read and write over MCP with
## a personal access token. rocx build writes nearly all of the program from routes/
## (`Generated/App`: every page and endpoint, the migrations in migrations/, the actors packages/guard
## keeps its counts in); this says the rest: what every request goes through first (the default
## middleware, then the MCP server at /mcp); that the JSON API's OpenAPI document is served, with
## Scalar to read it in (`/openapi.json`, `/openapi.html`); and that sign-in links are mailed by
## packages/email's plugin (over SMTP with `SMTP_URL`; without it, to the dev mailbox); and that its
## database is SQLite (D-045), a file beside the server.
app [program] { crypto: "../../packages/crypto/main.roc", email: "../../packages/email/main.roc", guard: "../../packages/guard/main.roc", markdown: "../../packages/markdown/main.roc", mcp: "../../packages/mcp/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import email.Email
import Generated/App
import Agents
import Middlewares

program = App.program({
	context: |_started| {},
	middleware: Middlewares.default.then(Agents.mount),
	openapi: Page(Scalar),
	plugins: [Email.plugin({ from: "Notes <notes@example.com>" })],
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/notes.db"),
})
