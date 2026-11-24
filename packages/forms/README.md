# forms

Write a form's rules once, in Roc, and run them on both sides, as zod does for TypeScript. The
browser checks what is typed as it is typed. The endpoint the form posts to reads the posted body
with the same rules, into a typed record, or refuses it with the same issues, field by field. The
rules go past what a type can say: lengths, patterns, email addresses, ranges and steps, choices,
days, lists, and checks across fields. Parse, don't just validate: what comes out is a Roc record.

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

The user guide, with a live demo, is the docs site's Forms page (`/ecosystem/forms`). This README
is the reference.

## Installing it

Name the package in the app's header (`main.roc`). `rocx build` gives the browser's half of the app
the same packages, so the header is the only place you name it. It is not a plugin: there is
nothing to add to `App.program`.

```roc
app [program] { forms: "../packages/forms/main.roc", pf: platform "../server/platform/main.roc" }
```

Then import what you need: `import forms.Form` (and `Value`, `Issues`, `Date`, `Regex`) in any
module, and `import forms.LiveForm`, `forms.TextField`, `forms.CheckboxField` or
`forms.IssueSummary` in a `.rocx` file.

## A whole example: one schema, a page, an endpoint

**The schema** is a module of the app's own, which both the page and the endpoint import. Here the
two passwords are a form of their own inside it. Their fields keep the names they are posted as,
and the check that compares them runs whenever both can be read, whatever is wrong elsewhere in
the form:

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

**The endpoint** parses the form's body with the schema. When the body doesn't read, it refuses
with a 422 and the issues as JSON (`Issues.refusal`). Its `body` type is `{}`, so the platform
doesn't parse the body: the form does. That matters for a checkbox left unticked, which a browser
doesn't send at all: the form judges it (`Unchecked`), instead of the platform answering 400.

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
when it refuses. This works with the runtime (the form is sent with `fetch`, and the page stays)
and without it (the browser posts the form, and the page comes back with what was typed and the
issues):

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

A field's issues show once you have left it, and then change as you type. All issues show once
the form has been sent. The inputs carry `required`, `minlength`, `pattern`, `min` and the other
constraint attributes the schema gives. `novalidate` turns off the browser's own bubbles, so only
the package's messages show. Leave it out, and the browser also holds a submit back on what those
attributes say, in its own words. Either way, the endpoint has the last word.

examples/tasks uses the package the same way: `TaskForm.roc` is the schema, `components/AddTask.rocx`
the form, and the list's `+server.roc` the endpoint.

## How it is built

**The rules are a Roc package** (`main.roc`): plain Roc on no platform, so the browser's half and
the server's run the same code, and a test runs it with nothing else.

| Module | What it does |
|---|---|
| `Form` | a form: fields by name (`Form.text`, `int`, `dec`, `checkbox`, `choice`, `date`, `field`, `optional`, `list`, `always`), put together with Roc's record builder; `.check`, `.check_at` (across fields), `.map`, `.try_map`, `.message`; `.parse(posted)`, `.parse_body(body)`, `.issues(posted)`; `.attributes(name)` and `.json_schema()`; `.names()`, `.is_list(name)`, `.secrets()`; `Form.decode(body)` |
| `Value` | one value, read and checked: `Value.text(checks)`, `int`, `dec`, `checkbox`, `choice`, `date`; `.check`, `.map`, `.try_map`, `.parse(raw)`; `.attributes()`, `.schema()`, `.is_required()` |
| `Issues` | what is wrong: `Issues.Issue` (`field`, `code`, `message`), `Issues.Code`; `english`, `key` and `params` (for translations); `at`, `under`, `messages`; `to_json`, `from_json`, `refusal`, `from_problem` |
| `Date` | a day, as `<input type="date">` sends it: `from_str`, `to_str`, `year`, `month`, `day`, `days`, `days_between`, `is_before`, `is_after` |
| `Regex` | regular expressions in plain Roc, in linear time: `compile`, `must`, `source`, `matches`, `found_in`, `find`, `find_all` |

`roc test packages/forms/main.roc` runs their `expect`s.

**The components are `.rocx` files** in `components/`. `rocx build` copies them into each app that
names the package (into `Generated/forms/`), so each half of the app compiles them on its own
platform. `LiveForm` is a form's state in a component. `<TextField>`, `<CheckboxField>` and
`<IssueSummary>` show it.

## Values and their checks

Each kind of value takes a list of checks, run in order. It reads the text a browser sends into a
Roc value, and reports everything wrong with it, not only the first thing. A text check other than
`Required` passes an empty value, as a browser's `minlength` and `pattern` do: `Value.text([Email])`
takes `""` or an address.

| Value | Reads | Checks |
|---|---|---|
| `Value.text(checks)` | `Str`, as typed | `Trim`, `Lowercase`, `CollapseSpaces` (each changes the text for the checks after it, and for what is read); `Required`; `MinLength(n)`, `MaxLength(n)` (in characters: code points); `Matches(pattern)` (the whole text, as the `pattern` attribute checks it); `Email` (as `<input type="email">` checks one); `Url` (`http` or `https`, a host, no spaces); `OneOf(options)`; `Secret` (a password: `type="password"`, never written back into a page) |
| `Value.int(checks)` | `I64`: `42`, `-3`, `+7`, with white space around it allowed | `Min(n)`, `Max(n)`, `Step(n)` (counted from the `Min`, or from 0, as a browser's `step` is) |
| `Value.dec(checks)` | `Dec`: `2.5`, `.5`, `-0.75`; a `.` before the decimals, no exponent | `Min(x)`, `Max(x)`, `Step(x)` |
| `Value.checkbox(checks)` | `Bool`: sent or not | `[Required]`: it must be ticked |
| `Value.choice(options)` | what the chosen option stands for: `[("free", Free), ("pro", Pro)]` reads `"pro"` as `Pro` | one of them |
| `Value.date(checks)` | `Date`: `2026-11-21` | `Min("2026-01-01")`, `Max(…)` |

An empty number, choice or day is `Required`. A bad pattern, or a bad day in a date's `Min` or
`Max`, crashes where the value is made. Roc computes a top-level value while the app compiles, so
in a top-level form that crash stops the build: a typo in a pattern never reaches a user.

A value can also be checked and changed by your own functions:

```roc
username = Value.text([Trim, Required]).check(|name| !reserved.contains(name), Custom("reserved", "That name is taken"))
isbn = Value.text([Trim, Required]).try_map(|text| Isbn.from_str(text) ?? Err(Custom("isbn", "Enter an ISBN")))
```

`value.parse(raw)` reads one value on its own: `Value.int([Min(18)]).parse("16") == Err([TooSmall(18)])`.

## Forms

| Function | What it does |
|---|---|
| `Form.field(name, value)` | the field posted as `name`, read as `value` says (its first value; `""` if it wasn't sent) |
| `Form.text(name, checks)`, `int`, `dec`, `checkbox`, `choice`, `date` | short for `Form.field(name, Value.text(checks))`, and so on |
| `Form.optional(name, value)` | `Err(Missing)` when left empty (or only white space), otherwise read: a `Try(a, [Missing])` |
| `Form.list(name, value, [MinItems(n), MaxItems(n)])` | every value posted as `name` (checkboxes that share a name, a `<select multiple>`), empty ones left out. An item's issues are at `name[i]`, the list's own at `name` |
| `{ a: …, b: … }.Form` | Roc's record builder: every field read, all their issues kept |
| `Form.always(value)` | a form with no fields that reads as `value`: a constant in a record builder |
| `.check(ok, code)` | adds `code` unless `ok(value)`, at the form's own field (a field's name; `""` for a whole form, an issue to show above it) |
| `.check_at(field, ok, code)` | the same, with the issue at `field`: a check across fields. It runs once every field can be read, even if some have issues |
| `.map(f)`, `.try_map(f)` | what was read, made into another value (`try_map`: or into an issue) |
| `.message(text)` | its issues, with this message instead (the code stays) |
| `.parse(posted)`, `.parse_body(body)` | the record, or every issue: from fields (`List({ name : Str, value : Str })`, as `Server.form_fields` reads them), or from a URL-encoded body |
| `.issues(posted)` | what is wrong, `[]` if nothing |
| `.attributes(name)` | what a browser's constraint attributes say of a field: `{ type, required, minlength, maxlength, pattern, min, max, step }`, each text one `""` when there is none, for `??=` |
| `.json_schema()` | the form as a JSON Schema object: each field's type and checks (`minLength`, `pattern`, `format`, `minimum`, `enum`…), and the fields it requires |
| `.names()`, `.is_list(name)`, `.secrets()` | its fields' names; whether one takes several values; the `Secret` ones |
| `Form.decode(body)` | a URL-encoded body (`name=Ada+L&tag=a&tag=b`) as fields, in order |

## Issues

An issue is `{ field : Str, code : Issues.Code, message : Str }`: where, what, and the English for
it. A code is a plain tag that carries what its message needs: `Required`, `Unchecked`,
`TooShort(min)`, `TooLong(max)`, `NoMatch(pattern)`, `NotEmail`, `NotUrl`, `NotDate`,
`NotOneOf(options)`, `NotInteger`, `NotNumber`, `TooSmall(min)`, `TooLarge(max)`,
`NotStep(below, above)` (the nearest values that fit), `TooEarly(day)`, `TooLate(day)`,
`TooFew(min)`, `TooMany(max)`, `NotSame(other)`, and the app's own, `Custom(key, message)`. The
numbers in `TooSmall`, `TooLarge` and `NotStep` are `Dec`s, so a code says the same whether its
field reads an `I64` or a `Dec`.

| Function | What it does |
|---|---|
| `Issues.english(code)` | the default English, a short sentence with no full stop: `"Use at least 3 characters"` |
| `Issues.key(code)`, `Issues.params(code)` | what a table of translations is keyed by: `"too_short"`, `[{ name: "min", value: "3" }]`; a custom code's own key |
| `Issues.at(issues, field)`, `under`, `messages` | a field's issues (`under`: its list items' too, `tags[0]`, `tags[1]`…), and their messages |
| `Issues.to_json`, `Issues.from_json` | the issues as JSON, and back |
| `Issues.refusal(issues)` | an endpoint's refusal: `Status(422, json)`, which is an `Endpoint.Refusal` |
| `Issues.from_problem(problem)` | the issues of a 422, from the `Server.Problem` that a submission's `error!()` or `Endpoint.send!` gives; `[]` for any other problem |

To show issues in another language, match on the code, or look its key and params up in a
catalog. packages/intl does the latter.

## Patterns: `Regex`

Roc has no regular expression engine, so this package has one, in plain Roc. A pattern compiles
once, to a program (a Thompson NFA). A Pike VM runs the program over the text, following every way
the pattern could match at once, one step per character. So no pattern and no text can make it
slow. The cost is what needs backtracking: there are no backreferences and no lookaround.

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
is a code point (`.` matches `é` whole). A repeat is at most 1000 times, and a program at most
20000 steps. A browser compiles `pattern` with the `v` flag, which wants `-`, `(`, `)`, `[`, `{`,
`}`, `/` and `|` escaped inside a class. Escape them, and both sides agree.

## `LiveForm` and the components

`LiveForm.of!(form, endpoint)` is the form's state in a component: what is typed, which fields
were left, whether it was sent, and what the endpoint refused (through `Router.use_submission!`).
Call it once, where the component makes its signals.

| Function | What it does |
|---|---|
| `LiveForm.of!(form, endpoint)` | a live form that posts to `endpoint`, empty |
| `LiveForm.filled!(form, endpoint, values)` | the same, starting with `values` typed in, field by field: an edit form's record as it is now, `[("title", task.title), ("notes", task.notes)]`. A ticked box is `("done", "on")`; leave out one that isn't |
| `LiveForm.local!(form)`, `local_filled!(form, values)` | a live form that posts nowhere, for an `on:submit` handler that shows every issue (`show_all!`) and reads the form (`form.parse(live.fields!())`), then sends it itself (`Endpoint.send!`) or keeps it in the browser |
| `live.reset!()` | from a handler: starts afresh where it is. What it started with is typed in again, no field is left, nothing is sent, and the endpoint's answer is forgotten, so no issue shows. The inputs stay, and so does focus |
| `live.accepted!()` | whether the endpoint accepted what the runtime last sent (answered with its result, not a refusal), until the form starts afresh. An add form resets once a task is in: `create_effect!(\|\| live.accepted!(), \|accepted\| if (accepted) live.reset!() else {})` |
| `live.url()` | the endpoint's URL, for the form's `action` (`""` for a local form) |
| `live.value!(name)`, `values!(name)`, `checked!(name, value)` | what is typed in a field; all of a list's values; whether a box is ticked |
| `live.input!(name, value)` | from `on:input.value`: what a field holds now |
| `live.toggle!(name, value, ticked)` | from `on:change.checked` (`"on"` for a lone box) |
| `live.leave!(name)` | from `on:blur`: the field's issues show from now on |
| `live.show_all!()`, `live.fields!()` | every field's issues show from now on, as after a send; what is typed, as the form would post it |
| `live.issues!(name)`, `invalid!(name)` | the issues to show at a field now, and whether it has any (for `aria-invalid`) |
| `live.all_issues!()`, `sent!()`, `pending!()` | every issue to show (the form's own first); whether it was sent; whether it is on its way |
| `live.attributes(name)`, `LiveForm.field_id(name)` | a field's constraint attributes; its input's `id` (`field-email`) |

When an issue shows:

- A field's own issues show once you leave the field, and from then on change as you type.
- Every field's issues show once the form has been sent.
- The endpoint's issues stay at a field until you type in it again.
- After a plain post (no runtime) that the endpoint refused, the page comes back with what was
  typed and the endpoint's issues, from the flash (see "Passwords" below). After one it accepted,
  the form starts afresh, with its `values` if it was `filled!`.
- With the runtime the page stays as it was, and so does the form, until `reset!`.

| Component | Props |
|---|---|
| `<TextField>` | `live`, `name`, `label`; `hint` (shown under the label, and read with the input), `type` (the input's, when its checks don't give one: `tel`, `search`), `autocomplete` |
| `<CheckboxField>` | `live`, `name`, `label` |
| `<IssueSummary>` | `live`, `title`: once the form is sent and has issues, a list of them, each a link to its field (`role="alert"`); `labels` (`[("name", "Name")]`), the fields' labels by name, so a link says which field it is about: `Name: Fill this in` |

A field's input carries the attributes its checks give (`type="email"`, `required`, `minlength`,
`pattern`, `min`, `max`, `step`), `aria-invalid`, and `aria-describedby` naming its hint and its
issues. A field keeps room under its input for an issue, so an issue that appears as you leave the
field (by pressing Send, say) moves nothing below it, and the press still lands on Send. The
colours come from custom properties: `--form-invalid`, `--form-border`, `--form-muted`,
`--form-radius`.

### Passwords

A `Secret` field is never written back into a page. When a plain post is refused, the platform
keeps the flash (what was typed, and the refusal) in the server's memory for a minute; the cookie
holds only its id. The page never fills an `<input type="password">` in again, and leaves such a
field out of what it notes for the browser. `LiveForm` leaves `form.secrets()` out of what it types
in again, so the person types the password again.

## Status

Works today, with no change to the platform: the package and its `expect`s
(`roc test packages/forms/main.roc`), and the components, which the docs site's Forms page and
examples/tasks, examples/quiz and examples/plate use.

Not yet (each is a proposal in PROPOSALS.md):

- **A refusal with field issues of the platform's own.** Today a refusal is a 422 whose text is the
  issues' JSON, sent as `text/plain`, which `Issues.from_problem` reads back. `Server.explain` would
  show that JSON to a person.
- **The form's rules in `/openapi.json`.** The document describes an endpoint whose `body` is `{}`
  as taking an empty object, so the rules (lengths, patterns, required fields) aren't in it.
  `form.json_schema()` is ready for it.
- **Holding a submit back in the browser** when the form has issues. Today it always goes to the
  endpoint, which refuses it with the same issues.
- **A ready-made endpoint handler.** The endpoint glue is a few lines in your route file (`post!`
  above). A package can now have modules only the server compiles (as plugins do), so forms could
  ship one.

## Limits

- A URL-encoded body only (`application/x-www-form-urlencoded`, what a browser and the runtime send
  for a form without files). Not JSON, and not `multipart/form-data` (files).
- Decimals are written with a `.`, and no exponent. A locale's `1,5` is for a translation layer.
- A regex has no flags (write `[A-Za-z]` for any case), no captures (`find` gives the whole match),
  and no backreferences or lookaround.
- `Url` takes `http` and `https` only, and checks no more of a host than that it has no spaces.
- A `check_at` across fields runs when the whole form can be read, so a number left empty elsewhere
  keeps it from running. Put the fields it compares in a form of their own (as `passwords` above),
  and it runs whenever those two can be read.
