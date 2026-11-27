import auth.Auth
import ../../../Accounts

## A mailed link (`GET|POST /auth/link?token=…`, packages/auth), used once: its address, let in as
## `Accounts.admit!` says.
respond! = |{ request, .. }| Auth.link_route!(request, Accounts.admit!)
