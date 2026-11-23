# The builtin `Try` has no JSON encoder or parser

Found 2026-11-23 on rocx-fork-9fcf362c0c (the rocx pin), and the same on
nightly-2026-11-18-a520eed, while asking whether an endpoint could answer a `Try` (D-054, item 5).
Builtin.roc declares `Try(ok, err) := [Ok(ok), Err(err)].{ parser_for : _, encoder_for : _ }`, and
the canonicalizer makes derived methods of those annotations (`Can.zig`, `derivedMethodKind`), but
the type checker finds neither on `Try`: `Json.to_str_try(failed)` and `Json.parse(text)` of a
`Try(U64, Str)` are "missing method" errors (Fails.roc). The same union as a nominal type of the
app's own (`Outcome(ok, err) := [Ok(ok), Err(err)].{ encoder_for : _, parser_for : _ }`) writes
`{"Err":"no"}` and reads `{"Ok":5}`, as a structural union does (Workaround.roc). So the derive
works; the builtin's declared one isn't reached (Builtin.roc's methods are looked up by another
path).

    ./repro.sh

    == roc test Fails.roc
    The value's type, which does not have a method named encoder_for, is:
    The value's type, which does not have a method named parser_for, is:
    exit 1
    == roc test Workaround.roc
    All (3) tests passed
    exit 0

Workaround in rocx: what crosses the wire as a `Try` is written as the structural union
`[Ok(a), Err(e)]` (read by a `match` as a `Try` is), and `rocx check` names it under the compiler's
report (web/README.md, JSON).
