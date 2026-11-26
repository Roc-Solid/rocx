import ../../../../../../Middlewares

## Sending reactions is rate limited (guard: 20 a minute from each reader); reading them isn't.
middleware = Middlewares.reactions_limit
