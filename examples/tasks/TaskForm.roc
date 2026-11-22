import forms.Form
import forms.Value
import forms.Date

## The app's forms, each written once with packages/forms. The endpoint a form posts to reads what
## was posted with it, into a typed record, or refuses it (422) with each field's issues; the add
## and new-list forms check what is typed with the very same rules as it is typed (`LiveForm`).
TaskForm := [].{

	## A task's title: something to read, not a novel.
	title : Form(Str)
	title = Form.text("title", [Trim, CollapseSpaces, Required, MaxLength(120)])

	## A new task, from the form under a list: a title, and maybe a day it is due and someone to do it.
	adding : Form({ title : Str, due : Try(Date, [Missing]), assignee : Try(Str, [Missing]) })
	adding = {
		title: TaskForm.title,
		due: Form.optional("due", Value.date([])),
		assignee: Form.optional("assignee", Value.text([Trim])),
	}.Form

	## A task as its page edits it: everything about it.
	editing : Form({ title : Str, notes : Str, due : Try(Date, [Missing]), assignee : Try(Str, [Missing]), done : Bool })
	editing = {
		title: TaskForm.title,
		notes: Form.text("notes", [Trim, MaxLength(2000)]),
		due: Form.optional("due", Value.date([])),
		assignee: Form.optional("assignee", Value.text([Trim])),
		done: Form.checkbox("done", []),
	}.Form

	## A new list, from the front page: its name.
	new_list : Form(Str)
	new_list = Form.text("name", [Trim, CollapseSpaces, Required, MaxLength(60)])
}

expect TaskForm.adding.parse_body("title=++Book+the+van++&due=&assignee=") == Ok({ title: "Book the van", due: Err(Missing), assignee: Err(Missing) })
expect TaskForm.adding.parse_body("title=Book+the+van&due=2026-12-01&assignee=jun").map_ok(|task| task.due.map_ok(Date.to_str)) == Ok(Ok("2026-12-01"))
expect TaskForm.adding.parse_body("title=+&due=2026-02-30&assignee=").map_err(|issues| issues.map(|issue| issue.field)) == Err(["title", "due"])
expect TaskForm.editing.parse_body("title=Pick+a+date&notes=&due=&assignee=mila&done=on").map_ok(|task| task.done) == Ok(Bool.True)
expect TaskForm.editing.parse_body("title=Pick+a+date&notes=&due=&assignee=mila").map_ok(|task| task.done) == Ok(Bool.False)
expect TaskForm.new_list.parse_body("name=Team++offsite") == Ok("Team offsite")
