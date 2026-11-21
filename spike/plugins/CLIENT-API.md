# Plugins, from the app's side

> Ideation, 2026-11-21, branch `plugins`. Nothing here is built. It starts from what an app's author
> writes, and only then asks what packages and the platform must do to make that work.

## Why

A package can give an app pure Roc (named in the app's header) and components (`components/*.rocx`,
which `rocx build` copies into both halves). Anything else is copied by hand. Push's "Setting up"
is six steps: keys in the environment, the package in the header, two server modules and a
migration copied into the app, three endpoint files written out, a `<script>` in the layout and a
second `--static` on the server's command line, then the button. Email and Audio can't leave the
platform at all, because a package can't give an app a table, a dev page, a job or a script.

The direction you gave on 2026-11-21: a package's server module exports a `Plugin(ctx)` value, the
app lists it in `App.program({ …, plugins: [...] })`, and the plugin carries its contributions as
values (routes, middleware, migrations, jobs, crons, static files embedded with
`import "static/sw.js" as sw : Str`), namespaced by the plugin's own name. This document works out
what that looks like for the app's author.

## What an app's author should get

1. **Installing is two lines.** The header names the package; `main.roc` lists its plugin. Nothing
   is copied into the app's tree, nothing is written into its `routes/` or `migrations/`.
2. **Using it is a function call.** `Email.send!(message)` in a job, `Audio.play!(url)` in a
   handler, `<PushButton />` in a page: as the platform's own modules read today.
3. **Configuration is typed Roc**, with defaults. A plugin that needs a secret reads its documented
   environment variable unless the app passes something else.
4. **The app decides where and in what order.** Route prefixes are the app's (with defaults);
   middleware order is the app's alone; dev-only parts appear only under `--dev`.
5. **Nothing is hidden.** What a plugin adds (routes, tables, jobs, scripts) is listed, under the
   plugin's name, where the app's own are listed (the start-up log, `/openapi.json`, the jobs page).
6. **Any piece can be taken over.** A plugin's handlers are exported functions, so an app that wants
   different behaviour at one route turns that route off and mounts its own.
7. **The browser side comes with it.** A plugin's scripts and browser effects reach every page; no
   `<script>` tag, no second `--static`.

## The same app, three ways

An app with email (send from jobs, a dev mailbox), push (a button, endpoints, a table, a job, a
service worker), MCP (one route and its OAuth metadata) and audio (a sound from a click handler).

### A. Plugins listed in the program (recommended)

```roc
# main.roc
app [program] {
	pf: platform "../server/platform/main.roc",
	email: "../packages/email/main.roc",
	push: "../packages/push/main.roc",
	mcp: "../packages/mcp/main.roc",
	audio: "../packages/audio/main.roc",
}

import email.Email
import push.Push
import mcp.Mcp
import audio.Audio
import Generated/App
import Tools

program = App.program({
	plugins: [
		Email.plugin({ from: "Acme <hello@example.com>" }),   # SMTP_URL; without it, the outbox
		Push.plugin({ at: "/push" }),                               # VAPID_* from the environment
		Mcp.plugin({ at: "/mcp", tools: Tools.all }),
		Audio.plugin,
	],
})
```

Everywhere else the app reads as it does today:

```roc
# Jobs.roc
welcome = Job.define("welcome", |{ to }| Email.send!({ to, subject: "Welcome", text: "…", html: "" }))

# routes/+page.rocx
<PushButton />
<button on:click={|_| Audio.play!("/sounds/ding.wav")}>Ding</button>
```

What each plugin adds, without another line:

| Plugin | Adds |
|---|---|
| `Email.plugin` | the outbox table (`email/0001_outbox`); the send job, retried; `/__rocx/mail` and its JSON under `--dev`; a look at the SMTP server at start |
| `Push.plugin` | the subscriptions table; the delivery job; `GET /push/key`, `POST /push/subscribe`, `POST /push/unsubscribe`; `/push-sw.js` at the root (a service worker's scope); the page's script on every page |
| `Mcp.plugin` | `POST`/`GET /mcp`; `/.well-known/oauth-protected-resource` |
| `Audio.plugin` | the player script on every page (the effect `Audio.play!` calls) |

### B. Installed by naming it in the header (auto-discovery)

```roc
app [program] { pf: platform "…", email: "../packages/email/main.roc", push: "../packages/push/main.roc", … }

program = App.program({ email: { from: "Acme <hello@example.com>" }, push: { at: "/push" } })
```

One line fewer, as Nuxt modules and Laravel's package discovery do. But naming a package then does
something nobody can see in the code, there's no single place that says what's installed, and a
pure package (charts, forms) and a plugin look the same in the header. Configuration would need a
field per plugin in the program's record, which the platform can't know in advance.

### C. No plugins: the app mounts each piece

```roc
program = App.program({
	migrations: Push.migrations.concat(Email.migrations),
	jobs: [Push.deliver, Email.sender],
})
# routes/push/key/+server.roc:        get! = Push.key_route!
# routes/push/subscribe/+server.roc:  post! = Push.subscribe_route!
# routes/push/unsubscribe/+server.roc: post! = Push.unsubscribe_route!
# routes/__rocx/mail/+server.roc:     get! = Email.mailbox_page!
# routes/mcp/+server.roc:             post! = Mcp.post!   (and get!, and the .well-known file)
# layout: <script src="/push.js"></script>, and a route serving each static file
```

Fully explicit, and close to what works today once server modules can come from a package. But
five places to touch per package, a forgotten one fails at run time (a job with no table, a button
with no endpoint), and a service worker or a dev-only page needs special handling in every app.

**Recommended: A, with C's pieces exported.** The plugin is the one line most apps write; the
handlers, migrations and jobs it bundles stay public, so an app can take one over (below).

## The details, from the app's side

### Configuration

A plugin's options are a record with defaults (Roc's `??` field defaults), so the common case is
`Email.plugin({})` or `Audio.plugin`. A secret comes from the environment at run time, under a
documented name, unless the app gives a function that finds it elsewhere:

```roc
Push.plugin({ at: "/push" })                                    # VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
Push.plugin({ at: "/push", keys!: |{}| Vault.vapid_keys!({}) })  # the app's own
```

`program` is a value, built before the server runs, so a plugin's options are values or functions
(`keys!`), never effects run while the program is made.

### What a plugin knows of the app

`Plugin(ctx)` is generic in the app's context (what its default middleware hands a route: the
signed-in user, the locale). A plugin's routes get that context without knowing its type; where a
plugin needs something from it, the app says how to find it, and the compiler checks the function:

```roc
Push.plugin({ at: "/push", user: |context| context.member })   # whose subscription this is
Admin.plugin({ at: "/admin", allowed: |context| context.role == Admin })
```

The same goes for what `rocx build` writes: `main.roc` imports `Generated/App`, so it can hand a
plugin the app's endpoints, which no package could import itself (mcp's tools made from them):

```roc
Mcp.plugin({ at: "/mcp", tools: McpTools.from(Api.endpoints) })
```

That is a reason for A over B: a plugin's options are written where the app's own values are in
scope.

### Calling a plugin from the app's code

A plugin's functions are ordinary module functions, imported with the package's flat name (your
answer: `import email.Email`, no `server` segment). `Email.send!(message)` needs no handle: it reads
the same environment the plugin does. Where a call needs configuration the app made (an S3
bucket), the app keeps the value in a module of its own, as with `packages/s3` today.

### Where its routes go

A plugin's routes sit under the prefix the app gives (`at:`), with a default. A few paths are
fixed by the web, not by the app: a service worker's scope (`/push-sw.js`), `/.well-known/…`; a
plugin declares those as root paths. Two routes at one path (the app's and a plugin's, or two
plugins') stop the server at start, naming both. Silently letting the app win would hide a typo.

Its endpoints join the app's: they're in `/openapi.json` under the plugin's name, and they pass
through the app's default middleware (so the app's auth guards a plugin's admin page).

### Middleware

A plugin never adds middleware to the app's chain: order is the app's. A plugin that offers
middleware (guard's rate limits and security headers, otel's request metrics) exports it, and the
app places it:

```roc
default = signed_in.then(Guard.security_headers(Security.defaults)).then(Otel.measure)
```

A plugin may wrap its own routes in middleware of its own (MCP's bearer check).

### Tables

A plugin's migrations are named `<plugin>/<name>` (`push/0001_subscriptions`), by the name the
plugin declares, not the app's alias, so renaming the alias never runs one again. They run after the
platform's own and before the app's. Removing a plugin leaves its tables: dropping data is the
app's decision.

### The browser

A plugin's scripts are values (`import "static/push.js" as script : Str`). The server serves each at
`/rocx/plugins/<plugin>/<file>` and adds a `<script type="module">` for it to every page, beside
`/rocx/start.js`. A file the web needs at a fixed path (a service worker) is a root route. A browser
effect (`Audio.play!`'s player) is a script that registers it, so `Browser.call!`'s mechanism carries
it, and `rocx:`-prefixed builtins in `runtime.js` can go.

### Paths before the app

A few paths belong to the platform's tools, not the app: the dev mailbox, the stories catalog,
packages/testing's hooks (`/__rocx/test/*`). A plugin may declare routes under `/__rocx/<plugin>/`
that are answered before the app's middleware, and only under the flag they name (`--dev`,
`--debug`, `--test`), so the app's auth never hides them and production never has them.

### Background work

A plugin may run loops (otel's exporter, presence's sweeps) and checks at start (email's look at
the SMTP server; S3's look at the bucket could come back as an optional `S3.plugin(bucket)`). The
start-up log names each with its plugin.

### Development and tests

- Dev-only routes (the mailbox) exist only under `--dev`; debug-only ones (its JSON, which
  packages/testing reads) only under `--debug`.
- The start-up log lists each plugin and what it added.
- A plugin's own checks at start (email's look at the SMTP server, S3's at the bucket) are logged as
  the platform's are now.

### Taking a piece over

```roc
Push.plugin({ at: "/push", routes: Off })   # the table, the job and the scripts, but no endpoints
# routes/push/subscribe/+server.roc
post! = |{ body, context, .. }| Push.subscribe!(body, context.user)   # with the signed-in user
```

## Not covered: plugins for the build

Some packages want work done when the app is built, not when it runs: markdown's content
collections (a typed module per folder of posts), intl's message keys and CLDR data per locale,
forms' body schemas in `/openapi.json`. That is a second kind of plugin, one `rocx build` runs (as
Astro's integrations and Vite's plugins do), and it is a separate design. This document covers what
an app's server and pages get when it runs.

## What this asks of packages and the platform (for later)

Sketched only, to check that A is buildable:

- **A `Plugin` type in the server platform**: a name, and lists of routes (method, path, handler,
  dev or debug only), migrations, jobs, crons, actors, static files and scripts, and checks.
  `App.program` takes `plugins` and merges them: migrations and jobs namespaced, routes into the
  router after the app's own (clashes refused at start), scripts into the page.
- **Server modules from packages**: `rocx build` copies a package's `server/*.roc` into the server
  half's `Generated/<package>/` (as components are copied today), so `import email.Email` resolves on
  the server and never reaches the browser. The browser half's equivalent (`browser/*.roc`) carries
  modules that call `Browser.call!`, such as `Audio`.
- **The platform's own pieces** that Email needs: a store that outlives a request without a
  database (the mailbox keeps 100 messages in host memory today; guard, presence and otel ask for
  memory-only state too, and the no-locks rule applies), the `--dev`/`--debug` flags readable by a
  plugin, a public `AdminHtml` (the mailbox's and the jobs page's look), and moving the platform's
  `rocx/0002` outbox table to a name the plugin owns without losing existing rows.
- **Background loops** are a fixed union in the platform today (`[Work, Schedules, CheckMail]`);
  plugins need to add their own.
- **Typing the list.** A plugin's middleware for its own routes is `Middleware(ctx, ctx)`, so a
  `List(Plugin(ctx))` has one type. Chaining middleware with `then` has hit an `--opt=speed`
  miscompile before (test/compiler-bugs/), and walking a list of records holding functions has
  crashed `--opt=speed` builds when the list is empty; both need checking early.
- **Endpoints a component calls** (`<PushButton>` asks `/push/key`): the component takes the
  plugin's prefix as a prop with the same default.

## Questions for you

1. **A, B or C?** (A recommended: a `plugins` list in the program.)
2. **Route clashes:** stop at start naming both (recommended), or the app's route wins?
3. **Secrets:** a plugin reads its documented environment variables unless the app passes a
   function (recommended), or the app always passes them?
4. **Browser scripts:** on every page (recommended: few and small), or only on pages whose layout
   asks?
5. **Build-time plugins** (content collections, message keys): design them next, or later?
