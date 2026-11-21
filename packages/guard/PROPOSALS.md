# guard: proposals

What packages/guard needs from outside its folder. Nothing here is implemented: the package works
without it today, in the ways README.md's "Status" says, and each proposal says what would get
better.

## Server-only modules in packages

**Problem.** The guards are middleware: they import `pf.Middleware`, `pf.Server`, `pf.Time` and
`pf.Actor`. A Roc package may name a platform only if it is its app's very platform, and a Roc
Solid app is two apps (the browser's half on web/platform, the server's on server/platform), so a
package can't import either. `rocx build` copies a package's `components/*.rocx` into each half
(`Generated/<alias>/`), which solves this for components; nothing does it for modules that belong
to the server only. Today an app copies `packages/guard/server/*.roc` beside its main.roc by hand.

**Options.**

1. `rocx build` also copies a package's `server/` folder (`.roc`, and `.rocx` transpiled) into the
   app's `Generated/<alias>/`, for the server's half only, and `import guard.Guard` imports the
   copy, as `import charts.BarChart` does a component.
2. The package takes the platform's functions as arguments (`Guard.rate_limit(…, { now!:
   Time.now_millis!, … })`). It can't: a middleware's answer is a `Server.Response`, whose body
   holds platform types (`Html`, `Events`), so the package can't even name what it returns.
3. The README holds the middleware as snippets for each app to paste. Every app keeps its own copy,
   and none gets fixes.

**Recommended: 1.** In `bin/rocx.mjs`:

```diff
 function componentPackages(dir) {
 	…
 			const components = join(root, "components");
-			if (found.has(name) || !existsSync(components)) continue;
-			const paths = [...files(components, ".rocx")];
-			found.set(name, { name, own: basename(root), paths, modules: new Set(paths.map((path) => basename(path, ".rocx"))) });
+			const server = join(root, "server");
+			if (found.has(name) || (!existsSync(components) && !existsSync(server))) continue;
+			const paths = existsSync(components) ? [...files(components, ".rocx")] : [];
+			// Server-only modules: copied into the server's half alone.
+			const serverPaths = existsSync(server) ? [...files(server, ".roc"), ...files(server, ".rocx")] : [];
+			const named = (path) => basename(path).replace(/\.rocx?$/, "");
+			found.set(name, { name, own: basename(root), paths, serverPaths, modules: new Set([...paths, ...serverPaths].map(named)), serverModules: new Set(serverPaths.map(named)) });
 }
```

and in `build()`, beside the loop that copies each package's components: copy each of
`pkg.serverPaths` to `Generated/<alias>/<Name>.roc` (a `.roc` as it is, its own package's imports
renamed as the components' are, and the marker line appended; a `.rocx` transpiled), and leave
them out of the browser's copy (`--client`). `linkComponents` already rewrites `import guard.Guard`
to the copy, once `Guard` is in `pkg.modules`. Inside the folder, a module imports its siblings by
name (`import Kept`): the copies sit side by side, as the originals do.

What only the server has must stay out of the browser's half. Route `+server.roc` files and
middleware are server-only already, and a server function's body loses its imports in the
browser's copy. A `.rocx` component (browser and server) that still imports a server-only module
after that fails the build: `guard.Guard is server-only: import it in a +server.roc, a middleware,
or a server function's body`.

**What depends on it.** `server/Guard.roc`, `server/FlagStore.roc`, `server/Kept.roc`: with it, an
app writes `import guard.Guard` instead of copying them.

**Undoing it.** Remove the copy loop and the `server/` scan. A package's server modules go back to
being copied by hand; nothing else changes.

## The client's address

**Problem.** The host accepts each connection with its peer's address and drops it
(`server/host/src/http.rs`: `let Ok((stream, _)) = accepted`), so Roc never learns who connected.
A rate limit by address can then only trust what a proxy wrote (`X-Forwarded-For`):

- `ClientIp.Direct` (no proxy in front) can't tell clients apart, so `Guard.ip(Direct)` gives no
  key and doesn't limit;
- `Proxies(cidrs)` can't check that the connection came from one of the app's proxies: a client that
  reaches the server directly can send an `X-Forwarded-For` naming anyone.

**Options.**

1. A field on `Server.Request`, `peer : Str`. Typed and visible, but `Request` is built in many
   places: `from_http`'s arguments, the `roc_respond` ABI, both platforms (`Server.roc` is shared),
   and every request literal in tests.
2. An effect, `Server.peer!({}) : Str`, read from the call's context, as `Server.request!` is. The
   host keeps the address in its `Asked`, and an in-process call (a server function a page calls
   while it renders) keeps its page's. In the browser, `""`.
3. A header the host sets (`x-rocx-peer`), removing any the client sent. No new API, but a magic
   name, and anything that passes a request's headers on could leak it.

**Recommended: 2.** A sketch:

```diff
 // server/host/src/http.rs
-                let Ok((stream, _)) = accepted else { continue };
+                let Ok((stream, peer)) = accepted else { continue };
                 let config = config.clone();
-                let service = service_fn(move |request| answer(request, config.clone()));
+                let service = service_fn(move |request| answer(request, peer, config.clone()));
 …
-    let answering = hosted::Asked::new(method.as_str(), target, headers…, body, config.context.clone(), config.dev);
+    let answering = hosted::Asked::new(method.as_str(), target, headers…, body, config.context.clone(), config.dev, peer.ip().to_canonical().to_string());

 // server/host/src/hosted.rs
+/// The address the request being answered came from ("" with none: a job, a schedule).
+#[no_mangle]
+pub extern "C" fn roc_peer() -> RocStr {
+    let peer = CALL.with(|context| context.borrow().asked.as_ref().map(|asked| asked.peer.clone()));
+    roc_str(&peer.unwrap_or_default())
+}
```

```roc
# web/platform/Host.roc and server/platform/Host.roc (the web host answers "")
peer! : {} => Str

# web/platform/Server.roc (shared), beside `request!`
## The address the request being answered came from (`203.0.113.7`, `2001:db8::1`): the
## connection's, which a client can't make up. Behind a proxy, the proxy's. `""` in the browser,
## and in a job or a schedule.
peer! : {} => Str
peer! = |{}| Host.peer!({})
```

and `"roc_peer": Host.peer!` in both platforms' `hosted` lists. In the package, `Guard`'s `peer`
(today `""`) becomes `Server.peer!({})`; `ClientIp` takes the peer already, and its tests cover it.

**What depends on it.** `Guard.ip(Direct)`, `Guard.ips` with `Direct`, and the safety of
`Proxies(…)` when the server can be reached other than through its proxies.

**Undoing it.** Remove the effect; the package's `peer` goes back to `""`.

## Memory: state between requests

**Problem.** A rate limit keeps a count for each client, and flags keep their overrides, between
requests. Until D-028, the only state a request could reach that outlived it was an actor's
(`Actor.ask!`). That works (the package uses it, in `server/Kept.roc`), but each message:

- goes through the actor's mailbox, runs its turn in a call of its own, and passes its state, the
  message and the reply as JSON: about a millisecond for a limited request, in a dev build, with 64
  shards (measured before D-021, when each message took a lock instead);
- with a database, also writes the actor's state to Postgres (`rocx_actors`) when the turn changes
  it: a write for every limited request (each moves a tally). A read of the flags' overrides
  changes nothing, so since D-021 it writes nothing.

**Since D-028** (2026-11-22) the platform has it: `Kv`, values in the server's memory by key, one
map behind one lock in the host, never written to Postgres, with a time to live, atomic increments
and a size limit past which the least recently used go (DECISIONS.md). That is option 1 as built,
but with no `update!`: a tally can't be read, changed and written back in one step, so `Kept` can't
move over as the sketch below has it. What is left is the package's own: each client's count as a
counter (`Kv.increment!` under a key for the client and the window, living as long as the window:
a fixed window; a sliding one weighs the window before too), in place of the tallies and their
shards. The flags' overrides must outlive a restart, so they stay an actor's state, of which `Kv`
could keep a copy for reads. The sketch below is from before D-021 took the host's locks away.

**Options.**

1. A server platform module, `Memory`, on the host's store and locks: values by name, kept until
   the server stops, never written to Postgres.
2. An actor whose state isn't written to Postgres (`keep: Memory` on its kind, since D-021). Smaller,
   but still a call of its own and JSON for every message.
3. A rate limiter in the host (Rust's `governor`). Fast, but the logic leaves Roc, and the package's
   tests with a fake clock no longer test what runs.

**Recommended: 1**, in Roc on the host's primitives, plus one new primitive to remove a value:

```roc
## server/platform/Memory.roc
import Host

## Values the server keeps in its memory, by name, until it stops: never written anywhere, gone
## on a restart. For what is cheap to lose and read on every request (a rate limit's counts, a
## cache). One instance of an app means one memory.
Memory := [].{

	## The value called `name`.
	get! : Str => Try(Str, [Missing])
	get! = |name|
		match Host.store_get!("memory:${name}") {
			Ok(value) => Ok(value)
			Err(_) => Err(Missing)
		}

	set! : Str, Str => {}
	set! = |name, value| Host.store_set!("memory:${name}", value)

	remove! : Str => {}
	remove! = |name| Host.store_remove!("memory:${name}")

	## Changes the value called `name` ("" when there is none) one request at a time: `change`
	## gives the next value ("" removes it) and an answer. `Err(Busy)` when another request held
	## it for `patience_ms`, or this one holds it already.
	update! : Str, U64, (Str -> { value : Str, answer : a }) => Try(a, [Busy])
	update! = |name, patience_ms, change| {
		lock = "memory:${name}"
		# 1: another request held it all that time; 2: this one holds it already (an update
		# inside an update of the same value), which would let go of the outer one's lock.
		if Host.lock!(lock, patience_ms) != 0 {
			Err(Busy)
		} else {
			next = change(Host.store_get!(lock) ?? "")
			if next.value.is_empty() {
				Host.store_remove!(lock)
			} else {
				Host.store_set!(lock, next.value)
			}
			Host.unlock!(lock)
			Ok(next.answer)
		}
	}
}
```

with `Host.store_remove! : Str => {}` (`memory.rs`: `values().lock().unwrap().remove(name)`), and
`Memory` in the server platform's `exposes`. The host's lock table could also drop a lock no call
holds, so that names made per request don't accumulate.

In the package, `Kept.hit!` becomes:

```roc
Memory.update!("guard/${name}/${shard.to_str()}", 30000, |text| {
	{ decision, tally } = Tally.hit(Tally.from_str(text), policy, key, now, room)
	{ value: tally.to_str(), answer: decision }
})
```

and `FlagStore` reads the overrides from memory (`Memory.get!`), asking the actor (which keeps them
in Postgres too) only when memory has none yet, after a restart, and when they change.

**What depends on it.** `server/Kept.roc` and `server/FlagStore.roc`, nothing else: `Tally`,
`RateLimit` and `Flags` are pure and stay as they are.

**Undoing it.** Remove the module; `Kept` and `FlagStore` go back to actors.

## Open questions

1. **Which `RateLimit` headers.** The package sends the IETF draft's headers as most APIs send them
   today: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `RateLimit-Policy: 5;w=60`.
   The draft's latest version folds them into `RateLimit: "default";r=4;t=12` and a structured
   `RateLimit-Policy`. Keep the separate headers, or send the new pair (or offer both)?
2. **Where the flags' overrides live.** Today they are an actor's state, so with a database they
   are kept in `rocx_actors` and outlive a restart, without the package shipping a migration (a
   package can't ship one yet). Is that the right home, or should flags get a table of their own
   (and packages a way to add migrations)?
3. **Which environment variable names the environment.** The package reads `APP_ENV`, or else `dev`
   under `--dev`, or else `production`. Should the platform name it (`Env.name!`), so every
   package reads the same one?
4. **Failing open.** When a limit's count can't be reached (its actor busy for 30 s), the request is
   let through and logged, rather than refused. Right for a login form too?
5. **HSTS.** The default is a year, without `includeSubDomains` or `preload`, so one site can't put
   its subdomains on HTTPS-only by accident. Stricter by default?
