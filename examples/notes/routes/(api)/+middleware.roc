import ../../Middlewares

## The JSON API: your notes, for scripts and AI clients, with a personal access token
## (`Authorization: Bearer acme_pat_…`) or the session cookie; neither, 401. /openapi.html describes
## every endpoint; MCP's tools are made of these (Agents.roc), and send them with the MCP request's
## token, so this decides for them too (D-103).
middleware = Middlewares.api
