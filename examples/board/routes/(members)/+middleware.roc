import ../../Middlewares

## The boards: someone who has joined, handed on as `context.me`; a browser without a session is
## sent to join first. The join page and its endpoint are outside this group, for anyone.
middleware = Middlewares.member
