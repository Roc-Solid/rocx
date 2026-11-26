import pf.Server
import pf.Endpoint
import auth.Auth

## GET /api/sign-in: what the page offers besides an address: the providers set up (their environment
## variables set), and whether the dev sign-in is open (under `--dev`).
get! : { request : Server.Request, params : {}, context : {} } => Try({ providers : List({ name : Str, label : Str, path : Str }), dev : Bool }, Endpoint.Refusal)
get! = |_| Ok({ providers: Auth.providers!({}), dev: Auth.dev_sign_in!({}) })
