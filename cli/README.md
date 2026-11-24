# The command-line platform

The Roc platform rocx itself is built on: `rocx-cli/*.roc`, compiled against it, is `bin/rocx`. You
need this README only to work on rocx. Apps never use this platform: they run on the server
platform (`server/`) and the browser platform (`web/`).

It is a platform for programs that work on files and run other programs, and that may watch a
directory tree while a server they started runs beside them, which is what `rocx dev` does (D-062).
`cli/platform` is its Roc; `cli/host` is its host, in Rust, using nothing but the C library.

| Module | What |
|---|---|
| `Stdout`, `Stderr`, `Stdin` | `line!` and `write!`, each a `Try`, so a caller's `?` reads as on other platforms; `Stdin.read_to_end!`, all of stdin |
| `Env` | `cwd!`, `var!`, `exe_path!`, `pid!`, `alive!` (whether a process is running) |
| `File` | `exists!`, `is_dir!`, `modified!` (nanoseconds), `read!`, `write!` (its directory made first), `create_new!` (only if nothing is there: a lock), `rename!`, `real_path!`, `make_dirs!`, `list!` (sorted), `delete!` and `copy!` (a file or a tree) |
| `Cmd` | a command built up (`args`, `cwd`, `env`, `stdin`), run without a shell: to its end with stdout and stderr apart (`output!`), in one pipe in the order written (`merged!`) or on this program's own output (`status!`); started beside this program (`spawn!`); or run in its place (`exec!`) |
| `Child` | a command started beside: `terminate!` (SIGTERM), `kill!` (SIGKILL), `id` |
| `Watch` | `dir!(dir, skip)`: watches a tree, but for hidden entries and the directories named in `skip` |
| `Events` | `next!(ms)`: the next event, `Changed(paths)`, `Exited(child, code)` (128 plus the signal's number when a signal ended it), `Signal(Hangup / Interrupt / Terminate)`, or `Timeout` after `ms` (0 waits for as long as it takes) |
| `Time` | `now_ms!` (a steady clock), `now_ns!` (the system's clock, as file times are), `sleep!` |

**One wait.** The host's threads each put what they see on one queue: a waiter for each child, the
watcher, and a reader of the signal pipe. `Events.next!` is the only effect that waits on that
queue, so a program that watches is one plain loop over it, with its state in `var`s
(`rocx-cli/Dev.roc`). Roc runs on the main thread alone, and only that thread touches Roc's memory.

**Changes, not noise.** The host knows each file in a watched tree by its size and modification
time. When the system names a path, the host looks at it again, and reports the file only when it
differs, appeared or went. A touch that changes only metadata, an event delivered late, or an
editor's temporary file that came and went is no change. Changes that come back to back are
reported as one event.

**Watching on macOS** uses FSEvents, loaded when watching starts (`dlopen`): Roc links a program
against the C library alone, so CoreServices can't be linked in. A write is seen within a few
milliseconds. Elsewhere, or with `ROCX_WATCH=poll`, the trees are walked again every 250 ms.

**Signals are events.** A handler writes SIGINT, SIGTERM and SIGHUP to a pipe, and a thread reads
them; the program decides what to do. A child still running when the program ends (or when Roc
crashes) is sent SIGTERM. `Cmd.exec!` first sends its children SIGTERM and waits up to ten seconds
for them to end, so a port a server held is free for the program that takes its place.

**Building.** `server/build.mjs`'s `buildCliHost` (and `rocx self-build`, and
`just rocx-bootstrap`, which needs no Node) build the host with cargo when its Rust is newer than
the library Roc links (`cli/platform/targets/<target>/libhost.a`). After changing `Host.roc`, run
`just glue` to regenerate `cli/host/src/roc_platform_abi.rs`. The glue names result types after the
first hosted function that returns each, so `lib.rs` gives them aliases in one place.

## Not yet

- Linux: the musl targets are named and `just rocx-bootstrap` builds for them, but nobody has tried
  them yet. Watching there polls (inotify is the next step).
- Output is text: a command's bytes that aren't UTF-8 are replaced, and there is no `File` call
  for bytes.
