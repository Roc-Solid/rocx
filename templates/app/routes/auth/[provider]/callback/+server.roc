import auth.Auth
import ../../../../Accounts

## Back from a provider (`GET /auth/<provider>/callback`, the redirect URI registered with it,
## packages/auth): who signed in there, let in as `Accounts.admit!` says.
respond! = |{ request, params, .. }| Auth.callback_route!(request, Accounts.providers, params.provider, Accounts.admit!)
