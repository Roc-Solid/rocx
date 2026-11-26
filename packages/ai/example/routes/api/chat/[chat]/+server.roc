import pf.Server
import pf.Endpoint
import pf.Events
import ai.Agent
import ai.Ai
import ai.Message
import ../../../../Chats
import ../../../../Notes
import ../../../../Team

## POST /api/chat/<chat>: the user's message, added to the chat's conversation; the page then
## listens to this path's events for the answer.
post! : { request : Server.Request, params : { chat : Str }, context : c, body : { text : Str } } => Try({}, Endpoint.Refusal)
post! = |{ params, body, .. }| {
	text = body.text.trim()
	if text.is_empty() {
		Err(BadRequest("say something"))
	} else {
		Chats.save!(params.chat, Chats.load!(params.chat).append(Message.user(text)))
		Ok({})
	}
}

## GET /api/chat/<chat>, asked for its events: the assistant's answer to the chat's last message
## (`Team.assistant`, which hands notes to the notes keeper and meals to the nutritionist, each an
## agent it uses as a tool): its text as it is written (`text`); what to show while the team works
## (`status`, from `agent`: a progress note the model wrote, or a tool or agent at work, with what it
## says it is doing); then the notes as they are now (`done`). When the page goes, the model stops.
events! : { request : Server.Request, params : { chat : Str }, context : c } => Try(Events({ text : Str, status : Str, agent : Str, done : Bool, problem : Str, notes : List({ id : U64, text : Str }) }), Endpoint.Refusal)
events! = |{ params, .. }|
	Ok(
		Events.stream(
			|{ send!, .. }| {
				said! = |text| send!({ text: text, status: "", agent: "", done: Bool.False, problem: "", notes: [] })
				shown! = |agent, status| send!({ text: "", status: status, agent: agent, done: Bool.False, problem: "", notes: [] })
				finished! = |problem| send!({ text: "", status: "", agent: "", done: Bool.True, problem: problem, notes: Notes.all!({}) })
				conversation = Chats.load!(params.chat)
				waiting = conversation.last().map_ok(|message| message.role_of() == User) ?? Bool.False
				if !waiting {
					finished!("")
				} else {
					ran = Agent.chat!(
						Team.assistant,
						conversation,
						{},
						|heard|
							match heard {
								Text(text) => said!(text)
								Calling(_) => Ok({})
								Update(Progress({ agent, says })) => shown!(agent, says)
								Update(Using({ agent, tool, says })) => shown!(agent, if (says.is_empty()) "Using ${tool}…" else says)
							},
					)
					match ran {
						Ok(reply) => {
							Chats.save!(params.chat, reply.messages)
							finished!("")
						}
						Err(Stopped(Gone)) => Err(Gone)
						Err(problem) => finished!(Ai.explain(problem))
					}
				}
			},
		),
	)
