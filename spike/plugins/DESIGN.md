# Design: plugins

> A design spec, 2026-11-21. Nothing here is built. It turns the app's side settled in
> `CLIENT-API.md` into what a package, `rocx build` and the server platform do, in three phases.
> When phase 1 lands it becomes a decision of its own (D-027 and D-028 are taken).
>
> **Decided (the user, 2026-11-21):** plugins are listed in `App.program({ plugins: [...] })`; each
> plugin declares what it needs as its own options type; two claims on one path stop the server at
> start, naming both; a plugin reads its documented environment variables unless the app passes a
> function; imports are flat (`import email.Email`); static files and migrations travel as values,
> namespaced by the plugin's own name. **Proposed here:** everything else, marked where it matters.

## 1. Summary

A plugin is a value of the server platform's type `Plugin(ctx)`: what a package adds to an app (its
routes, tables, jobs, schedules, actors, files, scripts, loops and checks) and what it needs to run
(environment variables, a database, other plugins). A package makes one from options of its own
(`JobsPage.plugin({ at, guard })`). The app lists them in its program; `App.program` merges their
routes, tables and jobs with the app's own, and hands the platform what only it can run: paths
answered before the app, files, scripts, loops and checks. At start the server checks every name,
path and need, applies plugins' migrations in the order their needs imply, and logs what each plugin
added.

```roc
# main.roc
app [program] {
	pf: platform "../server/platform/main.roc",
	admin: "../packages/admin/main.roc",
	email: "../packages/email/main.roc",
	push: "../packages/push/main.roc",
}

import admin.JobsPage
import email.Email
import push.Push
import Generated/App
import Middlewares

program = App.program({
	context: |started| { started },
	middleware: Middlewares.default,
	crons: [],
	plugins: [
		Email.plugin({ from: "Acme <hello@example.com>" }),
		Push.plugin({ user: |context| context.member }),
		JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin }),
	],
})
```

## 2. Goals and non-goals

**Goals.**
- Everything `CLIENT-API.md` promises an app: two lines to install, typed options with defaults,
  nothing copied by hand, nothing hidden, any piece replaceable.
- Email, Audio and the jobs page can leave the platform (D-025's rule: a platform module stays only
  if it needs the host or the transpiler), and push, mcp, presence, guard and otel lose their manual
  setup steps.
- Plugins compose: one plugin can be built on another's functions, and can require it installed.
- Mistakes surface early: in the compiler where it can see them, otherwise at start, never at the
  first request.

**Non-goals.**
- Plugins that run while the app is built (markdown's content collections, intl's message keys):
  a separate design (`CLIENT-API.md`, "Not covered").
- Loading plugins at run time, from outside the app's build. A plugin is Roc compiled into the app.
- Several instances of one app sharing plugin state (one instance per app).
- Plugins that change what the platform itself does: they add to an app; they don't replace the
  router, the job workers or the renderer.

## 3. A plugin package

```
packages/email/
  main.roc               # the pure package: Message, MIME, SMTP's protocol, checked by expects
  server/                # modules that import the server platform: copied into the server's half
    Email.roc            #   send!, plugin, Options
    Mailbox.roc          #   the dev mailbox's pages
    main.roc             #   optional: names this repo's server platform, for `roc check` alone
  components/            # copied into both halves: .rocx components, and .roc modules that use pf
  migrations/0001_outbox.sql
  static/                # files the plugin serves, embedded by its server modules
  README.md
```

- **`main.roc`** stays a package on no platform, named in the app's header as any package is.
- **`server/*.roc`** are copied by `rocx build` into the server half's `Generated/<alias>/`, where
  `pf` is the server platform the app names (the way `components/` are copied today, for both
  halves). They never reach the browser's half, so they may import `pf.Db`, `pf.Job`, `pf.Plugin`.
  `server/main.roc`, if a package keeps one, is not copied: it only lets `roc check` see the modules
  without an app.
- **`components/`** may hold `.roc` modules as well as `.rocx` ones: a module the browser's code
  calls that needs the platform (`Audio.play!` calls `Browser.call!`). They are copied into both
  halves, as components are, since a component's handler type-checks on both.
- **`migrations/` and `static/`** aren't copied anywhere: a server module embeds each file
  (`import "../migrations/0001_outbox.sql" as outbox : Str`, `import "../static/sw.js" as sw :
  List(U8)`) and puts it in the plugin's value.

**Flat imports.** `import email.Email` in the app means the copy of `server/Email.roc` on the
server's half (`Generated/email/Email.roc`), a copied component or `components/X.roc` on either
half, or the pure package's module otherwise. A name in two of those places (`Email.roc` in `main.roc`'s
package and in `server/`) is a build error naming both: a package's names are its own to keep apart.
On the browser's half, an import that resolves only to a server module is a build error at the
importing line ("Email is the email package's server module; the browser's half can't import it"),
where today the browser's build fails later, on that module's own imports.

## 4. The `Plugin` type

A new module in the server platform, exposed. A plugin is a nominal record, so every field but
`name` has a default and a plugin says only what it adds:

```roc
Plugin := [].{
	Value(ctx) := {
		name : Str,                                          # "email": the namespace of everything below
		routes : List(Route(ctx)) ?? [],                     # inside the app's middleware
		early : List(Early) ?? [],                           # before it, under a flag
		files : List(File) ?? [],                            # served as they are
		scripts : List(Str) ?? [],                           # files (by path) every page loads
		migrations : List({ name : Str, sql : Str }) ?? [],
		jobs : List({ name : Str, attempts : U64, timeout_ms : U64, run! : Str => Try({}, Str) }) ?? [],
		crons : List({ name : Str, schedule : Str, job : Str, input : Str }) ?? [],
		actors : List(Actor.Handler) ?? [],
		loops : List({ name : Str, run! : {} => {} }) ?? [],
		checks : List({ name : Str, run! : {} => Try({}, Str) }) ?? [],
		needs : List(Need) ?? [],
	}

	## A route the app's middleware has passed: what that middleware handed on is `ctx`.
	Route(ctx) : { method : Str, path : Str, kind : [Page, Endpoint], answer! : Server.Request, ctx => Server.Response }

	## A path the platform answers before the app, only when the server was started with `under`:
	## under `/__rocx/<plugin>/`, so the app's paths and its auth never meet it.
	Early : { method : Str, path : Str, under : [Dev, Debug, Test], answer! : Server.Request => Server.Response }

	## A file served as it is: at `/rocx/plugins/<plugin>/<path>`, or at `/<path>` when the web
	## fixes where it must be (a service worker's scope, `/.well-known/…`).
	File : { path : Str, at : [Plugin, Root], content_type : Str, body : List(U8) }

	## What a plugin needs that the compiler can't see.
	Need : [Env(Str), Database, Plugin(Str)]
}
```

Rules the server checks at start (section 6), so a plugin author meets them in the first run:

- `name` is lowercase letters, digits and `-`, unique among the app's plugins.
- Jobs, crons, actors, loops and checks are named `<plugin>.<name>` (`push.deliver`), as push's job
  is already. A job is enqueued by its kind's name, so the platform can't add the prefix itself; it
  refuses a name without it.
- Migrations are recorded as `<plugin>/<name>` (`push/0001_subscriptions`): only the platform reads
  these names, so it adds the prefix. The plugin's `name`, not the app's alias, so renaming the
  alias never runs one again.
- Early paths start with `/__rocx/<plugin>/`; file paths are relative (`sw.js`).

**Generic in the app's context.** `ctx` is what the app's middleware hands a route (the signed-in
user, the locale). A plugin's routes get it without knowing its type; where a plugin needs something
from it, its options say how to find it (`user : ctx -> Str`), so the compiler checks the app's
function. One list holds every plugin because each is a `Plugin.Value(ctx)` of the same `ctx`.

**A guard.** A plugin that takes the app's middleware as its guard (`guard : Middleware(ctx, out)`)
wraps its own routes in it and ignores what it hands on, so `out` never reaches `Value(ctx)`. The
pinned compiler fills `??` defaults, refuses a record missing a required field, and keeps `out` out
of the result (`CLIENT-API.md`, "Each plugin declares what it needs"); it also embeds a file as
bytes (`import "sw.js" as sw : List(U8)`), which `File` relies on.

## 5. What `App.program` does with them

`rocx build` writes `App.Config` with one more field, and `App.program` merges:

```roc
Config(given, handed) := {
	context : Str -> given,
	middleware : Middleware(given, handed),
	crons : List({ name : Str, schedule : Str, job : Str, input : Str }),
	openapi : OpenApi.Serving ?? Off,
	plugins : List(Plugin.Value(handed)) ?? [],
}
```

- **Routes.** A request runs the app's middleware as now, then the router: a plugin route whose
  method and path match answers it, otherwise `Routes.respond!` (the app's files). Clashes are
  refused at start, so the order between them never decides anything. A plugin route's path may
  have `[param]` segments, matched as the app's are, and `request.route` (D-026) is its pattern.
- **Migrations**: the platform's own, then each plugin's in the order section 6 sets, then the
  app's `migrations/*.sql`. An app's table may refer to a plugin's (a foreign key to auth's users);
  never the other way.
- **Jobs, crons, actors**: concatenated with the app's. The jobs page lists a plugin's with the
  rest.
- **Handed to the platform** (new fields of `program`, section 6): `early`, `files`, `scripts`,
  `loops`, `checks`, and each plugin's name, needs and route claims, for the checks and the log.

The platform's `requires` grows to:

```roc
program : {
	respond! : Str, Str, Str, List(U8), Str => Server.Response,
	migrations : List({ name : Str, sql : Str }),
	jobs : List({ name : Str, attempts : U64, timeout_ms : U64, run! : Str => Try({}, Str) }),
	crons : List({ name : Str, schedule : Str, job : Str, input : Str }),
	actors : List(Actor.Handler),
	logs : { format : [Auto, Pretty, Json] },
	plugins : List({
		name : Str,
		needs : List(Plugin.Need),
		claims : List({ method : Str, path : Str }),
		migrations : List({ name : Str, sql : Str }),
		early : List(Plugin.Early),
		files : List(Plugin.File),
		scripts : List(Str),
		loops : List({ name : Str, run! : {} => {} }),
		checks : List({ name : Str, run! : {} => Try({}, Str) }),
	}),
	routes : List({ method : Str, path : Str, file : Str }),
}
```

`routes` is the app's own route table, which `rocx build` writes (`Routes.claims`) so the platform
can compare it with the plugins'. A plugin's migrations travel in `plugins` rather than in
`migrations`, so the platform can name and order them.

## 6. Start

`init_for_host!` gains a step before anything is applied, then runs as it does now:

1. **The log's format**, as now.
2. **Check, all at once.** Every problem below is collected, and any one stops the server with the
   whole list, one line each:
   - two plugins with one name; a name or prefix rule from section 4 broken;
   - two claims on one method and path: the app's route file and a plugin, two plugins, or a file
     and a route ("GET /push/key: routes/push/key/+server.roc, and the push plugin");
   - a need not met: an environment variable unset or empty ("push: VAPID_PRIVATE_KEY isn't set"),
     a database without `--database-url`, a plugin not in the list ("auth needs the email plugin,
     which isn't in plugins");
   - needs that form a cycle ("auth needs email, which needs auth").
3. **Order.** Plugins sorted by their `Plugin(…)` needs, the app's list order breaking ties: the
   order migrations run in, and the order the log lists them in.
4. **Registry, schedules, actors**, as now, with the plugins' jobs, crons and actors among the app's.
5. **Migrations**: the platform's, the plugins' (in order), the app's.
6. **Jobs a stop cut short** queued again, as now.
7. **The host is told** the scripts (`Host.page_scripts!`, as it is told the kinds of actor) and
   the number of background loops.
8. **The log**, a line a plugin: "push: 3 routes, 2 files, 1 script, 1 table, 1 job".

Checks (`checks`) run once each in the background after start, as the mail check does now, and log
what they find; a failing check doesn't stop the server (S3 or SMTP being down at start isn't the
app's fault). Loops (`loops`) run each on a thread of its own until the server stops, started again
a second after a crash, as the job workers are.

## 7. Answering a request

`respond_for_host!` answers, in order:

1. An **early** path, when the server has the flag it names (`--dev`, `--debug`, `--test`); without
   the flag the path is the app's like any other, so production answers 404.
2. A plugin's **file**: `/rocx/plugins/<plugin>/<path>`, or its root path. `GET` and `HEAD` only,
   with its `content_type` and an ETag of its bytes.
3. The app: `program.respond!`, its middleware, then plugin routes and its own (section 5).

This replaces `Outbox.serves!`: the mailbox becomes the email plugin's early routes.

## 8. The browser

- **Scripts.** The host adds `<script type="module" src="/rocx/plugins/<plugin>/<file>">` for each
  script before `/rocx/start.js`, with the same base path start.js gets on a site served under one
  (the static docs on Pages). Every page loads them: few and small. A plugin with a heavy script
  loads the rest itself, when it is needed.
- **Effects.** A script registers a browser effect as page code does today
  (`globalThis.rocxEffects["audio.play"] = …`), named `<plugin>.<effect>`; `Browser.call!` finds it.
  The runtime gives effects what they can't reach otherwise as a second argument, `{ under }` (the
  site's base path applied to a URL), which Audio's player needs. The runtime's `rocx:` builtins go
  once Audio has moved.
- **Modules.** `Audio.play!` is `packages/audio/components/Audio.roc`, copied into both halves, calling
  `Browser.call!("audio.play", …)`. The app's code doesn't change but for `import audio.Audio`.

## 9. Plugins that need plugins

Three levels; the first two need nothing new.

**Code.** A package names another in its header (s3 and push name crypto today). An app that names
the first gets the second through it.

**Capabilities.** A plugin built on another's functions declares them in its options, and the app
passes them in `main.roc`. The compiler checks the shapes; nothing is looked up by name, and the
whole wiring is in one file:

```roc
plugins: [
	Email.plugin({ from: "Acme <hello@example.com>" }),
	Auth.plugin({ send!: Email.send! }),                  # sign-in links go out by email
	JobsPage.plugin({ guard: Auth.admins }),              # Auth's middleware guards the jobs page
	Push.plugin({ user: Auth.user_id }),                  # Auth knows whose subscription it is
]
```

(`Auth` is an example, not a package yet.) Where many plugins want one kind of capability, its type
lives with what it describes: a platform capability in the platform (`Db.Effects : { all!, run!,
transaction! }`, with `Db.effects` the host's), anything else in the providing package. A plugin
that declares `db : Db.Effects` then works with the host's `Db` or with a Postgres client on `Tcp`
from a package, and the app chooses. `packages/admin` takes `{ all!, run!, random! }` this way
already.

**Installed.** When a plugin needs another's tables, jobs or loops to exist, not only its functions
(auth's sign-in links go through email's outbox and send job), it says so: `needs: [Plugin("email")]`.
Passing `Email.send!` doesn't prove the email plugin is in the list; the need does, at start
(section 6), and orders the two. A plugin never reaches into another's tables: what it needs from
another is a function the other exports.

## 10. Errors, as an app's author meets them

| Mistake | Where | What it says |
|---|---|---|
| a required option left out | compile | "This record is missing the field: guard", at the `plugins` line |
| an option of the wrong type | compile | the usual mismatch, naming the plugin's `Options` type |
| a server module imported in a page | build | "Email is the email package's server module; the browser's half can't import it" |
| two names in one package | build | "email has Email in main.roc and in server/" |
| two claims on one path | start | "GET /push/key: routes/push/key/+server.roc, and the push plugin" |
| an unmet need | start | "push: VAPID_PRIVATE_KEY isn't set"; "auth needs the email plugin, which isn't in plugins" |
| a cycle | start | "auth needs email, which needs auth" |
| a name without its prefix | start | "push: the job deliver is named push.deliver, with the plugin's name first" |
| a check failing | log, after start | "email: the SMTP server at smtp.example.com:587 refused: …" |

## 11. Phases

**Phase 1: the type, and the jobs page.**
- `Plugin` in the server platform: `name`, `routes`, `migrations`, `jobs`, `crons`, `actors`,
  `needs`.
- `App.Config.plugins`; the router; `Routes.claims`; the checks, order and log of section 6.
- `rocx build` copies `server/*.roc` and resolves flat imports, with section 3's errors.
- `JobsPage` and `AdminHtml` move to `packages/admin`, as `JobsPage.plugin({ at, guard })`, with
  `JobsPage.respond!` kept for apps that mount it themselves. The platform gains `Job.kinds!` (today
  `Registry.kinds!`) and `Job.changes` (the live topic `rocx:jobs`).
- A fixture plugin in the server tests: a route, a migration, a job, a need.

**Phase 2: what runs beside the app.**
- `early`, `files`, `scripts`, `loops`, `checks`; `Host.page_scripts!`; effects' `{ under }`;
  `components/*.roc`.
- Audio moves (`packages/audio`). Push adopts a plugin: its endpoints, its table and job, its service
  worker at the root, its script; its README's six steps become one line.
- Email moves: its send job, the mailbox as early routes on `Kv` (D-028: no table), the SMTP
  check.

**Phase 3: endpoints and the rest.**
- A plugin's endpoints in `/openapi.json` (tagged with the plugin's name) and readable from
  components (`Endpoint.get!`) with the plugin's prefix.
- mcp, presence, guard and otel as plugins where they have something to add.
- Plugins for the build: their own design.

## 12. Tests

- **The fixture plugin** in `server/test/`: its route answers inside the app's middleware with the
  app's context; its migration is recorded as `fixture/0001_…`, and renaming its alias in the
  test app doesn't run it again; its job runs; its early route answers only under `--dev`; its file
  and script are served, and a page carries the script's tag.
- **Refusals at start**, one test each: a clash with an app route, a clash between plugins, an unset
  variable, a missing plugin, a cycle, a job without its prefix. Each checks the whole message.
- **The jobs page as a plugin**: D-011's tests, against the plugin, and one where `guard` refuses.
- **`--opt=speed`**: the test app built optimized with no plugins, one, and three (section 13).
- **Docs**: the platform reference lists `Plugin`; `/ecosystem` says which packages are plugins.

## 13. Risks

- **The compiler.** A list of records holding functions has crashed `--opt=speed` builds when the
  list is empty (`program.jobs`), and a chain of three `Middleware.then` once skipped its last step
  (test/compiler-bugs/). `plugins` is both shapes. Phase 1 builds the test app optimized with zero,
  one and three plugins before anything else, and reduces any failure to a case for the fork.
- **Flat imports.** Resolving one name to the server copy on one half and the package on the other
  is new in `rocx build`; a module name in two places of one package must stay an error, never a
  silent pick.
- **Base paths.** Script and file URLs must follow start.js's base path, or the static docs break.

## 14. Open questions

1. ~~Memory without a database~~: **`Kv`** (D-028), which the mailbox uses already.
2. **Where the jobs page lives**: `packages/admin` beside the tables admin (assumed above), or a
   package of its own.
3. **Plugin endpoints read from components**: a component of the plugin's builds its `Endpoint`
   from the prefix (`<PushButton at="/push">`), or `rocx build` adds plugins' endpoints to `Api`.
4. **Plugins for the build**: designed next, or later.
