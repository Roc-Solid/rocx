# otel: proposals

What `packages/otel` needs from outside its folder. Two needs landed with the package, in the
platform: `Time.now_nanos!` and `Server.Request`'s `route`. What's left works around each need, as
said.

## Server-only modules in packages

Same as every package's (see packages/guard/PROPOSALS.md): `server/Otel.roc` imports the server
platform, so today it's copied into the app by hand. `rocx build` already finds `Otel.meter`
(`Actor.define`) once it's there.

## A kind of actor kept only in memory

**Problem.** Each measurement is an actor message, and with a database the platform writes the
actor's state to Postgres after each one: a write for every request. Metrics are cheap to lose on a
restart, though keeping them makes the sums run on across it.

**Recommended.** The `keep: [Postgres, Memory]` field on `Actor.define`'s record, which guard and
presence ask for too. The package would set `keep: Memory`, and the README's cost note would go.

## Traces

**Problem.** A span needs to know which request it belongs to, deep in `Db.all!` and `Http.send!`,
with nothing passed by hand. The host knows each call's context (`CALL` in hosted.rs). Roc has no
ambient value a module can read, and passing a trace through every function is what tracing
should spare the app.

**Options.** A per-call slot in the host (two effects: set and read a value for this call); a trace
in the middleware's context, passed by hand to `Otel.span!`; or something in the language. The user
wants to talk with Roc's designers first.
