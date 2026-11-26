## MCP: a Roc Solid app's tools, resources and prompts, for AI agents (the Model Context Protocol).
## The protocol (`Mcp`, `Resource`, `Template`, `Prompt`, `Rpc`, `Bearer`) is plain Roc on no
## platform; `McpHttp` serves it from the app's server, on the server's platform, so the package
## names it, and `browser.roc` lists what the browser's half of an app may import (D-033).
package [Bearer, Mcp, McpHttp, Prompt, Resource, Rpc, Template] { crypto: "../crypto/main.roc", pf: platform "../../server/platform/main.roc", tools: "../tools/main.roc" }
