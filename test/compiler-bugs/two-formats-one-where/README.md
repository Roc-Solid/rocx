# A where clause asking one type for two formats crashes the compiler instead of being reported

Branch `fix-two-formats-one-where`, two commits on `rocx-fixes-3` (c69cdc3fdf): 62b8561a13 (a
failing test), c5951754fd (the fix).

Status: **fixed** — the program is a type error (upstream says so on purpose:
`src/check/test/issue_12310_test.zig`, "an annotation requiring two formats' parser_for is one method
conflict"), and the compiler now reports it instead of crashing. rocx's workaround
(`Endpoint.local` / `local_json`) stays.

## In one sentence

A function whose where clause asks one type for two formats' parser is a type error, but the
compiler crashed in `boxy_lowering` instead of just reporting it: the checker reported the conflict
but left the annotation looking valid, so uses still type-checked, and test units lowered the
rejected function.

## Like you're five

You ask the toy shop for one car that is all red and all blue at the same time. The shopkeeper says
"that can't exist", but still puts your order on the shelf like a normal one. Later a helper picks
it up, tries to build it, gets confused and falls over. Now the shopkeeper stamps the order
"impossible", so nobody tries to use it, and the helper skips any order with that stamp.

## What goes wrong

`Formats.roc`:

```roc
## A where clause asking a type to be readable by two formats, whose aliases
## each require a `read` method of their own format. No type has two `read`
## methods, so checking rejects `both`'s annotation and retires `both`.
Formats := [].{
	Left := [L].{
		a.Readable : where [a.read : Left -> a]
	}

	Right := [R].{
		a.Readable : where [a.read : Right -> a]
	}

	both : {} -> a where [a.Left.Readable, a.Right.Readable]
	both = |{}| crash "never called"
}
```

`uses.roc`:

```roc
# Uses of a definition whose where clause asks for two formats' `read`
# (Formats.roc). `Thing` has the first format's `read`, so `thing`'s use
# would check against that requirement alone, and `forward` copies both
# requirements into its own where clause. `roc test` reports the rejection
# and runs the expect beside them.

import Formats

Thing := [T].{
	read : Formats.Left -> Thing
	read = |_| T
}

thing : Thing
thing = Formats.both({})

forward = |x| Formats.both(x)

expect 1 + 1 == 2
```

- On c69cdc3fdf, 4674b5973d and nightly a520eed, `roc check uses.roc`, `roc test --no-cache
  uses.roc` and `roc test uses.roc` all end with `Segmentation fault (SIGSEGV)`, exit 139.
- The original `Crash.roc` (a format of the module's own plus Json's) only crashes when the cache
  is on; with `--no-cache` it reports 2 errors and exits 1. (rocx's old repro ran `roc test` with
  the cache, which is why it always crashed.)
- A debug compiler stops with "Boxy lowering invariant violated: an erroneous checked type reached
  Boxy lowering" (`types.zig:1711`, reached from `templateScope` at `lower.zig:2017`).

## Why it happens

Line numbers are at the base.

1. `stepRigidAnnoGen` (`Check.zig:29811`) relates the annotation's repeated `read` requirement. It
   reports the conflict, keeps the first requirement (`unify.zig:404`) and poisons the second
   (`unify.zig:451`).
2. Nothing marks the annotation erroneous. `generateAnnotationType` only marks it
   (`Check.zig:26217`) if its type or where-clause signatures hold an error, and
   `whereSignaturesContainError` (`Check.zig:26223`) walks only the where clause's own nodes. A
   where alias's requirement is a copy that neither walk reaches.
3. So `defReference` (`Check.zig:39674`) treats uses as normal. `thing` type-checks against the
   first requirement, and `forward` copies both requirements.
4. Lowering then converts the erroneous requirement in `templateScope` and crashes.
5. Separately, `seedUnitWorkers` lowers every function in the module, using `templateRejected`
   (`lower.zig:5339`) to skip rejected ones. That check only looks at the function type, which is
   fine here, so the rejected function is still lowered. That is why `Crash.roc` crashes with the
   cache even with no use.

## The fix

- **Checker** (`Check.zig`): a failed requirement merge is recorded by where clause
  (`annotation_method_conflicts`, set in `stepRigidAnnoGen`). `generateAnnotationType` now marks
  such an annotation erroneous, the same way it treats an erroneous signature. Every use becomes
  erroneous through `defReference`, in this module and in importers, and `forward` no longer picks
  up the bad requirement. This reuses the existing "erroneous annotation" path.
- **Boxy** (`lower.zig`): `templateRejected` also checks each where-clause requirement's types
  (callable and dispatcher), which is exactly what `templateScope` lowers.
- **design.md**: a recovery rule, and the method-conflict paragraph extended.
- Both parts are needed: the checker part alone still crashes every cached run (14 of 18 cases);
  the boxy part alone still crashes when the function is used.
- `Crash.roc` now reports just the one real error; the follow-on "missing method" error at the use
  is gone.

## Checked

Debug builds only (they also check the compiler's internal assertions; the load average was 60–110,
so no release build).

- `repro.sh` on the fixed build: `uses.roc` reports the conflict and exits 1 under `roc check`;
  `roc test` with and without the cache reports it, runs the expect (`1 passed`) and exits 1.
  `Crash.roc` reports 1 error, `0 passed / 1 compiler errors`, exit 1, on both paths.
  `Workaround.roc` (rocx's) still passes.
- 18 scratch variants (same module, imported, generic forwarder, annotation only, the original
  direct form, the boundary form), each through check, `--no-cache` and the cache: 15 crash on the
  base; none crash with the fix.
- New CLI cases (default, boxy dev, boxy interpreter, boxy dev with test units): all 4 fail at
  62b8561a13 with the invariant, all 4 pass at c5951754fd.
- Full subcommands suite: 2,321 selected, 2,284 passed, 0 failed, 37 skipped.
- Filtered Zig unit tests: 425 of 426 passed (1 skipped), including 307 checker tests such as all
  8 issue-12310 tests. The only failure is the base's `compile` test binary
  (`src/compile/test/list_map_reuse_output_test.zig:35` doesn't compile on `rocx-fixes-3`).
- rocx's 20 platform modules with expects (1,793 expects) give identical results on base and fix;
  `roc check main.roc` is clean.

## In rocx

Found 2026-11-22 on rocx-fork-3f66e242ea while reading a form's body by its endpoint's types
(D-038): `Endpoint.respond!` reads JSON as well as forms, and a function whose where clause asked
for both (`where [a.FormBody.Readable, a.Json.Parseable([InvalidJson(Str)])]`) crashed the compiler.
Crash.roc is that, reduced; Formats.roc and uses.roc are the smallest form, with a use.

The workaround stays, since the program is a type error: the form reader is made where the arg's type is known, by `Endpoint.local`
(`where [arg.FormBody.Readable]`), and kept in the endpoint; `Endpoint.respond!` asks only for
`Json.Parseable` and calls the reader it is given. packages/mcp's `McpHttp`, generic in its tools'
args as JSON alone, makes its endpoints with `Endpoint.local_json`, which has no reader. The same
shape is why `McpHttp` takes `OpenApi.body` as a value (`McpHttp.openapi`) rather than calling it.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
