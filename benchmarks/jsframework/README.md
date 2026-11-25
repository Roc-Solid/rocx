# Roc Solid in js-framework-benchmark

[js-framework-benchmark](https://github.com/krausest/js-framework-benchmark) is the common
yardstick for web frameworks: one page, a table of rows and six buttons (create 1,000 rows, 10,000,
append, update every 10th, clear, swap two). Its runner opens each framework's page in Chrome,
clicks, and measures how long until the page has painted, how much memory it holds, and what it
downloads. These are Roc Solid's two entries, and the script that measures them on this machine
beside the frameworks they are compared with. The results are in `site/js-framework-benchmark.json`.

- **`keyed/`**: each row kept by its id (`.map` with `key={row.id}`, D-071): a row moves with its
  data, and goes with it. This is the bracket the official results show.
- **`non-keyed/`**: a row kept by its position (`.map_with_index` with `key={i}`): a swap or a
  removal rewrites the rows that changed places. Upstream retired its non-keyed entries
  (2026-10-24); its runner still measures them, so ours, Joy's and vanillajs's are kept.

Each is an app of one page whose markup is the vanillajs entry's, which the runner relies on
(buttons by id, rows by class). They are separate apps, so neither carries the other's code. The
rows' data is plain Roc (`Rows.roc`, the same file in both, with its expects): an id from 1, and a
label of three words picked at random by a xorshift generator with a fixed seed (the vanillajs
entry's words; the runner reads only ids, the row count and the " !!!" an update adds). Nothing
is batched, cached or read from the DOM beyond what an app would do. The page is written as files
by `rocx build --static` (D-073), its wasm `--opt=size --specialize=yes`, as an app ships it, and
`runtime.js` as rocx ships it today (not minified).

## Compared with

| Entry | Why |
|---|---|
| vanillajs (keyed, non-keyed) | the floor: hand-written DOM code |
| Solid | the closest relative: signals, no virtual DOM |
| Leptos | the same idea in Rust and wasm (its committed build) |
| Joy (keyed, non-keyed) | the other Roc framework: Elm's architecture, a virtual DOM; built from its 0.35.0 tag the way its own `benchmarks/jsframework/README.md` says (`--opt=size`, `wasm-opt -Oz`, its runtime minified) |
| React (hooks) | the common one |

## Setting it up (once)

Everything lives outside this repository, in `~/jsfb/` (or set `JS_FRAMEWORK_BENCHMARK_DIR`):

1. Clone krausest/js-framework-benchmark into `~/jsfb/js-framework-benchmark`, then
   `npm ci --legacy-peer-deps && npm run install-local` there (the root's lint tools' peer
   dependencies conflict; nothing else needs the flag).
2. Patch the runner: `git apply <this repo>/benchmarks/jsframework/runner-trace-start.patch` in the
   clone, then `npx tsc` in `webdriver-ts/`. A trace of the measured click may hold events from
   before tracing started (the warmup's clicks), when the renderer that same-site tabs share still
   traced from an earlier iteration; the runner then counts the warmup's mousedowns and refuses the
   iteration ("at most one mousedown event is expected"; upstream repeats an iteration for the
   sibling error, "exactly one click", and not for this one). It happened to Roc Solid's entries
   only, on every benchmark that creates rows; the patch drops a trace's events from before
   `TracingStartedInBrowser`. Recomputed with and without it, the other entries' 135 traces of a
   run gave the same durations. `run.mjs` refuses to run without it.
3. A Chrome for the runner: Chrome for Testing under `~/jsfb/browsers`
   (`npx @puppeteer/browsers install chrome@stable --path ~/jsfb/browsers`), or `CHROME=<binary>`.
   The runner otherwise looks for `/Applications/Google Chrome.app`.
4. Build the other entries: `npm ci && npm run build-prod` in `frameworks/keyed/vanillajs`,
   `keyed/solid` and `keyed/react-hooks` (Leptos's build is committed); copy
   `retired/non-keyed/vanillajs` to `frameworks/non-keyed/vanillajs` and build it.
5. Joy: clone niclas-ahden/joy into `~/jsfb/joy` at its release tag, and make
   `frameworks/{keyed,non-keyed}/joy` with a `package.json`, an empty `package-lock.json` (the
   benchmark's server lists no entry without one), an `index.html` that mounts Joy's runtime with
   the app's wasm, and the wasm and runtime built in Joy's `nix develop`
   (`./build.roc --opt=size tests/apps/jsbench_keyed.roc`, then `wasm-opt -Oz`, then the runtime
   minified).

## Running it

```sh
just js-bench entries     # our two entries, built from this checkout into the clone
just js-bench bench       # the entries, then two rounds of everything, then the report
just js-bench bench --rounds=1 --count=3 --benchmarks=01_,05_   # a quick look
just js-bench report benchmarks/jsframework/runs/<stamp>        # a run's report again
just js-bench ready benchmarks/jsframework/runs/<stamp>         # its cold loads (ready to use) again
```

`bench` starts the benchmark's server on 8089 (`JSFB_PORT`; never 8080, which is the user's dev
server's) unless it is up, and stops it after. The runner is headless. Each round runs the
benchmarks one at a time, every entry in turn for each, so one benchmark's entries are measured
minutes apart rather than an hour; the second round walks the entries in reverse order. The report
pools every iteration of every round: per benchmark the mean and its standard deviation, and each
round's median (the noise band); per entry the geometric mean of the CPU benchmarks and its
slowdown against the fastest entry of each benchmark (the official table's measure), memory, and
what the page downloads (compressed, as the benchmark's server sends it). After the rounds it measures what the runner doesn't: when each page is ready to use, cold (a
fresh browser loads it from the benchmark's server, compression on, five times; Roc Solid's when it
has hydrated, the others' when their script has drawn the buttons). The runner's first paint
flatters a page the server rendered, which paints before its runtime and wasm have come. The report
then groups the benchmarks into the categories the docs' page leads with (ready to use, first
paint, making rows, updating rows, memory, download), each a geometric mean and each entry's ratio
to the best. It writes
`site/js-framework-benchmark.json` (committed, with the machine, its load and power, Chrome's version
and the commits measured) and `runs/<stamp>/report.md` (raw results and logs per round; not
committed).

Run it on mains, with nothing else heavy running: through `/tmp/rocx-gate.sh` with
`ROCX_GATE_EXCLUSIVE=1`, which holds both of the gate's slots. A full run takes about an hour and
a half. Only on the user's go.

## Not upstream yet

The official results come from krausest's own machine, from entries in the benchmark's repository
built from published releases. Ours can go there once this repository is public and rocx's compiler
is a release one can download; until then the numbers are this machine's.
