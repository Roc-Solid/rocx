## An app whose context `init!` makes once, when the server starts, for the server's tests
## (`server/test/context.test.mjs`): the host keeps it for as long as the server runs, and hands it
## to every request, job, actor's turn and plugin's call, loop, start and check. It holds text
## (`--context-file`'s), a list of a thousand strings, a record inside it, a function that captured
## some of it, and when it was made: each request answers with all of them, so a request that saw
## another context, or one freed under it, answers otherwise. Each of the others notes what it saw
## in `Kv`, for a request to read.
app [program] { jobs: "../../../packages/jobs/main.roc", pf: platform "../../platform/main.roc" }

import pf.Actor
import pf.Events
import pf.Kv
import pf.Log
import pf.Plugin
import pf.Server
import pf.Time
import jobs.Job

program = {
	init!: |started| {
		if started == "fail" {
			return Err("told to fail by --context-file")
		}
		var $words = []
		var $index = 0.U64
		while $index < 1000 {
			$words = $words.append("word ${$index.to_str()}")
			$index = $index + 1
		}
		made_at = Time.now_nanos!({})
		Log.info!(
			"context made",
			{
				started
			},
		)
		# An actor's turn needs the context, which isn't made yet: the host refuses it, and says why.
		asked =
			match Actor.ask!(said, "in init", {}) {
				Ok(answer) => "answered: ${answer}"
				Err(ActorErr(why)) => "refused: ${why}"
			}
		Ok({
			started,
			made_at,
			words: $words,
			nested: { label: "nested in ${started}", sizes: [1, 2, 3] },
			greet: |name| "hello, ${name}, from ${started}",
			asked,
		})
	},
	respond!: |request, context| {
		{ started, made_at, words, nested, greet, .. } = context
		summary = "${started}|${made_at.to_str()}|${words.len().to_str()}|${words.last() ?? "none"}|${nested.label}|${nested.sizes.len().to_str()}|${greet("you")}"
		match request.path {
			"/context" => text(200, summary)
			# Pauses (the call's coroutine waits, and may go on on another thread), then reads it.
			"/slow" => {
				Time.sleep!(20)
				text(200, summary)
			}
			# Reads it, then crashes: the host frees what the call made, and the context stays.
			"/crash" => crash "after reading the context: ${summary}"
			# A stream that reads it after its request has ended, as a call of its own.
			"/stream" =>
				Server.events(
					Events.stream(
						|{ send!, sleep! }| {
							for word in words.take_first(3) {
								send!("${word} ${greet("stream")}")?
								sleep!(5)
							}
							Ok({})
						},
					),
				)
			# What the app's `init!` was told when it asked an actor.
			"/asked-in-init" => text(200, context.asked)
			# A job, which notes what it saw.
			"/job" =>
				match Job.enqueue!(noting, { key: "job" }, { when: Now }) {
					Ok({}) => text(202, "queued")
					Err(JobErr(why)) => text(500, why)
				}
			# An actor's turn, whose reply is what it saw.
			"/actor" =>
				match Actor.ask!(said, "a key", {}) {
					Ok(answer) => text(200, answer)
					Err(ActorErr(why)) => text(500, why)
				}
			# The plugin's call, in a call of its own.
			"/call" =>
				match Plugin.isolated!("seer.say", "a call", 0) {
					Ok(answer) => text(200, answer)
					Err(why) => text(500, why)
				}
			# What the job, the plugin's start and its loop noted.
			"/saw" => {
				noted : Try(Str, [NotFound, BadValue(Str)])
				noted = Kv.get!(request.query)
				text(200, noted ?? "")
			}
			_ => text(404, "no such path")
		}
	},
	database: Sqlite("data/context.db"),
	migrations: [],
	actors: [Actor.handler(said)],
	logs: { format: Auto },
	plugins: plugins.map(Plugin.running),
	routes: [],
}

## A job that notes the context it was given under its input's key.
noting = Job.define(
	"noting",
	|context, { key }| {
		Kv.set!(key, "${key} saw ${context.started}", {})
		Ok({})
	},
)

## A kind of actor, and its one method, which answers with what its turn was given.
echo = Actor.define({ name: "echo", initial: |_key| {} })

said = Actor.method(echo, "said", |{ me, context, state, .. }| { state, reply: "the actor ${Actor.key_of(me)} saw ${context.started}" })

## The jobs plugin, and a plugin of the test's own whose call, loop, start and check each read the
## context.
plugins = [
	Job.plugin({ jobs: [Job.handler(noting)] }),
	{
		name: "seer",
		calls: [{ name: "seer.say", run!: |context, input| Ok("${input} saw ${context.started}") }],
		loops: [{ name: "seer.watch", run!: |context| Kv.set!("loop", "the loop saw ${context.started}", {}) }],
		starts: [
			|context| {
				Kv.set!("start", "the start saw ${context.started}", {})
				Ok({})
			},
		],
		checks: [{ name: "seer.look", run!: |context| Ok("the check saw ${context.started}") }],
	},
]

text : U16, Str -> Server.Response
text = |status, body| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)
