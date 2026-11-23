# Spike: a CLI platform for rocx, so `rocx dev` (and `just dev`) can be Roc

> A spike, 2026-11-23, on master at 657d507. Built and run on macOS (arm64). **Since taken up:** the
> platform is `cli/` (rocx is built on it), and `dev/main.roc` became `rocx-cli/Dev.roc`; what
> follows is the spike as it was.

## 0. In short

rocx is Roc (D-032), but its dev loop isn't: `rocx dev` hands off to `rocx-cli/dev.mjs`, and
`just dev` runs `site/serve.mjs`, both Node. A dev loop needs four things basic-cli doesn't give
together: a directory tree watched, children started and stopped with SIGTERM, the signals it is
sent, and one place to wait for whichever of those comes first.

This spike is a small platform with exactly those four, a Rust host on `libc` alone (611 lines), and
`dev.mjs` ported onto it (`dev/main.roc`). The port builds, serves and rebuilds `examples/hello` as
`rocx dev` does (§4).

**No HTTP is needed.** The page reload a dev loop needs is already the server's: under `--dev` every
page loads `/__reload.js`, which holds an EventSource on `/__reload` and reloads when the server
comes back (server/host/src/http.rs). The dev loop only restarts the server. So the CLI platform is
not an HTTP platform. It can become one later, if rocx ever serves something itself.

**Rust, as the server's host is.** It uses the same glue (`just glue`'s RustGlue.roc), the same
ABI and the same toolchain, which rocx already needs for the server. `std::process`, `std::io::pipe`
and `libc` cover everything. The one thing Rust's crates would usually give, file watching, isn't
usable from a Roc host anyway (§2), so no crate is lost.

## 1. The platform

`platform/` is the Roc side. `host/` is a Rust staticlib that Roc links into the app (`platform/targets/<target>/libhost.a`).

| Module | What |
|---|---|
| `Stdout`, `Stderr` | `line!`, `write!` |
| `Env` | `cwd!`, `var!`, `exe_path!` |
| `File` | `exists!`, `is_dir!`, `modified!`, `read!`, `write!` (its directory made), `rename!`, `real_path!`, `make_dirs!`, `list!` (sorted) |
| `Cmd` | `run!(program, args, cwd)`: to its end, its exit code and its stdout and stderr as one text in the order written (one pipe for both) |
| `Child` | `spawn!` (its stdio the program's), `terminate!` (SIGTERM), `kill!` (SIGKILL) |
| `Watch` | `dir!(dir, skip)`: the tree, but for hidden entries and the directories named |
| `Events` | `next!(ms)`: `Changed(paths)`, `Exited(child, code)`, `Signal(Hangup / Interrupt / Terminate)`, `Timeout` |
| `Time` | `now_ms!` (steady) |

**One wait.** Threads in the host put what they see on one queue: a waiter per child, the watcher,
and a reader of the signal pipe. `Events.next!` is the only effect that waits on it. An app is a
plain `while` loop over `next!`, with its state in `var`s. A debounce is `next!(100)` returning
`Timeout`. Roc runs on the main thread alone, and only that thread touches Roc's memory: events
become Roc values inside `next!`.

**Changes, not noise.** The host knows every file in a watched tree by its size and modification
time. It looks again at whatever the system names, and reports only a file that differs, appeared
or went. A metadata-only touch, a late duplicate event, an editor's file that came and went, a
hidden swap file, and anything in `build/` or `Generated/` are never reported. dev.mjs and serve.mjs
each kept their own map for this. Paths of changes queued back to back come as one event.

**Signals are events.** SIGINT, SIGTERM and SIGHUP are written to a pipe by a handler (the only
thing a handler may safely do) and read by a thread, so the app decides what to do with them. A
child still running when the program ends, or when Roc crashes, is sent SIGTERM by the host. That
replaces dev.mjs's `process.on("exit")`, and its once-a-second check that its parent is still
there: the loop is now the top process.

## 2. Watching on macOS without linking a framework

Roc links an app against the C library alone, which the server's host already found with
iana-time-zone (D-046). FSEvents lives in CoreServices, so the usual crates (`notify`, `fsevent-sys`)
can't be linked. kqueue, the other option, needs a descriptor per file and doesn't see writes to a
file inside a watched directory.

The host loads FSEvents at run time instead: `dlopen` CoreFoundation and CoreServices, `dlsym`
`FSEventStreamCreate` and the rest, and run the stream on a dispatch queue (`dispatch_queue_create`
is libSystem's). This is about 100 lines (host/src/watch.rs), and it works: a write is reported
**5–7 ms** after it happens (`examples/hello.roc`), in dev and `--opt=speed` builds.

Where FSEvents can't be loaded, or with `ROCX_WATCH=poll`, a thread walks the trees every 250 ms.
The site's watched tree is 764 source files, so polling would be cheap too. On Linux the spike polls.
inotify is a system call (libc, no library), and it is the obvious next step there.

## 3. What basic-cli already has

basic-cli 0.28.1, which rocx-cli is on, is further along than expected. It has `Cmd.spawn!` with
`Child.poll!`/`wait!`/`kill!`/`pid!`, `Signal.catch!`/`poll!` (signals interrupt blocking effects),
`Sleep`, and `File.time_modified!`. A dev loop on basic-cli alone would be possible, written as a
polling loop: sleep 100 ms, poll signals, poll each child, and walk the trees comparing times. What
it lacks:
- a file watcher;
- choosing the signal (`kill!` alone; the server stops cleanly on SIGTERM: a running job is
  finished, and a stop's jobs are queued again);
- a wait on several things at once.

That is the cheaper road, and its cost is a loop that is always awake and a rescan for every change.
The spike's platform costs a host to build and keep (cargo, per target). In return it gives an
event loop, native watching, SIGTERM, and no basic-cli download. A platform of rocx's own can
also take later what rocx wants (brotli for the size measurements, an `exec!`).

## 4. The port: dev/main.roc

`rocx-cli/dev.mjs` (264 lines of JavaScript) became 475 lines of Roc. It does the same work:
- reads the arguments;
- writes a `main.roc` when there is none;
- runs `rocx build --dev`;
- builds the server's host (the shared modules synced, cargo, the library copied only when it
  changed);
- does the server's `roc build` through `rocx check`;
- builds the browser's host when its Zig is newer, and its wasm;
- renames everything into place together, and says the time;
- starts the server with `--dev --static …` and what follows `--`;
- runs `check-sql.mjs` after each start (left in JavaScript).

`dev/Fs.roc` and `dev/Text.roc` are rocx-cli's own, unchanged but for Fs's effects, which now call
this platform instead of basic-cli. Fs had already kept rocx's file effects in one place, so moving
platforms is a dozen lines there.

Checked by hand on `examples/hello` (port 8131):

| What | Result |
|---|---|
| first build and serve | built in 2.45 s (cold); the page served |
| an edit to `+page.rocx` | "routes/+page.rocx changed", built in 0.55 s, server stopped (SIGTERM) and started, page shows the edit |
| `touch -a`, a hidden `.swp`, a `.tmp` | nothing |
| a `.rocx` that doesn't parse | rocx's error at its line; "rocx build failed; fix it and save again"; the old server keeps serving |
| the fix | rebuilt, restarted |
| the server killed (`kill -9`) | "the server stopped (137); save a file to build and start it again"; the next save starts it |
| an edit during a build | built again after it |
| SIGINT / SIGTERM to the loop | server and SQL check stopped, port free, nothing left running |
| `ROCX_WATCH=poll` | the same, a change seen within 250 ms; idle at 0.4% CPU |
| `--opt=speed` builds | the same |

## 5. Roc on the way

- `app` and `platform` are reserved words, even as a record field or a local.
- `{ id }` alone is a block, not a record: write `{ id: n }`. A nominal record (`Child := { id : U64 }`)
  is made by annotating a binding.
- `Str.join_with(list, sep)`, not `list.join_with`.
- An assignment in a match arm needs braces.
- Adding a hosted function renames the glue's result types. They are named after the first hosted
  function that uses them, alphabetically (`HostMakeDirsResult` serves `rename!`, `watch!` and
  `write_file!`), so the host's code changes with them. basic-cli puts new functions at the end
  for the same reason.

## 6. How hard is "all of it in Roc"

The platform was the small part. It worked on its first run, and the one real unknown (§2) is
settled. What is left is porting the JavaScript around it, in this order:

1. **The platform moves in, and rocx-cli moves onto it.** It would live beside `server/` and
   `web/` (`cli/platform`, `cli/host`). It needs what rocx-cli uses from basic-cli and the spike
   lacks:
   - `Cmd` with an environment variable (`NO_COLOR`), stdin bytes (`roc fmt --stdin`), and stdout
     and stderr captured apart;
   - `Stdin` read to its end (`rocx internal`);
   - `delete!` and `delete_all!`;
   - the musl targets (a musl host, as the server's; inotify).

   `rocxBinary()` and `just setup` then build the CLI host with cargo before Roc builds rocx.
   Small: about a dozen effects.
2. **`rocx dev` in Roc.** `dev/main.roc` becomes rocx-cli's `Dev.roc`, and `node!("dev.mjs")` goes.
   This is done here, but for the move.
3. **`rocx check --sql` in Roc.** `check-sql.mjs` is 144 lines, and its helpers are already Roc. It
   needs a directory copy. Then the dev loop runs `bin/rocx check --sql` instead of node.
4. **`just dev` as `rocx dev site`.** The site's build runs more than an app's, before each build:
   - `Generated/Sources.roc`: the examples' sources, refusals and compiler report;
   - `PlatformReference.roc`: site/reference.mjs, 242 lines;
   - `ExampleApps.roc` and `DbBench.roc`, from their JSON;
   - the examples' checks.

   It also watches rocx-cli/, web/ and server/ too. These are site/build.mjs's steps 1–4 in
   `--dev`. Ported, they are the biggest piece (roughly 600–800 lines of JavaScript), and rocx dev
   needs a way to run them: a program of the app's own (`site/prepare.roc`, on this platform) that
   `rocx dev` runs before each build when there is one, and a way to add directories to watch.
5. **Not ported:** `just site`'s full build. It measures the wasm in Node with `web/runtime.js`,
   which needs a JS engine; it also does brotli and gzip sizes, the example screenshots (a
   browser), and the SQLite-vs-Turso runs. The tests stay `node --test`.

Steps 1–3 take rocx-cli off Node entirely, apart from tests. Step 4 is what `just dev` needs.

## 7. Questions for the user

1. **Own platform, or basic-cli with polling (§3)?** Recommended: own platform. One event loop,
   native watching and SIGTERM; and rocx no longer downloads basic-cli.
2. **Where?** Recommended: `cli/platform` and `cli/host`, beside `server/` and `web/`.
3. **Linux watching:** inotify now, or polling first? Recommended: inotify. It is about 80 lines, a
   system call, no library.
4. **The site's extra steps (§6.4):** `site/prepare.roc` that `rocx dev` runs before each build, or
   the site's generators inside rocx itself? Recommended: the app's own prepare program. Other apps
   could use it (codegen from a schema), and rocx stays about apps.
