# A stored closure capturing a nominal type over a function-only variable crashes boxy

Branch `fix-endpoint-capture-boxy`, two commits on `rocx-fixes-3` (c69cdc3fdf): 596f1177a4 (a
failing test), 5b9a362920 (the fix). Status: **fixed**. Still crashes on c69cdc3fdf, and upstream
main (41b4f93fb0, 2026-11-26) has the same code.

## In one sentence

When a top-level constant holds a closure, made by a function with a where clause, that captures a
value like `Holder(a) :: { name : Str, read : Str -> a }` (where `a` appears only inside a function
field), every boxy run crashed restoring it: a saved type description that mentions `a` was taken
for one that has to be looked up in a table the reading code doesn't have.

## Like you're five

You label a lunchbox "a sandwich, any kind". Any kind is fine, because the box is the same size
whatever is inside. Your friend reads "any kind", thinks they have to go and look up which kind,
can't find the list, and gets stuck. The fix: a label you wrote yourself already says everything,
so nobody looks anything up.

## What goes wrong

`Capture.roc` (also the new test `test/cli/stored_fn_captures_nominal_over_fn_variable.roc`):

```roc
# A function value a top-level constant holds, made by a function with a
# where clause. Its closure captures `holder`, of a nominal type over the
# function's type variable `a` that only a function field mentions: the
# capture's representation is the same for every `a`, so the function that
# made the closure describes it statically, as `Holder(a)`.

Holder(a) :: { name : Str, read : Str -> a }

Rules := {}.{
	parse : Rules, Str -> Str
	parse = |_, text| Str.concat(text, "!")
}

reader : Holder(a), rules -> (Str -> a) where [rules.parse : rules, Str -> a]
reader = |holder, rules| |text| if text == "" crash holder.name else rules.parse(text)

rules : Rules
rules = {}

read : Str -> Str
read = reader({ name: "holder", read: |text| text }, rules)

expect read("a") == "a!"
```

- `roc check` finds no errors.
- On c69cdc3fdf, 4674b5973d and nightly a520eed, `roc test` with `--no-cache`, with
  `--specialize=no --opt=interpreter`, and with a fresh cache (test units) all segfault, exit 139.
  `--specialize=yes` passes.
- A debug compiler stops with "a worker without a type table read an input-dependent recipe"
  (`body.zig:1959`).
- All of these are needed to trigger it: the top-level constant, the where clause, the nominal
  type, and `a` appearing only inside a function field.
- This is rocx's case: `Endpoint.checked`'s reader capturing `endpoint` (whose `run` is a
  function). A copy of rocx's `server/platform` with the reader's crash message naming
  `endpoint.url` segfaults `roc test Endpoint.roc` on 4674b5973d and on c69cdc3fdf.

## Why it happens

1. `Holder(a)` is not "closed", because `isClosed` (`types.zig:1220`) counts nominal arguments. But
   its representation doesn't depend on `a`, because every function type is closed
   (`types.zig:1226`).
2. When `reader`'s closure is built, `descWord` (`body.zig:1729`) describes the capture statically,
   as `Holder(a)` with the variable still in it. That is correct.
3. The stored function value keeps that descriptor (`stored_fn.zig:520`). On restore it is decoded
   with `substitute_inputs = false` (`stored_fn.zig:1943`), meaning it substitutes nothing.
4. `readsInputs` (`body.zig:1931`) still treats any descriptor whose type isn't closed as reading
   the current function's inputs. So `staticClosure` (`body.zig:9838`) sends it to `slotLocal`, and
   the expect's body has no type table.
5. The table was never needed: the evaluator (`tables.zig:767`/`776`) evaluates such a descriptor
   as-is.

## The fix

In `body.zig`'s `readsInputs`:

```zig
.desc => |desc| if (desc.substitute_inputs and !self.program.store.isClosed(desc.ty)) break :walk true,
```

A stored descriptor is its producer's and reads none of the current function's inputs, so it is
evaluated where it is read, as the evaluator already does; any functions it carries are still
checked as before. Also updated: the `readsInputs` doc comment and design.md "Stored Function
Values".

## Checked

Debug builds only.

- `repro.sh` on the fixed build: all 4 runs report `All (1) tests passed`, exit 0.
- The platform copy (`roc test Endpoint.roc` with `endpoint.url` in the crash message): 188 expects
  pass, with `--no-cache` and with a fresh cache. Every intermediate reduction also passes.
- New CLI cases (default, boxy dev, boxy interpreter, boxy dev with test units): all 4 fail at
  596f1177a4 with the invariant, all 4 pass at 5b9a362920.
- Targeted filters (stored, captur, closure, constant, function value, boxy, compile-time,
  comptime): 572 run, 564 passed, 0 failed, 8 skipped.
- Full subcommands suite: 2,284 passed, 0 failed, 37 skipped.
- Filtered Zig unit tests: 405 of 409 passed (4 skipped), including the postcheck tests; the only
  failure is the base's `compile` test binary.
- rocx's 20 platform modules (1,793 expects) give identical results on base and fix.

## In rocx

`Endpoint.checked` (server/platform/Endpoint.roc) makes a reader that crashes on unwritable issues;
its message names no endpoint, because a reader capturing `endpoint` (a record whose `run` is a
function) crashed the compiler (found at 4674b5973d). The comment there can go, and the message can
name `endpoint.url`, once the pin has the fork's `fix-endpoint-capture-boxy`.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
