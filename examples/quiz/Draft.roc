import forms.Form
import forms.Value
import Game

## A new question set, as the editor (`routes/sets/new/+page.rocx`) has it typed: a title, a line
## about it, and its questions as plain text, one block each, quick to write and to paste:
##
## ```
## Which planet has the most moons?
## - Mars
## * Saturn
## - Venus
##
## How many legs has a spider?
## - Six
## * Eight
## ```
##
## A block's first line is the question; each line after it is a choice, `*` the right one and `-`
## the others. One schema (packages/forms) reads it: the page checks it as it is typed, and the
## endpoint (`routes/sets/+server.roc`) reads it into a `Draft.Made` with the very same rules, or
## refuses it with the same issues.
Draft := [].{

	## A set, read: what `Sets.create!` writes.
	Made : { title : Str, blurb : Str, questions : List(Game.Question) }

	## A set, as the host's list shows it (`Sets.all!`, `GET /host`). Here, not in `Sets`, which
	## imports `Db`: the browser's copy of `Generated/Api` names it too.
	Summary : { id : I64, title : Str, blurb : Str, questions : I64 }

	## The most questions a set may have.
	most_questions : U64
	most_questions = 30

	## The editor's form.
	form : Form(Draft.Made)
	form = {
		title: Form.text("title", [Trim, CollapseSpaces, Required, MaxLength(60)]),
		blurb: Form.text("blurb", [Trim, CollapseSpaces, MaxLength(140)]),
		questions: Form.field("questions", Value.text([Trim, Required]).try_map(|typed| Draft.read(typed).map_err(|why| Custom("questions", why)))),
	}.Form

	## The questions in `text`, or what is wrong with the first block that is: said so that it can be
	## fixed without counting lines ("Question 2: …").
	read : Str -> Try(List(Game.Question), Str)
	read = |typed| {
		found = Draft.blocks(typed)
		if found.is_empty() {
			Err("Write at least one question.")
		} else if found.len() > Draft.most_questions {
			Err("A set has at most ${Draft.most_questions.to_str()} questions; this one has ${found.len().to_str()}.")
		} else {
			var $read = []
			var $problem = ""
			for lines in found {
				if $problem.is_empty() {
					match Draft.block(lines) {
						Ok(asked) => {
							$read = $read.append(asked)
						}
						Err(why) => {
							$problem = "Question ${($read.len() + 1).to_str()}: ${why}"
						}
					}
				}
			}
			if ($problem.is_empty()) Ok($read) else Err($problem)
		}
	}

	## The text's blocks: its lines, trimmed, in runs between blank lines.
	blocks : Str -> List(List(Str))
	blocks = |typed| {
		lines = typed.replace_each("\r", "").split_on("\n").map(|line| line.trim())
		var $blocks = []
		var $block = []
		for line in lines {
			if line.is_empty() {
				if !$block.is_empty() {
					$blocks = $blocks.append($block)
					$block = []
				}
			} else {
				$block = $block.append(line)
			}
		}
		if ($block.is_empty()) $blocks else $blocks.append($block)
	}

	## One block, as a question.
	block : List(Str) -> Try(Game.Question, Str)
	block = |lines|
		match lines {
			[] => Err("it's empty.")
			[prompt, .. as rest] => {
				marked = rest.map(|line| if (line.starts_with("*")) (Bool.True, line.drop_prefix("*").trim()) else if (line.starts_with("-")) (Bool.False, line.drop_prefix("-").trim()) else (Bool.False, ""))
				rights = marked.keep_if(|(right, _)| right).len()
				if prompt.starts_with("*") or prompt.starts_with("-") {
					Err("start with the question, then its choices.")
				} else if Str.count_utf8_bytes(prompt) > 200 {
					Err("the question is too long (200 letters at most).")
				} else if rest.any(|line| !line.starts_with("*") and !line.starts_with("-")) {
					Err("start each choice with * (the right one) or - (a wrong one).")
				} else if marked.any(|(_, choice)| choice.is_empty()) {
					Err("a choice is empty.")
				} else if rest.len() < 2 or rest.len() > 4 {
					Err("give it two to four choices.")
				} else if rights != 1 {
					Err("mark exactly one choice right, with *.")
				} else if marked.any(|(_, choice)| Str.count_utf8_bytes(choice) > 80) {
					Err("a choice is too long (80 letters at most).")
				} else {
					answer = marked.find_first_index(|(right, _)| right) ?? 0
					Ok({ prompt, choices: marked.map(|(_, choice)| choice), answer })
				}
			}
		}

	## A set as the editor's text: what `read` reads back the same.
	write : List(Game.Question) -> Str
	write = |set|
		Str.join_with(
			set.map(
				|asked| {
					choices = asked.choices.map_with_index(|choice, at| "${if (at == asked.answer) "*" else "-"} ${choice}")
					Str.join_with([asked.prompt].concat(choices), "\n")
				},
			),
			"\n\n",
		)
}

spider : Str
spider = "How many legs has a spider?\n- Six\n* Eight"

expect Draft.read(spider) == Ok([{ prompt: "How many legs has a spider?", choices: ["Six", "Eight"], answer: 1 }])

# Blocks between blank lines, however many, with spaces and Windows line ends about.
expect
	Draft.read("\r\n  Which is a fruit?\r\n*  Plum \r\n- Leek\r\n\r\n\r\n${spider}\n\n")
		== Ok([{ prompt: "Which is a fruit?", choices: ["Plum", "Leek"], answer: 0 }, { prompt: "How many legs has a spider?", choices: ["Six", "Eight"], answer: 1 }])

expect Draft.read("") == Err("Write at least one question.")
expect Draft.read("Which is a fruit?\n- Plum\n- Leek") == Err("Question 1: mark exactly one choice right, with *.")
expect Draft.read("${spider}\n\nWhich is a fruit?\n* Plum\n* Leek") == Err("Question 2: mark exactly one choice right, with *.")
expect Draft.read("Which is a fruit?\n* Plum") == Err("Question 1: give it two to four choices.")
expect Draft.read("Which is a fruit?\n* Plum\nLeek") == Err("Question 1: start each choice with * (the right one) or - (a wrong one).")
expect Draft.read("* Plum\n- Leek") == Err("Question 1: start with the question, then its choices.")
expect Draft.read("Which?\n* Plum\n- ") == Err("Question 1: a choice is empty.")
expect Draft.read("Q?\n* a\n- b\n- c\n- d\n- e") == Err("Question 1: give it two to four choices.")

# What `write` writes, `read` reads back.
expect {
	set = [{ prompt: "Which is a fruit?", choices: ["Leek", "Plum", "Kale"], answer: 1 }, { prompt: "How many legs has a spider?", choices: ["Six", "Eight"], answer: 1 }]
	Draft.read(Draft.write(set)) == Ok(set)
}

# The form reads a whole post, and says what is wrong field by field.
expect
	Draft.form.parse_body("title=+Odds++and+ends+&blurb=&questions=${"How many legs has a spider?%0A- Six%0A* Eight"}")
		== Ok({ title: "Odds and ends", blurb: "", questions: [{ prompt: "How many legs has a spider?", choices: ["Six", "Eight"], answer: 1 }] })

expect
	match Draft.form.parse_body("title=&questions=Which%3F%0A- a%0A- b") {
		Err(issues) => issues.map(|issue| (issue.field, issue.message)) == [("title", "Fill this in"), ("questions", "Question 1: mark exactly one choice right, with *.")]
		Ok(_) => Bool.False
	}
