import forms.Form
import forms.Value
import Codes
import Game

## The join forms: a room's code and the name to play under, on the front page; and the name
## alone, on a room's own page, whose path has the code. The pages check them as they are typed,
## and their endpoints (`routes/join/+server.roc`, `routes/play/[code]/+server.roc`) read what
## was posted with the same rules.
Joining := [].{

	## What the form reads: a code, as `Codes.parse` has it, and a name.
	Made : { code : Str, name : Str }

	form : Form(Joining.Made)
	form = {
		code: Form.field("code", Value.text([Trim, Required]).try_map(|typed| Codes.parse(typed).map_err(|_| Custom("code", "A code is four letters, like BKRT.")))),
		name: Joining.name,
	}.Form

	## A room's own join form: the name alone.
	named : Form({ name : Str })
	named = Joining.name.map(|typed| { name: typed })

	## The name to play under.
	name : Form(Str)
	name = Form.text("name", [Trim, CollapseSpaces, Required, MaxLength(Game.longest_name)])
}

expect Joining.form.parse_body("code=bk-rt&name=+Ada+") == Ok({ code: "BKRT", name: "Ada" })

expect
	match Joining.form.parse_body("code=hello&name=") {
		Err(issues) => issues.map(|issue| (issue.field, issue.message)) == [("code", "A code is four letters, like BKRT."), ("name", "Fill this in")]
		Ok(_) => Bool.False
	}
