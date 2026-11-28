# forms: proposals for the platform

What packages/forms would change outside its own folder, if the user agrees. The package works
today without them (see README.md, "Status"). Proposals 1, 3 and 5 are done other ways, and 2 in
part; 2, 4 and 6 are open. Each open one says the problem, the options weighed, the one recommended
(with a sketch), what depends on it, and how it could be undone.

---

## 1. Server-only modules in packages

**Done another way (D-033, D-093).** A package whose modules need the server platform names it in
its header, as an app does, and lists what the browser's half compiles in a `browser.roc` beside
`main.roc`. Forms needs no such module: the platform reads an endpoint's body with the form its
route file names (`post_body`), so there is no glue for a `FormEndpoint` to hold.

---

## 2. A refusal with field issues

**In part since D-093:** `Issues.refusal` answers `Json(422, issues)`, which the platform sends as
`application/json`, and a checked endpoint refuses its form's issues so itself. The issues' shape is
still forms' own; what follows (a platform shape, RFC 9457) is still a proposal.

**Problem.** Forms refuses with a 422 whose body is its issues' JSON (`Issues.refusal`, the
platform's `Json` refusal, sent as `application/json`), and reads it back with
`Issues.from_problem`. It works, but:

- the shape is forms' own; a client that isn't Roc has to know it;
- `Server.explain(problem)`, which an app shows for any failure, shows that JSON to a person;
- `/openapi.json` documents every refusal under one `default` answer, a form's issues with no
  schema;
- every package or app that validates input invents its own shape.

**Options.**

1. Keep the convention (422, the issues as JSON), and document it.
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
3. A refusal with any JSON body (`Json(U16, Str)`): built (D-093), and what forms uses today. The
   browser still gets text, and nothing is typed.

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

with `respond!` sending a 422's body as `application/problem+json` and `Server.flash_back!` keeping
it as it keeps any body.

**What depends on it.** `Issues.refusal` would answer `Invalid(…)` (each issue as `key`, `params`,
`message`), `Issues.from_problem` would read `Invalid` too, and `LiveForm` would read
`submission.issues!()` instead of parsing the text. The codes come back as strings: forms would map
its own keys back to `Issues.Code` (`Issues.from_key`), and any it doesn't know to
`Custom(key, message)`.
**Undo.** Drop the tag from `Refusal` and `Problem`; `Issues.refusal` answers `Json(422, json)`
again.

---

## 3. A form's rules in `/openapi.json`

**Done another way (D-093).** A route file names the form its method's body is read with
(`post_body = Signup.form`). Generated/Api makes the contract `Endpoint.checked(…, Signup.form)`,
and `OpenApi.sent` documents a checked endpoint's body with `form.json_schema()`, as JSON,
URL-encoded and multipart.

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

**Done another way (2026-11-22).** The platform keeps a flash in the server's memory for a minute
(the cookie holds a random id, taken once). `Html` never writes a `value` into an
`<input type="password">`, and the page's note of the flash leaves out each field the page has as
one. A `Secret` renders as such an input, so no route names its secrets.

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

**Recommended: 1**: `Server.form_fields` of what `latest!(submission)` sent (`Submission.roc` has
both), made a method. **What depends on it:** `LiveForm.filled!` would read it instead of
`Server.flash!`.
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
4. **Dates.** forms has a small `Date` (a day, as `<input type="date">` sends it). packages/intl
   now has a `Date` of its own (a day on the calendar, with its formats). Should forms read into
   intl's, or the two become one type somewhere both can import?
5. **Trimming.** Text is read as typed unless a check says `Trim`, as zod and HTML do. Should
   `Form.text` trim by default?
6. **Translations.** `Issues.key(code)` and `Issues.params(code)` are what packages/intl would key
   a table by (`too_short`, `min: 3`). Does intl want anything else from an issue (the field's
   label, a plural's count as a number)?
