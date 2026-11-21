## roc-pg (github.com/niclas-ahden/roc-pg), a Postgres client written in Roc, on this platform: it
## connects through the platform's `Tcp`, logs in with its `Random`, and checks each query against
## `schema.sql` when the app is compiled (a column that isn't there, a parameter of the wrong type,
## a column that may be null read as one that can't, all fail the build). The same file is the
## app's migration, so the schema it checks against is the one the server applies.
##
## `GET /` puts Earth in the table, if it isn't there, and lists the planets. The server is started
## with the database's URL as its context (`--context-file`), for roc-pg to connect to.
app [program] {
	pf: platform "../../platform/main.roc",
	pg: "https://github.com/niclas-ahden/roc-pg/releases/download/0.5.3/GHArBE4QrXKDpttdxtb8GQWXZWhWSuMBgA73qRoETm8r.tar.zst",
}

import pf.Random
import pf.Tcp
import pg.Catalog
import pg.Client
import pf.Server
import "schema.sql" as schema_sql : Str

## What roc-pg checks this app's queries against.
Schema := [].{
	catalog : {} -> Catalog
	catalog = |{}| Catalog.from_schema(schema_sql)
}

program = {
	respond!,
	migrations: [{ name: "roc-pg example: planets", sql: schema_sql }],
	jobs: [],
	crons: [],
	actors: [],
	logs: { format: Auto },
}

respond! = |_method, _target, _headers, _body, url|
	match planets!(url) {
		Ok(listed) => Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], listed)
		Err(_) => Server.response(500, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "roc-pg failed")
	}

## Connects (a connection a request, which roc-pg recommends: it has no pool), writes, reads.
planets! = |url| {
	db : Client.Client(Tcp, Schema)
	db = Client.connect_url!(url, { connect!: |host, port| Tcp.connect!(host, port), random_u64!: Random.seed_u64!, statement_timeout: Client.millis(30_000) })?
	_ = db.execute!("INSERT INTO rocpg_planets (id, name, gravity) VALUES ($id, $name, $gravity) ON CONFLICT (id) DO NOTHING", { id: 3.I32, name: "Earth", gravity: 9.80665.F64 })?
	found : List({ id : I32, name : Str, gravity : F64, moons : Try(I32, [Null]) })
	found = db.query!("SELECT id, name, gravity, moons FROM rocpg_planets WHERE gravity > $least ORDER BY id", { least: 1.0.F64 })?
	db.close!()
	Ok(Str.join_with(found.map(|planet| "${planet.id.to_str()} ${planet.name}"), "\n"))
}
