# A closure default inside a generalized local function is lowered in the wrong evidence scope

Branch `fix-nested-site-evidence-scope`, two commits on `rocx-fixes-3` (c69cdc3fdf):

- 1fda3a7065 Add a failing test for a closure default inside a generalized local function
- d3c7b9ce86 Lower a field default in its owner's root evidence frame

Status: **fixed**. Upstream main (41b4f93fb0) has the same code, so the bug is there too.

## In one sentence

With lambda-set specialization (`--specialize=yes`, which `--opt=speed` uses by default and rocx
uses for the browser's wasm), building a record that leaves out a field whose default is a
closure, inside a local function that is generalized and captures something, makes Monotype lower
the default's closure in that local function's evidence scope instead of the root scope the closure
was checked in: a debug compiler stops at "root nested function site was lowered from a non-root
evidence scope", and release compilers (nightly-2026-11-18-a520eed, the fork at 4674b5973d and at
c69cdc3fdf) segfault **or build a wrong program**. The fix lowers every default in its owner's root
evidence frame.

## Like you're five

A teacher keeps a box of spare crayons that belongs to the whole class. A child sitting in the
small reading corner asks for one, and the teacher hands it over with a note saying "from the
reading corner's box". Later the class checks where every crayon came from, finds a class crayon
labelled as the reading corner's, and stops everything because the labels don't match. The fix: a
spare crayon is always labelled as coming from the class box, wherever the child who asked is
sitting.

## What goes wrong

`Bad.roc` (11 lines, no platform):

```roc
Opts := { suffix : (() -> Str) ?? (|| "!") }

shout = |s| {
	wrap = |_| {
		opts = Opts.{}
		Str.concat(s, (opts.suffix)())
	}
	wrap({})
}

expect shout("a") == "a!"
```

`wrap` captures `s`, so it stays a local function instead of being lifted to the top level. Its
argument is unused, so it is generalized, and with specialization its body is lowered inside its own
evidence scope. `Opts.{}` leaves out `suffix`, whose default is a closure.

The other files:

- `Foreign.roc` is the same with the nominal and its default in another module (`Labels.roc`): the
  shape the app hit, a component's props record from another module.
- `Number.roc` uses the default `(U8 -> U8) ?? (|n| n + 1)` and expects `"a5"`:

```roc
Opts := { f : (U8 -> U8) ?? (|n| n + 1) }

add = |s| {
	wrap = |_| {
		opts = Opts.{}
		Str.concat(s, (opts.f)(4).to_str())
	}
	wrap({})
}

expect add("a") == "a5"
```

- `Plain.roc` is `Bad.roc` with `wrap = || ...` (not generalized), and passes everywhere.

Also found while reducing: a `|{}|` argument generalizes too (a record pattern is open); an
annotated `wrap : {} -> Str` does not generalize; a local function that captures nothing is lifted
to the top level and doesn't hit the bug.

`repro.sh` runs each file's expect in four modes (`ROC=…/roc ./repro.sh`; `RUNS=n` repeats each):

```
$ ROC=<debug build of the fork at c69cdc3fdf> ./repro.sh
Roc compiler version debug-c69cdc3f
Bad.roc      --opt=size --specialize=yes  exit 134 panic: postcheck invariant violated: root nested function site was lowered from a non-root evidence scope (in post-check monotype)
Bad.roc      --opt=speed                  exit 134 panic: postcheck invariant violated: root nested function site was lowered from a non-root evidence scope (in post-check monotype)
Bad.roc      --opt=size --specialize=no   exit 0   All (1) tests passed
Bad.roc      --opt=dev                    exit 0   All (1) tests passed
Foreign.roc  (the same four results as Bad.roc)
Number.roc   (the same four results as Bad.roc)
Plain.roc    all four modes: exit 0   All (1) tests passed
```

Release compilers don't check invariants (`Common.invariant` is `unreachable` there), so they carry
on from a state the code assumes is impossible. All three release compilers (`rocx-fork-4674b5973d`,
`rocx-fork-c69cdc3fdf`, `nightly-2026-11-18-a520eed`) gave the same result on every run:

```
$ ROC=…/roc-fork/c69cdc3fdf…/bin/roc ./repro.sh
Roc compiler version rocx-fork-c69cdc3fdf
Bad.roc      --opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check monotype)
Bad.roc      --opt=speed                  exit 139 Segmentation fault (SIGSEGV) (in post-check monotype)
Bad.roc      --opt=size --specialize=no   exit 0   All (1) tests passed
Bad.roc      --opt=dev                    exit 0   All (1) tests passed
Foreign.roc  --opt=size --specialize=yes  exit 139 Segmentation fault (SIGSEGV) (in post-check monotype)
Foreign.roc  --opt=speed                  exit 139 Segmentation fault (SIGSEGV) (in post-check monotype)
Foreign.roc  --opt=size --specialize=no   exit 0   All (1) tests passed
Foreign.roc  --opt=dev                    exit 0   All (1) tests passed
Number.roc   --opt=size --specialize=yes  exit 1   1 failed (the program crashed: invalid numeric literal)
Number.roc   --opt=speed                  exit 1   1 failed (the program crashed: invalid numeric literal)
Number.roc   --opt=size --specialize=no   exit 0   All (1) tests passed
Number.roc   --opt=dev                    exit 0   All (1) tests passed
Plain.roc    all four modes: exit 0   All (1) tests passed
```

So a release compiler does build wrong code: `Number.roc` compiles, and the compiled program crashes
at run time with "invalid numeric literal" instead of returning `"a5"`. Other shapes come out right
by chance: on c69cdc3fdf, a default `|n| n` or `|n| Str.concat(n, "!")` builds and passes.

How it showed up: a large app's browser program, on a debug build of c69cdc3fdf, stopped at the
invariant with `--specialize=yes` (`--specialize=no` built; `roc check` found nothing). The
construction was a component call that left out a closure-defaulted prop (`|| NoCover`) of a
component in another module, inside a local function `|kind, _round| ...` whose second argument is
unused (so it is generalized) and which captures signals (so it stays local). The release c69cdc3fdf
built that program without a crash, so it may hold such wrong code.

## Why it happens

A record field default (`field : T ?? default`) is checked once, as a root of its own, then lowered
again at every construction that leaves the field out (design.md, "Defaulted Fields"). Line numbers
are at c69cdc3fdf.

1. **Checking records the closure at the root scope.** `src/check/checked_artifact.zig:18716-18719`
   scans each default for nested-function sites as its own root. `beginScan()` resets the lexical
   dispatch scope to `.root`, and `addSite` (`:19653`) records each closure's site with
   `lexical_scope = .root` and owner `.default_root`.
2. **The local function's body runs in its own scope.** `lowerDraftLocalProcAtNode`
   (`src/postcheck/monotype/lower.zig:47268-47269`) enters the local function's scope with
   `enterEvidenceScope`. Its body is lowered with `self.evidence` set to a `.generalized` frame whose
   parent is the owner's root frame.
3. **Materializing the default keeps that scope.** `defaultedFieldValueAtCell`
   (`lower.zig:51280-51346`) swaps the view (for a foreign default), the instantiation context, the
   binder environment and `in_default_expr`, because "the default is a closed expression: it binds
   nothing from the consuming body". It leaves `self.evidence` alone, so it is still the local
   function's generalized frame.
4. **The closure's site doesn't match.** The closure in the default goes through `stepNestedFn` →
   `evidenceForNestedSiteAtNode` (`lower.zig:52769`). Its site is `.root` but the current frame is
   `.generalized`, so the equality check at `:52806` fails. The site owns no scope of its own, so it
   reaches `.root => Common.invariant("root nested function site was lowered from a non-root
   evidence scope")` at `:52814`.

In a release build that invariant is `unreachable`. The optimizer may then assume the `orelse` never
runs and use whatever `owned_scope` holds as a dispatch-scope id, entering a scope the closure has
nothing to do with: the segfaults, and the wrong program for `Number.roc`, where the literal `1` is
resolved against the wrong evidence.

What passes: without specialization (Boxy) none of this code runs; a construction directly in the
owner's body passes, because `self.evidence` is already the root frame there; so does one in a local
function that isn't generalized, since that function has no scope of its own.

## The fix

In `src/postcheck/monotype/lower.zig`:

- **New `EvidenceChain.rootFrame()`.** It returns the chain's frame for its owner's root scope,
  found with `atScope(.{ .owner = self.scope.owner, .lexical = .root })`. Every chain starts at its
  owner's root frame, so not finding it is a compiler invariant.
- **`defaultedFieldValueAtCell` uses it.** It sets `self.evidence` to `self.evidence.rootFrame()` for
  the materialization, in both the same-module and the foreign branch, and restores the
  construction's frame afterwards.

Why this is right: the checker records the default's sites at the root lexical scope, and a default
constrains no type parameter (design.md: "chain-free ... with no enclosing template params"), so
nothing in it can read a generalized local function's evidence. Lowering in the owner's root frame is
exactly what already happens, and works, when the construction is in the owner's own body; that case
is unchanged, since `atScope` returns the same frame. The frame's owner stays the template that
recorded the materialization, which restoring a stored default closure relies on. There is a
precedent: restoring a local procedure declared in a default already resolves a default-root site
this way (`lower.zig:68094-68124`). design.md ("Defaulted Fields") says so in one more sentence.

## Checked

Debug compilers built from the branch.

- **New tests** (`test/cli/default_closure_in_generalized_local/{Main,Labels}.roc`, four entries in
  `src/cli/test/parallel_cli_runner.zig`): at 1fda3a7065, 1 passed and 3 failed (the three
  specialized runs, with the invariant); at d3c7b9ce86, 4 passed.
- **`repro.sh`:** all 16 runs pass on the fixed compiler (Bad, Foreign, Number, Plain × 4 modes).
- **Reduction scratch:** the 16 other shapes from the reduction all pass with the fix (same-module
  and foreign defaults; tag, Str, U8 and function defaults; closures inside the local function; two
  callers at different types).
- **The app's browser program**, `roc build --target=wasm32 --opt=size --specialize=yes --no-cache`:
  0 errors and 0 warnings, 2.69 MB, no invariant. Before the fix it stopped at the invariant.
- **Regression suites** at d3c7b9ce86: `run-test-cli -- --suite subcommands --suite echo` 3512
  passed, 37 skipped, 0 failed; `run-test-zig-module-postcheck` 614/615 (1 skipped);
  `run-test-eval` 2679 passed, 0 failed, 57 skipped.

## In rocx

rocx's components take props records with closure defaults (`kicker : (() => Str) ?? (|| "")`), so a
page that calls a component from inside a local function that captures a signal and has an unused
argument meets this. The browser's wasm is built `--specialize=yes` (D-064), so a release build can
come out wrong without a word; `--specialize=no` (the servers' default) is safe. Until the pin has
the fork's `fix-nested-site-evidence-scope`, annotate such a local function (an annotated one isn't
generalized) or give it no unused argument.

Run it with `ROC=…/roc ./repro.sh` (`just compiler-bugs` runs it on the nightly and the fork).
