## What a tool is, for a model to use: its name, what it does, the JSON Schema of its arguments and
## what it does with them (`Tool`); what it answers (`Content`); and any JSON, read a field at a time
## (`JsonValue`). No platform: packages/ai gives its tools to Claude, packages/mcp serves the same
## tools over MCP, and either imports just this.
package [Content, JsonValue, Tool] { crypto: "../crypto/main.roc" }
