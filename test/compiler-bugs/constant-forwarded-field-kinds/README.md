# A constant in a recursive group, read inside a generic function, has no instance Monotype can find

Branch `fix-forwarded-constant-kinds`, two commits on `fix-recursive-constant-descriptor`: 8898571c8c (a
failing test), 7511dc8f1c (the fix). In `rocx-fixes-5` as 7cf852ba41 and 4a91a147bf. Status:
**fixed**. Introduced upstream by PR #13549 (b9aaefb7bb, on 26c2804ee4); not on the nightly 890d6c8.

## In one sentence

A constant in a recursive binding group generalizes its record literal's field kinds, and when a
generic function reads it, Monotype's specialization looks the instance up by its closed type among
the constant's instance roots; both sides of that comparison could carry a field kind nothing
decided (the canonical root's, whose instantiation gave the kind variable the type `[]` instead of a
kind, and the read's own, for a field the function never touches), so a debug compiler stopped
every `--specialize=yes` build, which is how rocx builds the browser's wasm.

## Like you're five

A toy shop keeps one copy of a toy for each size of box, with the size written on each copy's tag.
On the very first copy someone drew a doodle instead of a size. A helper looking for the right copy
read every tag, reached the doodle and gave up. Another helper didn't know the size of one pocket,
so he didn't look at all. Now the first tag says "normal", and a pocket nobody measured counts as
"normal" too, which is what it always turns out to be.

## What goes wrong

`Forwarded.roc`:

```roc
# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back), read inside a generic function (`forwarded`, generic
# over the context). The group's shared boundary generalizes `holder`, and
# with it the undetermined kind variable of its `run` field. The read in
# `forwarded` is forwarded to the call that closes its type, so the
# specialization of `forwarded` at U8 looks the instance up by its closed
# type among the constant's instance roots, measuring the type of each. The
# canonical root's type gave the kind variable a type (`[]`), not a kind, so
# its field stayed undetermined: "unresolved record field kind reached
# Monotype sealing" under --specialize=yes.

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

forwarded = |context, input| (holder.run)(context, input)

expect forwarded(4.U8, 5) == 5
```

`Fields.roc`, the same with a field the generic function doesn't read:

```roc
# The same with a second field the generic function does not read
# (`count`): nothing in `counted` commits that field's kind, so the read's
# own type still has an undetermined kind when the instance is looked up,
# and the lookup took it for an open type: "a read of polymorphic constant
# root 0 names no instance (edge use)" under --specialize=yes, with or
# without the canonical root's fix.

mixed = { count: 3.U64, run: |_context, input| added(input) }

added : U64 -> U64
added = |input| {
	_ = mixed
	input + 10
}

counted = |context, input| (mixed.run)(context, input)

expect counted(1.I32, 1) == 11
```

`Shapes.roc` is the new test (`test/cli/polymorphic_constant_in_recursive_group_forwarded.roc`):
`holder` read at U8 and at Str, forwarded through two generic functions, and one field of a
two-field constant read. `repro.sh` runs each file 6 ways (the default, boxy dev and interpreter,
`--specialize=yes` dev and interpreter, test units from a fresh cache).

- **rocx-fixes-4** (3943c21646): 18 of 18 pass.
- **upstream main bec95b9f4a, release:** every boxy run segfaults (the field-kind bug,
  `recursive-constant-field-kind`); `--specialize=yes` passes (a release build's invariants are off).
- **with the field-kind fix, or rocx-fixes-5 at 5ef2601bb3 (debug):** the boxy runs pass; every
  `--specialize=yes` run stops: `Forwarded.roc` and `Shapes.roc` at "unresolved record field kind
  reached Monotype sealing", `Fields.roc` at "a read of polymorphic constant root 0 names no
  instance (edge use)".
- **the fix:** 18 of 18 pass.

## Why it happens

Line numbers at upstream main bec95b9f4a.

1. `holder` and `again` are one recursive group, whose shared boundary (`Check.zig:24826`,
   `generalizeRank` at :24853) generalizes `holder` and its `run` field's kind variable with it.
2. `forwarded` reads `holder` at an open type, so the instance is forwarded to `forwarded`'s scheme
   (b9aaefb7bb, `publishLiteralArgumentRoots`), and an instance root is made at the expect's closed
   type.
3. The canonical instantiation (`checked_artifact.zig:23460–23475`) gives every scheme variable
   without a row default the empty tag union, a kind variable included;
   `cloneCheckedTypeRootSubstituting` (:6570–6578) keeps it as `.undetermined(image)` and
   `sealDecidedVariables` (:22687) returns early, so the canonical root's type has `run`'s kind
   undetermined over `[]`.
4. Monotype specializes `forwarded` at U8; with no edge naming the read's root,
   `restoredConstantInstance` measures every instance root's type (`monotype/lower.zig:49058–49063`,
   `closedCheckedMonoOf`); `instField` (:29065) turns the undetermined kind into a cell nothing
   commits, and the sealer stops at `solve.zig:8794`.
5. In `Fields.roc` `counted` reads only `run`, so `count`'s kind in the read's type is a cell nothing
   commits; the lookup ran only when `typeIsResolved(request_node)` (:49058), so the read fell
   through to the invariant at :49071. The policy for this already exists in
   `specializationLookupTypeForNode` (:23676): a type whose only open cells are field kinds reads
   them as `required`.

## The fix

7511dc8f1c, "Look up a constant's instance with open field kinds at required":

- `src/check/checked_artifact.zig`: the canonical instantiation walks the constant's type for kind
  variables and gives each `.field_kind = .required` instead of `[]` (its one instantiation, design.md
  "Decided Variables"), as `sealDecidedVariables` makes it in every other root.
- `src/postcheck/monotype/lower.zig`, `restoredConstantInstance`: the read is looked up at
  `specializationLookupTypeForNode(request_node)`, not only at a resolved type.
- `design.md`, "Polymorphic Constants". Boxy is unchanged (`resolveKindSlots` maps both a committed
  `required` and `[]` to the field's value type).

## Checked

Debug builds.

- The new test: at 8898571c8c, 3 passed and 2 failed (both `--specialize=yes`); at 7511dc8f1c, 5 of 5.
- `run-test-zig-module-check` 2755/2755; `run-test-eval` 2679 passed, 0 failed, 57 skipped;
  `run-test-cli -- --suite subcommands` 2297 passed, 37 skipped; snapshots clean; `zig fmt` clean.
- More shapes pass in 4 modes with the fix: a two-field constant read through both fields; two reads
  of a one-field constant in one function; a non-recursive control; an optional-kind use (`.?run`)
  inside a generic function, a generic getter returning the constant, a local function forwarding
  it.
- On rocx-fixes-5 with all four of this round's last commits (debug): this repro 18/18, the literal
  one 18/18, and every sibling repro passes.
