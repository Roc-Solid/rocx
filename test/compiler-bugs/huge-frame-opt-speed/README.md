# `--opt=speed` stack frames that grow with the page

**In one sentence:** under `--opt=speed` with lambda-set specialization, a procedure that builds a
page keeps a stack slot for every piece of markup it makes instead of reusing them, so a big page
needs megabytes of stack. Found 2026-11-23 on the fork (12.4 MB for the docs site), mostly
fixed at the pin 4674b5973d (248 KB), back on the pin bump's base c69cdc3fdf (2.86 MB), fixed again
by the fork's branch `fix-dispatcher-frame` (400 KB).

## Like you're five

Each time the computer makes a toy (a piece of a web page), it needs a spot on the floor to build
it before the toy goes into the box. It is supposed to write "done with this spot" so the next toy
can reuse it. The new version forgot to write that down for most toys, so every toy took a new
spot, and a big page needed a huge floor. Now it writes it down for every toy again, and the spots
get reused. A row of 160 toys that all have to sit on the floor at the same time still needs 160
spots, though.

## What goes wrong

rocx's servers are built `--specialize=no` (D-064), which this doesn't touch; a specialized build
(`--opt=speed`'s default, the browser's wasm, `ROCX_SPECIALIZE=yes`) is where it shows. The site's
server renders a page on an 8 MiB stack.

Largest frame of a Roc procedure, `--opt=speed`:

| Repro | 4674b5973d (pin) | c69cdc3fdf (the bump's base) | c69cdc3fdf + fix |
|---|---|---|---|
| `./repro.sh` (the default: `FANOUT=4 WIDE=96`, 4 × 120) | 41,744 B | **276,192 B** | 28,672 B |
| `./repro.sh 4 480` | 59,952 B | **1,088,368 B** | 38,304 B |
| `./repro.sh 4 960` | | **2,171,248 B** | 46,640 B |
| `FANOUT= ./repro.sh 10 120` (one list of 120) | | 279,536 B | 279,280 B |
| `FANOUT= WIDE=32 ./repro.sh 60 40` | 256,256 B | 32,000 B | 31,744 B |
| `FANOUT= WIDE= ./repro.sh 60 40` / `120 40` | 4,608 / 7,184 B | 3,104 / 3,104 B | 2,160 / 2,160 B |
| the docs site (`--specialize=yes`) | 248,304 B | **2,858,560 B** | 399,728 B |

Three separate effects show up:

1. **The regression on c69cdc3fdf, which the fix closes.** A procedure's frame becomes the sum of
   the slots of every `Html` value it builds, not the most it holds at once. In the site each
   `Html` value is 2,304 bytes: a 2.86 MB frame, 9 procedures over 1 MiB. `FANOUT` isolates it:
   items in a tree of short lists, so few values are alive at once.
2. **What is left after the fix: the widest list literal.** Every element of a list literal is
   computed before the list exists, so all of them need a slot at the same time, markers or not.
   The site's largest remaining frame (399,728 B) is a list literal of 161 `Html` values:
   161 × 2,304 = 371 KB. It grows with the widest markup list and with the size of `Html`, not
   with the number of closures.
3. **The old residual on 4674b5973d.** There the page views are inlined into one dispatcher whose
   frame is their sum, even with every slot marked (`WIDE=32`: 256 KB for 60 pages). On c69cdc3fdf
   each page view stays a procedure of its own. (This README's old numbers, 56 KiB at 60 × 40, are
   4.5 KiB on 4674b5973d now: the platform's `Html` changed.)

## Why it happens

**Which slots get lifetime markers.** On c69cdc3fdf, `src/backend/llvm/SlotLifetimes.zig` assumes
LLVM's SROA removes every slot whose address never escapes, so only slots whose addresses are
passed to calls get `llvm.lifetime.start`/`end` (upstream's d48d0123aa; `AddressedCallLocals` in
`MonoLlvmCodeGen.zig` returns nothing for `.assign_list`, `.assign_struct`, `.assign_tag` and the
other aggregate statements).

**Why that fails here.** `emitListLiteral` makes the list and then `memcpy`s each element's slot
into its buffer. The element's address reaches no call, so it gets no markers; SROA can't split a
slot a `memcpy` reads whole (here also written by a 2,264-byte padding `memset`), so the slot stays
alive for the whole call. Before optimization, the site's 2.86 MB procedure had 13,536 slots and
689 lifetime markers.

**How it got into the bump.** The fork's 4674b5973d marked every slot; the pin bump dropped that
commit as "the same as upstream's d48d0123aa", which it is not.

**Why `Html` is 2,304 bytes.** With specialization, a closure value is as big as the largest set of
values captured by any closure in its lambda set. `Html`'s payloads hold closures
(`TextOf(() => Str)`, `Component(() => Html)`, …), so one closure anywhere in the app that captures
a big record makes every `Html` value big. `WIDE=N` does that on purpose.

## The fix

Branch `fix-dispatcher-frame` in the fork (two commits on `rocx-fixes-3`: 8c283ce82d, a failing
test, "slots of aggregates copied into a list have bounded lifetimes"; af56927097, the fix) marks
the slot of every local that has one, as 4674b5973d did, with c69cdc3fdf's lifetime code. A dynamic
local's descriptor keeps its whole-call lifetime (the code generator reads it wherever it touches
the local), as do procedure arguments.

Checked: the site built with the fix answers all 67 parameterless GET routes byte for byte as the
unfixed build does; the LLVM backend's tests 41/41 (the new one fails without the fix); the eval
suite 2,679 passed, 0 failed, 57 skipped.

Not attempted, for what remains (effect 2): build a list literal's elements in place in its buffer
(LIR and ValuePlan); box large closure captures, so a closure inside `Html` costs a pointer; or have
the app's closures capture less.

## Running it

    ROC=…/roc ./repro.sh [PAGES ITEMS]

`gen.py` writes `Bad.roc`: a page as rocx's `Root` renders one (the route a memo of the path, a
layout given the page's meta as a getter, an `<Errored>` around a keyed part that makes one of
PAGES page components, each ITEMS list items with holes). `repro.sh` builds it with `--opt=speed`
(`OPTS=` for others) and prints the largest frame of a Roc procedure (`_roc__p…`) and of the whole
binary, read by `frames.py` from each function's prologue (arm64 macOS, `otool`). Settings:

- `PLATFORM=…/server/platform/main.roc`: the platform to build on (default: this repo's, which needs
  its host built). The platform must match the compiler: this repo's for 4674b5973d; the pin bump's
  (glue regenerated) for c69cdc3fdf and the fix.
- `WIDE=N` (default 96): each page also gets a hole whose closure captures a record of N strings,
  so every `Html` value is about N × 24 bytes. `WIDE=` for none.
- `FANOUT=K` (default 4): the items in a tree of lists of at most K instead of one list. `FANOUT=`
  for one list.
- `SHAPES=mixed`: six kinds of hole body instead of one (LLVM folds holes that differ only in their
  constants).
- `KEEP=1`: keep `Bad.roc` and the binaries in `./out`.
