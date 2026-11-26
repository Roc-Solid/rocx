import ../../Middlewares

## The admin's pages and actions: only with the admin's session. The sign-in page and its endpoint
## sit outside this group, for anyone.
middleware = Middlewares.admin
