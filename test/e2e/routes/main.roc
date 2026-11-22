## The routes as an app on the server platform, which has the HTTP modules the generated code
## imports (`pf.Server`, `pf.Endpoint`): each request answered by `Generated/Routes`, a page by
## `Generated/Root`, which the host renders. The e2e tests serve it; `roc test` checks its paths.
app [program] { pf: platform "../../../server/platform/main.roc" }

import Generated/Routes
import Generated/Paths

program = {
	respond!: |request, context| Routes.respond!(request, context),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}

expect Paths.blog_slug({ slug: "x" }) == "/blog/x"
expect Paths.blog_slug({ slug: "a b/c" }) == "/blog/a%20b%2Fc"
expect Paths.all == ["/blog", "/"]
