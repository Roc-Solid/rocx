import tools.JsonValue
import tools.Tool
import Ai
import Message
import Turn

## An agent: a model with a role (its system prompt), the tools it may use, and how hard it thinks,
## made once and asked as often as needed (`ask!`, `chat!`). An agent is also a tool (`as_tool`):
## another agent can hand it a task, as it would call any tool, and gets its answer back. So a team
## is built of plain values: specialists, each with its own prompt and tools, and an agent that
## knows when to ask which.
##
##     keeper : Agent({})
##     keeper = { name: "notes_keeper", description: "Keeps the user's notes: give it a task in words", system: "You keep notes…", tools: Notes.tools }
##
##     assistant : Agent({})
##     assistant = { name: "assistant", description: "The user's assistant", system: "Hand note keeping to notes_keeper…", tools: [keeper.as_tool(), nutritionist.as_tool()] }
##
##     reply = Agent.chat!(assistant, conversation, {}, heard!)?
##
## Each agent's turns are on the log with its name (`ai.turn`'s `label`), so what each spends can
## be told apart. The context (`ctx`) is the caller's: every agent in a team gives its tools the one
## it was given.
Agent(ctx) := {
	name : Str,
	description : Str,
	system : Str,
	tools : List(Tool(ctx)) ?? [],
	model : Str ?? "",
	effort : [Low, Medium, High, XHigh, Max] ?? Medium,
	max_turns : U64 ?? 10,
	max_tokens : U64 ?? 64_000,
}.{

	## The agent's answer to `prompt`, a conversation of one message: its tools run until it is
	## done (`Ai.run!`), `heard!` given its text as it is written and each tool's name as it is
	## about to use it.
	ask! : Agent(ctx), Str, ctx, (Turn.Heard => Try({}, err)) => Try(Ai.Reply, Ai.Problem(err))
	ask! = |agent, prompt, context, heard!| Agent.chat!(agent, [Message.user(prompt)], context, heard!)

	## The agent's next turn in a conversation (`messages`, the user's last): a chat's, or an
	## earlier reply's `messages` with a new `Message.user` after them.
	chat! : Agent(ctx), List(Message), ctx, (Turn.Heard => Try({}, err)) => Try(Ai.Reply, Ai.Problem(err))
	chat! = |agent, messages, context, heard!| {
		request : Ai.Request
		request = { messages: messages, system: agent.system, model: agent.model, effort: agent.effort, max_turns: agent.max_turns, max_tokens: agent.max_tokens, label: agent.name }
		Ai.run!(request, agent.tools, context, heard!)
	}

	## The agent as a tool, for another agent (or an MCP server): its name and description are the
	## tool's, and it takes one argument, `task`, the work it is handed, in words. The task is a
	## conversation of its own (the agent sees nothing of the one it was called from); its answer's
	## text is the tool's result, and what went wrong (`Ai.explain`) a tool error the calling model
	## can act on. Its own work isn't streamed: the caller hears `Calling(name)`, then the answer.
	as_tool : Agent(ctx) -> Tool(ctx)
	as_tool = |agent|
		Tool.new(
			agent.name,
			agent.description,
			task_schema,
			|arguments, context|
				match arguments.get("task") {
					Ok(String(task)) if !task.trim().is_empty() =>
						match Agent.ask!(agent, task, context, |_| Ok({})) {
							Ok(reply) => Tool.text(reply.text)
							Err(problem) => Refused("${agent.name} couldn't do it: ${Ai.explain(problem)}")
						}
					_ => Refused("${agent.name} needs a task: what to do, in words.")
				},
		)
}

## What an agent takes as a tool: its task, in words.
task_schema : Str
task_schema = "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\",\"description\":\"The work to hand over, in words: what to do, with everything needed to do it, as the agent sees nothing else of the conversation.\"}},\"required\":[\"task\"]}"

expect {
	helper : Agent({})
	helper = { name: "helper", description: "Helps", system: "Help." }
	listed = Tool.to_json(helper.as_tool())
	listed.get("name") == Ok(String("helper")) and listed.get("inputSchema").map_ok(JsonValue.to_str) == Ok(task_schema)
}
