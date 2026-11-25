# packages/tools: proposals

What the package could do next. None of it is built.

## 1. A tool's schema from its type, here

`Tool.typed` takes its arguments' JSON Schema as text, because the schema writer (`OpenApi`) is the
server platform's and this package names no platform; packages/ai's `Ai.tool` and packages/mcp's
`McpHttp.tool` write it there. A schema format of its own here (the platform's, copied, or moved
here and used by `OpenApi`) would let `Tool.typed` take the type alone, wherever the tool is made.

## 2. Content for the Messages API

`Content.to_json` writes MCP's content block; packages/ai writes the Messages API's from the same
value (`Ai.roc`, `content_json`). A second writer here would keep both shapes beside each other.
