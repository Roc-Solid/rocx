# A constant in a recursive group takes on a function's codec requirement

Branch `fix-constant-codec-dictionary`, two commits on upstream main (bec95b9f4a): 9bfadefee4 (a
failing test), 5841b455dd (the fix). In `rocx-fixes-5` as e6f98703b9 and 05bd02d732. Status:
**fixed**. Introduced upstream by PR #13549 (26c2804ee4, b9aaefb7bb); not on the nightly 890d6c8.

## In one sentence

A top-level constant in a recursive binding group with a function that encodes or parses a record
is generalized by the group, so it is a polymorphic constant, and it also took on the function's
generated-codec requirement, so evaluating each closed instance asked for a JSON codec dictionary
no read of a constant can supply, and the compiler crashed.

## Like you're five

A teacher has a box of crayons and makes a copy of it for every table, and each copy must work on
its own. This box sat right next to a friend's box and picked up the friend's sticky note: "to open
me you need the special key." When the teacher copied the crayon box, the note came along, but
nobody had a key to give it, so she got stuck. Now the note stays with the friend who really needs
the key, and the crayon box never keeps it.

## What goes wrong

`Minimal.roc`:

```roc
# A constant in a recursive binding group: `holder` reads `shown`, which
# reads `holder` back. The group's shared boundary generalizes `holder` (over
# its hole `_`), so it is a polymorphic constant, evaluated per closed
# instance. `shown`'s generated codec relation (`{ n : U64 }.Json.Encodable`)
# is copied where `holder` uses `shown`, and was captured as a requirement of
# `holder`'s scheme, which a read of a constant never supplies.

holder : { run : _, { n : U64 } -> Str }
holder = { run: |_context, input| shown(input) }

shown : { n : U64 } -> Str
shown = |input| {
	_ = holder
	Json.to_str(input)
}

expect (holder.run)({}, { n: 1 }) == "{\"n\":1}"
```

`Shapes.roc` (the new test, `test/cli/polymorphic_constant_in_recursive_group_codec.roc`) has the
shape rocx's push example met: `deliver : Job(_, Input)` calls `again`, which calls
`enqueue(deliver, { ..input, n: input.n + 1 })` where `enqueue` asks `where [i.Json.Encodable([])]`;
`deliver` read at `{}` and at `Str`; and a direct `Json.to_str` and a `Json.parse` case. Order
matters: with `shown` defined before `holder`, it doesn't show.

`repro.sh` runs five modes per file (boxy dev, boxy interpreter, `--specialize=yes` dev and
interpreter, boxy test units from a fresh cache):

- **rocx-fixes-4** (3943c21646, release): all pass.
- **upstream main bec95b9f4a, debug:** every `--specialize=no` run stops at "Boxy lowering invariant
  violated: a derived codec or map dictionary is resolved from a type alone, but checking records
  each with its plan at the dispatch it serves" (`callConstantWrapper` → `frameDictionary` → … →
  `dictionaryOfTree`); every `--specialize=yes` run at "postcheck invariant violated: composite
  scheme requirement had no checked call-site evidence".
- **upstream main, release:** the invariant is `unreachable`, so it varies: of 5 runs of
  `Minimal.roc`, boxy dev 4 pass and 1 segfaults (exit 139), test units 3 pass and 2 segfault;
  `Shapes.roc` happened to pass all 25 (undefined behaviour that didn't crash).
- **the fix, debug:** `Minimal.roc` and `Shapes.roc` pass in all 10 runs.

In rocx: `packages/push/example`'s server (`--opt=dev`), its Push module's constant
`deliver = Job.define_with(…)`. With rocx-fixes-5 and both fixes the app builds and its tests pass
9/9.

## Why it happens

Line numbers at upstream main bec95b9f4a.

1. `holder` and `shown` refer to each other: one recursive SCC.
2. `topLevelConstantGeneralizes` (`src/check/Check.zig:39848`, `return !…is_recursive` at :39855)
   rules recursive groups out, so `holder` is not a boundary of its own and `keepRequirementVarsWeak`
   never runs for it.
3. The group's shared frame generalizes every member anyway (`finishRecursiveGroupBoundary` :24826,
   `generalizeRank` :24853): `holder`'s hole becomes a generalized variable.
4. `beginDef` (:22952, `if (def_is_function or group_prechecked) try self.activateSchemeOwner(…)`)
   gives every recursive member a scheme owner, the constant included.
5. At `holder`'s use of `shown`, `shown`'s generated codec relation (`{ n : U64 }.Json.Encodable`)
   is copied as a candidate owned by `holder` (`recordSchemeRequirementCandidate`, :3191);
   `captureSchemeDispatchRequirements` (:49526) makes it an explicit requirement and
   `publishBindingSchemeCodecRequirement` (:49108) records it on `holder`'s definition.
6. `holder`'s entry-wrapper template gets an evidence parameter (`checked_artifact.zig` :15120,
   :15785, :14761), and literal-argument publication treats `holder` as a polymorphic constant.
7. Boxy calls the entry wrapper for each closed instance with one dictionary per parameter
   (`body.zig:5151`); a read of a constant carries no evidence, so the dictionary is derived from
   the type (:9093), which a derived codec can't be: the invariant at :8195. Monotype finds no
   call-site evidence either.

PR #13549: 26c2804ee4 made generalized top-level values polymorphic constants and enforced "a
polymorphic constant owns no requirement" only for a constant in a group of its own; b9aaefb7bb
evaluates each instance through the entry wrapper. On the nightly the group already generalized the
constant and gave it an owner, but a value was evaluated once, so nothing asked for the dictionary.

## The fix

`src/check/Check.zig`: the shape test moves out of `topLevelConstantGeneralizes` into a new
`isTopLevelConstant` (a value definition bound to one name that no platform requirement types), and
`beginDef` activates a scheme owner for a recursive-group member only when it isn't such a constant
(`def_is_function or (group_prechecked and !self.isTopLevelConstant(def_idx))`). A constant member's
body requirements, a member's codec relation copied at its use among them, belong where a weak
value's would, as for a constant in a group of its own. The group still generalizes the constant;
function and value-alias members keep their owners. `design.md`, "Polymorphic Constants", gets a
paragraph. Using the constant at a type without the method is still reported as "missing method".

## Checked

- The new test: at 9bfadefee4, 5 of 5 fail (3 at the boxy invariant, 2 at Monotype's); at
  5841b455dd, 5 pass.
- `run-test-cli -- --suite subcommands`: 2292 passed, 0 failed, 37 skipped. `run-test-zig-module-check`:
  2755/2755. `run-test-eval`: 2679 passed, 0 failed, 57 skipped. `run-check-snapshots`: clean.
- More probes pass in all four modes: a structural `where` requirement on the constant's generalized
  variable through an annotated member (with `to_str` and with `Json.Encodable`); number literals,
  `Str.inspect`, nested records with lists, and a constant read inside a generic function at two
  types.
- rocx, on rocx-fixes-5 + the sibling fix + this one: the push app builds (`--opt=dev`, with and
  without specializing), its tests 9/9; auth 20/20, guard 4/4, `packages/testing`'s build test 2/2,
  templates 29/29.

## Not this bug

`Unannotated.roc` (the same group with no annotation on the constant and no codec at all) still
crashes under `--specialize=no` ("boxy runtime invariant violated: adapted descriptors describe
different kinds of value"), with or without this fix, and passes on rocx-fixes-4: a separate
regression of the same PR (`recursive-constant-descriptor`).
