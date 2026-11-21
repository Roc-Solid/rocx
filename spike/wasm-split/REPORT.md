# PARKED (2026-11-21, the user's call): wasm splitting by page

Nothing landed. The design and a working loader are kept here as the starting point.

**Where the work is:** here. `parked/` has the changed files, whole: src/split.mjs (new), src/routes.mjs,
bin/rocx.mjs, web/runtime.js, web/start.js, site/build.mjs, site/test/site.test.mjs, Justfile.
They are based on the tree of 2026-11-21 ~19:50, so rebase them onto master before use (diff each
against the same file at the repo's root). `scripts/` holds the analysis experiments; they still
name the investigation's working copy, /tmp/rocx-split (see scripts/README.md). The measurements
below were taken there.

**What a future pickup needs, in order:**
1. **A compiler change in the fork (the better path):** Roc's wasm linker (src/cli/wasm_link.zig,
   composition in writeSealedWasmObject → linkWasmObjectsRelocatable) keeps the relocations it
   resolves while composing, like wasm-ld's --emit-relocs, plus a reference for static data the
   runtime finds by itself. With exact references, moving data becomes safe as well, and the ~90 KB
   main is reachable. Possibly upstreamable.
   Without it: the one-line `--keep-temp` wasm32 fix in rocBuildWasmLlvm (main.zig ~10060; the
   native path has `reportKeptTempDir` at ~11276). That keeps roc_app_unsealed_wasm32.o, whose
   relocations are exact for the app. src/split.mjs takes it as `unsealed` (today
   ROCX_SPLIT_UNSEALED, an experiment).
2. **The preload check:** render every page in Node with only its own chunks (the build already
   starts the server). Any chunk a render reaches joins that page's list, which keeps late loads
   out of hydration. Late loads in handlers stay possible; strict tests flag them.
3. **`--specialize=no` for the browser's build**, which is required: specialization inlines every
   closure into one dispatcher. Its runtime cost (stage 1: hydration per page, charts Auto/glide
   and flock frame times) is not measured yet.
4. **Functions only**, until (1): all data stays in main (costs ~2 KB).
   Measured: main 124.3 KB br vs 162.1 today.
5. Also: the trampoline change (roc_tail_driver inlines tail-called procedures) and the
   native-callable table; and remove analyse()'s `debug` return.

Proven so far: with every chunk preloaded, all 25 split-mode site tests pass (strict hydration,
byte for byte, demos, the Pages export under /rocx/).

---

# Splitting the browser's wasm by page: measurements (rocx-67, 2026-11-21)

All work in /tmp/rocx-split (a copy of the tree, production client via `prepare({ dev: false })`,
fork compiler .tools/roc-active = 3f66e242ea). Nothing in the shared checkout was touched.
Scripts: /tmp/rocx-split/scripts; outputs: /tmp/rocx-split/out.

## Method

Build the client wasm 24 times: as shipped, with every page's `view!` replaced by `Html.empty({})`
("core": layout, error page, platform glue), and once per page with only that page replaced. The
difference to the full build is the code only that page reaches: what splitting could move out of
the main download. Brotli quality 11, as the site's facts.

## Results (brotli KB; raw in the tsv files)

| | shipped (`--opt=size --specialize=yes`) | boxy (`--specialize=no`) |
|---|---|---|
| whole wasm | 162.1 | 176.0 |
| core (no pages) | 34.8 | 54.9 |
| /ecosystem/charts alone | 49.6 | 48.4 |
| /showcase alone | 32.3 | 16.5 |
| /components alone | 13.7 | 10.1 |
| /calls alone | 7.4 | 5.8 |
| /safety alone | 4.5 | 3.7 |
| /syntax alone | 3.3 | 2.9 |
| / alone | 1.8 | 1.5 |
| /members alone | 1.0 | 0.9 |
| the 14 prose pages (platform/*, rocx, routing, tooling, ecosystem, members/join) | ~0 each | ~0 each |
| shared by 2+ pages, not core (remainder) | ~14 | ~31 |

So ~78% of today's wasm is code that only some pages use; the 14 prose pages need none of it.

## Can it be cut?

- **Shipped mode can't be cut per function.** With lambda-set specialization, Roc dispatches boxed
  closures through a switch, and LLVM inlines the bodies into it: one function is 166 KB (23% of
  the module), and it grows with each page added (27 KB with no pages, 50 KB with /showcase only).
- **Boxy mode can:** ~1000 functions, the largest 15 KB, closures called through the table.
- **Binaryen `wasm-split --multi-split` works on Roc's output** (binaryen 133, nixpkgs). Cutting
  /showcase and /ecosystem/charts out of the boxy build: primary 117.0 KB, charts 47.5 KB, showcase
  23.2 KB brotli. All three validate (binaryen). The chunks import `primary`'s memory, table,
  `__stack_pointer` and functions: ONE heap, one table (this answers DESIGN §4's "Roc can't link
  wasm modules over one heap": it is one Roc program, cut after linking, not separate apps).
  Calls from primary into a chunk not yet loaded go through placeholder imports
  (`placeholder.<Chunk>`), which is where the runtime would hook in: load the chunk, then re-run
  the computation, as it already does for a server answer that isn't in.
  Overhead: +11.6 KB brotli across the three files vs one (placeholders, exports, lost context).
- **Blocker: function names aren't stable between builds.** `--debug` gives a name section, but
  names are hashes (`roc__p<32 hex>`) that shift when unrelated code changes: removing a prose
  page (≈0 bytes of its own) renames ~38 functions. So the manifest (which function goes to which
  chunk) can't come from the wasm alone. It needs the compiler: stable, module-qualified names
  (or a proc → module map), plus each page entry's function, then rocx computes reachability.
- Data (47 KB raw of string constants) stays in the primary module; wasm-split moves functions
  only. Pages' own strings would need a further step.
- wabt's wasm-validate rejects `-all` output (`exact` import types); pass the real feature set.

## What a page would load (boxy, estimate)

Prose page ≈ core 55 KB + overhead, vs 162 today (~3×). /showcase ≈ 55 + shared + 16.5;
/ecosystem/charts ≈ 55 + shared + 48. Exact numbers need the real manifest.

## Work it would take

1. Roc fork: stable symbol names (or a symbol → module map) with `--debug`; optionally keep lambda
   bodies out-of-line in specialize mode so the smaller mode is splittable too.
2. rocx build: client in boxy mode with names; manifest from page entries + call graph (direct
   calls + table refs; may need relocations); `wasm-split --multi-split`; strip; binaryen via Nix.
3. runtime.js / start.js: instantiate primary + chunks over one memory/table; placeholders suspend
   the computation and load the chunk; the server preloads the current page's chunk(s).
4. Client-side navigation is where chunks pay off; the two fit together.

## Update ~21:00: no stable names needed; the fork change is at most one line

- Names only need to be unique within ONE build, and they are (`roc__p<hash>` is a content digest:
  src/lir/LIR.zig `ProcIdentity`). Cross-build instability only broke the remove-a-page method.
- The exact call graph comes from the app's relocatable object, which an UNMODIFIED fork gives:
  - set the platform's wasm32 `output: Archive` (in a copy) → `roc build --output=x.a` writes
    host.wasm + roc_app_llvm_wasm32_size.o (combined; symbol table + reloc.CODE/DATA);
  - or the pre-combine `roc_app_unsealed_wasm32.o` (PIC; relocs incl. TABLE_INDEX_REL_SLEB), which
    `--keep-temp` should keep but doesn't for wasm32: rocBuildWasmLlvm (src/cli/main.zig ~10060)
    lacks the `if (args.keep_temp) try reportKeptTempDir(ctx, app_object.artifact_dir);` line the
    native path has (main.zig:11276). One-line bug fix, upstreamable on its own merits.
  Both gave the same manifest.
- Page entries: rocx marks each page's entry closure (a marker string); the function whose data
  relocation points at the marker is the entry. All 22 pages resolve to exactly one function.
- Exact split (scripts/graph6.py → wasm-split, explicit features, all 24 pieces valid in binaryen
  AND wabt): primary 117.5 KB br; charts 25.4, showcase 17.4, components 8.5, shared 8.4, calls 4.2,
  safety 3.9, / 3.0, syntax 2.4, members 1.9, prose pages 0.2 each.
- Why primary is 117.5, not ~55 (the no-pages build): (a) all data (104 KB raw; pages' strings)
  stays in primary, wasm-split moves functions only → a rocx-side data-splitting step; (b) ~244
  functions hang only off 4-byte static data objects (`roc__d<N>`) that no relocation references:
  probably dead static closures Roc's linker keeps (it doesn't GC data), or a path not decoded yet.
  Both are rocx-side questions, not fork changes.

## Update ~21:40: data split done; main is 89.9 KB br (gate: stop before the loader)

Pipeline (all scripts in /tmp/rocx-split/scripts, no fork change):
1. Build twice from the same source: the real wasm (`--debug` for names) and `output: Archive`
   (platform copy) for the linkable object. Final data address = object offset + 1048704 (constant).
2. Graph (plan.py): relocations (calls, table refs, data refs, data→function), plus references the
   combine step folded into constants: code i32.consts (546 edges) and data words (3341 edges) that
   land inside a data object's final range.
3. Owner of every function and data object: core / one page / Shared (2+ pages) / Unreached.
4. `wasm-split --multi-split` (functions), then apply_data.py moves each owner's data into its
   chunk as active segments at the same addresses (a memory import added where missing). All 25
   pieces validate (binaryen + wabt).

Sizes (brotli; boxy build): main 89.9 (data 104→55 KB raw), Shared 8.8, Unreached 31.7 (153 fns +
65 KB raw data nothing references; never loaded unless called: VERIFY at runtime).
First load per page, today 162.1 for every page:
- text-only pages (platform/*, routing, rocx, tooling, ecosystem, members/join): 90.2
- / 101.7, /syntax 101.2, /members 100.9, /safety 102.9, /calls 103.3, /components 107.8,
  /ecosystem/charts 126.7, /showcase 128.7

Why main isn't ~54 (the no-pages build): 226 core functions (117 KB raw) aren't in the no-pages
build. The biggest doors:
- `roc_tail_driver.0/.1` (47 KB raw): Roc's tail-call trampoline; LLVM inlines the tail-called
  procs, page ones too, into two central functions (no calls left to cut). Compiler-side.
- `roc_builtins_native_callable_call` → table `roc__d830_1` (45 fns, 29 KB raw): one shared table
  of callables, so every callable looks core-reachable. Maybe rocx-side (attribute by index), maybe
  compiler-side.
- The rest is mostly builtins whose LLVM names differ between builds (noise), and page metas
  (titles/tocs) that Root references for every page.
Estimated floor with the two dispatchers fixed: ~65–70 KB br main.

## Update ~22:45: loader built and proven; safe main is 124 KB br (gate: stop, report)

Built in /tmp/rocx-split/repo (not in the tree): src/split.mjs (analysis, wasm-split, Chunks.roc),
`rocx build --split` (Root puts a <NoHydration> before each page: server = <link rel=preload
data-rocx-chunk>, browser = the page's marker), web/runtime.js (Runtime.load({chunk, preload,
strict}); placeholders throw NotReady and load the chunk; a call into Unreached is console.error,
and throws when strict), web/start.js (preloads the page's chunks from the links, beside itself, so
/rocx/ on Pages works), site/build.mjs (`--split` / ROCX_SPLIT=1, loadApp, split facts),
site tests (a page fetches app.wasm and exactly the chunks it names, never Unreached), Justfile
(binaryen_version 133: system wasm-split, else .tools/binaryen; `just site-split`).

Proven: with every chunk preloaded, all 25 split-mode site tests pass (strict hydration, byte for
byte, every demo, the Pages export under /rocx/). The mechanics are sound.

What turned out wrong in the earlier numbers (89.9 / 90.7 KB): they were unsafe.
- Roc's composition step folds references into plain numbers (table slots in code and data, data
  addresses), and the runtime reaches some static data no reference shows. Several functions the
  analysis called Unreached run on every page (e.g. roc_mount's per-page closures).
- Moving data is unsafe: data in the wrong chunk reads as garbage (wrong text, wrong counts),
  silently. Keeping ALL data in main costs only ~2 KB br, so the split is functions only.
- A late chunk load (a page calling code in a chunk it didn't preload) during hydration or a
  handler breaks the page (hydration hangs; a click lands late). So each page must preload every
  chunk it will call: assignment must be complete, not just safe.

Safe numbers (functions only; unsealed object's relocations; doubt → main): main 124.3 KB br
(today 162.1 for every page). First load: text-only pages ~124.5, / ~126, /syntax 133.1,
/calls 134.8, /showcase ~144, /ecosystem/charts 156.7.

Still open (why the split tests don't all pass with each page's own list): a few functions are
reached on other pages by paths neither object shows (e.g. /calls and /ecosystem/charts call a
closure the graph gives to /syntax). Fixes, in order:
1. Build-time check: render every page in Node with only its chunks (the build already starts the
   server); any chunk a render reaches joins that page's list. Catches render and hydration paths.
2. The --keep-temp wasm32 fork fix (one line) to get roc_app_unsealed_wasm32.o reliably (today:
   ROCX_SPLIT_UNSEALED, a copy caught from the scratch dir, for the experiment only).
3. Handler-only paths can still load late (correct, but delayed): strict tests catch them.
Size beyond 124 KB needs compiler work: the tail-call trampoline (roc_tail_driver), and a linker
reference map (relocations kept through composition) before any data could move.
"Unreached" (b): nothing is truly dead; what looked unreached runs (it's reached by references
composition folded). Nothing to strip.
Stage 1 (runtime cost of --specialize=no): not measured yet.
