# A constant read in a value a platform requirement types is never given its instance

Branch `fix-imported-literal-requirements`, two commits on upstream main (bec95b9f4a): 0341bb1761
(a failing test), 4f00cb51b4 (the fix). In `rocx-fixes-5` as 0cb3f00b40 and b466d2255a. Status:
**fixed**. Introduced upstream by PR #13549 (26c2804ee4, b9aaefb7bb); not on the nightly 890d6c8.

## In one sentence

An app value that a platform requirement types (`main`, rocx's `program`) is never generalized, and
since polymorphic constants landed (PR #13549) a polymorphic constant it reads at a type variable
its type keeps was forwarded as a literal requirement to its entry procedure, which nothing ever
supplies, so Boxy crashed lowering the platform's read of that value.

## Like you're five

There is one big toy box that the shop owner opens. Inside, the box makes a ball using a shared
ball machine, but the machine wants to be told what kind of ball to make. The rule said the person
who opens the box must say which kind, but the shop owner never says anything when opening it. So
the machine waited for an answer that never came, and everything fell over. Now the box picks the
plain ball by itself, because nobody will ever tell it anything else.

## What goes wrong

`platform/main.roc` (with a `targets:` block that builds an archive for every target, so no host is
needed):

```roc
platform ""
    requires {
        [Model : model] for main : { init : {} -> model, read : model -> U64 }
    }
    exposes []
    packages {}
    provides { "init": init_for_host, "read": read_for_host }
    targets: {
        x64glibc: { inputs: [app], output: Archive },
        arm64glibc: { inputs: [app], output: Archive },
        x64musl: { inputs: [app], output: Archive },
        arm64musl: { inputs: [app], output: Archive },
        x64mac: { inputs: [app], output: Archive },
        arm64mac: { inputs: [app], output: Archive },
        x64win: { inputs: [app], output: Archive },
        arm64win: { inputs: [app], output: Archive },
        x64mingw: { inputs: [app], output: Archive },
        arm64mingw: { inputs: [app], output: Archive },
    }

init_for_host : {} -> Box(Model)
init_for_host = |{}| Box.box((main.init)({}))

read_for_host : Box(Model) -> U64
read_for_host = |model| (main.read)(Box.unbox(model))
```

`app.roc`:

```roc
app [main] { pf: platform "platform/main.roc" }

# A polymorphic constant: the type of its items generalizes.
empty = []

# A platform requirement types `main`, so `main` is a weak value, never
# generalized. Its Model, `{ seen : List(a) }`, keeps an item type
# nothing fixes, and `init` reads `empty` at it.
main = {
    init: |{}| { seen: empty },
    read: |model| model.seen.len(),
}
```

`repro.sh` builds it five ways: `--opt=dev`; `--opt=dev --specialize=no`; `--opt=interpreter
--specialize=no`; `--opt=dev --specialize=yes`; `--specialize=no` with a fresh cache.

- **rocx-fixes-4** (3943c21646): all five pass.
- **upstream main bec95b9f4a, release:** the four boxy runs exit 139, "Segmentation fault (in
  post-check boxy_lowering)"; `--specialize=yes` builds.
- **upstream main, debug:** the four boxy runs stop at "Boxy lowering invariant violated: an edge's 0
  literal arguments do not cover its callee's 1 literal requirements (caller read_for_host, callee a
  template of an imported module)".
- **rocx-fixes-5 a1714c98de, release:** as upstream's release.
- **the fix** (debug, on upstream main and on rocx-fixes-5 with the sibling fixes): all five pass.

In rocx it was `packages/testing`'s app: `program = App.program({ init!: |started| Ok({ started:
started }), plugins: [Job.plugin({ jobs: App.jobs })] })` reads the polymorphic constant
`App.jobs : List(Job.Handler(_))` at the app context's type, whose record literal leaves a tail
variable the weak `program` keeps ("… 2 literal requirements (caller actor_for_host!, …)").

## Why it happens

- `src/check/checked_artifact.zig:22928` (`publishLiteralArgumentRoots`): a binding whose solved rank
  isn't `generalized` is only skipped as a polymorphic constant; its entry procedure still lists
  every variable its type keeps as scheme variables (`templateEvidenceSchemeVar` /
  `appendSchemeVars`).
- `:22567` (`literalRequirementVariableIsBound`) counts those variables as quantified, so at `:23754`
  a requirement reached inside the value at one of them (a constant read inside a function the value
  holds, among them) is classified `.open` and forwarded to the entry procedure's requirements.
- Nothing supplies it: a read of a weak value has no recorded substitution, so it is skipped
  (`:23728`); the platform's read of a required constant records no edge (`:23337`,
  `templateOfValueRef` is null for `.platform_required_const`); requirement edges are made only for
  function requirements (`:23564`).
- Boxy's `restoreConstUse` (`src/postcheck/boxy/body.zig:7078`) calls the entry procedure with edge
  `.use`, 0 arguments; `fillLiteralArgs` (`body.zig:4761`) hits the invariant (a release compiler
  segfaults).
- PR #13549: 26c2804ee4 made top-level constants generalize (`empty`, `App.jobs` are polymorphic);
  b9aaefb7bb made each constant read a `constant_instance` requirement forwarded through schemes.
  Before that, the only open literal requirements were numbers and strings, whose variables carry
  requirements and are defaulted by the module's end.

## The fix

- `checked_artifact.zig`: `publishLiteralArgumentRoots` marks the entry procedures of the module's
  weak values (constant or callable bindings whose rank isn't `generalized`; aliases and valueless
  bindings excluded). At an edge inside such a value, the new `literalRequirementInstanceKeeping`
  treats that procedure's scheme variables as quantified by no scheme, even where a generalized
  local scope over one of them lists it, so a requirement at one of them is decided where it is
  reached, with a root at the sealed type, as at a scheme that binds none, and is never forwarded.
  Generalized bindings are unchanged.
- `boxy/body.zig` (`readConstantInstance`): Boxy still lowers the weak value's entry procedure over
  its variables, so its body may read such a root at an open type; it restores the stored value
  directly only at a closed type, and otherwise reads it through the root's thunk, as a forwarded
  instance is read.
- `design.md`, "Polymorphic Constants": a paragraph.
- Test: `test/int/weak_model_constant.roc` on the test/int host, a weak Model reading `empty` and a
  record constant whose tag payload is a kept variable, directly in `main` and in the functions it
  holds; 4 runner cases (dev and interpreter, each specialized and not).

## Checked

- The new test: 0/4 at 0341bb1761 (boxy "0 … do not cover … 2 literal requirements"; Monotype "a
  read of polymorphic constant root 1 names no instance"); 4/4 at the fix.
- `run-test-zig-module-check` 2755/2755; `run-check-snapshots` 72/72 steps; `run-test-eval` 2679
  passed, 0 failed, 57 skipped; `run-test-cli -- --suite subcommands` 2291 passed, 0 failed, 37
  skipped; test wiring, tidy and zig format clean.
- On rocx-fixes-5 with the sibling fixes and this one (debug): `repro.sh` all five pass; the new test
  4/4; the sibling fixes' tests 4/4 each; the testing app builds; rocx's `packages/testing` tests
  28 passed, 0 failed, 3 skipped (no DATABASE_URL), hydration in Chromium and Gecko included.

## Still open, separate

With `--specialize=yes`, a debug compiler still stops in Monotype ("a read of polymorphic constant
root 0 names no instance (edge use)") on a shape that needs both a constant read inside a function
the value holds and a platform that passes the app's model unboxed across the host boundary. Real
platforms box it (`Box(Model)`, as rocx's server platform does with its context), and there it
passes; rocx's servers are boxy anyway.
