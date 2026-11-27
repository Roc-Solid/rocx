# A closure checked against `() => T` defaults the number it reads to `Dec`

Branch `fix-effectful-closure-dec-default`, two commits on
`rocx-fixes-3` (c69cdc3fdf):

- 9f5e2e3c1c Add failing tests for a callback stored where an effectful function is expected
- db71ec7bd8 Keep a callback's effect formula off the effectful type it meets

Status: **fixed**. This is a checker bug; the program is correct.

## In one sentence

When a closure whose body calls a function with an undecided effect was unified with an effectful
function type, the unifier copied the closure's effect dependencies onto that type, which can be a
shared module-level annotation. Rank adjustment then walked those dependencies and pinned the
enclosing function's parameters at module rank, so they were never generalized, and a numeral
among them was defaulted to `Dec` when the module was sealed.

## Like you're five

You borrow some crayons for one drawing and write a note saying which crayons the drawing needs.
Your friend sticks the note on the classroom's shared crayon cupboard instead of on your drawing.
Now everyone thinks those crayons belong to the cupboard, so nobody can take them home. When the
teacher tidies up, she puts them all in the "beige" drawer because nobody claimed them. The fix:
when the drawing is done, the note goes in the bin instead of on the cupboard, and you keep your
own copy in your pocket.

## What goes wrong

A closure in its own slot (a record field or a list item, not a direct call argument) can call
something whose effect isn't known yet: a function it captured, or a method on a value whose type
isn't known yet. If that slot's type is `() => Str` (effectful) and belongs to an annotation that
every caller shares, the enclosing function stops being generic in what the closure captured.
Pure slots (`() -> Str`) and calls made outside the closure are fine.

The smallest form, one module (`Shared.roc`):

```roc
Shared := [].{
    keep : List(() => Str) -> Str
    keep = |_| "kept"

    show = |f, n| keep([|| f(n)])

    small : (U8 -> Str), U8 -> Str
    small = |g, x| show(g, x)

    large : (U16 -> Str), U16 -> Str
    large = |g, x| show(g, x)
}
```

```
── ✗ type mismatch ──────────────────────────────────────────── Shared.roc:17:22
    U16 -> Str
    U8 -> Str
```

`show` should be `(a -> Str), a -> Str`. Instead, `small`'s U8 fixes `n` for `large`. With
`List(() -> Str)` (`SharedPure.roc`) it checks.

The rocx shape (`ErrorPage.roc` + `Bad.roc`): `view!` compares `status!()` with `404` and calls
`to_str` on it inside the getter it gives `page!`. With no caller in `ErrorPage.roc`, the number is
defaulted to `Dec` when the module is sealed, so a caller in another module fails:

```
== roc check Bad.roc
── ✗ type mismatch ──────────────────────────────────────────────── Bad.roc:6:33
    { status: () -> U16 }
    { status: () -> Dec }
exit 1
```

These play no part: the record pattern, `!` names, string interpolation, the record itself (a list
or tuple slot does the same), and the method (`|| f(n)` with a captured function does the same).
What matters:

- the closure is in a slot of its own, so it is generalized on its own;
- it calls something whose effect is still undecided;
- it meets an effectful function type that lives at an outer rank.

## Why it happens

A temporary rank dump on `|f, n| keep([|| f(n)])` shows it (the instrumentation was removed again):

```
inner `|| f(n)`:   unb#22@3(-> Str deps{unb#268@2(flex#19@2 -> Str)})
outer boundary, pool var below its rank:
                   eff#22@1(-> Str deps{unb#268@2(flex#19@2, -> Str)})   <- keep's `() => Str`, now listing f
after generalize:  unb#20@1(unb#268@1(flex#19@1, -> Str), #19^, -> Str@1)  <- f and n pinned at rank 1
```

Line numbers below are at `rocx-fixes-3`.

1. `src/check/Check.zig:36704-36717` (`resumeLambdaCheck`): the closure's body calls `f`, whose
   effect is unresolved, so the closure's type is `fn_unbound` with `effect_deps = [f]`.
2. The closure sits in a list (or record) slot, so it generalizes on its own. Afterwards it is
   unified with the item type `() => Str` from `keep`'s annotation. That annotation has no type
   variables, so every use of `keep` shares one `() => Str` node at rank 1.
3. `src/check/unify.zig:2112-2125`: `fn_unbound` meets `fn_effectful` and the result is effectful.
   The merge goes through `contentForMerge`, whose `fn_effectful` case (`unify.zig:697-699`) calls
   `funcForMerge` (`unify.zig:4368`). That keeps the union of both sides' `effect_deps`, so the
   shared rank-1 node now lists `f`. The `fn_pure` case (`unify.zig:692-696`) already drops the
   list, which is why the pure version works.
4. At the outer lambda's boundary, `src/types/generalize.zig:353-357` adjusts the pool's vars,
   lowest rank first, each walked at its own starting rank (`adjustPooledRank`,
   `generalize.zig:446-448`). `stepFunc` descends into the rank-1 node's `effect_deps`
   (`generalize.zig:733-741`), and `requestDescRank` lowers every var it reaches to 1
   (`generalize.zig:590-592`). `f` and `n` end at rank 1: never quantified, shared by every use.
5. With no caller in the module, module-end literal defaulting (`finalizeLiteralDefaults`,
   `Check.zig:45019`) makes `n` a `Dec`. A caller in the same module fixes it first; a second
   caller with another type then fails, as `Shared.roc` shows.

Dependencies on a decided (`fn_effectful`) type say nothing about that type: the effect solver
treats it as terminal and never reads them (`src/types/effect_solver.zig:96,116`). Their one reader
was `lambdaBodyIsEffectful` (`Check.zig:21640`). It asks whether a lambda's body performs an
effect, for the effectful-function-name warning (`checkEffectfulFunctionName`, `Check.zig:21718`)
and for compile-time roots. That is why `funcForMerge` kept the union.

## The fix

db71ec7bd8:

- `src/check/unify.zig:697-708` (`contentForMerge`): a merged `fn_effectful` type carries no
  `effect_deps`, exactly as a merged `fn_pure` already doesn't. `funcForMerge` now unions
  dependencies only for `fn_unbound` merges, and its comment says so.
- `src/check/Check.zig`: each lambda keeps its own body's dependency list in a new keyed field,
  `lambda_body_effect_deps` (`Check.zig:1786-1791`, inventory `:2305`, init `:5110`). It is filled
  in `resumeLambdaCheck` (`:36730-36736`) when the body's effect is still undecided as the type is
  made. `lambdaBodyIsEffectful` (`:21648-21662`) reads it in addition to what it read before.
  Without this half, `a : U64 => U64; a = |n| if n == 0 0 else b(n - 1)`, with `b` an effectful
  member of `a`'s recursive group, loses its effectful-function-name warning (checked: a build with
  only the unify change reported `b` alone; the base and the full fix report both `a` and `b`).
- `design.md`, "Effect Slots": a paragraph on merged effectful types and the lambda's own list.
- `src/check/test/call_effect_dependencies_test.zig`: one more test, for the `a`/`b` case.

Why this is right: it makes the effectful case match the pure case the code already had, and it
follows the design's own rule that effect dependencies "encode invoked effects, not additional
parameters of the enclosing function". `fn_unbound` lists are untouched: still a union on merge,
still walked by rank adjustment, instantiation and import copying.

What it doesn't change:

- `finalizeFunctionEffectsAtBoundary` (`Check.zig:24958`) still writes an effectful root with its
  own list; that is not a merge.
- Literal defaulting and generalization order are unchanged, and the closure is still generalized
  on its own.
- No snapshot output changes.

Not fixed, separate (also present on the base and on nightly a520eed, pure or not): a numeral
written inside a nested lambda and passed to a captured function is defaulted at the inner
lambda's boundary. For example, `v = |f| { k = || f(1); k() }` gives `v : (Dec -> r) -> r`.
`boundaryHasLiteralCandidate` (`Check.zig:49788`) judges candidates by their unadjusted rank, so a
literal reached only through an enclosing variable still looks like the inner scope's. It is a
different mechanism, not needed for the rocx case, and untouched.

## Checked

Compilers: base = `…/roc-fork/c69cdc3fdf…/bin/roc`; fixed = debug
`a debug build of the branch` built from db71ec7bd8.

Repro: `ROC=<roc> ./repro.sh`. It runs the three rocx files plus `Shared.roc` and `SharedPure.roc`.

| file | base c69cdc3 | fork 4674b59 | nightly a520eed | fixed |
|---|---|---|---|---|
| Bad.roc | ✗ `() -> U16` vs `() -> Dec` | ✗ | ✗ | ✓ |
| Pure.roc | ✓ | ✓ | ✓ | ✓ |
| Hoisted.roc | ✓ | ✓ | ✓ | ✓ |
| Shared.roc | ✗ `U16 -> Str` vs `U8 -> Str` | ✗ | ✗ | ✓ |
| SharedPure.roc | ✓ | ✓ | ✓ | ✓ |

These variants also pass with the fix; all failed on base: a record field with `== 404`; a list
slot; a tuple slot; a pure function taking `{ kicker : () => Str }`; a local
`l : List(() => Str)` annotation; a captured function called inside the closure; two callers in the
same module with U8 and U16.

New tests, run with `zig build run-test-zig-module-check -- --test-filter stored`:

- At 9f5e2e3c1c (tests only), 2 fail, both with Type Mismatch: "a callback stored where an
  effectful function is expected leaves its enclosing function generic" (`U16 -> Str` vs
  `U8 -> Str`); "a number a stored effectful callback reads is not defaulted"
  (`{ status: () -> U16 }` vs `{ status: () -> Dec }`).
- At db71ec7bd8, 14/14 pass.
- db71ec7bd8 also adds "a lambda that meets an effectful annotation keeps its body's
  dependencies", which expects two effectful-function-name warnings. It passes on the base too; it
  guards the side-table half of the fix.

Suites at db71ec7bd8 (private ZIG_GLOBAL_CACHE_DIR, debug):

- `run-test-zig-module-check --summary all`: **2743/2743 passed**.
- `run-test-eval`: **2679 passed, 0 failed, 0 crashed, 57 skipped** (2736 total).
- `run-check-snapshots`: 8 diffs, all `Bool.not`'s `target-node "19211"` → `"19216"`, plus a DEV
  OUTPUT hash warning for `dev_object_float_math.md`. It is **identical with the base
  `Check.zig`/`unify.zig`**: 159add67a5 added `output = []` to `List.map` in `Builtin.roc`
  (+5 nodes before `Bool`), and the fork never regenerated the snapshots.
- `run-check-zig-format`, `run-check-tidy`, `run-check-zig-lints`,
  `run-check-type-checker-patterns`, `run-check-unreachable-rationale`: pass.
- `run-check-test-wiring`: fails compiling `src/compile/test/list_map_reuse_output_test.zig:35`
  ("expected optional type"), a test file from `rocx-fixes-3` (d1bb7f36d3). Unrelated and
  untouched.

No release build was made.

## In rocx

Found 2026-11-27 when an app's release build failed at Generated/Root.roc: its error page
(`routes/+error.rocx`) gave a `view!` component (whose props rocx types as `() => T` getters)
`kicker={"Error ${status.to_str()}"}`, so the page took `{ status : () -> Dec }` where Root hands it
a `U16`.

`rocx check` didn't see it: it checks the dev build, where each getter a body reads is written
`Html.read_at!("…", status!)` (D-052), and with that the number stays generic. Only the release
build (`rocx build`, `--image`), which reads `status!()`, failed.

Workaround until the pin has the fix: call `to_str` in the page's body (`code = status.to_str()`)
and use `code` in the attribute, as `hoisted_view!` in ErrorPage.roc does. An error page's status
doesn't change, so reading it once costs nothing.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
