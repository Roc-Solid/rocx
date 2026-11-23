# The builtin `Try` has no JSON encoder or parser

Found 2026-11-23 on rocx-fork-9fcf362c0c (the rocx pin), and the same on
nightly-2026-11-18-a520eed, while asking whether an endpoint could answer a `Try` (D-054, item 5).
Builtin.roc declares `Try(ok, err) := [Ok(ok), Err(err)].{ parser_for : _, encoder_for : _ }`, and
the canonicalizer makes derived methods of those annotations (`Can.zig`, `derivedMethodKind`), but
the type checker finds neither on `Try`: `Json.to_str_try(failed)` and `Json.parse(text)` of a
`Try(U64, Str)` are "missing method" errors (Fails.roc). The same union as a nominal type of the
app's own (`Outcome(ok, err) := [Ok(ok), Err(err)].{ encoder_for : _, parser_for : _ }`) writes
`{"Err":"no"}` and reads `{"Ok":5}`, as a structural union does (Workaround.roc). So the derive
works; the checker allowed a builtin `Try` in a derived codec only in the format's two conventions,
`Try(a, [Null])` (a value that may be `null`) and a record field's `Try(a, [Missing])`, and
reported every other `Try` as missing the method.

    ./repro.sh

    == roc test Fails.roc
    The value's type, which does not have a method named encoder_for, is:
    The value's type, which does not have a method named parser_for, is:
    exit 1
    == roc test Workaround.roc
    All (3) tests passed
    exit 0

**Fixed** in the fork since 4674b5973d (2026-11-24), with upstream's fix for issue 13112 (its tests
from 2abc4dc15d, then 52b8b05fa5 and 48043c2f08): the checker accepts a builtin `Try` whose error
isn't the format's `[Null]` or a record field's `[Missing]` as the tag union it is, and Monotype
and Boxy derive its codec from its backing. Both files pass there:

    == roc test Fails.roc
    All (2) tests passed
    exit 0

Until then rocx wrote what crossed the wire as a `Try` as the structural union `[Ok(a), Err(e)]`,
and `rocx check` named it under the compiler's report; both are gone (D-054).
