import pf.Middleware

## Passes each request on, but it is the account's own: the static copy leaves the page out.
middleware = Middleware.make(|request, context, next!| next!(request, context))
