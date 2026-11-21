## GET /api/echo/:message: the message, said back. The echo demo reads it for each message as the
## page renders (`Endpoint.get!`), so the page carries every answer and picking asks nothing.

get! = |{ params, .. }| Ok("Echo: ${params.message}")
