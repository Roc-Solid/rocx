import Fs
import Term
import Text
import Versions

## `rocx agents [dir] [--force]` (D-108): rocx's rules for coding agents in the app's AGENTS.md, a
## block between two markers that rocx owns, and a CLAUDE.md that imports AGENTS.md when the app has
## none. The block's text is this rocx's `agents/block.md`; it points at `agents/guide.md`, which the
## app reaches as `.rocx/agents/guide.md`, the guide for the rocx it builds with. The start marker
## holds the text's fingerprint, so `rocx check` tells a block of another rocx (`Stale`) and one
## someone edited (`Edited`) from one that is up to date. Everything outside the markers is the
## app's, and kept as it is; a block someone edited is replaced only with `--force`. `rocx new`
## writes both files.
Agents := [].{

	## AGENTS.md's rocx block: the text before it, the fingerprint its start marker holds, the text
	## between its markers, and the text after it.
	Block : { before : Str, print : Str, inside : Str, after : Str }

	## What `rocx agents` makes of an AGENTS.md: a new file, the block added at the end of one that
	## had none, or replaced; or nothing to do; or a refusal.
	Update : [Created(Str), Added(Str), Replaced(Str), Unchanged, Edited, Unclosed]

	## The block's text in the rocx at `home`.
	block_path : Str -> Str
	block_path = |home| Fs.join([home, "agents", "block.md"])

	## The block's start marker, before its fingerprint.
	start : Str
	start = "<!-- rocx:start "

	## The block's end marker.
	end : Str
	end = "<!-- rocx:end -->"

	## A text's fingerprint: the first 16 hex digits of its SHA-256, its line endings `\n` (an editor
	## that writes `\r\n` changes nothing).
	fingerprint : Str -> Str
	fingerprint = |text| {
		unix = text.to_utf8().keep_if(|byte| byte != '\r')
		Text.cut(Crypto.SHA256.hash(unix).to_hex().to_utf8(), 0, 16)
	}

	## The block's text, ending with a newline.
	ended : Str -> Str
	ended = |text| if (text.ends_with("\n")) text else "${text}\n"

	## The block as AGENTS.md holds it: the start marker with the text's fingerprint, the text, the
	## end marker.
	marked : Str -> Str
	marked = |text| {
		body = Agents.ended(text)
		"${Agents.start}${Agents.fingerprint(body)} · written by `rocx agents`, which rewrites this block as rocx changes: write the app's own notes outside it -->\n${body}${Agents.end}\n"
	}

	## A new AGENTS.md's opening, before the block.
	heading : Str
	heading = "# AGENTS.md\n\nNotes for coding agents working on this app. The block below is rocx's (`rocx agents`\nrewrites it as rocx changes); write the app's own notes outside it.\n\n"

	## AGENTS.md's rocx block, if it has one; `Unclosed` for a start marker with no end after it.
	found : Str -> [Absent, Found(Agents.Block), Unclosed]
	found = |file| {
		bytes = file.to_utf8()
		at =
			match Text.index_of(bytes, Agents.start.to_utf8(), 0) {
				Ok(i) => i
				Err(NotFound) => return Absent
			}
		marker_end = Text.line_end(bytes, at)
		closing =
			match Text.index_of(bytes, Agents.end.to_utf8(), marker_end) {
				Ok(i) => i
				Err(NotFound) => return Unclosed
			}
		print_at = at + Agents.start.to_utf8().len()
		print = Text.cut(bytes, print_at, Text.run_end(bytes, print_at, Text.is_alnum))
		after_marker = closing + Agents.end.to_utf8().len()
		after_at = if (Text.at(bytes, after_marker) == '\n') after_marker + 1 else after_marker
		Found({ before: Text.cut(bytes, 0, at), print, inside: Text.cut(bytes, marker_end + 1, closing), after: Text.rest(bytes, after_at) })
	}

	## AGENTS.md as `rocx agents` leaves it, from what it holds (`""` when there is none) and the
	## block's text; with `force`, a block someone edited is replaced too.
	updated : Str, Str, Bool -> Agents.Update
	updated = |file, text, force| {
		block = Agents.marked(text)
		if file.is_empty() {
			return Created("${Agents.heading}${block}")
		}
		match Agents.found(file) {
			Absent => Added("${Text.trim_end(file)}\n\n${block}")
			Unclosed => if (force) Added("${Text.trim_end(file)}\n\n${block}") else Unclosed
			Found(held) => {
				written = Agents.fingerprint(held.inside) == held.print
				if written and held.print == Agents.fingerprint(Agents.ended(text)) {
					Unchanged
				} else if written or force {
					Replaced("${held.before}${block}${held.after}")
				} else {
					Edited
				}
			}
		}
	}

	## How AGENTS.md's block (`file`, "" for none) stands against this rocx's text: up to date, of
	## another rocx, edited since rocx wrote it, or not there.
	standing : Str, Str -> [Current, Stale, Edited, Absent]
	standing = |file, text|
		match Agents.found(file) {
			Absent => Absent
			Unclosed => Edited
			Found(held) =>
				if Agents.fingerprint(held.inside) != held.print {
					Edited
				} else if held.print == Agents.fingerprint(Agents.ended(text)) {
					Current
				} else {
					Stale
				}
		}

	## `rocx agents`'s words (after `agents`), at the rocx at `home`.
	run! : List(Str), Str => Try({}, [Exit(I32)])
	run! = |args, home| {
		force = args.contains("--force")
		given = args.keep_if(|arg| arg != "--force")
		if given.len() > 1 or given.any(|arg| arg.starts_with("-")) {
			return Versions.failed!("usage: rocx agents [dir] [--force]")
		}
		dir = Fs.resolve(Fs.cwd!(), [given.first() ?? "."])
		if !Fs.is_dir!(dir) {
			return Versions.failed!("rocx agents: no directory ${given.first() ?? "."}")
		}
		styled = Term.styled!({})
		Term.header!(styled, "rocx agents", [Fs.basename(Fs.real!(dir))])
		match Agents.write!(dir, home, force) {
			Ok(said) => {
				for line in said {
					match line {
						Done(text) => Term.ok!(styled, text)
						Hint(text) => Term.warn!(styled, text)
					}
				}
				Ok({})
			}
			Err(why) => Versions.failed!("rocx agents: ${why}")
		}
	}

	## Writes the block into `dir`'s AGENTS.md, and a CLAUDE.md that imports it when `dir` has none;
	## what was done, a line each, or why nothing was.
	write! : Str, Str, Bool => Try(List([Done(Str), Hint(Str)]), Str)
	write! = |dir, home, force| {
		text =
			match Fs.read!(Agents.block_path(home)) {
				Ok(read) => read
				Err(_) => return Err("this rocx has no ${Agents.block_path(home)}")
			}
		path = Fs.join([dir, "AGENTS.md"])
		(made, said) =
			match Agents.updated(Fs.read_or_empty!(path), text, force) {
				Created(new) => (Some(new), "AGENTS.md made, with rocx's block")
				Added(new) => (Some(new), "AGENTS.md: rocx's block added at its end")
				Replaced(new) => (Some(new), "AGENTS.md: rocx's block brought up to date")
				Unchanged => (None, "AGENTS.md: rocx's block is up to date")
				Edited => return Err("AGENTS.md's rocx block was edited since rocx wrote it: move those notes outside the block and run rocx agents again, or rocx agents --force to replace it")
				Unclosed => return Err("AGENTS.md has rocx's start marker and no ${Agents.end} after it: put the end marker back, or rocx agents --force to add a new block")
			}
		match made {
			Some(new) =>
				match Fs.write!(path, new) {
					Ok({}) => {}
					Err(CantWrite(why)) => return Err("AGENTS.md: ${why}")
				}
			None => {}
		}
		claude = Fs.join([dir, "CLAUDE.md"])
		imported =
			if !Fs.exists!(claude) {
				match Fs.write!(claude, "@AGENTS.md\n") {
					Ok({}) => [Done("CLAUDE.md made: it imports AGENTS.md, for Claude Code")]
					Err(CantWrite(why)) => return Err("CLAUDE.md: ${why}")
				}
			} else if Fs.read_or_empty!(claude).contains("AGENTS.md") {
				[]
			} else {
				[Hint("CLAUDE.md doesn't name AGENTS.md: a line `@AGENTS.md` in it has Claude Code read it")]
			}
		Ok([Done(said)].concat(imported))
	}

	## The block's standing in `dir`'s AGENTS.md against the rocx at `home` (`Absent` when this rocx
	## has no block to compare with), for `rocx check`.
	standing! : Str, Str => [Current, Stale, Edited, Absent]
	standing! = |dir, home|
		match Fs.read!(Agents.block_path(home)) {
			Ok(text) => Agents.standing(Fs.read_or_empty!(Fs.join([dir, "AGENTS.md"])), text)
			Err(_) => Absent
		}
}

expect Agents.fingerprint("a\r\nb\n") == Agents.fingerprint("a\nb\n")
expect Agents.fingerprint("a\n").to_utf8().len() == 16
expect Agents.found("# Notes\n") == Absent
expect Agents.found("x\n<!-- rocx:start abc -->\nhi\n") == Unclosed

# A new file: the heading, then the block, which reads back as rocx wrote it.
expect {
	made = Agents.updated("", "rules\n", Bool.False)
	match made {
		Created(new) => new.starts_with("# AGENTS.md") and Agents.standing(new, "rules\n") == Current
		_ => Bool.False
	}
}

# A file of the app's own: the block added at its end, the rest kept.
expect {
	match Agents.updated("# Our notes\n\nKeep it tidy.\n", "rules\n", Bool.False) {
		Added(new) => new.starts_with("# Our notes\n\nKeep it tidy.\n\n<!-- rocx:start ") and new.ends_with("rules\n<!-- rocx:end -->\n")
		_ => Bool.False
	}
}

# A block of another rocx: replaced, what is around it kept; the same text again: nothing to do.
expect {
	old = "Before.\n\n${Agents.marked("old rules\n")}\nAfter.\n"
	match Agents.updated(old, "new rules\n", Bool.False) {
		Replaced(new) => new == "Before.\n\n${Agents.marked("new rules\n")}\nAfter.\n" and Agents.updated(new, "new rules\n", Bool.False) == Unchanged
		_ => Bool.False
	}
}
expect Agents.standing("Before.\n${Agents.marked("old rules\n")}", "new rules\n") == Stale

# A block someone edited: refused, replaced with force; `rocx check` says so.
expect {
	edited = Str.replace_first(Agents.marked("rules\n"), "rules", "rules, and ours")
	Agents.updated(edited, "rules\n", Bool.False) == Edited and Agents.standing(edited, "rules\n") == Edited
}
expect {
	edited = Str.replace_first(Agents.marked("rules\n"), "rules", "rules, and ours")
	match Agents.updated(edited, "rules\n", Bool.True) {
		Replaced(new) => new == Agents.marked("rules\n")
		_ => Bool.False
	}
}
expect Agents.standing("# Ours\n", "rules\n") == Absent
