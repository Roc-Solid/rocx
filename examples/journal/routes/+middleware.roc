import ../Middlewares

## Around every request the journal answers: guard's security headers, and who the reader is
## (`context.reader`).
middleware = Middlewares.default
