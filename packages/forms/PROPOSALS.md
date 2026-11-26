# forms: proposals for the platform

What packages/forms would change outside its own folder, if the user agrees. The package works
today without what is still proposed (see README.md, "Status"), and each proposal says what in the
package would use it. Since D-093 (2026-11-26), an endpoint's body is read and checked by a form
the route file names (`post_body = Signup.form`): proposal 3 is done that way, and proposal 2 in
part (the 422's issues labelled `application/json`, the platform's `Json` refusal). Each section: the problem, the options weighed, the one
recommended (with a sketch), what depends on it, and how it could be undone.

---

## 1. Server-only modules in packages

**Problem.** A package is plain Roc on no platform, or `.rocx` components that `rocx build` copies
into both halves of an app (`components/` → `Generated/<pkg>/`). A module that only the server
half can compile (one that imports `pf.Server`, `pf.Endpoint`, `pf.Middleware`, `pf.Db`…) has no
home: put in `components/`, it is copied into the browser's half too, where those modules don't
exist or mean something else.

For forms the need is small. The endpoint's glue is pure today, because the platform's types it
touches are structural: `Server.Request` is a record (a package function can take `{ body :
List(U8), .. }`), and a function's returned tag union is open, so `Issues.refusal` returns
`[Status(U16, Str)]`, which is an `Endpoint.Refusal`. What forms would put in a server-only module
is convenience with the platform's own names in its signatures:

```roc
# packages/forms/server/FormEndpoint.roc (server half only)
import pf.Server
import pf.Endpoint
import forms.Form
import forms.Issues

## An endpoint handler that reads the form, refuses with its issues, and hands the record on.
handler : Form(a), ({ request : Server.Request, params : p, context : c, form : a } => Try(r, Endpoint.Refusal)) -> ({ request : Server.Request, params : p, context : c, body : {} } => Try(r, Endpoint.Refusal))
```

and, with proposal 2, a middleware that refuses a form before its route runs.

**Options.**

1. A `server/` directory beside `components/`: `rocx build` copies its `.roc` and `.rocx` files
   into `Generated/<pkg>/` of the server half only, and leaves them out of `--client`. `import
   forms.FormEndpoint` is linked to the copy as a component's import is; a file the browser's half
   compiles that imports one is a rocx error at its line ("FormEndpoint is the server's: import it
   from a +server.roc or a server function's body"). A server function's body may use one, since
   the browser's copy drops the body and the imports only it used.
2. A second package that names the server platform (`packages/forms/server/main.roc` with
   `pf: platform "../../../server/platform/main.roc"`), named only in the server half's header.
   The compiler allows a package to name exactly the app's platform. But `rocx build --client`
   copies the server header's packages into the browser's (`headerPackages`), so it would have to
   learn to leave out a package that names a platform; and a package that names a path to a
   platform breaks when the app is elsewhere.
3. Nothing: keep server glue in the app (a few lines in each `+server.roc`), as forms does today.

**Recommended: 1.** It is the copy `components/` already has, with one more rule (server half
only), so a package stays one directory, one name in the header, and `pf` keeps meaning the half's
platform. A sketch of the change to `bin/rocx.mjs`:

```diff
 function componentPackages(dir) {
 	…
-			const components = join(root, "components");
-			if (found.has(name) || !existsSync(components)) continue;
-			const paths = [...files(components, ".rocx")];
-			found.set(name, { name, own: basename(root), paths, modules: new Set(paths.map((path) => basename(path, ".rocx"))) });
+			const components = join(root, "components");
+			const serverOnly = join(root, "server");
+			if (found.has(name) || (!existsSync(components) && !existsSync(serverOnly))) continue;
+			const paths = existsSync(components) ? [...files(components, ".rocx")] : [];
+			const servers = existsSync(serverOnly) ? [...files(serverOnly, ".rocx"), ...files(serverOnly, ".roc")] : [];
+			const moduleOf = (path) => basename(path).replace(/\.rocx?$/, "");
+			found.set(name, { name, own: basename(root), paths, servers, modules: new Set([...paths, ...servers].map(moduleOf)), serverModules: new Set(servers.map(moduleOf)) });
```

and in `build`, the `servers` copied as `paths` are (a `.roc` file as it is, a `.rocx` file
transpiled), except under `--client`, where `linkComponents` refuses an import of one of
`serverModules` from a file the browser's half keeps.

**What depends on it.** Nothing in forms today; `FormEndpoint` would come with it.
**Undo.** Remove the copy and the check; packages are pure Roc and components again.

---

## 2. A refusal with field issues

**In part since D-093:** `Issues.refusal` answers `Json(422, issues)`, which the platform sends as
`application/json`, and a checked endpoint refuses its form's issues so itself. The issues' shape is
still forms' own; what follows (a platform shape, RFC 9457) is still a proposal.

**Problem.** An endpoint refuses with `Endpoint.Refusal` (`BadRequest(Str)`, `Conflict(Str)`,
`Status(U16, Str)`, …), always sent as `text/plain`, and a browser reads any refusal as
`Server.Problem.Refused(U16, Str)`. Forms refuses with a 422 whose text is its issues' JSON
(`Issues.refusal`), and reads it back with `Issues.from_problem`. It works, but:

- the answer says `text/plain` and is JSON; a client that isn't Roc has to know the convention;
- `Server.explain(problem)`, which an app shows for any failure, shows that JSON to a person;
- `/openapi.json` documents every refusal as text;
- every package or app that validates input invents its own shape.

**Options.**

1. Keep the convention (422, the issues as JSON in the text), and document it.
2. A refusal of the platform's own for invalid input, with a shape the platform defines and
   strings for codes (the platform can't know a package's tag unions):

   ```roc
   # Endpoint
   Refusal : [BadRequest(Str), …, Invalid(List(Server.FieldIssue))]
   # Server
   FieldIssue : { field : Str, code : Str, params : List({ name : Str, value : Str }), message : Str }
   Problem : [HttpErr(Str), Refused(U16, Str), BadAnswer(Str), Invalid(List(FieldIssue))]
   explain : Problem -> Str          # Invalid: its messages, one a line
   # Submission
   issues! : Submission(arg, result) => List(Server.FieldIssue)   # [] unless the latest was Invalid
   ```

   sent as `422` with `content-type: application/problem+json` (RFC 9457):
   `{"type":"about:blank","title":"Unprocessable Content","status":422,"errors":[{"field":"age","code":"too_small","params":{"min":"18"},"message":"Enter 18 or more"}]}`.
   `Endpoint.answer` and the runtime read a 422 of that type back as `Invalid`, and the OpenAPI
   document lists the 422 with its schema beside the default refusal.
3. A refusal with any JSON body (`Json(U16, Str)`): smaller, but the browser still gets text, and
   nothing is typed.

**Recommended: 2.** Field errors are what every form has, Solid Start's and SvelteKit's forms hand
them back as data (`fail(422, { errors })`), and RFC 9457 is the shape other clients already read.
The codes as strings are what a translation table wants anyway: forms' `Issues.key` and
`Issues.params` already give exactly `code` and `params`. A sketch of `Endpoint.refused`:

```diff
 refused : Refusal -> (U16, Str)
 refused = |refusal|
 	match refusal {
 		…
+		Invalid(issues) => (422, problem_json(issues))
 	}
```

with `respond!` sending a 422's body as `application/problem+json` and `Server.flash_back` keeping
it as it keeps any body.

**What depends on it.** `Issues.refusal` would answer `Invalid(…)` (each issue as `key`, `params`,
`message`), `Issues.from_problem` would read `Invalid` too, and `LiveForm` would read
`submission.issues!()` instead of parsing the text. The codes come back as strings: forms would map
its own keys back to `Issues.Code` (`Issues.from_key`), and any it doesn't know to
`Custom(key, message)`.
**Undo.** Drop the tag from `Refusal` and `Problem`; `Issues.refusal` answers `Status(422, json)`
again.

---

## 3. A form's rules in `/openapi.json`

**Done another way (D-093).** A route file names the form its method's body is read with
(`post_body = Signup.form`); Generated/Api makes the contract `Endpoint.checked(…, Signup.form)`,
and `OpenApi.sent` documents a checked endpoint's body with `form.json_schema()`, as JSON, URL-encoded
and multipart. What follows is the proposal as it was.

**Problem.** rocx writes an endpoint's request schema from its handler's `body` type. A form's
endpoint has `body : {}` (the form reads the body itself, so that a box left unticked, which a
browser doesn't send, is the form's to judge, not a 400), so `/openapi.json` documents an empty
object, and only as `application/json`, while the rules (`minLength`, `pattern`, `format`,
`minimum`, `enum`, which fields are required) are in the form. Seen in the scratch app:

```json
"requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "properties": {}, "required": [] } } } }
```

**Options.**

1. A route file may say a method's body schema itself: `post_schema : Str`. rocx's Api writer
   passes it to `OpenApi.operation` in place of the one from the type (which already takes the
   schema as text), under both `application/x-www-form-urlencoded` and `application/json`.
2. The body's type carries the form: a nominal type whose `parser_for` reads a form body with the
   form's rules, and whose schema the OpenAPI format writes. A type can't hold a value (the form),
   so each form would need a type of its own and its parser written by hand: much more for each
   app to write.
3. A comment convention rocx reads (`## @body Signup.form`): text, not code; nothing checks it.

**Recommended: 1.** One definition, checked by the compiler, and a value forms already makes:

```roc
# routes/signup/+server.roc
## The schema of what POST takes, for /openapi.json.
post_schema : Str
post_schema = Signup.form.json_schema()
```

In `openApiDocument` (`src/routes.mjs`), for a method whose route file defines `<method>_schema`
(`definitions(source)` already lists a file's definitions), the file's module (`SignupServer`, as
`Generated/` names it) gives the schema:

```diff
 					.map((method) => {
 						const takes = ["POST", "PUT", "PATCH"].includes(verbOf(method));
-						return operation(verbOf(method).toLowerCase(), docs[method] ?? "", takes ? `OpenApi.body(${call(method)}, tags)` : '""', [`OpenApi.answer(${call(method)}, tags)`]);
+						const own = schemas.has(method) ? `${moduleOf(at.server)}.${method.replace("!", "")}_schema` : `OpenApi.body(${call(method)}, tags)`;
+						return operation(verbOf(method).toLowerCase(), docs[method] ?? "", takes ? own : '""', [`OpenApi.answer(${call(method)}, tags)`]);
 					}),
```

and `OpenApi.operation` listing the body under `application/x-www-form-urlencoded` as well as
`application/json`. With proposal 2, the operation also lists
the 422 and its schema. (Since D-054, `OpenApi.operation` takes the body's contents rather than a
schema, and `OpenApi.sent` lists a form's body three ways, JSON, URL-encoded and multipart, from its
type: this proposal's schema would go under the same three, its rules added.)

**What depends on it.** `Form.json_schema` (built and tested); the README's endpoint would gain
two lines.
**Undo.** Stop reading `<method>_schema`; the type's schema is used again.

---

## 4. Holding back a submit the browser knows is invalid

**Problem.** `on:submit` always prevents the browser's default (runtime.js, `bind`), and the
runtime only sends a submission no handler prevented. So a component can't say "not this time": a
form with `on:submit` is never sent by the runtime, and one without is always sent. `LiveForm`
lets every submit go, and the endpoint refuses it with the same issues: correct, but a round trip
for what the browser already knew, and the page waits for it.

(Today an app can leave `novalidate` off: the browser then holds a submit back itself for what the
inputs' attributes say, in its own bubbles and its own words. Checks across fields and the app's
own go to the endpoint either way.)

**Options.**

1. The runtime holds back a submit of a form marked held: in `submitted(event)`, a form with
   `data-rocx-hold` is prevented and not sent. An app writes `data-rocx-hold?={…}`, which rocx
   already writes as a computed boolean attribute. A `click` on the submit button still runs
   (pressing Enter in a field clicks the default button too), which is where a component learns
   that a submit was tried.
2. A handler that answers whether to go on (`on:submit.go={|| valid!()}`): Bool-answering handlers
   are new to the runtime and the transpiler.
3. `setCustomValidity` on each input through `Browser.call!`, so the browser's constraint
   validation holds the submit: the browser's bubbles again, and a call per field per keystroke.

**Recommended: 1**, a line in `web/runtime.js`:

```diff
 	submitted(event) {
 		if (event.defaultPrevented) return;
 		const form = event.target;
 		if (!form || form.localName !== "form") return;
+		// A form a component holds back (it knows it is invalid): not sent, the page stays.
+		if (form.hasAttribute("data-rocx-hold")) return event.preventDefault();
```

**What depends on it.** `LiveForm` would gain `tried!()` (from the submit button's `on:click`) and
a `<SubmitButton live={live}>` that marks it; the page's form would write
`data-rocx-hold?={live.held!()}`, held while any field has issues.
**Undo.** Remove the line; a held form is sent as any other.

---

## 5. Secrets out of the flash

**Done another way (2026-11-22).** The platform keeps a flash in the server's memory (the cookie
holds a random id, taken once), `Html` never writes a `value` into an `<input type="password">`,
and the page's note of the flash leaves out each field the page has as one. A `Secret` renders as
such an input, so no route needs to name its secrets. What follows is the proposal as it was.

**Problem.** A plain post (no runtime) that an endpoint refuses comes back with a flash: a cookie
(`rocx-flash`, HttpOnly, SameSite=Lax, 60 seconds) holding the form's whole body as posted, so
the page can show what was typed. A password is in it, sent back to the browser and up with every
request for that minute. `LiveForm` doesn't write a `Secret` back into the page, but the cookie
has it.

**Options.**

1. The endpoint names the fields to leave out of its flash: a route file's `<method>_secrets :
   List(Str)`, which `Endpoint.respond!` drops from the input before `Server.flash_back`. With
   forms: `post_secrets = Signup.form.secrets()`.
2. The platform leaves out fields whose names look secret (`password`, `*password*`, `token`): a
   guess, which misses `pin` and catches `password_hint`.
3. No fields in the flash at all, only the result or refusal: the page loses what was typed.

**Recommended: 1**, beside proposal 3's `<method>_schema` (the same reading of a route file's
definitions). In `Endpoint.respond!`:

```diff
-				PlainForm => Server.flash_back(request, { url: endpoint.url, input: Server.text_of(request), status, body })
+				PlainForm => Server.flash_back(request, { url: endpoint.url, input: without(Server.text_of(request), endpoint.secrets), status, body })
```

with `Endpoint.local` given the secrets the route file names (`[]` when it names none).

**What depends on it.** `Form.secrets` (built and tested), which `LiveForm` already uses to leave
secrets out of what it fills in.
**Undo.** Drop the field; the whole body is flashed again.

---

## 6. All of a submission's fields

**Problem.** A `Submission` gives one field as typed (`field!(name)`, `FormData.get`) and the arg as
the endpoint reads it (`input!()`), but not every value of a field that has several (boxes that
share a name: `topics=roc&topics=zig`). So `LiveForm` reads `Server.flash!` itself to fill in what
was typed after a plain post, repeating what `Submission` keeps private: which flash is whose, and
that the runtime's latest submission comes first.

**Options.** 1. `Submission.fields! : Submission(arg, result) => List({ name : Str, value : Str })`,
`FormData`'s entries: the runtime's latest submission's, or the flash's when it is this endpoint's.
2. Leave it: `LiveForm` reads the flash, and keeps what is typed in its own signal after that.

**Recommended: 1**: `fields_of(latest!(submission))`, which `Submission.roc` already has, made a
method. **What depends on it:** `LiveForm.of!` would read it instead of `Server.flash!`.
**Undo:** remove the method.

---

## Open questions

1. **The English.** The default messages are second person, short, with no full stop: "Fill this
   in", "Use at least 3 characters", "Enter 18 or more", "Tick this box to go on", "These don't
   match". Is that the voice wanted, or the browser's ("Please fill out this field.")?
2. **Holding a submit back** (proposal 4): should a form the browser knows is invalid be sent at
   all? Today it is, and the endpoint answers with the same issues.
3. **`novalidate`.** The README's page writes it, so only the package's messages show. Without it,
   the browser also holds a submit back on what the attributes say, in its own words and language.
   Which should the docs show first?
4. **Dates.** forms has a small `Date` (a day, as `<input type="date">` sends it). If the platform
   or packages/intl gets a date type, forms should read into that one instead.
5. **Trimming.** Text is read as typed unless a check says `Trim`, as zod and HTML do. Should
   `Form.text` trim by default?
6. **Translations.** `Issues.key(code)` and `Issues.params(code)` are what packages/intl would key
   a table by (`too_short`, `min: 3`). Does intl want anything else from an issue (the field's
   label, a plural's count as a number)?
