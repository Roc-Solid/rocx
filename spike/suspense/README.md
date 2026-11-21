# Spike: async values read as plain values (Solid 2.0's model, in Roc)

> Kept as a record. What it showed became rocx's components: the browser's platform in `web/`
> (see `web/README.md`) does what "Not tried yet" below lists, and the islands it mentions were
> replaced by them.

Solid 2.0 reads an async memo as a plain value: `user().name`. A read whose value is still pending
throws (`NotReadyError`); the nearest `<Loading>` shows its fallback, and the computation runs
again when the value is in. Errors go to the nearest `<Errored>`. This spike asks whether Roc can
do the same, with no `Try` at the read and no JSPI.

    just setup                      # the toolchain, once (from the repo root)
    sh spike/suspense/build.sh      # the host, then the app twice: dev backend and optimized
    node spike/suspense/run.mjs

## How

- `Async.read! : Str => Str` is a hosted function. When the value isn't there, the JS import
  throws; the exception unwinds the Zig and Roc frames to the runtime, which waits and runs the
  render again. Roc never sees the abort: its code reads a plain `Str`.
- The unwound frames never run their epilogues, so Roc's stack pointer (in linear memory, the
  exported `__stack_pointer` global) is left lower; the runtime saves it before each run and
  restores it after an abort.
- `Async.start!` starts a request without reading it, as a Solid memo starts when it is made, so
  five reads cost one wait, not five.
- `Cell(a)` keeps any Roc value in the host (`Box(a)` through a hosted function generic in `a`),
  and gives it back typed: what signals need.

## What it showed (Node; both the dev backend and the optimized build)

| | |
|---|---|
| five reads, one at a time | 6 runs: a waterfall, one round trip per abort |
| five started first, then read | 2 runs: one wait for all five |
| one of them fails | a distinct exception the runtime catches (an `<Errored>`); the instance keeps working, and a retry renders |
| stack pointer | each abort leaves it ~500 bytes lower; without the restore, 50 aborts sink it ~25 KB |
| typed cells | a record kept by the host comes back as the record |
| leaks | an abort leaks what the aborted run held: ~3 allocations per abort when it comes after strings were built, none at the first read |

## What it means for an API

Plain values and boundaries are possible, in every browser: no JSPI, nothing suspended, so the
shared-stack problem of waiting in wasm never arises. A sketch of what it could look like:

```roc
Profile := [].{
	view! : {} => Html
	view! = |{}| {
		# Made first, so all requests start at once; each is read as a plain value.
		user = memo!(|| current_user!({}))
		posts = memo!(|| posts_of!(user.get!().id))   # runs again when `user` is in
		<Loading fallback={<Spinner />}>
			<h1>{user.get!().name}</h1>
			<Errored fallback={|problem, retry| <p>No posts: {problem} <button on:click={retry}>Again</button></p>}>
				<ul>{...posts.get!().map(|post| <li>{post.title}</li>)}</ul>
			</Errored>
		</Loading>
	}
}

current_user! : {} => User
current_user! = server(|request, {}| …, { method: "GET" })   # name and path by default
```

- A server function has the same type on both sides. On the server it is a call; in the browser a
  request whose read aborts until the answer is in, or fails into the nearest `<Errored>`.
- Five calls, one spinner, errors per region: one `<Loading>` around everything, an `<Errored>`
  around each region that should fail on its own.
- Handlers call server functions directly, no message for it: a handler that reads a pending
  answer aborts and runs again once it is in. Solid 2.0 queues writes until a flush, so the aborted
  run's writes can simply be dropped, and the replay makes them again; a call's answer is kept for
  the replay, so a command isn't sent twice. (`createOptimistic`-style writes that show at once would
  be the exception.)
- Components run once; holes that read signals become computations the runtime runs again when
  what they read changes, patching their node: fine-grained, no tree to diff.

## Open

- **Leaks on abort.** An arena per run would free what an aborted run made, but not what it handed
  the host to keep (a signal's new value). Reading async values before building anything keeps it
  small meanwhile.
- **Running again is the rule.** Computations, and handlers up to their last pending read, must be
  safe to run again; Solid has the same rule for memos.
- **Not tried yet:** effectful closures kept by the host and run through one provided function (the
  computations and handlers), the reactive graph and scheduling (in JS), keyed lists, SSR with the
  answers serialized into the page for hydration, and how much of today's islands carries over.
