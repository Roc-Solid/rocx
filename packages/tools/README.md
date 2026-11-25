# tools

What a tool is, for a model to use, on no platform: its name, what it does, the JSON Schema of its
arguments and what it does with them (`Tool`); what it answers (`Content`); and any JSON, read a
field at a time (`JsonValue`). A tool made once serves wherever a model asks for it: packages/ai
gives it to Claude from the app's server (`Ai.run!`, an agent's `tools`), and packages/mcp serves it
to AI clients over MCP. Both import this package, and neither owns the definition (D-085).

```roc
app [program] { pf: platform "…/server/platform/main.roc", tools: "…/packages/tools/main.roc" }

import tools.Tool

convert = Tool.typed("convert", "Celsius to Fahrenheit", celsius_schema, convert!).read_only()
```

`Tool.typed` takes the JSON Schema of its arguments as text; packages/ai's `Ai.tool` and
packages/mcp's `McpHttp.tool` and `McpHttp.endpoint` write it from the arguments' Roc type, as the
platform writes `/openapi.json`'s. It depends on packages/crypto (Base64, for an image's bytes),
which it names itself. `roc test packages/tools/main.roc` runs its expects.

| Module | What it has |
|---|---|
| `Tool` | `Tool.typed(name, description, schema, run!)`: arguments read into a Roc type, the answer written as JSON. `Tool.typed_with_params(name, description, params_schema, body_schema, run!)`: arguments read into two types from one object (an endpoint's path params and its body), their schemas merged. `Tool.new(name, description, schema, run!)`: any JSON in, an `Outcome` out. Hints: `read_only`, `additive`, `idempotent`, `closed_world`. Also `titled`, `answers(schema)`, `reporting`. Outcomes: `Tool.text`, `Tool.structured`, `Tool.answer`. |
| `Content` | What a tool answers with: `Text`, `Image` and `Audio` (bytes, sent as Base64), `Link` (to a resource), `Embedded` (a resource's contents). Helpers: `Content.text`, `Content.image`, `Content.link`. |
| `JsonValue` | Any JSON, read a field at a time (`parse`, `get`, `to_text`, `is_object`, `to_str`). `decode` into a Roc type and `encode` from one, through `Json`. A number keeps the text it came as, so an id or an `I64` goes back exactly. |

A tool's hints (`read_only`, `additive`, `idempotent`, `closed_world`), its answer's schema
(`answers`) and `reporting` are what MCP tells a client; packages/ai sends a model a tool's name,
description and arguments' schema. `Content.to_json` writes MCP's content block; packages/ai writes
the Messages API's from the same `Content`. A resource's contents held whole (`Embedded`) are
`Content.Contents`, which packages/mcp's `Resource.Contents` is.
