# A `?` on a row that ends in the annotation's `..others`

## In one sentence

The checker refused a `?` (or a tail call) on a callback whose error row is
`[DbErr(Str), ..others]` inside a function whose result is `[NotFound, DbErr(Str), ..others]`,
although every error the callback can return is in that result. It was a gap in how `?` combines
error rows, and branch `fix-rigid-others-row` fixes it.

## Like you're five

Your toy box has a label: "red blocks, a blue ball, and whatever toys my friend brings". Your
helper's box says "red blocks, and whatever toys my friend brings". Everything in the helper's box
fits in yours. But the grown-up checking read the labels word by word, saw no blue ball on the
helper's label, and said "these don't match!". Now the grown-up checks that each thing on the
helper's label is on yours, and that "whatever my friend brings" means the same friend on both.

## What goes wrong

`Callback.roc` (no platform):

```roc
Callback := [].{
	save : (I64 -> Try({}, [DbErr(Str), ..others])) -> Try({}, [NotFound, DbErr(Str), ..others])
	save = |step| {
		step(1)?
		Err(NotFound)
	}
}
```

The base compiler (c69cdc3fdf) says this; so do 4674b5973d and nightly a520eed:

```
── ✗ type mismatch ── Callback.roc:7:3
This ? may return early with a type that doesn't match the function body.
step(1)?
If this Try is an Err, then the ? after it immediately returns an Err whose payload has this type:
    [DbErr(Str), ..others]
... but this function's return type is:
    Try({}, [DbErr(Str), NotFound, ..others])
```

- **Controls that pass everywhere:** `Closed.roc` (both rows closed) and `Bare.roc` (the callback's
  row is the bare rigid `e`, the result `[NotFound, ..e]`).
- **Also failing:**
  - `TailCall.roc`: the callback's call is the body's value after a `?`.
  - `Transaction.roc`: the shape `examples/uptime` met. An unannotated lambda passed to
    `transaction! : ({} => Try(a, [DbErr(Str), ..others])) => Try(a, [DbErr(Str), ..others])`
    `?`s a database call and `alert!`, and returns `NotFound`. The first of its two errors points
    at an `if` and says "This ? may return early", which is confusing.

The compiler is wrong here. `others` is rigid, so the function must work for whatever tags the
caller adds. Every error the callback can return is either `DbErr` (listed in the result) or a tag
of `others`, which is the result's own tail. The body adds only `NotFound`, which is listed.
`Unlisted.roc` (the same body, its result without `..others`) must be rejected, and still is.

## Why it happens

`processReturnConstraints` (`src/check/Check.zig`; design.md, "Try Return-Row Composition") sorts
each `?` row that has tags. Line 51919 at c69cdc3fdf:

```zig
if (gathered.nested or (self.tryReturnTailGainsNoTag(gathered.tail, composed.err) and !gathered.host_fixed)) { ...projected... } else { plan.relation = .whole; }
```

- `tryReturnTailGainsNoTag` (line 52048) is true only for a closed row or an annotation-bounded
  tail, and false for a rigid one.
- So `[DbErr(Str), ..others]` is made equal to the whole result row. That needs
  `others ~ [NotFound, ..others]`, which a rigid variable can never satisfy.
- `Bare.roc` passes because rows with no tags have an explicit "the result already shares this
  tail" check (line 52000). Rows with tags have no such path.
- The body's own result goes through the same sorting, hence `TailCall.roc`.

## The fix

- **What changed in the checker:**
  - A source row with tags whose tail is rigid is now treated like a closed row: its tags join the
    result through a fresh row, and the source row itself is left alone (`tryReturnTailIsRigid`).
  - Its rigid tail is then unified with the result's tail:
    - An annotated result accepts it only when its tail is the same rigid variable.
    - An unannotated result takes the rigid as its tail.
    - Anything else (closed, bounded, a different rigid) is a mismatch. It is reported against the
      contribution's own type (`reportTryReturnContribution`), so `Unlisted.roc` gets the same
      message as before.
  - Host-boundary rows are still related whole. design.md has a new paragraph describing the rule.
- **Lowering:** no change needed. It already handles `?` contributions whose source and
  destination rows differ but share a tail.
- **Tests:**
  - `src/check/test/rigid_tail_try_composition_test.zig`: 4 accepted shapes and 2 rejections that
    must stay.
  - `test/cli/RigidTailTryComposition.roc`: 12 expects, wired for 5 backend variants in
    `src/cli/test/parallel_cli_runner.zig`.
- **Still not covered:** re-raising by hand,
  `match step(1) { Ok({}) => Err(NotFound), Err(e) => Err(e) }`. That uses a different mechanism
  (design.md, "Row Subsumption"), which only re-opens closed rows. Write `step(1)?` instead.
- **Display quirk, unchanged:** mismatch reports can print a rigid under a fresh name (`..a`
  instead of `..first`). The base compiler does this too.
- **For rocx:** with this compiler, `examples/uptime` can write `..others` instead of naming
  `JobErr`.

## Checked

- **`repro.sh`:**
  - Base: Callback, Transaction and TailCall exit 1; Bare and Closed exit 0; Unlisted exits 1. The
    same on 4674b59 and a520eed.
  - Fixed debug build: the first five exit 0; Unlisted exits 1 with an unchanged message.
- **Checker tests (`zig build run-test-zig-module-check`):** 2746/2746 pass. At commit 1, 2742 pass
  and 4 fail.
- **`roc test` on `RigidTailTryComposition.roc`:**
  - Base: "Compilation failed with 3 errors".
  - Fixed: "All (12) tests passed" under `--specialize=no/yes` × `--opt=interpreter/dev`,
    `--opt=speed`, and the default.
- **`roc check` on all 711 `test/cli/*.roc`:** base and fix agree except the new file.
- **`roc test` on 40 `test/cli` files that use `?` and row variables:** identical results under
  both specialization settings.
- **Eval suite (`zig build run-test-eval`):** 2679 passed, 0 failed, 0 crashed, 57 skipped (2736).
- **Snapshots (`zig build run-check-snapshots`, 1422 regenerated):** no `?` or row snapshot
  changed. It fails on 8 `Bool.not` `target-node` shifts (19211 → 19216). That drift is already
  on `rocx-fixes-3`, from the earlier fixes' Builtin.roc change; it was reverted, not part of the
  branch.
- **Lint:** `run-check-type-checker-patterns`, `run-check-tidy`, `run-check-test-asset-coverage`
  and `zig fmt --check` pass.

## In rocx

examples/uptime names its job's error (`Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])`) where it
wanted a transaction's body to pass on `..others` (0f982e1). With the fork's branch
`fix-rigid-others-row` it can write `..others`; until the pin has it, it keeps the names.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
