# `--opt=speed` inlines every closure of a lambda set into one function, and its stack frame grows with the program

Found 2026-11-23 on the fork rocx builds with (9fcf362c0c), with the docs site and D-040's route
levels (branch nav-phase2): built with `--opt=speed`, the site's server overflowed the 8 MiB stack a
render runs on (D-027's coroutines), on every page, before it wrote a byte (`rocx server: a call into
Roc overflowed its stack (8 MiB)`). `--opt=dev` was fine, and so was `--specialize=no`.

It isn't recursion. Under lldb the fault is in a function's prologue, in its stack probe
(`sub x9, sp, #0xc17, lsl #12`, then a loop touching each page): a frame of 12.4 MB. Six functions
had it, specializations of the platform's `Html.serialize!` (Html.roc's lines 446 to 457, about
3.8 MB of code each). Their DWARF inline records show what is in them: the site's pages' code,
whole (the Markdown parser, packages/intl's message, plural and date formatting, every page's
view), inlined through the closures `Html`'s holes and components hold (`() => Html`, the boxes
`keep!` makes). With lambda-set specialization each closure field's lambda set is every closure
stored there in the program, and a call through it is a switch over all of them, each case the
closure's body, inlined (each has one caller). The cases' stack slots aren't shared, so the frame is
roughly the sum of everything reachable.

**The numbers (largest frame, 4 KiB pages):**

| Build of the docs site (server) | `--opt=dev` | `--opt=speed` | `--opt=speed --specialize=no` |
|---|---|---|---|
| master (fe4651f) | 2 | 350 (1.4 MB) | 7 (28 KB) |
| with route levels (nav-phase2) | 2 | 3095 (12.4 MB), six functions | 7 (28 KB) |
| … with `meta` in a memo | | 3095, one function | |
| … with the levels as `Html.html_of` | | 3133, one function | |

The route levels add closures to `Html`'s lambda sets (each level's case and maker, the layout's
`meta` getter) and multiply the copies; whatever shape `Root` has, one dispatcher holding every page
remains, past the stack. Render time is the same either way (the site's 50 pages, a round, 8 rounds:
386 and 393 ms specialized, 386 and 367 ms boxy on master; 376 and 369 ms boxy with levels).

**Bad.roc** (written by gen.py) is the shape reduced: a page as rocx's `Root` renders one, a memo of
the path, a layout given the page's `meta` as a getter, an `<Errored>` around a keyed part
(`Html.switched`) that makes one of PAGES components of ITEMS list items with holes. The frame
grows with the program under `--opt=speed` and not under `--opt=dev`, but at sizes that build in
minutes it stays far from 8 MiB (what the site inlines is page logic, not just markup):

    ROC=…/roc ./repro.sh 20 40      Bad --opt=dev -> 8 KiB      Bad --opt=speed -> 8 KiB
    ROC=…/roc ./repro.sh 60 40      Bad --opt=dev -> 8 KiB      Bad --opt=speed -> 56 KiB
    ROC=…/roc ./repro.sh 60 120     Bad --opt=dev -> 8 KiB      Bad --opt=speed -> 168 KiB

The case that overflows is the site at nav-phase2 before the workaround: `rocx site prepare`, then
`roc build --opt=speed site/main.roc`, run it, `GET /`.

## Workaround

rocx builds every app's `--opt=speed` server with `--specialize=no` (D-064: server/build.mjs's
`specializeFlags`, which `buildApp` and packages/testing's `buildForTests` use; `ROCX_SPECIALIZE=yes`
or `--specialize=yes` asks for specialization back). Any large app built specialized can meet the
same growth; the cure is in the compiler: share the stack slots of a switch's cases (lifetime markers on the
allocas), or keep closure bodies out of line past a size. The wasm-split spike
(spike/wasm-split/REPORT.md) needs `--specialize=no` in the browser's build for the same reason.
