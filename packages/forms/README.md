# forms

A form's rules, written once in Roc and run on both sides, as zod is for TypeScript. The browser
checks what is typed as it is typed; the endpoint the form posts to reads what was posted with the
very same rules, into a typed record, or refuses it with the same issues, field by field. The rules
go past what a type can say: lengths, patterns, email addresses, ranges and steps, choices, days,
lists, and checks across fields. Parse, don't just validate: what comes out is a Roc record.

```roc
import forms.Form

signup = {
	name: Form.text("name", [Trim, Required, MaxLength(80)]),
	email: Form.text("email", [Trim, Lowercase, Required, Email]),
	age: Form.int("age", [Min(18), Max(130)]),
	plan: Form.choice("plan", [("free", Free), ("pro", Pro)]),
	terms: Form.checkbox("terms", [Required]),
}.Form

signup.parse_body("name=Ada&email=Ada%40example.com&age=36&plan=pro&terms=on")
# Ok({ name: "Ada", email: "ada@example.com", age: 36, plan: Pro, terms: Bool.True })

signup.parse_body("name=&email=ada%40&age=12&plan=gold")
# Err([{ field: "name", code: Required, message: "Fill this in" },
#      { field: "email", code: NotEmail, message: "Enter an email address, like name@example.com" },
#      { field: "age", code: TooSmall(18), message: "Enter 18 or more" },
#      { field: "plan", code: NotOneOf(["free", "pro"]), message: "Choose one of the options" },
#      { field: "terms", code: Unchecked, message: "Tick this box to go on" }])
```

## A whole example: one schema, a page, an endpoint

Name the package in the app's header, as `charts` is named (`rocx build --client` gives the
browser's half the same packages):

```roc
app [program] { forms: "../packages/forms/main.roc", pf: platform "../server/platform/main.roc" }
```

**The schema** is a module of the app's own, which the page and the endpoint both import. The two
passwords are a form of their own inside it: their fields keep the names they are posted as, and
the check across them runs whenever both can be read, whatever the rest of the form says:

```roc
# Signup.roc
import forms.Form

## The sign-up form: what the page shows and checks as it is typed, and what its endpoint reads.
Signup := [].{
	Passwords : { password : Str, confirm : Str }

	Account : { name : Str, email : Str, age : I64, plan : [Free, Pro], passwords : Signup.Passwords, terms : Bool }

	## A password, typed twice: a form of its own, so the check across them runs whenever both can be read.
	passwords : Form(Signup.Passwords)
	passwords = ({ password: Form.text("password", [Required, MinLength(8), Secret]), confirm: Form.text("confirm", [Required, Secret]) }.Form).check_at("confirm", |p| p.password == p.confirm, NotSame("password"))

	form : Form(Signup.Account)
	form = {
		name: Form.text("name", [Trim, Required, MaxLength(80)]),
		email: Form.text("email", [Trim, Lowercase, Required, Email]),
		age: Form.int("age", [Min(18), Max(130)]),
		plan: Form.choice("plan", [("free", Free), ("pro", Pro)]),
		passwords: Signup.passwords,
		terms: Form.checkbox("terms", [Required]),
	}.Form
}
```

**The endpoint** reads the form's body with it, and refuses what doesn't read with a 422 and the
issues as JSON (`Issues.refusal`). Its `body` is `{}`: the form reads the body itself, so a box
left unticked (which a browser doesn't send at all) is the form's to judge, not a 400.

```roc
# routes/signup/+server.roc
import pf.Server
import pf.Endpoint
import forms.Issues
import ../../Signup

## POST /signup, from the sign-up form: the account it reads, or a 422 with each field's issues,
## the same the page shows as it is typed.
post! : { request : Server.Request, params : {}, context : c, body : {} } => Try({ welcome : Str }, Endpoint.Refusal)
post! = |{ request, .. }|
	match Signup.form.parse_body(Server.text_of(request)) {
		Ok(account) => Ok({ welcome: "Welcome, ${account.name}" })
		Err(issues) => Err(Issues.refusal(issues))
	}
```

**The page** checks the same form as it is typed (`LiveForm`), and shows the endpoint's issues
when it refuses, with the runtime (the form is sent with `fetch`, and the page stays) or without
it (the form posts, and the page comes back with what was typed and the issues):

```roc
# routes/signup/+page.rocx
import pf.Html
import forms.LiveForm
import forms.TextField
import forms.CheckboxField
import forms.IssueSummary
import ../../Generated/Api
import ../../Signup

## The sign-up page: the form, checked as it is typed, sent to `POST /signup`.
view! = |_| {
	live = LiveForm.of!(Signup.form, Api.post_signup({}))
	<main>
		<h1>Sign up</h1>
		<IssueSummary live={live} title="Fix these, then send it again" />
		<form method="post" action={live.url()} novalidate>
			<TextField live={live} name="name" label="Name" autocomplete="name" />
			<TextField live={live} name="email" label="Email" autocomplete="email" />
			<TextField live={live} name="age" label="Age" hint="You must be 18 or over." />
			<label for="field-plan">Plan</label>
			<select id="field-plan" name="plan" on:change.value={|picked| live.input!("plan", picked)}>
				<option value="">Choose…</option>
				<option value="free" selected?={live.value!("plan") == "free"}>Free</option>
				<option value="pro" selected?={live.value!("plan") == "pro"}>Pro</option>
			</select>
			<TextField live={live} name="password" label="Password" autocomplete="new-password" />
			<TextField live={live} name="confirm" label="Password, again" autocomplete="new-password" />
			<CheckboxField live={live} name="terms" label="I accept the terms" />
			<button type="submit" disabled?={live.pending!()}>Sign up</button>
		</form>
	</main>
}
```

A field's issues show once it has been left, and then change as it is typed; all of them once the
form has been sent. The inputs carry `required`, `minlength`, `pattern`, `min`… from the schema;
`novalidate` keeps the browser's own bubbles away, so only these messages show. Leave it out, and a
browser also holds a submit back on what those attributes say, in its own words, with the runtime
or without. Either way the endpoint has the last word.

## Two halves

**The rules are a Roc package** (`main.roc`): plain Roc on no platform, so the browser's half and
the server's run the same code.

| Module | What it does |
|---|---|
| `Form` | a form: fields by name (`Form.text`, `int`, `dec`, `checkbox`, `choice`, `date`, `field`, `optional`, `list`), put together with the record builder; `.check`, `.check_at` (across fields), `.map`, `.try_map`, `.message`; `.parse(posted)`, `.parse_body(body)`, `.issues(posted)`; `.attributes(name)` and `.json_schema()` for a browser and an OpenAPI document; `Form.decode(body)` |
| `Value` | one value read and checked: `Value.text(checks)`, `int`, `dec`, `checkbox`, `choice`, `date`; `.check`, `.map`, `.try_map`, `.parse(raw)`; `.attributes()`, `.schema()` |
| `Issues` | what is wrong: `Issues.Issue` (`field`, `code`, `message`), `Issues.Code`; `english`, `key` and `params` (for translations), `at`, `under`, `messages`; `to_json`, `from_json`, `refusal`, `from_problem` |
| `Date` | a day, as `<input type="date">` sends it: `from_str`, `to_str`, `days`, `days_between`, `is_before`, `is_after` |
| `Regex` | regular expressions in plain Roc, linear-time: `compile`, `must`, `matches`, `found_in`, `find`, `find_all` |

`roc test packages/forms/main.roc` runs their `expect`s.

**The components are `.rocx` files** (`components/`), which `rocx build` copies into the app, as
it copies `charts`' (see packages/charts/README.md): `LiveForm`, a form's state in a component,
and `<TextField>`, `<CheckboxField>` and `<IssueSummary>`, which show it.

## Values and their checks

Each kind of value takes a list of checks, run in order: what it reads, and everything wrong with
it, not only the first thing. A text check other than `Required` passes an empty value, as a
browser's `minlength` and `pattern` do: `Value.text([Email])` takes `""` or an address.

| Value | Reads | Checks |
|---|---|---|
| `Value.text(checks)` | `Str`, as typed | `Trim`, `Lowercase`, `CollapseSpaces` (each changes the text for the checks after it); `Required`; `MinLength(n)`, `MaxLength(n)` (characters, as code points); `Matches(pattern)` (the whole text, as the `pattern` attribute); `Email` (as `<input type="email">` checks one); `Url` (`http` or `https`, a host, no spaces); `OneOf(options)`; `Secret` (a password: `type="password"`, never written back into a page) |
| `Value.int(checks)` | `I64`: `42`, `-3`, `+7`, white space around it | `Min(n)`, `Max(n)`, `Step(n)` (from the `Min`, or 0, as a browser's `step`) |
| `Value.dec(checks)` | `Dec`: `2.5`, `.5`, `-0.75`; no exponent, a `.` before the decimals | `Min(x)`, `Max(x)`, `Step(x)` |
| `Value.checkbox(checks)` | `Bool`: sent or not | `[Required]`: it must be ticked |
| `Value.choice(options)` | what the chosen option stands for: `[("free", Free), ("pro", Pro)]` | one of them; none chosen is `Required` |
| `Value.date(checks)` | `Date`: `2026-11-21` | `Min("2026-01-01")`, `Max(…)` |

An empty number, choice or day is `Required`. A bad pattern, or a bad day in `Min`, crashes where
the value is made, and since Roc computes a top-level value as the app compiles, that stops the
build: a typo in a pattern is never found by a user.

Beyond the checks, a value can be checked and changed by functions:

```roc
username = Value.text([Trim, Required]).check(|name| !reserved.contains(name), Custom("reserved", "That name is taken"))
isbn = Value.text([Trim, Required]).try_map(|text| Isbn.from_str(text) ?? Err(Custom("isbn", "Enter an ISBN")))
```

## Forms

| | |
|---|---|
| `Form.field(name, value)` | the field posted as `name`, read as `value` says (its first value; `""` if it wasn't sent) |
| `Form.text(name, checks)`, `int`, `dec`, `checkbox`, `choice`, `date` | `Form.field(name, Value.text(checks))`, and so on |
| `Form.optional(name, value)` | `Err(Missing)` when left empty, otherwise read: `Try(a, [Missing])` |
| `Form.list(name, value, [MinItems(n), MaxItems(n)])` | every value posted as `name` (boxes that share it, a `<select multiple>`), empty ones left out; an item's issues at `name[i]`, the list's at `name` |
| `{ a: …, b: … }.Form` | Roc's record builder: both read, all their issues kept |
| `Form.always(value)` | a form of no fields |
| `.check(ok, code)` | `code` at the form's own field (a field's name; `""` for a whole form) unless `ok(value)` |
| `.check_at(field, ok, code)` | the same, at `field`: across fields. It runs when every field can be read, even if some are wrong |
| `.map(f)`, `.try_map(f)` | what was read, made into another (`try_map`: or an issue) |
| `.message(text)` | its issues, with this message (the code stays) |
| `.parse(posted)`, `.parse_body(body)` | the record, or every issue: from fields (`List({ name : Str, value : Str })`, as `Server.form_fields` reads them), or from a form's body |
| `.issues(posted)` | what is wrong, `[]` if nothing |
| `.attributes(name)` | what a browser's constraint attributes say of a field: `{ type, required, minlength, maxlength, pattern, min, max, step }`, each `""` when none, for `??=` |
| `.json_schema()` | the form as a JSON Schema object: each field's type and checks (`minLength`, `pattern`, `format`, `minimum`, `enum`…), and the ones it requires |
| `.names()`, `.is_list(name)`, `.secrets()` | its fields; whether one takes several values; the `Secret` ones |
| `Form.decode(body)` | `name=Ada+L&tag=a&tag=b` as fields |

## Issues

An issue is `{ field : Str, code : Issues.Code, message : Str }`: where, what, and the English for
it. A code is a plain tag with what it needs said: `Required`, `Unchecked`, `TooShort(min)`,
`TooLong(max)`, `NoMatch(pattern)`, `NotEmail`, `NotUrl`, `NotDate`, `NotOneOf(options)`,
`NotInteger`, `NotNumber`, `TooSmall(min)`, `TooLarge(max)`, `NotStep(below, above)` (the nearest
that fit), `TooEarly(day)`, `TooLate(day)`, `TooFew(min)`, `TooMany(max)`, `NotSame(other)`, and
the app's own, `Custom(key, message)`. A number in a code is a `Dec`.

| | |
|---|---|
| `Issues.english(code)` | the default English: `"Use at least 3 characters"` |
| `Issues.key(code)`, `Issues.params(code)` | for a table of translations: `"too_short"`, `[{ name: "min", value: "3" }]`; a custom code's own key |
| `Issues.at(issues, field)`, `under`, `messages` | a field's issues (`under`: its items' too), and their messages |
| `Issues.to_json`, `Issues.from_json` | the issues as JSON, and back |
| `Issues.refusal(issues)` | an endpoint's refusal: `Status(422, json)`, an `Endpoint.Refusal` |
| `Issues.from_problem(problem)` | the issues of a 422 a submission's `error!()` or `Endpoint.send!` gives (a `Server.Problem`); none for any other |

## Patterns: `Regex`

There is no regular expression engine in Roc, so this package has one, in plain Roc. A pattern
compiles once (a Thompson NFA), and a Pike VM runs it over the text, every way it could match at
once, a step per character: no pattern and no text can make it slow. That rules out what needs
backtracking: there are no backreferences and no lookaround.

| Syntax | Matches |
|---|---|
| `a`, `\.`, `\\`, `\n`, `\t`, `\xE9`, `é`, `\u{1F600}` | that character |
| `.` | any character but a line break |
| `[abc]`, `[a-z0-9_]`, `[^,;]` | one of them; one that isn't |
| `\d` `\w` `\s`, `\D` `\W` `\S` | a digit, a word character (`[A-Za-z0-9_]`), white space (JavaScript's); and their opposites |
| `^`, `$` | the start, the end of the text |
| `\b`, `\B` | a word's edge; anywhere else |
| `(…)`, `(?:…)` | a group |
| `a\|b` | either, the first preferred |
| `*`, `+`, `?`, `{2}`, `{2,}`, `{2,5}` | so many times; with `?` after (`*?`), as few as can be |

```roc
zip = Regex.must("\\d{2}-\\d{3}")
zip.matches("12-345")          # Bool.True: the whole text, as a `pattern` attribute checks it
zip.found_in("at 12-345, PL")  # Bool.True: anywhere, as JavaScript's `test`
zip.find("at 12-345")          # Ok({ start: 3, end: 9, text: "12-345" }): the leftmost match, in bytes
Regex.must("\\d+").find_all("1 22 333")  # ["1", "22", "333"]
Regex.compile("(ab")           # Err(InvalidRegex("at 1: a ( with no ) after it"))
```

The syntax is JavaScript's, so a pattern means the same in the `pattern` attribute. A character
is a code point (`.` matches `é` whole). A repeat is at most 1000 times, a program at most 20000
steps. A browser compiles `pattern` with the `v` flag, which wants `-`, `(`, `)`, `[`, `{`, `}`,
`/` and `|` escaped inside a class: escape them, and both sides agree.

## `LiveForm` and the components

`LiveForm.of!(form, endpoint)`, in a component, is the form's state there: what is typed, which
fields were left, whether it was sent, what the endpoint refused (`Router.use_submission!`).

| | |
|---|---|
| `LiveForm.filled!(form, endpoint, values)` | the same, starting with `values` typed in, field by field: an edit form's record as it is now, `[("title", task.title), ("notes", task.notes)]` (a box ticked is `("done", "on")`; leave out one that isn't) |
| `LiveForm.local!(form)`, `local_filled!(form, values)` | a live form that posts nowhere: for one whose `on:submit` handler checks it (`show_all!`) and reads it (`form.parse(live.fields!())`), then sends it itself or keeps it |
| `live.reset!()` | from a handler: starts afresh, where it is (its inputs, focus too): what it started with typed in again, no field left, not sent, the endpoint's answer forgotten, so no issue shows |
| `live.accepted!()` | whether the endpoint accepted what the runtime last sent (its result, not a refusal), until the form starts afresh: `create_effect!(\|\| live.accepted!(), \|accepted\| if (accepted) live.reset!() else {})` resets an add form once a task is in |
| `live.url()` | the endpoint's URL: the form's `action` (`""` for a local one) |
| `live.value!(name)`, `values!(name)`, `checked!(name, value)` | what is typed in a field; all of a list's values; whether a box is ticked |
| `live.input!(name, value)` | from `on:input.value`: what a field holds now |
| `live.toggle!(name, value, ticked)` | from `on:change.checked` (`"on"` for a lone box) |
| `live.leave!(name)` | from `on:blur`: its issues show from now on |
| `live.show_all!()`, `live.fields!()` | every field's issues show from now on, as after a send; what is typed, as the form would post it |
| `live.issues!(name)`, `invalid!(name)` | the issues to show at a field now, and whether it has any (`aria-invalid`) |
| `live.all_issues!()`, `sent!()`, `pending!()` | every issue to show (the form's own first); whether it was sent; whether it is on its way |
| `live.attributes(name)`, `LiveForm.field_id(name)` | a field's constraint attributes; its input's `id` (`field-email`) |

When an issue shows: a field's own, once it has been left, and from then on as it is typed; every
field's, once the form has been sent. The endpoint's issues stay at a field until it is typed in
again. After a plain post the endpoint refused, the page comes back with what was typed (not a
`Secret`) and the endpoint's issues, from the flash; after one it accepted, the form starts afresh
(with its `values`, if it was `filled!`). With the runtime the page stays as it was, and the form
too, until `reset!`.

| Component | Props |
|---|---|
| `<TextField>` | `live`, `name`, `label`; `hint` (said under the label, and read with the input), `type` (the input's, when its checks don't give it: `tel`, `search`), `autocomplete` |
| `<CheckboxField>` | `live`, `name`, `label` |
| `<IssueSummary>` | `live`, `title`: once the form is sent and has issues, a list of them, each a link to its field (`role="alert"`); `labels` (`[("name", "Name")]`), the fields' labels by name, so a link says which field it is about: `Name: Fill this in` |

A field's input carries the attributes its checks give (`type="email"`, `required`, `minlength`,
`pattern`, `min`, `max`, `step`), `aria-invalid`, and `aria-describedby` naming its hint and its
issues. A field keeps a line under its input for an issue, so one that shows as the field is left
(as Send is pressed, say) moves nothing under it, and the press still lands on Send. The colours
come from custom properties: `--form-invalid`, `--form-border`, `--form-muted`, `--form-radius`.

## Status

Works today, with no change to the platform: the package, its `expect`s (`roc test
packages/forms/main.roc`), and the components, built into a scratch app (both halves type-checked,
the server run, the page driven in Chromium): the endpoint refusing with its issues, a plain post
coming back with them, and the page checking as it is typed and showing the endpoint's issues
after a send.

Waiting on a proposal (PROPOSALS.md):

- A refusal with field issues of the platform's own: today it is a 422 whose text is the issues'
  JSON, which `Issues.from_problem` reads back; `Server.explain` would show that JSON.
- The form's rules in `/openapi.json`: an endpoint whose `body` is `{}` is documented as an empty
  object, and only as JSON. `form.json_schema()` is ready for it.
- Holding a submit back in the browser when the form has issues: today it always goes to the
  endpoint, which refuses it with the same issues.
- A password left out of the flash: a plain post's flash cookie holds what was typed, a `Secret`
  too, for a minute (the page doesn't show it again).

## Limits, for now

- A form's body only (`application/x-www-form-urlencoded`, what both a browser and the runtime
  send); not JSON, nor `multipart/form-data` (files).
- Decimals are written with a `.`, and no exponent; a locale's (`1,5`) is for a translation layer.
- A regex has no flags (`[A-Za-z]` for any case), no captures (`find` gives the whole match), and
  no backreferences or lookaround.
- `Url` takes `http` and `https` only, and doesn't check a host's shape past having no spaces.
- A `check_at` across fields runs when the whole form can be read: a number left empty elsewhere
  keeps it from running. Put the fields it compares in a form of their own (as `passwords` above),
  and it runs whenever those two can be read.
