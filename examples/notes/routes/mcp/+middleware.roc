import ../../Middlewares

## MCP: a personal access token alone, 120 calls a minute for each.
middleware = Middlewares.agent.then(Middlewares.agent_limit)
