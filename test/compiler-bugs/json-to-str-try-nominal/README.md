# `Json.to_str_try` of a record holding a nominal type beside another field crashes the compiler

**In one sentence:** writing a record to JSON crashed the compiler (in `boxy_lowering`) when one of
its fields was a type of the app's own with a derived `encoder_for` and another field sat beside
it.

## Like you're five

You ask a robot to write down what's in a lunchbox: an apple, and a little box with a sandwich in
it. The robot knows how to write down an apple, and how to write down a little box. But when the
little box sits next to the apple, it mixes up whose instructions are whose and falls over. The
compiler did the same: it fell over (crashed) instead of writing the JSON. Now it keeps each
box's instructions with that box.

## Details

Found 2026-11-21 on nightly-2026-11-18-a520eed, with the platform's `Json.to_str_try` of a record
like `{ id: "a1", badge }` where `Badge := { name : Str }.{ encoder_for : _ }` (Crash.roc). `roc
test`, `roc check` and `roc build` of a program doing it crashed in `boxy_lowering` (SIGSEGV).

Workaround.roc is what rocx's platforms did meanwhile: they wrote through a function whose where
clause names the floats' failures in an open union, `where [a.Json.Encodable([Infinity, NaN,
NegativeInfinity, ..])]`. A type variable there (`Encodable(e)`) crashed as Crash.roc does.

    ./repro.sh

    == roc test Crash.roc
    Segmentation fault (SIGSEGV) in the Roc compiler.
    exit 139
    == roc test Workaround.roc
    All (5) tests passed
    exit 0

## Why

A derived encoder for a record calls each field's encoder. When a field's type is a nominal type
with a derived encoder of its own, that call is a derivation nested in another. `boxy_lowering`
didn't bind the nested derivation's type variables at the call that nests it, so it read
variables that were never set and crashed.

## The fix

The fork binds a nested codec derivation's variables at the call that nests it
(`src/postcheck/boxy/codec.zig`; a failing test, then the fix: 9168c5ef41 + 17858b118e on the first
fork, d4b2d707bc + dc48e823c8 on `rocx-fixes-3`). **Fixed** in every fork build since 3f66e242ea:
`roc test Crash.roc` passes. Not upstream yet (nightly 890d6c8 still needs it); the user's PR
branch is `fix-boxy-lowering-encodable-main`. The platforms' where clauses were removed once the
fork had it.
