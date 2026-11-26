import ../../Middlewares

## The account page and its endpoints: signed-in people only. Signed out, the page goes to sign in
## (and comes back after); anything else is a 401. A group, a directory in brackets, adds nothing
## to the path: these are /account and /api/account.
middleware = Middlewares.signed_in
