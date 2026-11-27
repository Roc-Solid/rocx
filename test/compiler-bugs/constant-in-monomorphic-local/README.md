# A polymorphic constant read in a local over its enclosing function's variable crashes boxy

Branch `fix-boxy-regression-main`, two commits on upstream main (bec95b9f4a): ccc4f20833 (a failing
test), c426908af4 (the fix). Status: **fixed**. Both commits cherry-pick cleanly onto `rocx-fixes-5`
(they are 70366091ac and 45baebbcff there). Introduced upstream by PR #13549 (b9aaefb7bb); it is on
upstream's main, not on the nightly 890d6c8.

## In one sentence

A local function whose type mentions only its enclosing function's type variable, and which reads a
polymorphic constant at that variable, has its uses skipped by the literal-argument pass, so the
constant's instance never reaches the enclosing function and boxy lowers a call of the local with no
argument for it: a release compiler segfaults in `boxy_lowering`.

## Like you're five

In a relay race each runner hands a baton to the next one. One rule says a runner who didn't start a
new lap has nothing to pass on. A runner in the middle only carries the baton he was handed, so he
decides he started nothing and keeps it. The last runner reaches back, grabs air, and the race
stops. The fix: a runner carrying someone else's baton always passes it on.

## What goes wrong

`Local.roc`:

```roc
# A polymorphic constant (`holder`, a record holding a function: its type
# `{ run : a -> a }` is generalized) read inside a local function whose type
# mentions only its enclosing function's variable: `inner : t -> List(t)`,
# where `t` is `outer`'s. `inner` generalizes nothing of its own, so
# checking records no instantiation at `inner(other)`; the instance of
# `holder` it reads at `t` has to reach `outer`, and through it the expect,
# which fixes `t` to `Str`.

holder = { run: |x| x }

outer = |other| {
	inner = |x| [other, (holder.run)(x)]
	inner(other)
}

expect outer("a") == ["a", "a"]
```

`Shapes.roc` (the new test, `test/cli/polymorphic_constant_read_in_monomorphic_local.roc`) has the
same read in a local that is called, passed as a function value (`[other].map(inner)`), and called
from another such local; its 4 expects use `holder` at `Str`, `U8` and `I64`.

`repro.sh` runs each file 5 ways: the default, `--specialize=no --opt=dev`, `--specialize=no
--opt=interpreter`, `--specialize=yes`, and test units from a fresh cache.

- **rocx-fixes-4** (3943c21646, the nightly 890d6c8 + fixes): `Local.roc` passes all 5 runs.
  `Shapes.roc` is a type mismatch there: before #13549 `holder` is a weak constant and can't be read
  at three types.
- **upstream main bec95b9f4a (release):** the 4 boxy runs of each file exit 139, "Segmentation fault
  (SIGSEGV)", in post-check `boxy_lowering`; `--specialize=yes` passes.
- **upstream main bec95b9f4a (debug):** the boxy runs stop with "Boxy lowering invariant violated: an
  edge's 0 literal arguments do not cover its callee's 1 literal requirements (caller outer, callee
  a local procedure)"; `--specialize=yes` stops in Monotype with "postcheck invariant violated: a
  read of polymorphic constant root 0 names no instance (edge use)".
- **rocx-fixes-5** (a1714c98de, release): the same as upstream main.
- **the fix** (debug builds of upstream main + fix, and of rocx-fixes-5 + fix): all 10 runs pass.

In rocx it was `test/static/app` (`roc build --target=arm64mac --opt=dev`): the constant is
`routes/account/+middleware.roc`'s `middleware = Middleware.make(|request, context, next!|
next!(request, context))`, read by `Routes.respond!`, which is called inside `App.program`'s local
`route! = |routed, context| Plugin.respond!(config.plugins, routed, context, |answered, handed|
Routes.respond!(answered, handed))`, whose context type is `program`'s own variable. The same crash
stopped `packages/auth/example`, `packages/guard/example`, `packages/testing`'s build test and the
template's stories app.

## Why it happens

1. Since PR #13549 (stored-images-and-poly-constants), a top-level constant generalizes over the
   variables that carry no requirement (26c2804ee4).
2. Each read of such a constant is a literal requirement (`constant_instance`) of the constant's
   entry wrapper, and an open read is forwarded like an open literal, through the schemes around
   it, up to the use that closes the type (b9aaefb7bb; `src/check/checked_artifact.zig:22895`).
3. `inner` generalizes nothing of its own (`x`'s type is `other`'s), but its dispatch scope's
   `scheme_vars` are every generalized variable its type mentions (`publishScheme` /
   `appendSchemeVars`, checked_artifact.zig:14792), `other`'s, which `outer` generalized, among them.
4. The read of `holder` inside `inner` is an edge in `inner`'s scope; `literalRequirementVariableIsBound`
   (checked_artifact.zig:22553) finds its variable in that list, so the instance is forwarded into
   `inner`'s scope as `inner`'s literal requirement (checked_artifact.zig:23812).
5. Checking records no instantiation at `inner(other)`: a monomorphic local's use has no
   `SchemeUseRecord`, and the evidence pass publishes the identity substitution only when the scope
   has evidence parameters (`if (params.len == 0) return;`, checked_artifact.zig:17757). Before
   #13549 that never mattered: a literal forwarded on an enclosing variable always carried a
   `from_numeral` requirement, so the scope had a parameter and a substitution.
6. The literal-argument fixpoint skips every edge with `callee.vars.len != 0 and edge.subst.len ==
   0` (checked_artifact.zig:23726–23728, from 998fd9f820, 2026-10-30), so every use of `inner` gets
   no literal arguments, `outer` never requires the instance, and no instance at `Str` is made.
7. Boxy: `lowerGeneralizedLocalCall` (body.zig:6807) fills `inner`'s one literal word from the use
   edge's empty arguments, the invariant at body.zig:4761 (a release build reads past it and
   segfaults). Monotype: `restoredConstantInstance` finds no instance (monotype/lower.zig:49071).

## The fix

c426908af4, "Instantiate a monomorphic local's literal requirements at its uses":

- `src/check/checked_artifact.zig`: an edge with no recorded substitution is still skipped, except
  when its callee is a generalized local scope and every variable of that scope is quantified by a
  scheme around the use (new `literalRequirementVariablesAreBound`). Such a use shares those
  variables, so the edge instantiates the scope's literal requirements as they are, and the instance
  is forwarded to the enclosing scheme like any other open requirement:

  ```zig
  if (callee.vars.len != 0 and edge.subst.len == 0 and
      !(edge.callee == .scope and literalRequirementVariablesAreBound(store, templates, edge.scope, callee.vars))) continue;
  ```

- `src/postcheck/boxy/body.zig` `enterLocalScopeFrame`: when a literal chain enters a local scope at
  a site with no recorded substitution, the frame reads the scope's variables from the environment
  it is entered in (the enclosing frame's) instead of substituting them:

  ```zig
  const vars: []const checked.CheckedTypeId = if (subst.len == 0) &.{} else scheme.scheme_vars;
  ```

- `design.md`, "Literal Arguments": one paragraph on such uses.

A use of a local that generalizes variables of its own, and every edge with a recorded
substitution, are unchanged.

## Checked

Debug builds; Zig 0.17.1 with a private cache.

- **The new test** (`test/cli/polymorphic_constant_read_in_monomorphic_local.roc`, 5 `subcommands`
  cases: boxy dev, boxy interpreter, boxy dev with test units, `--specialize=yes` dev and
  interpreter): before the fix all 5 fail (the 3 boxy runs at the `fillLiteralArgs` invariant, the 2
  specialized at Monotype's "names no instance"); at c426908af4 all 5 pass.
- **`run-test-zig-module-check`:** 2755/2755. **`run-test-eval`:** 2679 passed, 0 failed, 57 skipped
  (the same as the base). **`run-test-cli -- --suite subcommands`:** 2292 passed, 0 failed, 37
  skipped (with the 5 new). **`run-check-snapshots`:** no tracked snapshot changed. **`zig fmt
  --check`:** clean.
- **More shapes, all passing with the fix** (upstream main segfaults on their file): a monomorphic
  local inside a generic local used at `Str` and `U8`; a local alias (`f = inner`); a recursive
  local; a local stored in a record field and called through it; a local called beside a direct read
  of the constant.
- **rocx:** `test/static/app` builds with `--opt=dev`, `--opt=interpreter` and `--specialize=yes` on
  upstream main + fix and on rocx-fixes-5 + fix; with rocx-fixes-5 + fix, `test/static.test.mjs` 6/6,
  `packages/auth/example` 20/20, `packages/guard/example` 4/4, `packages/testing/test/build.test.mjs`
  2/2, `templates/test/template.test.mjs` 29/29.

## Not this bug

Two other crashes from the same PR stay, and crash the same way on unfixed upstream main:
`packages/push/example` ("a derived codec or map dictionary is resolved from a type alone…", while
computing the Push module's polymorphic constant `deliver = Job.define_with(…)`), and
`packages/testing`'s app ("an edge's 0 literal arguments do not cover its callee's 2 literal
requirements (caller actor_for_host!, callee a template of an imported module)").
