## How rocx's commands write (D-107): a header naming the command and what it works on, a line for
## each step (`◌ what…` as it runs, `✓ what  time` when done, drawn in place at a terminal), and
## what to do next. At a terminal that takes colour (standard error is one, NO_COLOR is unset and
## TERM isn't `dumb`), the marks and names are coloured; elsewhere (a pipe, CI, a test) the same
## lines are plain text, each step's start a line of its own, so a log reads in order.
import pf.Env
import pf.Stderr
import pf.Time
import Text

Term := [].{

	## Whether rocx writes in colour, with steps drawn in place: standard error is a terminal,
	## NO_COLOR (no-color.org) is unset or empty, and TERM isn't `dumb`.
	styled! : {} => Bool
	styled! = |{}| Stderr.is_terminal!({}) and (Env.var!("NO_COLOR") ?? "").is_empty() and Env.var!("TERM") != Ok("dumb")

	paint : Bool, Str, Str -> Str
	paint = |styled, code, text| if (styled) "\u(1b)[${code}m${text}\u(1b)[0m" else text

	bold : Bool, Str -> Str
	bold = |styled, text| Term.paint(styled, "1", text)

	dim : Bool, Str -> Str
	dim = |styled, text| Term.paint(styled, "2", text)

	green : Bool, Str -> Str
	green = |styled, text| Term.paint(styled, "32", text)

	red : Bool, Str -> Str
	red = |styled, text| Term.paint(styled, "31", text)

	yellow : Bool, Str -> Str
	yellow = |styled, text| Term.paint(styled, "33", text)

	cyan : Bool, Str -> Str
	cyan = |styled, text| Term.paint(styled, "36", text)

	## `text` and spaces after it, to `width` characters.
	pad : Str, U64 -> Str
	pad = |text, columns| {
		length = Text.length(text)
		if (length >= columns) text else Str.concat(text, Str.repeat(" ", columns - length))
	}

	## Spaces, then `text`, to `columns` characters: a time lined up on its right.
	lpad : Str, U64 -> Str
	lpad = |text, columns| {
		length = Text.length(text)
		if (length >= columns) text else Str.concat(Str.repeat(" ", columns - length), text)
	}

	## A command's first line, `  rocx build · my-app → dist/ · arm64mac` (`command`, then `parts`),
	## and a blank line after it.
	header! : Bool, Str, List(Str) => {}
	header! = |styled, command, parts| {
		rest = parts.keep_if(|part| !part.is_empty()).map(|part| Term.dim(styled, " · ").concat(part))
		_ = Stderr.line!("  ${Term.bold(styled, command)}${Str.join_with(rest, "")}")
		_ = Stderr.line!("")
		{}
	}

	## A step begun: `what`, and when it began. At a terminal, `  ◌ what…` with no line's end, which
	## `done!` or `failed!` draws over; elsewhere a line of its own.
	Step : { what : Str, started : U64, styled : Bool }

	## How wide a step's name is padded, for the times after it to line up.
	step_width : U64
	step_width = 28

	begin! : Bool, Str => Step
	begin! = |styled, what| {
		_ =
			if styled {
				Stderr.write!("  ${Term.dim(styled, "◌")} ${what}…")
			} else {
				Stderr.line!("  · ${what}…")
			}
		{ what, started: Time.now_ms!({}), styled }
	}

	## The step done: `  ✓ what  1.2 s`, over its `◌` line at a terminal.
	done! : Step => {}
	done! = |step| Term.finish!(step, Term.green(step.styled, "✓"), Term.dim(step.styled, Term.lpad(Term.took(Time.now_ms!({}) - step.started), 8)))

	## The step done under another name (what it found out it was): `  ✓ server host · SQLite  0.4 s`.
	done_named! : Step, Str => {}
	done_named! = |step, what| Term.done!({ ..step, what })

	## The step done, with `note` (dim) where its time would go: `  ✓ server host  unchanged`.
	done_with! : Step, Str => {}
	done_with! = |step, note| Term.finish!(step, Term.green(step.styled, "✓"), Term.dim(step.styled, note))

	## The step done, said as `text` (`  ✓ built in 0.3 s`) over its `◌` line.
	done_as! : Step, Str => {}
	done_as! = |step, text| {
		line = "  ${Term.green(step.styled, "✓")} ${text}"
		_ = Stderr.write!(if (step.styled) "\r\u(1b)[2K${line}\n" else "${line}\n")
		{}
	}

	## The step failed: `  ✗ what`, over its `◌` line; what went wrong is the caller's to say after.
	failed! : Step => {}
	failed! = |step| Term.finish!(step, Term.red(step.styled, "✗"), "")

	finish! : Step, Str, Str => {}
	finish! = |step, mark, after| {
		line = Text.trim_end("  ${mark} ${Term.pad(step.what, Term.step_width)} ${after}")
		_ = Stderr.write!(if (step.styled) "\r\u(1b)[2K${line}\n" else "${line}\n")
		{}
	}

	## `work!` as a step named `what`: begun, then drawn done or failed by its answer.
	step! : Bool, Str, ({} => Try(a, err)) => Try(a, err)
	step! = |styled, what, work!| {
		step = Term.begin!(styled, what)
		match work!({}) {
			Ok(value) => {
				Term.done!(step)
				Ok(value)
			}
			Err(why) => {
				Term.failed!(step)
				Err(why)
			}
		}
	}

	## Text said in the middle of a step (a compiler's warnings, a note): at a terminal, the step's
	## `◌` line is cleared first, so the text starts a line of its own; the step's `✓` comes after.
	note! : Str => {}
	note! = |text| {
		_ = Stderr.line!(if (Term.styled!({})) "\r\u(1b)[2K${text}" else text)
		{}
	}

	## A line that isn't a step's: `  ✓ text` (a check that passed, said once).
	ok! : Bool, Str => {}
	ok! = |styled, text| {
		_ = Stderr.line!("  ${Term.green(styled, "✓")} ${text}")
		{}
	}

	## A warning's line: `  ! text`, in yellow.
	warn! : Bool, Str => {}
	warn! = |styled, text| {
		_ = Stderr.line!("  ${Term.yellow(styled, "!")} ${text}")
		{}
	}

	## What was made, one `  path  size` line each, the sizes lined up, then a blank line.
	files! : Bool, List({ path : Str, bytes : U64 }) => {}
	files! = |styled, made| {
		widest = made.map(|each| Text.length(each.path)).fold(0, |most, n| if (n > most) n else most)
		_ = Stderr.line!("")
		for each in made {
			_ = Stderr.line!("  ${Term.pad(each.path, widest + 2)}${Term.dim(styled, Term.size(each.bytes))}")
		}
		{}
	}

	## What to do next: a blank line, then `  Run  command`, `       more` (each of `lines` after the
	## first indented under it), the label bold.
	next! : Bool, Str, List(Str) => {}
	next! = |styled, label, lines| {
		_ = Stderr.line!("")
		indent = Str.repeat(" ", Text.length(label) + 4)
		for line in lines.map_with_index(|line, i| { line, i }) {
			_ = Stderr.line!(if (line.i == 0) "  ${Term.bold(styled, label)}  ${line.line}" else "${indent}${line.line}")
		}
		{}
	}

	## Milliseconds as a person reads them: `0.3 s`, `12.4 s`, `2 min 5 s`.
	took : U64 -> Str
	took = |ms|
		if ms >= 60_000 {
			"${(ms // 60_000).to_str()} min ${((ms % 60_000) // 1000).to_str()} s"
		} else {
			tenths = (ms + 50) // 100
			"${(tenths // 10).to_str()}.${(tenths % 10).to_str()} s"
		}

	## Bytes as a person reads them: `812 B`, `14 KB`, `4.6 MB` (powers of 1000, as a download says).
	size : U64 -> Str
	size = |bytes|
		if bytes < 1000 {
			"${bytes.to_str()} B"
		} else if bytes < 1_000_000 {
			"${((bytes + 500) // 1000).to_str()} KB"
		} else {
			tenths = (bytes + 50_000) // 100_000
			"${(tenths // 10).to_str()}.${(tenths % 10).to_str()} MB"
		}
}

expect Term.took(240) == "0.2 s"
expect Term.took(38_160) == "38.2 s"
expect Term.took(125_000) == "2 min 5 s"
expect Term.size(812) == "812 B"
expect Term.size(14_200) == "14 KB"
expect Term.size(4_611_072) == "4.6 MB"
expect Term.pad("ab", 4) == "ab  "
expect Term.paint(Bool.False, "32", "ok") == "ok"
expect Term.paint(Bool.True, "32", "ok") == "\u(1b)[32mok\u(1b)[0m"
expect Term.lpad("0.1 s", 8) == "   0.1 s"
