import pf.Server
import pf.Endpoint
import guard.Flags
import ../../FlagStore
import ../../Features
import ../../Middlewares

## GET /flags: the app's flags, decided on the server for whoever is signed in (the `user` the app's
## middleware handed on). The layout reads it as each page renders, and the page carries the
## answer, so the browser's first run reads the same values instead of asking again.
get! : { request : Server.Request, params : {}, context : Middlewares.Context } => Try(Flags.Values, Endpoint.Refusal)
get! = |{ context, .. }| Ok(FlagStore.values!(Features.all, { user: context.user, groups: [] }))
