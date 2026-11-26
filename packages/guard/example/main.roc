## An app that uses packages/guard: security headers, a body limit and maintenance mode on every
## request, a limit on /api and on the login route, a route behind a feature flag, and a page that
## shows the new checkout to those who have it on. The middleware is the package's own
## (`import guard.Guard`): `rocx build .`, then build it as any app. The flags' overrides are kept
## in its database (SQLite) too, by the package's plugin, so a restart keeps them (D-057).
app [program] { guard: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App
import guard.FlagStore

## Every request: routes/+middleware.roc's, then each directory's on the way to its route.
program = App.program({
	init!: |started| Ok({ facts: started }),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/guard.db"),
	plugins: [FlagStore.plugin({})],
})
