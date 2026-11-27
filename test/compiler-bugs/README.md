# Roc compiler bugs rocx has met

Each folder is one bug: the smallest program that shows it, a `repro.sh` that runs it (`ROC=…/roc
./repro.sh` picks the compiler), and a README that says it in one sentence, then like you're five,
then what goes wrong, why, and the fix. `just compiler-bugs` runs every repro on the pinned nightly
and on the fork rocx builds with.

rocx builds with a fork of Roc (`~/roc-fork`, private; the compiler binary is published per pin,
D-069). Each fix there is a branch of two commits: a test that fails, then the fix.

## Where each one stands

The compilers: upstream's nightly-2026-11-18-a520eed (the nightly rocx pins); the fork at the pin,
4674b5973d (`rocx-fixes-2`); upstream's main at bec95b9f4a (2026-11-27, 93 commits past the latest
nightly, 890d6c8); and `rocx-fixes-5`, the fork rebased onto that main: the fork's earlier fixes
and this folder's of 2026-11-27, each two commits (a1714c98de).

| Bug | In short | nightly | 4674b59 (pin) | upstream main | rocx-fixes-5 |
|---|---|---|---|---|---|
| [effectful-closure-dec-default](effectful-closure-dec-default/) | a closure checked against `() => T` makes a number it captured a `Dec` | ✗ | ✗ | ✗ | ✓ |
| [nested-lambda-literal-default](nested-lambda-literal-default/) | a number a local closure passes to a captured function becomes a `Dec` | ✗ | ✗ | ✗ | ✓ |
| [rigid-others-row](rigid-others-row/) | `?` on a `[…, ..others]` error refused in a function whose result ends in the same `..others` | ✗ | ✗ | ✗ | ✓ |
| [two-formats-one-where](two-formats-one-where/) | a where clause asking one type for two formats crashes the compiler instead of being reported (it is a type error) | crash | crash | crash | reported |
| [endpoint-capture-boxy](endpoint-capture-boxy/) | a stored closure capturing a nominal type over a function-only variable crashes `boxy_lowering` | crash | crash | crash | ✓ |
| [nested-site-evidence-scope](nested-site-evidence-scope/) | a closure default left out of a record built in a generalized local function is lowered in the wrong scope: a crash, **or a wrong program** (`--specialize=yes`) | crash / wrong | crash / wrong | crash / wrong | ✓ |
| [lambda-solve-specialize-wasm](lambda-solve-specialize-wasm/) | specializing crashes when a function's closure is reached from two binding groups | crash | crash | ✓ | ✓ |
| [huge-frame-opt-speed](huge-frame-opt-speed/) | specialized stack frames grow with the page (`./repro.sh`'s largest frame) | – | 41,744 B | **276,192 B** | 28,672 B |
| [json-to-str-try-nominal](json-to-str-try-nominal/) | writing a record holding a nominal type to JSON crashes the compiler | crash | ✓ | crash | ✓ |
| [try-json-codec](try-json-codec/) | the builtin `Try` has no JSON encoder or parser | ✗ | ✓ | ✓ | ✓ |
| [list-map-reuse-opt-speed](list-map-reuse-opt-speed/) | `List.map` writes past its items under `--opt=speed` | crash | ✓ | crash | ✓ |
| [middleware-skipped-opt-speed](middleware-skipped-opt-speed/) | a chain of three effectful closures skips its last step under `--opt=speed` | crash | ✓ | ✓ | ✓ |
| [two-guarded-routes-opt-speed](two-guarded-routes-opt-speed/) | two routes sharing a middleware that remembers something crash a server at start | crash | ✓ | ✓ | ✓ |

✗ is a wrong answer (a type error that shouldn't be, or a wrong result); crash is the compiler or
the built program crashing; wrong is a program built without a word that computes the wrong thing.
On the nightly, the `--opt=speed` server repros now crash while compiling (`lambda_solve`), before
they can show their own bug.

So upstream's main still has nine of them: the fork's fixes are all still needed there. Its
slot-lifetime change (d48d0123aa) marks only slots passed to a call, which is why its frames are
about ten times the pin's (huge-frame-opt-speed). The pin bump should take `rocx-fixes-5`: the
earlier bases, `rocx-fixes-3` (c69cdc3fdf, on the nightly 890d6c8) and `rocx-fixes-4` (it with
these fixes), are superseded.

## Running them

    just compiler-bugs                      # every repro, on the nightly and the fork
    ROC=…/roc test/compiler-bugs/<bug>/repro.sh

The server repros (`*-opt-speed`) build apps on `server/platform`, so its host must be built (`just
test` or `node server/build.mjs`) for the compiler's glue: this checkout's platform for the pin, the
pin bump's for upstream main and `rocx-fixes-5`.
