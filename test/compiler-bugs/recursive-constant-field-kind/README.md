# An unannotated constant in a recursive group crashes boxy's compile-time evaluation

Branch `fix-recursive-constant-descriptor`, two commits on upstream main (bec95b9f4a): c356774324 (a
failing test), 15d0065a9d (the fix). In `rocx-fixes-5` as 06e3a5d147 and 5ef2601bb3. Status:
**fixed**. Introduced upstream by PR #13549 (26c2804ee4, b9aaefb7bb); not on the nightly 890d6c8.

## In one sentence

A constant in a recursive group gets its record field's undetermined kind (required or optional)
generalized by the group, and the frame that evaluates each of the constant's instances bound that
kind variable to the kind itself (`[#Required]`, or `[]` for the canonical instance) instead of to
the field's storage, so building the record adapted a function into a slot described as a tag
union.

## Like you're five

You have a lunchbox with one spot for a sandwich. A note on the spot is supposed to say "a sandwich
goes here". Someone wrote "this spot is needed" on it instead, which is true but doesn't say what
fits. When the sandwich arrived, the helper saw a note that didn't describe a sandwich and stopped.
The fix: before packing, turn "this spot is needed" into "a sandwich goes here".

## What goes wrong

`Unannotated.roc`:

```roc
# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back) whose record literal's field no annotation gives a
# kind. The group's shared boundary generalizes `holder`, and with it the
# undetermined kind variable of its `run` field. Each closed instance is
# evaluated at compile time; its frame must bind that kind variable to the
# field's storage, not to the instance's committed kind (`[#Required]`) or,
# for the canonical instance, a sealed flex (`[]`).

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)({}, 1) == 1
```

`NoContext.roc` is the same without `_context` and crashes the same way, so the cause isn't
`_context`'s variable; a tuple `(|_context, input| again(input), 0.U8)` in place of the record
passes (tuples have no field kinds). `Shapes.roc` is the new test
(`test/cli/polymorphic_constant_in_recursive_group_field_kinds.roc`, five expects: two context
types, a constant with no context, one with a data field and two function fields, a use at an
optional kind). `repro.sh` runs each file five ways (the default, `--specialize=no --opt=dev`,
`--specialize=no --opt=interpreter`, `--specialize=yes`, test units from a fresh cache).

- **rocx-fixes-4** (3943c21646): all three files pass all five runs.
- **upstream main bec95b9f4a, debug:** every boxy run stops at "boxy runtime invariant violated:
  adapted descriptors describe different kinds of value" (a compile-time crash of `holder` for each
  instance); `--specialize=yes` passes.
- **rocx-fixes-5 a1714c98de, release:** the boxy runs segfault (SIGSEGV).
- **the fix** (debug, on upstream main and on rocx-fixes-5 with the sibling fixes): all 15 runs pass.

## Why it happens

1. Since PR #13549 top-level constants generalize (26c2804ee4) and each closed instance is evaluated
   at compile time (b9aaefb7bb). A constant of its own keeps its record literal's undetermined field
   kinds weak (`Check.keepRequirementVarsWeak`, `src/check/Check.zig:39864`); a constant in a
   recursive group never gets that call: it generalizes at the group's shared boundary
   (`finishRecursiveGroupBoundary` → `generalizeRank`, Check.zig:24827), which quantifies the kind of
   `holder`'s `run` field.
2. So `holder`'s entry wrapper has that kind variable among its `scheme_vars`, and Boxy lowers the
   field as a `variable_slot` whose storage is the variable (`Layouts.fieldStorage`,
   `src/postcheck/boxy/layouts.zig:373`). Its descriptor must describe the field's slot (design.md,
   "Field Kinds"), which every scheme call builds with `Program.resolveKindSlots` (lower.zig:2774).
3. `Builder.callConstantWrapper` (`src/postcheck/boxy/body.zig:5134`) built the instance frame from
   `self.convert(variable)` and `fillRowNodes`, and never resolved kind slots: the kind variable
   stayed the substitution's entry (`[#Required()]`, or `[]` for the other instance) where the
   function type was expected.
4. The wrapper builds `{ run: … }` by adapting the lambda's value into that slot (`finishRecord` →
   `emitAdapt`); a function and a tag union make the plan `.mismatch` (`static_descs.zig:1929`), and
   running it is the invariant at `src/boxy_runtime/compiled.zig:379` (a release build reads past it
   and segfaults).

## The fix

15d0065a9d: in `callConstantWrapper`, after `fillRowNodes`, `try
self.program.resolveKindSlots(callee_worker.kinds, bound);`, with a comment on why. design.md,
"Field Kinds": an instance's frame builds the wrapper's kind variables into slots, and a constant in
a recursive group quantifies its field kinds, unlike a constant of its own.

## Checked

Debug builds.

- The new test (5 cases: boxy dev, boxy interpreter, boxy test units, `--specialize=yes` dev and
  interpreter): at c356774324, the 3 boxy runs fail (compile-time crashes), the 2 specialized pass;
  at 15d0065a9d, 5 of 5 pass.
- `run-test-zig-module-check` 2755/2755; `run-test-eval` 2679 passed, 0 failed, 57 skipped;
  `run-test-cli -- --suite subcommands` 2321 run, 0 failed, 37 skipped; `run-check-snapshots` clean;
  `zig fmt --check` clean.
- On rocx-fixes-5 (b466d2255a, with the sibling fixes): both commits apply cleanly, and `repro.sh`
  passes all 15 runs.

## Two more shapes, fixed apart

`Forwarded.roc` (the constant read inside a generic function: `--specialize=yes` stopped in Monotype)
and `Literal.roc` (a number literal in the constant: both strategies crashed) failed with this fix
too. They had causes of their own: see
[constant-forwarded-field-kinds](../constant-forwarded-field-kinds/) and
[recursive-constant-literal](../recursive-constant-literal/). This folder's `repro.sh` still runs
them.
