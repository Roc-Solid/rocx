import ../../Middlewares

## Signed-in requests only: a page's GET goes to sign in, anything else is a 401. The sign-in pages
## and their endpoints sit outside the groups, for anyone.
middleware = Middlewares.signed_in
