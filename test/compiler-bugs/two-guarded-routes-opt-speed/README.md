# Two routes guarded by a capturing middleware crash an `--opt=speed` server at start

Found 2026-11-22 on nightly-2026-11-18-a520eed and on the fork rocx builds with (3f66e242ea), while
making the jobs page a plugin (D-033, D-034): `JobsPage.plugin({ at, guard })` gives two routes (GET
and POST at `at`), each a closure that runs the app's `guard` (a `Middleware`) before the page.
Built with `--opt=speed`, the e2e app (test/e2e/app, its `guard` a middleware of its own) exited with
SIGSEGV as it started, before its first line of log; `--opt=dev` was right. The server's test app,
whose guard captures nothing, was fine.

Reduced, on the server platform's `Plugin` and `Middleware`:

- **Bad.roc**: a plugin whose two routes each capture one middleware made by
  `Middleware.headers([…])` (its function captures a list), and a program that keeps
  `plugins.map(Plugin.running)`. Crashes at start.
- **AppShape.roc**: the same, as rocx's Generated/App has it (a nominal `Config` with `??` defaults,
  the app's middleware around the plugins' routes). Crashes at start.
- **NoCapture.roc**: Bad.roc with a middleware whose function captures nothing. Works.

It needs all of: two closures (one route works, and so do two routes that don't capture the
middleware), a middleware whose function captures something, and the program mapping the plugins
(`Plugin.running`; without it the server runs). The context's type doesn't matter (`Str` here,
`{ started : Str }` in the app). A copy without the platform's types (a local middleware type and
plugin record) doesn't crash: not reduced further.

    ROC=…/roc ./repro.sh

    AppShape  --opt=dev   GET /doc -> get, POST /doc -> post
    AppShape  --opt=speed exited (139) before it listened
    Bad       --opt=dev   GET /doc -> get, POST /doc -> post
    Bad       --opt=speed exited (139) before it listened
    NoCapture --opt=dev   GET /doc -> get, POST /doc -> post
    NoCapture --opt=speed GET /doc -> get, POST /doc -> post

The same with the nightly and with the fork up to 3f66e242ea.

**Fixed** in the fork since 9fcf362c0c: every program above answers under `--opt=speed` too. The fix is
upstream's: upstream main 9e28b549e3 answers as well, without the fork's own fix for
`list-map-reuse-opt-speed`. Most likely it is ae32726512, which the fork took with that fix: under
`--opt=speed`, a `List.map` over closures (here `plugins.map(Plugin.running)`) read each item as a
closure with no callable set, and calling one crashed. `JobsPage.plugin` is back to a GET and a POST route; for a day it gave one route,
for every method at `at` (`*`), so one closure captured the guard.
