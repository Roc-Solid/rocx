import auth.Auth

## A sign-in's second factor (`POST /auth/code`, packages/auth), posted from /sign-in/code.
respond! = |{ request, .. }| Auth.code_route!(request)
