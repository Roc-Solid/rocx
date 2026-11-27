# A closure checked against `() => T` defaults the number it reads to `Dec`

Found 2026-11-27 on rocx-fork-4674b5973d (the rocx pin), and the same on
nightly-2026-11-18-a520eed, nightly-2026-11-20-3b29392 and the fork's builds on nightly 890d6c8
(c69cdc3fdf, 24e2e481a8). An app's error page (`routes/+error.rocx`) wrote
`kicker={"Error ${status.to_str()}"}` into a component whose props are getters (a `view!`
component, so rocx types each prop `() => T`). Its release build failed at Generated/Root.roc:
the error page took `{ status : () -> Dec }`, and Root hands it a `U16`.

In simple terms: when a closure is passed where an effectful function (`() => T`) is expected,
and it calls a method on a number it captured from outside, Roc decides that number is a `Dec`
instead of leaving it generic. A caller with another number type gets a type mismatch. Checked
against a pure function (`() -> T`), the same code is generic.

Reduced: ErrorPage.roc has a page whose prop is `() => Str` (`page!`) and one whose prop is
`() -> Str` (`pure_page`), and three error pages that compare `status` with `404` and show it.
`view!` calls `to_str` inside the getter it gives `page!`; `pure_view` does the same with
`pure_page`; `hoisted_view!` calls `to_str` in its body and gives `page!` a getter holding the
`Str`. Each is called with a `U16` from a module of its own: a caller in ErrorPage.roc fixes the
number's type before it is defaulted, and passes. The record pattern and the `!` names play no
part: `|{ status }|` or `|props|` with `(props.status)()` fail the same.

    ./repro.sh

    == roc check Bad.roc
    ── ✗ type mismatch ──────────────────────────────────────────────── Bad.roc:6:33
        { status: () -> U16 }
        { status: () -> Dec }
    ── 1 error and 0 warnings ────────────────────────────────────────────── Bad.roc
    exit 1
    == roc check Pure.roc
    No errors found in 25ms for Pure.roc
    exit 0
    == roc check Hoisted.roc
    No errors found in 7ms for Hoisted.roc
    exit 0

`rocx check` didn't see it: it checks the dev build, where each getter a body reads is written
`Html.read_at!("…", status!)` (D-052), and with that the number stays generic. Only the release
build (`rocx build`, `--image`), which reads `status!()`, failed.

Workaround in the app: call `to_str` in the page's body (`code = status.to_str()`) and use `code`
in the attribute, as `hoisted_view!` does. An error page's status doesn't change, so reading it
once costs nothing.
