# A numeral a local closure passes to a captured function is defaulted to `Dec`

Branch `fix-nested-lambda-literal-default`, two commits on `rocx-fixes-3` (c69cdc3fdf):

- 6de3ddf5ec Add failing tests for a numeral a nested lambda passes to a captured function
- 8fe4bc4425 Judge a boundary's open literals by their ranks after escape adjustment

Status: **fixed**. This is a type-checker bug; the programs are correct. Upstream main (41b4f93,
2026-11-26) still has the old code.

## In one sentence

A local closure's generalization boundary decided which open literals it owned by their rank before
rank adjustment had run, so a numeral whose type is the argument of a function the enclosing
function takes (`|f| { k = || f(1); k() }`) still looked like the closure's own: it was defaulted to
`Dec` there, and the enclosing function took a `Dec -> b` instead of any number.

## Like you're five

You and your big sister share a toy box. One of her toys is put in your box for a moment, still in
her bag. At tidy-up time you sort your box, find a toy with no label, and put it in the "grey"
drawer. But it was your sister's, and she wanted to choose its drawer herself. The fix: before you
tidy, you look inside every bag, and anything of your sister's goes back to her to sort.

## What goes wrong

`Nested.roc`:

```roc
## `v` takes a function and calls it with the numeral `1` from inside a local closure `k`. `v`
## should be generic in that number: `(a -> b) -> b where a is a number`. Before the fix it is
## `(Dec -> b) -> b`: the numeral was defaulted at `k`'s generalization boundary, though its type is
## the argument type of `f`, a parameter of `v`. With no caller in this module, `roc check
## Nested.roc` passes either way; Caller.roc, in another module, shows the type.
Nested := [].{
	v = |f| {
		k = || f(1)
		k()
	}

	## The same with effectful functions.
	v! = |f!| {
		k! = || f!(1)
		k!()
	}

	## Control: the numeral is the receiver of `to_str`, so nothing outside `k` reaches its type.
	## It is still defaulted to Dec at `k`'s boundary, and `local` is `(Str -> b) -> b`.
	local = |f| {
		k = || f(1.to_str())
		k()
	}
}
```

`Caller.roc`:

```roc
## `roc check Caller.roc` should pass: `Nested.v` is generic in the number it passes to `f`. Before
## the fix the first two calls fail: `Nested.v` and `Nested.v!` want a `Dec -> _ret`.
import Nested

Caller := [].{
	small : (U8 -> Str) -> Str
	small = |g| Nested.v(g)

	small! : (U8 => Str) => Str
	small! = |g!| Nested.v!(g!)

	shown : (Str -> Str) -> Str
	shown = |g| Nested.local(g)
}
```

`v` should be `(a -> b) -> b where [a.from_numeral : Numeral -> Try(a, [InvalidNumeral(Str)])]`, the
same as `direct = |f| f(1)`. Instead it is `(Dec -> b) -> b`. The module itself checks; a caller in
another module fails:

```
── ✗ type mismatch ───────────────────────────────────────────── Caller.roc:7:23
    U8 -> Str
    Dec -> _ret
```

In one module (`Shared.roc`), a U8 caller and a U16 caller both fail against `Dec -> _ret`.

The same happens with effectful functions (`v! = |f!| { k! = || f!(1); k!() }`); with two closure
levels; with the numeral inside a tuple, record or list the closure passes; with `f(1) + f(2)`; and
when the closure passes its own argument next to the numeral (`k = |x| f(x, 1)` wants
`U8, Dec -> _ret`). Not affected (`Direct.roc`): the numeral passed directly in `v`'s body, and a
local that holds the call's result (`k = f(1)`).

`ROC=<roc> ./repro.sh`:

| file | base c69cdc3 | fork 4674b59 | nightly a520eed | fixed (debug) |
|---|---|---|---|---|
| Nested.roc | ✓ | ✓ | ✓ | ✓ |
| Caller.roc | ✗ `U8 -> Str` vs `Dec -> _ret`; `U8 => Str` vs `Dec -> _ret` | ✗ same | ✗ same | ✓ |
| Shared.roc | ✗ `U8 -> Str` / `U16 -> Str` vs `Dec -> _ret` | ✗ same | ✗ same | ✓ |
| Direct.roc | ✓ | ✓ | ✓ | ✓ |

## Why it happens

When two type classes are unified, the merged class keeps the lower rank. The classes inside its
structure keep their own ranks until generalization adjusts ranks (`Generalizer.adjustRank`,
`src/types/generalize.zig`).

Literal defaulting at a boundary runs before generalization (`src/check/Check.zig:33242` at
c69cdc3fdf: "boundary defaulting runs first—it must see ranks BEFORE they are promoted"). It picks
its candidates by rank, before that adjustment:

- `boundaryHasLiteralCandidate` (Check.zig:49788), which gates `relateBoundaryRequirements` (49836)
  and the fast path (49886);
- `boundaryDefaultsReceiver` (49780);
- the `.boundary` universe in `runLiteralDefaultingRounds` (47084:
  `if (resolved.desc.rank != boundary.rank) continue;`).

In `v`, `f(1)` builds a function type `num -> ret` at `k`'s rank and unifies it with `f`'s type,
which has `v`'s rank. The merged function class takes `v`'s rank, but `num` keeps `k`'s.
`k : () -> ret` doesn't reach `num`, so `k`'s boundary defaults it to `Dec`. Rank adjustment would
have moved `num` to `v`'s rank, but it runs too late.

`Generalizer.adjustEscapes` (generalize.zig:297) runs only the enclosing part of rank adjustment and
settles nothing. `decideUnreachedOpenRowsAtBoundary` (Check.zig:59847) already uses it for open
rows, for the same reason (upstream d47394f064). Literal defaulting never did.

## The fix

All in `src/check/Check.zig` at 8fe4bc4425:

- `boundaryHasLiteralCandidate` now returns `Allocator.Error!bool`. If the pool holds an open
  literal at the boundary's rank (`poolHasOpenLiteral`, the old body), it calls
  `adjustBoundaryEscapes` and looks again. Its two callers and `boundaryDefaultsReceiver` (which
  only runs when it returns true) now see adjusted ranks.
- `adjustBoundaryEscapes` calls `generalizer.adjustEscapes(&env.var_pool)`. It skips scopes without
  a rank of their own (`!generalizesInnermostScope()`, the nesting limit), which share the
  enclosing scope's pool.
- Each boundary defaulting round adjusts again before it gathers candidates, because a round's
  commits can link more structure (defensive: no builtin-only program was found that needs it).

Cost: a boundary with no open literal at its rank does exactly what it did before; one that has
one walks the enclosing-reachable part of its pool again, which generalization walks anyway.
design.md: a new paragraph in "Pending Dispatch Requirements In Type Schemes" states the ownership
rule, with this example.

Literal defaulting still works where it should:

- A numeral nothing outside the closure reaches is still defaulted at the closure's boundary:
  `k = || f(1.to_str())` gives `v : (Str -> a) -> a`, and the numeral is `Dec`.
- A top-level `five = 5` is still `Dec`.
- An unreachable literal of the enclosing definition still defaults at that definition's boundary,
  with the LITERAL DEFAULTED warning (`method_call_literal_boundary_default.md` is unchanged).

## Checked

Debug builds. The fixed compiler was built from 8fe4bc4425.

- **Repro:** the table above.
- **More variants:** `f(1) + f(2)` with I32; `(f(1), g(1.5))` with U8 and F32; two closure levels
  with I64; `{ a: f(1), b: 2 }` with U16 and U32; `(k(), k())` with I8; `f([1, 2, 3])` with
  `List(U8)`. All fail on base and pass with the fix. A string (`f("hi")`) passes on both.
- **New tests** (`src/check/test/nested_lambda_literal_test.zig`): at 6de3ddf5ec, 4 of 5 fail with a
  type mismatch (U8/U16 in one module, effectful, own argument next to the numeral, another
  module); the control passes. At 8fe4bc4425, all pass.
- **`run-test-zig-module-check`:** 2745/2745 passed (2740 on the base plus 5 new).
- **`run-test-eval`:** 2679 passed, 0 failed, 0 crashed, 57 skipped (2736), the same as the base.
- **`run-check-snapshots`:** only the base's 8 `Bool.not` diffs and its `dev_object_float_math.md`
  warning, both from 159add67a5 and fixed on branch `fix-list-map-test-hygiene`.
- **Format, tidy, lints, type-checker patterns, unreachable rationale:** pass.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
