# otel: proposals

What `packages/otel` needs from outside its folder. Two needs landed with the package, in the
platform: `Time.now_nanos!` and `Server.Request`'s `route`. What's left works around each need, as
said.

## Server-only modules in packages

**Done (D-033, 2026-11-26).** `Otel` is the package's own: the package names the server platform,
and `browser.roc` lists the rest. Its sums aren't an actor any more (which `rocx build` finds only
in an app's own files), so nothing is copied into the app: it lists `Otel.plugin({})`.

## A kind of actor kept only in memory

**Not needed any more.** The sums are kept in the plugin's loop's memory, fed through `Kv`, so a
measurement is no database write. Guard and presence may still want it for their own reasons.

## Traces

**Problem.** A span needs to know which request it belongs to, deep in `Db.all!` and `Http.send!`,
with nothing passed by hand. The host knows each call's context (`CALL` in hosted.rs). Roc has no
ambient value a module can read, and passing a trace through every function is what tracing
should spare the app.

**Options.** A per-call slot in the host (two effects: set and read a value for this call); a trace
in the middleware's context, passed by hand to `Otel.span!`; or something in the language. The user
wants to talk with Roc's designers first.
