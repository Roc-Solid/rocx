# A chain of three effectful closures skips its last step under `--opt=speed`

**In one sentence:** Under `--opt=speed`, a chain of three effectful closures skipped its last step.

## Like you're five

Three friends pass a ball down a line: the first to the second, the second to the third, and
the third shoots at the goal. When the compiler made the line faster, the second friend threw the
ball straight past the third, so no one ever shot. With two friends it worked; with three, the
last one was forgotten.

## Details

**Fixed** on the fork rocx builds with (pin 4674b5973d): `./repro.sh` answers `doc` for every app
and both opts (checked 2026-11-26, D-103).

On 2026-11-27 the nightly no longer gets as far as answering: building Bad.roc, Middleware.roc
and TwoSteps.roc with `--opt=speed` crashes the compiler (SIGSEGV in `lambda_solve`); the fork
builds them, and each answers `doc`.

Found 2026-11-21 on nightly-2026-11-18-a520eed (the rocx pin), while making the OpenAPI document
opt-in: a middleware that answered `/openapi.json` was skipped when it was the third in a chain
(`default` = `same_origin.then(headers)`, then it), in a server built with `--opt=speed`. The
server answered 404 from the routes; `--opt=dev` was right.

Reduced: three closures of type `Str, (Str => Str) => Str`, composed by
`then = |first, second| |path, next!| first(path, |passed| second(passed, next!))`. With
`then(then(pass_on!, pass_on!), answer_doc)`, `--opt=speed` calls the final continuation
(`"fell through"`) instead of `answer_doc` (`"doc"`). No record or nominal type is needed
(Bad.roc); the shape it was found in, a middleware type, fails the same way (Middleware.roc). Two
steps work (TwoSteps.roc).

    ./repro.sh

    Bad        --opt=dev   GET /doc -> doc
    Bad        --opt=speed GET /doc -> fell through
    Middleware --opt=dev   GET /doc -> doc
    Middleware --opt=speed GET /doc -> fell through
    TwoSteps   --opt=dev   GET /doc -> doc
    TwoSteps   --opt=speed GET /doc -> doc

Workaround in rocx: `OpenApi.respond` is called directly inside `Middleware.run!`'s last callback,
not chained as a third middleware.
