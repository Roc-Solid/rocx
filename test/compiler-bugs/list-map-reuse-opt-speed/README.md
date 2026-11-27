# `List.map` writes past its items under `--opt=speed` when their closures' captures come from elsewhere

**In one sentence:** Under `--opt=speed`, `List.map` checked whether its new items fit in the old ones' places using the wrong item, then wrote bigger items over their neighbours.

## Like you're five

You have a row of small cups and want to turn each drink into a new one. To save washing up,
you pour each new drink back into its old cup, but only when it fits. The compiler measured a
practice drink that was never poured instead of the real one, decided the drinks were small
enough, and poured big drinks into small cups. They spilled into the next cups and off the end of
the table: the program wrote over memory that wasn't its own and crashed.

## Details

Found 2026-11-22 on the fork rocx builds with (3f66e242ea), with the docs site's page for each example
app (site/Ui/ExampleApp.rocx): built with `--opt=speed`, the site's server crashed on `/examples/plate`
and `/examples/quiz`, in the host's allocator (a page's ring of buffers, a free list walked through a
pointer the program had overwritten). `--opt=dev` was right, and so was `--specialize=no`. The page
filtered the screenshots `AppNotes` names by those there are and mapped them to `Html`; the forms
package's page, elsewhere in the site, puts capturing closures in the same `Html` type.

**Bad.roc** is it reduced: rows of a string and a number, mapped by a function that makes a cell of
text and no closure, into a tag union whose other tag holds a closure; elsewhere, the program puts a
button whose closure captures a string (the request's path) in the same list of cells.

    ROC=…/roc ./repro.sh

    Bad --opt=dev   -> beta; gamma; delta; path: pressed /
    Bad --opt=speed -> crashed (exit 139)

The same on upstream main (9e28b549e3, 2026-11-22).

## Why

`List.map` writes its output into its input's allocation when the input list is unique and an output
item fits an input item's slot. Whether it fits is decided while the program is compiled, from the
output item's type, which the check read from the map's transform. With `--opt=speed`, the compiler
specializes `List.map` for a known transform and rebuilds the transform at each place it's used, each
its own instance. The instance the check reads is never called, so nothing flows into its result: it
describes a cell without the button's captured string. That cell is exactly a row's size (32 bytes),
so the check allowed the in-place branch, and each real cell (56 bytes, with the capture) was written
over the next row and past the end of the allocation.

## The fix

In the fork, branch `rocx-list-map-reuse` (the pin), and for upstream `fix-list-map-reuse-output-main`
(a failing test, then the fix): `List.map` passes an empty output list to the check and to the retype
of its buffer, for its type alone, so the check reads the item the map really writes. The pin also
takes upstream's fix of the same mistake on the input side (ae32726512), which it lacked: most likely
what fixes `two-guarded-routes-opt-speed`.
