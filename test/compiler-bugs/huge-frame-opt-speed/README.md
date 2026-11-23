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

## Mostly fixed in the fork since 4674b5973d

The 12.4 MB was mostly slots no lifetime marker bounded. The LLVM backend marked only the slots of
locals whose addresses it passes to Roc procedures and RC helpers, and left those it passes to
builtin calls (a list literal's `roc_builtins_list_with_capacity`, `Str.concat` and so every
interpolation, `Num.to_str`, …): when LLVM doesn't inline the builtin, the slot's address escapes,
and without markers it holds its bytes for the whole activation, so a dispatcher holding every page
summed them. The fork (branch `rocx-fixes-2`: a failing test 0eb36c9c3b, the fix 4674b5973d) marks
the slot of every local that has one; upstream's open issue 13320 is the same mechanism with
interpolations. Largest frames of `--opt=speed` servers built specialized (`ROCX_SPECIALIZE=yes`),
at e6aec90, against D-064's numbers on 9fcf362c0c:

| App | 9fcf362c0c | 4674b5973d |
|---|---|---|
| the docs site | 12.4 MB (overflows) | 264 KiB (`just site` renders every page with it) |
| plate | 848 KiB | 164 KiB |
| journal | 372 KiB | 64 KiB |
| notes | 192 KiB | 152 KiB |
| quiz | 132 KiB | 40 KiB |
| board | 120 KiB | 32 KiB |
| uptime | 104 KiB | 40 KiB |
| tasks | 80 KiB | 36 KiB |

What's left still grows with the program, more slowly. Bad.roc above shows only that part: its
frames are the same on both (56 KiB at 60 pages of 40 items, 112 KiB at 120, 168 KiB at 60 of 120).
It is the dispatcher over a lambda set's closures (here one per hole, 2,400 of them): each closure's
inlined body keeps a slot of its own, about 24 bytes a closure, though each now has markers. In the
binary, 2,402 calls of `roc_builtins_int_to_str` write to 511 different places on the stack, so
LLVM's stack coloring shares those slots only in part. From the same bitcode (9fcf362c0c's, kept
with `--keep-temp`), LLVM 23's `opt -O3` and `llc` give that dispatcher a frame of 608 bytes; whether
it inlines less there or colors better, and so whether a newer LLVM in the compiler is the cure,
wasn't looked into.

## Workaround

rocx builds every app's `--opt=speed` server with `--specialize=no` (D-064: server/build.mjs's
`specializeFlags`, which `buildApp` and packages/testing's `buildForTests` use; `ROCX_SPECIALIZE=yes`
or `--specialize=yes` asks for specialization back). Since 4674b5973d a specialized build's frames
are far smaller (above) and the site renders, but they still grow with a lambda set's closures;
whether specialization is the default again is D-064's call. The wasm-split spike
(spike/wasm-split/REPORT.md) needs `--specialize=no` in the browser's build for the same reason.
