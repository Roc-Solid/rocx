import auth.Auth
import ../../../Accounts

## Off to a provider (`GET /auth/<provider>?then=…`, packages/auth): one of `Accounts.providers`, which
## asks who is signing in.
respond! = |{ request, params, .. }| Auth.provider_route!(request, Accounts.providers, params.provider)
