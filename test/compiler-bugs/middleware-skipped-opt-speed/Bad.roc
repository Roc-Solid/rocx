app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Server

## Three effectful closures, composed by `then`: `then(then(pass_on!, pass_on!), answer_doc)` should
## answer "doc" for every request. Built with `roc build --opt=dev` it does; with `--opt=speed`
## (nightly-2026-11-18-a520eed) the chain calls its final continuation instead, "fell through", as if
## `answer_doc` weren't there. With two steps (TwoSteps.roc) both answer "doc".
then : (Str, (Str => Str) => Str), (Str, (Str => Str) => Str) -> (Str, (Str => Str) => Str)
then = |first, second| |path, next!| first(path, |passed| second(passed, next!))

pass_on! : Str, (Str => Str) => Str
pass_on! = |path, next!| next!(path)

answer_doc : Str, (Str => Str) => Str
answer_doc = |_, _| "doc"

program = {
	respond!: |_method, target, _headers, _body, _started| {
		chain = then(then(pass_on!, pass_on!), answer_doc)
		Server.response(200, [], chain(target, |_| "fell through"))
	},
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}
