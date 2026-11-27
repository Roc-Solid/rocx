# A constant in a recursive group generalizes its literal's type

Branch `fix-recursive-constant-literal`, two commits on `fix-recursive-constant-descriptor`: 801532a79a
(a failing test), 1d6c9c7c69 (the fix). In `rocx-fixes-5` as f321bc1f62 and 2dd60e319d. Status:
**fixed: the program compiles.** Introduced upstream by PR #13549 (26c2804ee4, exposed by
b9aaefb7bb); the nightly 890d6c8 rejected the program instead.

## In one sentence

A top-level constant keeps every type variable that carries a requirement (a number literal's, say)
weak, but a constant in a recursive binding group skipped that rule, so the group's shared boundary
made it polymorphic over the literal's type, a requirement no read of a constant can supply, and
evaluating its canonical instance with that type at `[]` crashed both strategies.

## Like you're five

Two friends share a jar of marbles. The rule is that a jar's marbles get one color everybody agrees
on, and a jar on its own always picks its color straight away. This jar sat between the two friends,
so nobody picked, and it said "any color you like". When the teacher made copies of the jar for the
class, she painted the marbles "no color at all", and they didn't fit in the copies. Now the shared
jar picks one color straight away, just like a jar on its own.

## What goes wrong

`Literal.roc`:

```roc
# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back) with a field whose type carries a requirement: the
# number literal's `from_numeral`. A constant of its own keeps that type
# weak, one type every use shares, defaulted when the module finishes. The
# group's shared boundary generalized it with the constant instead, so the
# constant was polymorphic over a variable with a requirement no read of a
# constant can supply: its canonical instance put the literal in a field of
# type `[]`. Boxy stops at a Dev/codegen layout invariant
# (tag_payload_struct_access) while evaluating it, Monotype at "measuring a
# closed checked type did not record its Monotype".

holder = { n: 1, run: |input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)(1) == 1
```

`Shapes.roc` is the new test (`test/cli/polymorphic_constant_in_recursive_group_literal.roc`): a read
of `holder.n`, a second constant whose literal a use fixes to U8, and a constant whose function member
does arithmetic. `Alone.roc` is the same constants without the recursion. `repro.sh` runs each file
6 ways.

- **rocx-fixes-4** (3943c21646): `Literal.roc` and `Shapes.roc` are refused, "This top-level value
  still has an unresolved polymorphic type"; `Alone.roc` passes 6/6.
- **upstream main bec95b9f4a, release:** all 12 runs of `Literal.roc` and `Shapes.roc` segfault;
  `Alone.roc` passes.
- **with the field-kind fix, or rocx-fixes-5 at 5ef2601bb3 (debug):** the boxy runs stop at a codegen
  layout invariant ("actual layout 14 (scalar) did not match expected layout 16 (zst)"),
  `--specialize=yes` at "measuring a closed checked type did not record its Monotype".
- **the fix:** 18 of 18 pass.

Why compile rather than refuse: design.md, "Polymorphic Constants", says a variable that carries a
requirement doesn't generalize, the constant keeps it weak, and the codec fix adds that a constant in
a recursive group owns no requirement either. The same constants outside a recursive group
(`Alone.roc`) compile on every compiler, so the recursion shouldn't change whether the program is
accepted. Using the literal at two types (`holder.n + 1.U8` and `holder.n + 1.I64`) is still a type
mismatch, as for a constant on its own.

## Why it happens

Line numbers at upstream main bec95b9f4a.

1. `topLevelConstantGeneralizes` (`Check.zig:39848`) is false for a member of a recursive group
   (:39855), so `holder` isn't a boundary of its own and `keepRequirementVarsWeak` never runs for it.
2. The group's boundary (`finishRecursiveGroupBoundary`, :24826) defaults only literals no member's
   type reaches; `generalizeRank` (:24853) then quantifies the literal's `from_numeral` variable.
3. The canonical instantiation (`checked_artifact.zig:23460–23475`) gives that variable `[]`, so the
   literal `1` is stored in a field of type `[]`, and evaluating that instance fails (Boxy: a scalar
   where the field's layout is zero-sized, `LirCodeGen.zig:13490`; Monotype: no Monotype recorded,
   `monotype/lower.zig:28781`).

## The fix

1d6c9c7c69, "Keep a recursive group's value members' requirement variables weak" (`src/check/Check.zig`):
`keepGroupValueRequirementVarsWeak` walks from the type of every value member (not a function, not a
value alias), collects what carries a requirement (a literal's undetermined type, static-dispatch
constraints) and every dispatch still waiting on a type it reached, and pins them at the enclosing
rank, by the loop `keepRequirementVarsWeak` uses (split out as `pinRequirementVarsWeak`). It runs at
the same two points as for a constant on its own: before the group boundary's defaulting and before
`generalizeRank`. Field kinds and uncommitted tails aren't pinned (the field-kind fix's model);
types only a function member reaches still generalize; a function member sharing such a type shares
the weak variable (as Haskell's monomorphism restriction does). `design.md`: a paragraph in
"Polymorphic Constants".

## Checked

Debug builds.

- The new test: at 801532a79a, 0 of 5 (the layout invariant); at 1d6c9c7c69, 5 of 5.
- `run-test-zig-module-check` 2755/2755; `run-test-eval` 2679 passed, 0 failed, 57 skipped;
  `run-test-cli -- --suite subcommands` 2297 passed, 37 skipped; snapshots clean; `zig fmt` clean.
- More shapes: a function member doing arithmetic on the constant's type and a literal list field
  crash on the base and pass with the fix; the literal used at two types is a type mismatch.

## Not this bug (older, on the nightly too)

```roc
holder = { run: |input| again(input, 0) }
again = |input, extra| { _ = holder; _ = extra + extra; input }
expect (holder.run)(5.U64) == 5
```

A literal in the constant's body sits at a type its own type doesn't mention but a function member's
does: it fails at run time with "dispatch on a value that can never exist" on rocx-fixes-4 and on
rocx-fixes-5 with these fixes, so it isn't a #13549 regression. Not fixed.
