import mcp.McpHttp
import ../../Agents

## The MCP server (packages/mcp) for AI clients: Claude, an IDE or the MCP Inspector, with a personal
## access token (this directory's middleware). Its tools are the JSON API's endpoints, sent with the
## request's token, so their own middleware decides too.
respond! = |{ request, context, .. }| McpHttp.respond!(Agents.server, request, context)
