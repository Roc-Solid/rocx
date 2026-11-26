import ../../Middlewares

## The app's pages and the endpoints only they use: someone signed in (a session), handed on as
## `Middlewares.Me`. A browser asking for a page signed out is sent to sign in, and back after.
middleware = Middlewares.signed_in
