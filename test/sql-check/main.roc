## The app `rocx check --sql`'s tests check (test/check-sql.test.mjs, D-058): a SQLite app whose
## statements (Store.roc) are right, or wrong in the one way each one's comment says, on purpose.
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Server
import Store
import "migrations/0001_tables.sql" as tables : Str

program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
	respond!: |_, _| Server.response(200, [], Store.all!({})),
	database: Sqlite("data/check.db"),
	migrations: [{ name: "0001_tables.sql", sql: tables }],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}
