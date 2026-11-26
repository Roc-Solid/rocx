## Roc Solid (rocx)

This app is built with Roc Solid, through the `rocx` command: Roc on the server and in the
browser, `.rocx` components, routes from files. `.rocx/` is the version it builds with: a link
each checkout makes, never committed, and `.rocx-version` names it. Before you write routes,
pages, components or middleware, read `.rocx/agents/guide.md`: how an app is laid out and the
mistakes to avoid, with pointers into the references (`.rocx/web/README.md`,
`.rocx/server/README.md`, each package's README under `.rocx/packages/`, and
https://roc-solid.github.io/).

The rules that matter most:

- Finish with `rocx check` (both programs, each problem at its `.rocx` line) and `rocx test`;
  format with `rocx fmt <paths>`. `rocx dev` serves the app, rebuilt as you save.
- Edit sources only: never `Generated/`, the `.roc` rocx writes beside each component's `.rocx`,
  `build/`, `dist/`, or anything under `.rocx/`.
- A path is a page or an endpoint, not both. A page's data and its forms' actions are an endpoint
  at the same path under `routes/api/`: `routes/lists/[id]/+page.rocx` reads
  `routes/api/lists/[id]/+server.roc`.
- Every handler is annotated, `=> Try(Answer, Endpoint.Refusal)`, and rocx copies its types into
  `Generated/Api`. `Ok` is sent as JSON. A handler whose every answer is a response of its own (a
  file, a redirect that sets a cookie) is annotated `Try(Server.Response, Endpoint.Refusal)`.
- Pages read with `Api.get_…(params).read!()` (answered while the page renders, and carried with
  it) and send with `.send!(arg)`. Forms post to an endpoint (`Endpoint.url_of(…)`) and work
  without JavaScript; `use_submission!` reads what came back.
- Middleware is by folder: `+middleware.roc` wraps its directory and everything under it, and a
  `(name)/` folder groups routes without adding to their path. A route file never names middleware.
- Data that changes: read it in a memo, hand components the accessor, `refresh!` it, and key rows
  by a stable id (`key={post.id}`). Never key a view on the whole answer (`key={data}`): every new
  answer would remount it, and its video, focus and animations with it.
- Settings and secrets come from the environment (`Env.var!`); a `.env` is read only through
  `--env-file` (`rocx dev` passes the folder's own). Outside `--dev`, a plugin missing a setting it
  needs (email's `SMTP_URL`, AI's key) stops the server as it starts, on purpose.
