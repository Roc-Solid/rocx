import ai.Agent
import Notes

## The chat's agents: two specialists, and the assistant the user talks to, which hands each its
## part as a tool (`as_tool`). The notes keeper has the notes tools; the nutritionist has none, only
## its role. Each agent's turns are logged under its name. The assistant asks for `updates`, so the
## chat hears what to show while the team works: its progress notes (on the models that write them),
## each tool and agent as it starts, with what it says it is doing, the keeper's own tools too.
Team := [].{

	## Keeps the notes, with the notes tools.
	keeper : Agent({})
	keeper = {
		name: "notes_keeper",
		description: "Keeps the user's notes. Give it a task in words: add a note (say exactly what it should say), say what is noted (about something, or all of it), or remove a note. It answers what it did or found.",
		system: Notes.guide,
		tools: Notes.tools,
		effort: Low,
		doing: "Seeing to your notes…",
	}

	## Reckons what a meal holds.
	nutritionist : Agent({})
	nutritionist = {
		name: "nutritionist",
		description: "Reckons the calories in a meal described in words, food by food, and the total. Give it the meal as the user said it.",
		system: "You reckon the calories in a meal, food by food, with a usual portion where no amount is given. Answer with one short line per food and the total, plain text.",
		effort: Low,
		doing: "Counting the calories…",
	}

	## The assistant the chat talks to.
	assistant : Agent({})
	assistant = {
		name: "assistant",
		description: "The user's assistant.",
		system: "You are the user's assistant. Hand anything about their notes to notes_keeper, and anything about what a meal holds to nutritionist; give each everything it needs, as it sees nothing else of the chat. To note a meal's calories, ask nutritionist first, then notes_keeper. Answer in a sentence or two, plain text, no Markdown.",
		tools: [Team.keeper.as_tool(), Team.nutritionist.as_tool()],
		effort: Low,
		updates: Bool.True,
	}
}
