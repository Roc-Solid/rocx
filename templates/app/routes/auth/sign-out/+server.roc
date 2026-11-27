import auth.Auth

## Signing out (`POST /auth/sign-out`, packages/auth): the session ended, and on to `then`, else home.
respond! = |{ request, .. }| Auth.sign_out_route!(request)
