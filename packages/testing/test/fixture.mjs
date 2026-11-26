// A small app on Roc Solid, for testing the helpers against a real server and a real browser: a
// page with a counter, a form posted to an endpoint, an endpoint the page reads, JSON, a stream of events,
// email, and a job that sends one. app.test.mjs writes it into a directory of its own and builds it.
import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { repo } from "../build.mjs";

/** Writes the app into `dir`, its platform named by a path from there (Roc takes no absolute one). */
export function writeFixture(dir) {
	const real = realpathSync(dir);
	const platform = relative(real, realpathSync(join(repo, "server", "platform", "main.roc")));
	const jobs = relative(real, realpathSync(join(repo, "packages", "jobs", "main.roc")));
	const email = relative(real, realpathSync(join(repo, "packages", "email", "main.roc")));
	const files = {
		"main.roc": `## The fixture's program: rocx build writes Generated/App from its routes; the jobs plugin
## (packages/jobs) runs the jobs its modules define, and the email plugin (packages/email) sends or
## keeps its mail.
app [program] { email: "${email}", jobs: "${jobs}", pf: platform "${platform}" }

import pf.Middleware
import email.Email
import jobs.Job
import Generated/App

program = App.program({
	init!: |started| Ok({ started: started }),
	middleware: Middleware.same_origin({}),
	# A failed job waits 5 s for its next attempt: longer than a test settles the queue for.
	plugins: [Job.plugin({ jobs: App.jobs, retry_ms: 5000 }), Email.plugin({})],
})
`,
		"Jobs.roc": `import jobs.Job
import email.Email

## The app's jobs.
Jobs := [].{

	## Welcomes an address, by email.
	welcome : Job.Kind(_, { to : Str })
	welcome = Job.define(
		"welcome",
		|_context, { to }|
			match Email.send!({ to, subject: "Welcome", text: "Your notes are at https://notes.example/notes", html: "<p>Your notes are at <a href=\\"https://notes.example/notes\\">your notes</a>.</p>" }) {
				Ok({}) => Ok({})
				Err(EmailErr(why)) => Err(why)
			},
	)
}
`,
		"Counter.rocx": `import pf.Html
import pf.Solid exposing [create_signal!]

## A count you can add to.
Counter := [].{
	view! : { start : U64 } => Html
	view! = |{ start }| {
		(count!, set_count!) = create_signal!(start)
		<p>
			<button type="button" on:click={|| set_count!(count!() + 1)}>Add one</button>
			<output aria-label="Count">{count!().to_str()}</output>
		</p>
	}

	<story name="At ten">
		<Counter start={10} />
	</story>
}
`,
		"routes/+layout.rocx": `import pf.Html

## The document around every page.
view! = |{ meta, children, .. }|
	<>
		<!doctype html>
		<html lang="en">
			<head>
				<meta charset="utf-8" />
				<title>{meta.title}</title>
			</head>
			<body>
				<nav aria-label="Main"><a href="/">Notes</a></nav>
				<main>{...children}</main>
			</body>
		</html>
	</>
`,
		"routes/+error.rocx": `import pf.Html

meta = { title: "Not here" }

view! = |{ status, problem }|
	<section role="alert">
		<h1>{status.to_str()}</h1>
		<p>{problem}</p>
	</section>
`,
		"routes/+page.rocx": `import pf.Html
import pf.Server
import pf.Endpoint
import ../Counter
import ../Generated/Api

meta = { title: "Notes" }

## How many notes there are: GET /notes, read as the page renders.
count! : {} => U64
count! = |{}| Endpoint.get!(Api.get_notes({}))

view! = |_|
	<section aria-labelledby="title">
		<h1 id="title">Notes</h1>
		<p data-testid="count">{count!({}).to_str()} notes</p>
		<Counter start={1} />
		<form method="post" action={Endpoint.url_of(Api.post_notes({}))}>
			<label for="body">New note</label>
			<input id="body" name="body" />
			<button>Add</button>
		</form>
	</section>
`,
		"routes/notes/+server.roc": `import pf.Server
import pf.Endpoint

## GET /notes: how many notes there are.
get! : { request : Server.Request, params : {}, context : c } => Try(U64, Endpoint.Refusal)
get! = |_| Ok(3)

## POST /notes, from the page's form: a note with words in it.
post! : { request : Server.Request, params : {}, context : c, body : { body : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	if (body.body.trim().is_empty()) Err(BadRequest("a note has words")) else Ok("added \${body.body.trim()}")
`,
		"routes/api/echo/+server.roc": `import pf.Server
import pf.Endpoint

## POST /api/echo: the word, said back, and how long it is.
post! : { request : Server.Request, params : {}, context : c, body : { word : Str } } => Try({ said : Str, length : U64 }, Endpoint.Refusal)
post! = |{ body, .. }| Ok({ said: body.word, length: body.word.to_utf8().len() })
`,
		"routes/api/ticks/+server.roc": `import pf.Server
import pf.Endpoint
import pf.Events

## GET /api/ticks: three ticks, then the stream ends.
events! : { request : Server.Request, params : {}, context : c } => Try(Events({ tick : U64 }), Endpoint.Refusal)
events! = |_|
	Ok(
		Events.stream(
			|{ send!, sleep! }| {
				var $tick = 1
				while $tick <= 3 {
					send!({ tick: $tick })?
					sleep!(10)
					$tick = $tick + 1
				}
				Ok({})
			},
		),
	)
`,
		"routes/api/mail/+server.roc": `import pf.Server
import pf.Endpoint
import email.Email

## POST /api/mail: an email to \`to\`, sent now (kept in the dev mailbox: no SMTP_URL).
post! : { request : Server.Request, params : {}, context : c, body : { to : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Email.send!({ to: body.to, subject: "Hello", text: "Hello, see https://notes.example/hello for more.", html: "" }) {
		Ok({}) => Ok({})
		Err(EmailErr(why)) => Err(BadRequest(why))
	}
`,
		"routes/api/welcome/+server.roc": `import pf.Server
import pf.Endpoint
import jobs.Job
import ../../../Jobs

## POST /api/welcome: a welcome queued for \`to\` (a job: needs the database).
post! : { request : Server.Request, params : {}, context : c, body : { to : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Job.enqueue!(Jobs.welcome, { to: body.to }, {}) {
		Ok({}) => Ok({})
		Err(JobErr(why)) => Err(Status(503, why))
	}
`,
	};
	for (const [path, content] of Object.entries(files)) {
		mkdirSync(dirname(join(real, path)), { recursive: true });
		writeFileSync(join(real, path), content);
	}
	return real;
}
