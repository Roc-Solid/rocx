## MCP on the server platform: the route that serves an app's MCP server, and tools made from its
## endpoints, functions and handlers (`McpHttp`). A package that names the server platform,
## so only the server's half of an app can name it: see ../README.md, and PROPOSALS.md, "Server-only
## modules in packages".
package [McpHttp] { mcp: "../main.roc", pf: platform "../../../server/platform/main.roc", tools: "../../tools/main.roc" }
