## rocx fmt: a .rocx file's Roc formatted by `roc fmt`, its markup kept as written (was
## src/format.mjs). Roc can't read markup, so each markup expression, and each <style> stylesheet, is
## swapped for a placeholder Roc formats as it would anything in its place, and put back afterwards,
## its later lines moved as far as its first line's line moved. The markup, and the Roc in its holes,
## stay as they are.
import pf.Cmd
import pf.OsStr
import Text
import Value
import Transpile

Format := [].{

	## What can go wrong formatting: a problem in a .rocx file's markup (`Rocx`), or something it
	## can't transpile (`Crash`); `roc fmt` couldn't read its Roc (`FormatError`, its reasons at the
	## file's lines); the markup went missing in what roc wrote (`Lost`); there is no `roc` to run
	## (`NoRoc`, the command that was tried), or it couldn't be run (`CantRun`).
	Problem : [Rocx(Transpile.RocxError), Crash(Str), FormatError(Str), Lost(Str), NoRoc(Str), CantRun(Str)]

	## `roc fmt --stdin`: `code` formatted, with `roc`. When roc can't read it, a FormatError giving its
	## reasons at the file's lines.
	roc_fmt! : Str, Str, Str => Try(Str, [FormatError(Str), NoRoc(Str), CantRun(Str)])
	roc_fmt! = |code, roc, file| Format.roc_fmt_at!(code, roc, file, |n| n)

	## `roc_fmt!`, with `line` giving the file's line for a line of `code` (both from 1).
	roc_fmt_at! : Str, Str, Str, (U64 -> U64) => Try(Str, [FormatError(Str), NoRoc(Str), CantRun(Str)])
	roc_fmt_at! = |code, roc, file, line| {
		command = Cmd.new(OsStr.from_str(roc)).args([OsStr.from_str("fmt"), OsStr.from_str("--stdin")]).stdin(Bytes(code.to_utf8())).stdout(Capture).stderr(Capture)
		match command.run!() {
			Err(CmdErr(StartFailed(NotFound, _))) => Err(NoRoc(roc))
			Err(CmdErr(problem)) => Err(CantRun("${roc}: ${problem.to_str()}"))
			Err(Interrupted) => Err(CantRun("${roc}: interrupted"))
			Ok(output) =>
				match output.status {
					Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes))
					_ => {
						said = "${Str.from_utf8_lossy(output.stdout_bytes)}\n${Str.from_utf8_lossy(output.stderr_bytes)}"
						reasons = said.split_on("\n").map(Text.trim).keep_if(|one| one != "" and one != "Errors:").map(
							|one|
								match Format.located(one) {
									Some(at) => "${file}:${line(at.line).to_str()}:${at.column}: ${at.reason}"
									None => "${file}: ${one}"
								},
						)
						Err(FormatError(if (reasons.is_empty()) "${file}: roc fmt can't read it" else Str.join_with(reasons, "\n")))
					}
				}
		}
	}

	## `/^(.*?),? at (\d+):(\d+)$/` on one of roc's reasons: what it says, and where.
	located : Str -> [Some({ reason : Str, line : U64, column : Str }), None]
	located = |said| {
		bytes = said.to_utf8()
		ends_here = |r| {
			if !Text.starts_with_at(bytes, " at ".to_utf8(), r) {
				None
			} else {
				d1 = Text.run_end(bytes, r + 4, Text.is_digit)
				d2 = Text.run_end(bytes, d1 + 1, Text.is_digit)
				if d1 > r + 4 and Text.at(bytes, d1) == ':' and d2 > d1 + 1 and d2 == bytes.len() {
					Some({ line: Str.from_utf8_lossy(Text.slice(bytes, r + 4, d1)), column: Text.cut(bytes, d1 + 1, d2) })
				} else {
					None
				}
			}
		}
		var $l = 0
		while $l < bytes.len() {
			b = Text.at(bytes, $l)
			# `.` doesn't match a line terminator: the prefix can't have one.
			if b == '\r' or b == '\n' or (b == 0xE2 and Text.at(bytes, $l + 1) == 0x80 and (Text.at(bytes, $l + 2) == 0xA8 or Text.at(bytes, $l + 2) == 0xA9)) {
				return None
			}
			found =
				if b == ',' {
					match ends_here($l + 1) {
						Some(m) => Some(m)
						None => ends_here($l)
					}
				} else {
					ends_here($l)
				}
			match found {
				Some(m) => return Some({ reason: Text.cut(bytes, 0, $l), line: U64.from_str(m.line) ?? 0, column: m.column })
				None => {}
			}
			$l = $l + 1
		}
		None
	}

	## The spaces and tabs a line starts with.
	indent_of : Str -> Str
	indent_of = |line| Text.indent(line)

	## Where each <pre> or <textarea> in some markup keeps its text: from the end of its opening tag to
	## the start of its closing one (`/<(pre|textarea)\b[^>]*>([^]*?)<\/\1\s*>/gi`).
	preformatted_ranges : List(U8) -> List({ open : U64, close : U64 })
	preformatted_ranges = |text| {
		var $found = []
		var $i = 0
		while $i < text.len() {
			tag =
				if Text.at(text, $i) != '<' {
					None
				} else if Transpile.caseless_at(text, "pre", $i + 1) and !Text.is_word(Text.at(text, $i + 4)) {
					Some("pre")
				} else if Transpile.caseless_at(text, "textarea", $i + 1) and !Text.is_word(Text.at(text, $i + 9)) {
					Some("textarea")
				} else {
					None
				}
			matched =
				match tag {
					None => None
					Some(name) => {
						opened = Text.run_end(text, $i + 1 + name.to_utf8().len(), |b| b != '>')
						if opened >= text.len() {
							None
						} else {
							match Transpile.closing_tag(text, opened + 1, name) {
								Ok(closing) => Some({ open: opened + 1, close: closing.at, end: closing.end })
								Err(_) => None
							}
						}
					}
				}
			match matched {
				Some(m) => {
					$found = $found.append({ open: m.open, close: m.close })
					$i = m.end
				}
				None => {
					$i = $i + 1
				}
			}
		}
		$found
	}

	## `text`'s lines after its first, moved from `from` (the indent they were written against) to `to`.
	## A line with less indent than `from`, or one a <pre> or <textarea> keeps as text, stays.
	moved : Str, Str, Str -> List(Str)
	moved = |text, from, to| {
		text_lines = text.split_on("\n")
		if from == to {
			return text_lines
		}
		kept = Format.preformatted_ranges(text.to_utf8())
		var $offset = 0
		var $out = []
		var $n = 0
		for line in text_lines {
			start = $offset
			$offset = $offset + line.to_utf8().len() + 1
			stays = $n == 0 or !line.starts_with(from) or kept.any(|r| r.open < start and start <= r.close)
			$out = $out.append(if (stays) line else to.concat(line.drop_prefix(from)))
			$n = $n + 1
		}
		$out
	}

	## The markup a file's Roc holds, outermost only: markup in a hole is its markup's.
	outermost : List({ kind : Str, from : U64, to : U64 }) -> List({ kind : Str, from : U64, to : U64 })
	outermost = |spans|
		spans.sort_with(|a, b| if (a.from < b.from) Before else if (a.from > b.from) After else Same).fold(
			[],
			|found, span|
				match found.last() {
					Ok(last) => if (span.from >= last.to) found.append(span) else found
					Err(_) => found.append(span)
				},
		)

	## The line (from 1) of the byte at `pos`: `source.slice(0, pos).split("\n").length`.
	line_at : List(U8), U64 -> U64
	line_at = |bytes, pos| Text.newlines(bytes, 0, pos) + 1

	## A .rocx file, its Roc as `roc fmt` writes it and its markup as written.
	format_rocx! : Str, Str, Str => Try(Str, Problem)
	format_rocx! = |source, file, roc| {
		bytes = source.to_utf8()
		var $prefix = "rocx_fmt_"
		while source.contains($prefix) {
			$prefix = $prefix.concat("x")
		}
		prefix = $prefix
		spans =
			match Transpile.markup_spans(source, file, { module_path: "", client: Bool.False, contexts: [], views: [], route: Bool.False }) {
				Ok(found) => found
				Err(Rocx(e)) => return Err(Rocx(e))
				Err(Crash(message)) => return Err(Crash(message))
			}
		# Each piece of markup, and how it stands in for it: `Inline`, a name (on one line, or after code
		# on its line); `Lines`, a `\\` string a line per line it has, so that Roc keeps it on its own
		# lines; `Sheet`, a comment (a stylesheet or a story stands where definitions go).
		pieces = Format.outermost(spans).map_with_index(
			|span, i| {
				text = Text.cut(bytes, span.from, span.to)
				line_begins = Text.line_start(bytes, span.from)
				own_line = Text.is_blank(Text.cut(bytes, line_begins, span.from))
				kind = if (span.kind == "style" or span.kind == "story") Sheet else if (own_line and text.contains("\n")) Lines else Inline
				{ from: span.from, to: span.to, text, kind, name: "${prefix}${i.to_str()}", indent: Text.indent(Text.cut(bytes, line_begins, bytes.len())) }
			},
		)
		# What roc reads, and for each of its lines the file's line, for roc's reasons.
		var $masked = ""
		var $line = 1
		var $lines = [1]
		var $at = 0
		for piece in pieces {
			before = Text.cut(bytes, $at, piece.from)
			$masked = $masked.concat(before)
			for b in before.to_utf8() {
				if b == '\n' {
					$line = $line + 1
					$lines = $lines.append($line)
				}
			}
			written = piece.text.split_on("\n")
			match piece.kind {
				Lines => {
					var $n = 0
					for said in written {
						if $n > 0 {
							$masked = $masked.concat("\n").concat(Text.indent(said))
							$line = $line + 1
							$lines = $lines.append($line)
						}
						$masked = $masked.concat("\\\\ ${piece.name}")
						$n = $n + 1
					}
					# What follows on its last line would be in the string: it goes on the next.
					rest_end = Text.line_end(bytes, piece.to)
					if !Text.is_blank(Text.cut(bytes, piece.to, rest_end)) {
						$masked = $masked.concat("\n")
						$lines = $lines.append($line)
					}
				}
				Sheet => {
					$masked = $masked.concat("# ${piece.name}")
					$line = $line + written.len() - 1
				}
				Inline => {
					$masked = $masked.concat(piece.name)
					$line = $line + written.len() - 1
				}
			}
			$at = piece.to
		}
		after = Text.cut(bytes, $at, bytes.len())
		$masked = $masked.concat(after)
		for b in after.to_utf8() {
			if b == '\n' {
				$line = $line + 1
				$lines = $lines.append($line)
			}
		}
		lines = $lines
		final_line = $line
		formatted =
			match Format.roc_fmt_at!($masked, roc, file, |n| if (n >= 1) lines.get(n - 1) ?? final_line else final_line) {
				Ok(text) => text
				Err(FormatError(message)) => return Err(FormatError(message))
				Err(NoRoc(command)) => return Err(NoRoc(command))
				Err(CantRun(message)) => return Err(CantRun(message))
			}
		var $out = formatted
		for piece in pieces {
			written = piece.text.split_on("\n")
			lost = Lost("rocx fmt: lost the markup at ${file}:${Format.line_at(bytes, piece.from).to_str()}")
			match piece.kind {
				Lines => {
					marked = "\\\\ ${piece.name}"
					out_lines = $out.split_on("\n")
					first =
						match out_lines.find_first_index(|said| Text.trim_end(said).ends_with(marked)) {
							Ok(i) => i
							Err(_) => return Err(lost)
						}
					if out_lines.drop_first(first).take_first(written.len()).any(|said| !Text.trim_end(said).ends_with(marked)) {
						return Err(lost)
					}
					head = out_lines.get(first) ?? ""
					indent = Text.indent(head)
					markup0 = Format.moved(piece.text, piece.indent, indent)
					head_bytes = head.to_utf8()
					mark_at = Format.last_index_of(head_bytes, marked.to_utf8()) ?? 0
					markup1 = markup0.update(0, |m| Text.cut(head_bytes, 0, mark_at).concat(m)) ?? markup0
					# Roc puts a comma after a multi-line string on its own line; after markup, it closes it.
					comma =
						match out_lines.get(first + written.len()) {
							Ok(next) => {
								nb = next.to_utf8()
								c = Text.skip_space(nb, 0)
								Text.at(nb, c) == ',' and c < nb.len() and Text.skip_space(nb, c + 1) >= nb.len()
							}
							Err(_) => Bool.False
						}
					markup = if (comma) markup1.update(markup1.len() - 1, |m| m.concat(",")) ?? markup1 else markup1
					drop = written.len() + (if (comma) 1 else 0)
					$out = Str.join_with(out_lines.take_first(first).concat(markup).concat(out_lines.drop_first(first + drop)), "\n")
				}
				_ => {
					placeholder = if (piece.kind == Sheet) "# ${piece.name}" else piece.name
					out_bytes = $out.to_utf8()
					found =
						match Format.placeholder_at(out_bytes, placeholder.to_utf8()) {
							Ok(k) => k
							Err(_) => return Err(lost)
						}
					indent = Text.indent(Text.cut(out_bytes, Text.line_start(out_bytes, found), out_bytes.len()))
					$out = Text.cut(out_bytes, 0, found).concat(Str.join_with(Format.moved(piece.text, piece.indent, indent), "\n")).concat(Text.cut(out_bytes, found + placeholder.to_utf8().len(), out_bytes.len()))
				}
			}
		}
		Ok($out)
	}

	## Where `needle` last is in `bytes`.
	last_index_of : List(U8), List(U8) -> Try(U64, [NotFound])
	last_index_of = |bytes, needle| {
		var $i = if (bytes.len() >= needle.len()) bytes.len() - needle.len() + 1 else 0
		while $i > 0 {
			if Text.starts_with_at(bytes, needle, $i - 1) {
				return Ok($i - 1)
			}
			$i = $i - 1
		}
		Err(NotFound)
	}

	## The first `placeholder` in `bytes` not followed by a name's character (`/placeholder(?![A-Za-z0-9_])/`).
	placeholder_at : List(U8), List(U8) -> Try(U64, [NotFound])
	placeholder_at = |bytes, placeholder| {
		var $i = 0
		while $i < bytes.len() {
			match Text.index_of(bytes, placeholder, $i) {
				Ok(k) => {
					if !Text.is_word(Text.at(bytes, k + placeholder.len())) {
						return Ok(k)
					}
					$i = k + 1
				}
				Err(_) => return Err(NotFound)
			}
		}
		Err(NotFound)
	}

	## A formatting problem, as `rocx internal` answers it (what the JavaScript threw).
	problem_value : Problem -> Value
	problem_value = |problem|
		match problem {
			Rocx(e) => Value.rocx_problem(e)
			Crash(message) => Value.problem(message)
			FormatError(message) => Value.format_problem(message)
			Lost(message) => Value.problem(message)
			NoRoc(command) => Value.problem("spawnSync ${command} ENOENT")
			CantRun(message) => Value.problem(message)
		}

	## `rocx internal`'s calls of this module's functions (rocx-cli/rocx.mjs names them), by name.
	rpc! : Str, List(Value) => Try(Value, [Failed(Value), Unknown(Str)])
	rpc! = |name, args| {
		arg = |i| args.get(i) ?? Null
		match name {
			"formatRocx" =>
				match Format.format_rocx!(Value.str(arg(0)), Value.str_or(arg(1), "input.rocx"), Value.str_or(Value.field(arg(2), "roc"), "roc")) {
					Ok(text) => Ok(Text(text))
					Err(problem) => Err(Failed(Format.problem_value(problem)))
				}
			"rocFmt" => {
				options = arg(1)
				match Format.roc_fmt!(Value.str(arg(0)), Value.str_or(Value.field(options, "roc"), "roc"), Value.str_or(Value.field(options, "file"), "<stdin>")) {
					Ok(text) => Ok(Text(text))
					Err(FormatError(message)) => Err(Failed(Value.format_problem(message)))
					Err(NoRoc(command)) => Err(Failed(Value.problem("spawnSync ${command} ENOENT")))
					Err(CantRun(message)) => Err(Failed(Value.problem(message)))
				}
			}
			_ => Err(Unknown(name))
		}
	}
}
