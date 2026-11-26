import ../../Middlewares

## The members' page and its endpoint: a member's cookie, handed on as `context.member`; a browser
## that has none is sent to join. `(members)` is a group: it adds nothing to their paths.
middleware = Middlewares.member
