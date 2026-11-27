import auth.Auth
import ../../../Account

## A mailed link (`GET|POST /auth/link?token=…`, packages/auth), used once: its address, let in as
## `Account.admit!` says.
respond! = |{ request, .. }| Auth.link_route!(request, Account.admit!)
