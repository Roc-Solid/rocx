import ../Visitor

## Every request: the visitor, from their cookie, handed on as `context.visitor`.
middleware = Visitor.middleware
