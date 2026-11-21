# Scripts from the wasm-splitting investigation (2026-11-21)

These are experiments, not tools. They hard-code paths under /tmp/rocx-split (the working copy
`repo/`, build outputs in `out/`), so point them at a fresh copy before running. Binaryen comes from
`nix shell nixpkgs#binaryen`. The conclusions are in ../REPORT.md.

What a pickup may want:
- measure.mjs and measure-debug.mjs: build the client once per page with that page removed, and
  once with no pages ("core"). They print each page's own bytes (raw and brotli).
- prepare.mjs: writes the production client copy (`prepare({ dev: false })`) in a copy of the tree.
- unar.py: extracts the members of a GNU `ar` archive (the `output: Archive` build's .a).
- sections.py, segs.py and funcs.py: a wasm module's sections, data segments, and functions' code sizes.
- sitesize.mjs and sitesize2.mjs: run src/split.mjs's analyse() and wasm-split on a site build, and
  print the main module's and each page's first-load sizes. Set NODATA=1 for functions only, and
  UNSEALED=<path> to add the unsealed object.
- latestack.mjs, whohits.mjs and bisect.mjs: render pages in Node with only some chunks loaded. They
  name the function behind a late chunk load (via wasm-split's placeholder map), or the chunk a
  page needs.
- browse.mjs: opens pages in Chromium (web/test/browser.mjs) and prints the wasm fetched, the
  console and errors. With REBUILD=1, rebuilds the site with --split first.
- graph*.py, plan.py and apply_data.py: the Python prototypes that src/split.mjs ported.
  apply_data.py moves data into the chunks, which turned out to be unsafe (see REPORT.md).
- who*.py, why*.py, refs*.py, unsealed*.py, orphans.py, dead.py, d830.py, paths.py, extra.py,
  memtrace*.mjs and query.mjs: one-off traces of particular missed references.
