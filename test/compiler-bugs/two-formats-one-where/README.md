# A where clause asking for two formats crashes the compiler

Found 2026-11-22 on rocx-fork-3f66e242ea (the rocx pin), and the same on
nightly-2026-11-18-a520eed, while reading a form's body by its endpoint's types (D-038). A
format of the platform's own (`FormBody`) works as `Json`'s does, through the derived
`parser_for`. But `Endpoint.respond!` reads JSON as well as forms, and a function whose where clause
asks for both (`where [a.FormBody.Readable, a.Json.Parseable([InvalidJson(Str)])]`) crashes the
compiler in `boxy_lowering` (SIGSEGV). It crashes whichever format the function's body uses, both
or one, and whether the where clause names `parser_for` itself or an alias of it.

Reduced: a format with three record methods and `parse_str` (`Shape`), and one function asking for
both formats and using `Json.parse` alone (Crash.roc). Two functions, each asking for one format,
used on the same record type, pass (Workaround.roc).

    ./repro.sh

    == roc test Crash.roc
    Segmentation fault (SIGSEGV) in the Roc compiler.
    exit 139
    == roc test Workaround.roc
    All (2) tests passed in 39.6 ms.
    exit 0

Workaround in rocx: the form reader is made where the arg's type is known, by `Endpoint.local`
(`where [arg.FormBody.Readable]`), and kept in the endpoint; `Endpoint.respond!` asks only for
`Json.Parseable` and calls the reader it is given. packages/mcp's `McpHttp`, generic in its tools'
args as JSON alone, makes its endpoints with `Endpoint.local_json`, which has no reader. The same
shape is why `McpHttp` takes `OpenApi.body` as a value (`McpHttp.openapi`) rather than calling it.
