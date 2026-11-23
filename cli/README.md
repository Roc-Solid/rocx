# The command-line platform

What rocx (`rocx-cli/`, built into `bin/rocx`) runs on: a Roc platform for programs that work on
files and run other programs, and that may watch a directory tree while a server they started runs
beside them (D-062). `cli/platform` is its Roc; `cli/host` its host, Rust on the C library alone.

| Module | What |
|---|---|
| `Stdout`, `Stderr`, `Stdin` | `line!`, `write!` (a `Try`, so a caller's `?` reads as on other platforms); all of stdin |
| `Env` | `cwd!`, `var!`, `exe_path!`, `pid!`, `alive!` (a process is running) |
| `File` | `exists!`, `is_dir!`, `modified!` (nanoseconds), `read!`, `write!` (its directory made), `create_new!` (only if nothing is there: a lock), `rename!`, `real_path!`, `make_dirs!`, `list!` (sorted), `delete!` and `copy!` (a file or a tree) |
| `Cmd` | a command built up (`args`, `cwd`, `env`, `stdin`), no shell; run to its end with stdout and stderr apart (`output!`), in one pipe in the order written (`merged!`) or this program's own (`status!`); started beside it (`spawn!`); or put in this program's place (`exec!`) |
| `Child` | a command started beside: `terminate!` (SIGTERM), `kill!` (SIGKILL), `id` |
| `Watch` | `dir!(dir, skip)`: a tree, but for hidden entries and the directories named |
| `Events` | `next!(ms)`: `Changed(paths)`, `Exited(child, code)`, `Signal(Hangup / Interrupt / Terminate)` or `Timeout` |
| `Time` | `now_ms!` (steady), `now_ns!` (the system's clock, as file times are), `sleep!` |

**One wait.** The host's threads each put what they see on one queue: a waiter for each child, the
watcher, and a reader of the signal pipe. `Events.next!` is the only effect that waits on it, so a
program that watches is one plain loop over it, its state in `var`s (`rocx-cli/Dev.roc`). Roc runs
on the main thread alone; only it touches Roc's memory.

**Changes, not noise.** The host knows each file in a watched tree by its size and modification
time. It looks again at whatever the system names, and reports a file only when it differs, appeared
or went: a metadata-only touch, an event delivered late, or an editor's file that came and went is
no change. Changes queued back to back come as one event.

**Watching on macOS** is FSEvents, loaded when watching starts (`dlopen`): Roc links an app against
the C library alone, so CoreServices can't be linked. A write is seen within a few milliseconds.
Elsewhere, or with `ROCX_WATCH=poll`, the trees are walked again every 250 ms.

**Signals are events.** SIGINT, SIGTERM and SIGHUP are written to a pipe by a handler and read by a
thread; the program decides what to do. A child still running when the program ends (or when Roc
crashes) is sent SIGTERM. `Cmd.exec!` sends its children SIGTERM and waits for them (up to ten
seconds) first, so a port a server held is free for the program that takes its place.

**Building.** `server/build.mjs`'s `buildCliHost` (and `rocx self-build`, `just rocx-bootstrap`)
build the host with cargo when its Rust is newer than the library Roc links
(`cli/platform/targets/<target>/libhost.a`). After changing `Host.roc`, `just glue` regenerates
`cli/host/src/roc_platform_abi.rs`: the glue names result types after the first hosted function
returning each, so `lib.rs` aliases them in one place.

## Not yet

- Linux: the musl targets are named and `just rocx-bootstrap` builds for them, untried; watching
  there polls (inotify, a system call, is the next step).
- Output is text: a command's bytes that aren't UTF-8 are replaced, and there is no `File` call for
  bytes.
