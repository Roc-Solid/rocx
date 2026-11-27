import auth.Auth
import ../../../Accounts

## The dev sign-in (`POST /auth/dev`, packages/auth): under `rocx dev`, any address, let in as
## `Accounts.admit!` says; without `--dev`, 404.
respond! = |{ request, .. }| Auth.dev_route!(request, Accounts.admit!)
