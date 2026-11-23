app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Server

## A middleware, as a record holding the function it runs: it answers a path itself, or passes it on
## to `next!`. `then` runs one, then the other.
Mw :: { run : Str, (Str => Str) => Str }.{
	make : (Str, (Str => Str) => Str) -> Mw
	make = |run| { run: run }

	then : Mw, Mw -> Mw
	then = |first, second| {
		run_first = first.run
		run_second = second.run
		{ run: |path, next!| run_first(path, |passed| run_second(passed, next!)) }
	}

	run! : Mw, Str, (Str => Str) => Str
	run! = |mw, path, last!| {
		run = mw.run
		run(path, last!)
	}
}

pass_on : Mw
pass_on = Mw.make(|path, next!| next!(path))

## Every request should answer "doc": the third middleware answers it. With `--opt=speed` it is
## "fell through". The shape it was found in: a middleware type, as a platform's is.
program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
	respond!: |request, _started| Server.response(200, [], pass_on.then(pass_on).then(Mw.make(|_, _| "doc")).run!(request.path, |_| "fell through")),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}
