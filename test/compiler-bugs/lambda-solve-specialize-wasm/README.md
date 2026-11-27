# Lambda solving crashes when a function's closure is reached from two binding groups

## In one sentence

With lambda-set specialization on (`--specialize=yes`, which `--opt=speed` defaults to and rocx
uses for the browser's wasm), nightly-2026-11-18-a520eed and every rocx fork build on it (the pin
4674b5973d among them) crash in `post-check lambda_solve` on a 22-line, platform-free program, in
which a function wraps a function value in a closure and is called from closures in two different
top-level functions; upstream fixed it between a520eed and main of 2026-11-22, most likely in
7bcaed18f3, so the pin bump to c69cdc3fdf ends it.

## Like you're five

Two classes each get a coloring page, but by mistake both pages share one box of crayons. The
first class finishes and glues its crayons onto its picture to keep it. Then the second class takes
a crayon out of that same box, which pulls it off the first class's finished picture. When the
teacher checks the first picture at the end, it doesn't look like it should, and she gets so
confused she trips over. The fix is to give each class its own box.

## What goes wrong

`Bad.roc` is a type module with one expect; it needs no platform:

```roc
Bad := [].{
	keep = |pred| [].keep_if(|item| Bad.apply(pred, item))

	apply = |f, x| f(x)

	id = |x| x

	main = |{}| {
		pred = Str.is_empty
		first = Bad.id(|| Bad.keep(pred))
		Bad.view({ first, pred })
	}

	view = |{ first: _, pred }| Bad.ignore(|| Bad.keep(pred))

	ignore = |_| ""
}

expect Bad.main({}) == ""
```

`roc check` finds no problems, and the expect passes with `--opt=dev`, `--opt=interpreter` and
`--opt=size --specialize=no`. With specialization the compiler crashes before any code is made.
`repro.sh` runs each mode three times (`RUNS=n` to change), because a release compiler's crash
isn't the same from run to run:

```
$ ROC=…/roc-fork/4674b5973d…/bin/roc ./repro.sh
Roc compiler version rocx-fork-4674b5973d
--opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
--opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
--opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
--opt=speed                  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
--opt=speed                  exit 134 overflowed its stack (in post-check lambda_solve)
--opt=speed                  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
--opt=size --specialize=no   exit 0   All (1) tests passed
--opt=size --specialize=no   exit 0   All (1) tests passed
--opt=size --specialize=no   exit 0   All (1) tests passed
--opt=dev                    exit 0   All (1) tests passed
--opt=dev                    exit 0   All (1) tests passed
--opt=dev                    exit 0   All (1) tests passed

$ ROC=…/roc_nightly-…-2026-11-18-a520eed/roc ./repro.sh
Roc compiler version nightly-2026-11-18-a520eed
--opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check lambda_solve)
  … (as on 4674b5973d: the specialized runs crash, the other two modes pass)

$ ROC=…/roc-fork/c69cdc3fdf…/bin/roc ./repro.sh
Roc compiler version rocx-fork-c69cdc3fdf
--opt=size --specialize=yes  exit 0   All (1) tests passed
  … (all twelve runs pass)

$ ROC=<debug build of the fork at 4674b5973d> RUNS=1 ./repro.sh
Roc compiler version debug-428836d7
--opt=size --specialize=yes  exit 134 panic: postcheck invariant violated: a scheme node was not a class root (in post-check lambda_solve)
--opt=speed                  exit 134 panic: postcheck invariant violated: a scheme node was not a class root (in post-check lambda_solve)
--opt=size --specialize=no   exit 0   All (1) tests passed
--opt=dev                    exit 0   All (1) tests passed
```

Of 15 runs of `--opt=size --specialize=yes` on 4674b5973d, 13 segfaulted, 1 overflowed its stack
and 1 passed. The app it was found in mostly segfaults too, and at times stops with
`guarded list invalidated: monotype_lifted.Program.branches: span start=4452235472
len=5549568820 exceeds current_len=17235`; one step of the reduction stopped with the same panic
on `Program.expr_ids`. They are one bug; see below.

### How it showed up

A large app's browser program (309 files, about 49,000 lines) failed `roc build --target=wasm32
--opt=size --specialize=yes` in under 2 seconds; `--specialize=no` built it, and c69cdc3fdf built
it specialized in about 24 seconds. Reduced on the web platform, it is this, which still crashes on
4674b5973d and builds on c69cdc3fdf (rocx's `use_submissions!`, `create_memo!` and
`pending_inputs!` play `keep`, `id` and `apply`):

```roc
app [main!] { pf: platform "…/web/platform/main.roc" }

import pf.Html
import pf.Router exposing [use_submissions!]
import pf.Solid exposing [create_memo!]
import pf.Endpoint

main! : {} => Html
main! = |{}| {
	endpoint : Endpoint(_, Str, {})
	endpoint = Endpoint.remote("POST", "/move")
	sent = use_submissions!(endpoint)
	data! = create_memo!(|| sent.pending_inputs!())
	view!({ data!, sent: || sent })
}

view! = |{ data!: _, sent: sent! }| {
	moving! = || sent!().pending_inputs!()
	cell!(moving!)
}

cell! = |_| Html.empty({})
```

That is an ordinary page's shape: a memo of the submissions on their way, and a child component
given a getter of the same submissions.

## Why it happens

**What "guarded list invalidated" means.** The compiler keeps a program's parts in `GuardedList`s
(`src/collections/GuardedList.zig`): when a borrowed span or index no longer fits its list, the
access panics with "guarded list invalidated" instead of reading memory. The list here is the
lifted program's match branches (`monotype_lifted.Program.branches`), read while lambda solving
walks a `match` (`solve.zig`: `.match_ => … self.lifted.branchSpan(match.branches)`). The span's
start and length (4,452,235,472 and 5,549,568,820, against 17,235 rows) aren't a span at all, so
the list didn't grow under a borrow: what was read as a match expression wasn't one. The guard only
caught a read that was already wrong; the segfaults and the stack overflow are the same wrong state
ending elsewhere.

**Where it really goes wrong.** A debug build stops each time, earlier, at an invariant:

```
thread … panic: postcheck invariant violated: a scheme node was not a class root
src/postcheck/lambda_solved/solve.zig:1079:38: in substituteContent
src/postcheck/lambda_solved/solve.zig:1048:54: in instantiate
src/postcheck/lambda_solved/solve.zig:1020:42: in instantiation
src/postcheck/lambda_solved/solve.zig:1007:44: in referenceVarType
src/postcheck/lambda_solved/solve.zig:998:41: in referenceFnType
src/postcheck/lambda_solved/solve.zig:2548:84: in exprSlot
src/postcheck/lambda_solved/solve.zig:1928:45: in beginExpr
src/postcheck/lambda_solved/solve.zig:1951:39: in inferExpr
src/postcheck/lambda_solved/solve.zig:2531:44: in expectExpr
src/postcheck/lambda_solved/solve.zig:1746:40: in solveFn
src/postcheck/lambda_solved/solve.zig:895:56: in solveBodies
```

The app reduced to the page that matters (11 modules) stops there too, with the same stack. A
release build doesn't check invariants, so it goes on with a broken type store, and what happens
next depends on what that memory holds: a segfault, a stack overflow, the guard's panic, or now and
then a build that finishes. A specialized build of a program of this shape that "succeeds" on these
compilers can't be trusted either.

**Why the invariant breaks (as far as can be told; not bisected).** Lambda Solved solves the
program's binding groups one after another; when a group is done, its types are generalized into
schemes, and design.md's rule is that scheme nodes are never related again once their group
finishes. Each local has one type for the whole program. In `Bad.roc`, `keep` is given a known
function (`Str.is_empty`, through the local `pred`) and wraps it in a closure that captures it; it
is called from a closure in `main` and from a closure in `view`, which are different binding
groups. Specializing for the known function (SpecConstr) clones the closure, and on a520eed the
clone keeps its source's capture locals (`.captures = source_fn.captures`, three places in
`src/postcheck/monotype_lifted/spec_constr.zig`), so functions of two groups name one local. The
first group to finish generalizes that local's type into its scheme; the second unifies with it,
linking a scheme node; when the first group's function is referenced again (`referenceFnType`) and
its scheme instantiated, a node in it is no longer a class root. Upstream's notes on issue 13197
(`test/repros/issue-13197/README.md` in 7bcaed18f3, "Startup-placeholders: a separate cause") trace
the same invariant, on the same `expectExpr` → `beginExpr` → `inferExpr` path, to exactly this.

The reduction agrees: every part of `Bad.roc` is needed. The expect passes when `apply` is inlined
(`|item| pred(item)`), when `keep_if` is `map` or `any`, when `id` is left out (`first = || …`),
when `view` takes two arguments instead of a record, when `Str.is_empty` is written at both uses
instead of bound to `pred`, or when the `first` binding is inlined into the record.

## Status

Fixed upstream, so the pin bump to c69cdc3fdf (rocx-fixes-3 on nightly 890d6c8) ends it:

- It crashes on nightly a520eed and on every fork build on a520eed rocx has (3f66e242ea,
  3cf64982c7, 9fcf362c0c, 4674b5973d), release and debug.
- It passes on the fork's builds on 890d6c8 (c69cdc3fdf, 24e2e481a8), and on an existing debug
  build of upstream main at 9e28b549e3 (2026-11-22) with two fork commits on top (0f0b3311b4). So
  the fix is in a520eed..9e28b549e3.
- Most likely 7bcaed18f3, "Keep SpecConstr substitutions and lifted locals sound for lambda
  solving" (merged in #13227, 884836c475, 2026-11-19): it replaces those three
  `.captures = source_fn.captures` with copies of their own (`copySpecCaptures`), links in one
  binding group every two functions that name a common local, and has debug builds check that no
  local is shared across groups (`verifyGroupOwnedLocals`). The other candidate in the range is
  f89301db92, "Keep monomorphic callee slots out of caller lambda-set schemes" (#13253,
  2026-11-19). It isn't d95a4bfbdd ("Claim a binding group's function types when its solving
  begins"): the fork has it already (3cf64982c7) and crashes. Neither candidate was built alone.

Then rocx's fallback in `rocx-cli/Static.roc` (`browser_build!`: when the specialized browser build
crashes, build again with `--specialize=no`) can be reconsidered. Until the bump, note that
`compiler_crashed` looks for "in the Roc compiler", "Segmentation fault" or "panicked", and two
forms of this crash have none of them: the guard's panic ("Roc hit an internal compiler error …
thread … panic: guarded list invalidated …") and the stack overflow ("The Roc compiler overflowed
its stack memory and had to exit"). Those runs fail the build instead of falling back, and a run
that happens to finish ships a wasm built from a broken solve.

Not this bug, and still open on c69cdc3fdf: on a debug build, the whole app stops before lambda
solving, in `post-check monotype`, at `postcheck invariant violated: root nested function site was
lowered from a non-root evidence scope` (`evidenceForNestedSiteAtNode` ← `stepNestedFn` ← … ←
`defaultedFieldValueAtCell` ← `defaultedFieldValueFromDefaultAtCell` ← `finishConstructor`, in
`src/postcheck/monotype/lower.zig`). It does so on the fork at 4674b5973d and at db71ec7bd8
(c69cdc3fdf with two commits on top); a release build doesn't check it and goes on. Not reduced
yet.

## Checked

On the Mac (arm64), 2026-11-27, with the compilers in `.tools`:

- `ROC=<compiler> RUNS=3 ./repro.sh` on nightly-2026-11-18-a520eed and the fork's 3f66e242ea,
  3cf64982c7, 9fcf362c0c and 4674b5973d: 28 of the 30 specialized runs (`--opt=size
  --specialize=yes`, `--opt=speed`) crashed in `post-check lambda_solve` (2 passed: a release
  build's crash isn't certain); every `--opt=size --specialize=no` and `--opt=dev` run passed.
- The same on the fork's 24e2e481a8 and c69cdc3fdf: all twelve runs passed on each.
- 15 runs of `roc test --opt=size --specialize=yes --no-cache Bad.roc` on 4674b5973d: 13
  segfaults, 1 stack overflow, 1 pass.
- Existing debug builds, run as they were (none built for this): the fork at 4674b5973d and at
  17858b118e (on a520eed) stop at "a scheme node was not a class root" in both specialized modes;
  upstream main 9e28b549e3 with two fork commits (0f0b3311b4) and the fork at db71ec7bd8 (on
  890d6c8) pass.
- `roc check Bad.roc` on 4674b5973d: no errors; `roc test --opt=interpreter Bad.roc` passes.
- The app's browser program: `roc build --target=wasm32 --opt=size --specialize=yes` crashes on
  4674b5973d (a segfault, or the guard's panic) and builds on c69cdc3fdf (22 s); on debug builds of
  4674b5973d and db71ec7bd8 it stops at the monotype invariant above. The web-platform reduction
  above crashes on 3f66e242ea, 3cf64982c7, 9fcf362c0c and 4674b5973d, and builds on 24e2e481a8 and
  c69cdc3fdf.
- Upstream history: `git log a520eeda6c..890d6c8222 -- src/postcheck`, the candidates' diffs and
  notes, and `git show <commit>:<file>` for which trees have `verifyGroupOwnedLocals`,
  `prepareGroupSignatures` and `.captures = source_fn.captures`.
