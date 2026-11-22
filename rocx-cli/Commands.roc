## `rocx check` and `rocx lint` (were check() and lint() in bin/rocx.mjs).
import pf.Cmd
import pf.OsStr
import pf.Stdout
import pf.Stderr
import Fs
import Text
import Remap

Commands := [].{

	## `rocx check -- <command>`: runs the command (`roc check app/main.roc`) with its reports pointed
	## into .rocx files (Remap): what it printed, its output then its errors, and its exit code.
	check! : List(Str) => I32
	check! = |command| {
		match command {
			[] => {
				_ = Stderr.line!("usage: rocx check -- <command> [args…]")
				2
			}
			[program, .. as rest] => {
				ran = Cmd.new(OsStr.from_str(program)).args(rest.map(OsStr.from_str)).env(OsStr.from_str("NO_COLOR"), OsStr.from_str("1")).output_limit(NoLimit).run!()
				match ran {
					Ok(output) => {
						said = Remap.remap!(Str.from_utf8_lossy(output.stdout_bytes.concat(output.stderr_bytes)))
						_ = Stdout.write!(if (said.is_empty() or said.ends_with("\n")) said else said.concat("\n"))
						match output.status {
							Exited(code) => code
							Signaled(_) => 1
						}
					}
					Err(CmdErr(err)) => {
						_ = Stderr.line!("✗ rocx check: ${err.to_str()}")
						1
					}
					Err(Interrupted) => 1
				}
			}
		}
	}

	## Whether rocx wrote the file: its last line is the marker (a file that only mentions it, in a
	## string, isn't).
	is_generated : Str -> Bool
	is_generated = |text| (Remap.trim_end(text).split_on("\n").last() ?? "").starts_with(Remap.marker)

	## Whether the bytes at `i` are a line terminator a JavaScript `.` doesn't match (`\r`, U+2028,
	## U+2029; `\n` isn't in a line).
	is_terminator : List(U8), U64 -> Bool
	is_terminator = |bytes, i| {
		b = Text.at(bytes, i)
		b == '\r' or b == '\n' or (b == 0xE2 and Text.at(bytes, i + 1) == 0x80 and (Text.at(bytes, i + 2) == 0xA8 or Text.at(bytes, i + 2) == 0xA9))
	}

	## A line's code, for lint: a `\\` line is none; each string literal is `""`
	## (`/"(?:[^"\\]|\\.)*"/g`), then a comment goes (`/#.*/`).
	code_of : Str -> Str
	code_of = |line| {
		if Text.trim_start(line).starts_with("\\\\") {
			return ""
		}
		bytes = line.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			if Text.at(bytes, $i) == '"' {
				match Commands.string_end(bytes, $i + 1) {
					Ok(end) => {
						$out = $out.concat(['"', '"'])
						$i = end
					}
					Err(_) => {
						$out = $out.append('"')
						$i = $i + 1
					}
				}
			} else {
				$out = $out.append(Text.at(bytes, $i))
				$i = $i + 1
			}
		}
		# The first `#`, to the end of the line (or a terminator `.` doesn't match), goes.
		match Text.index_of_byte($out, '#', 0) {
			Ok(hash) => {
				var $stop = hash
				while $stop < $out.len() and !Commands.is_terminator($out, $stop) {
					$stop = $stop + 1
				}
				Str.from_utf8_lossy(Text.slice($out, 0, hash).concat(Text.slice($out, $stop, $out.len())))
			}
			Err(_) => Str.from_utf8_lossy($out)
		}
	}

	## Where a string literal whose text starts at `i` ends (after its closing quote), if it is closed.
	string_end : List(U8), U64 -> Try(U64, [Open])
	string_end = |bytes, i| {
		var $j = i
		while $j < bytes.len() {
			b = Text.at(bytes, $j)
			if b == '"' {
				return Ok($j + 1)
			} else if b == '\\' {
				if $j + 1 >= bytes.len() or Commands.is_terminator(bytes, $j + 1) {
					return Err(Open)
				}
				$j = $j + 2
			} else {
				$j = $j + 1
			}
		}
		Err(Open)
	}

	## Whether code calls `Html.source_text` (`/\bHtml\.source_text\b/`).
	calls_source_text : Str -> Bool
	calls_source_text = |code| {
		bytes = code.to_utf8()
		needle = "Html.source_text".to_utf8()
		var $from = 0
		while $from < bytes.len() {
			match Text.index_of(bytes, needle, $from) {
				Ok(at) => {
					before = at == 0 or !Text.is_word(Text.at(bytes, at - 1))
					after = at + needle.len() >= bytes.len() or !Text.is_word(Text.at(bytes, at + needle.len()))
					if before and after {
						return Bool.True
					}
					$from = at + 1
				}
				Err(_) => return Bool.False
			}
		}
		Bool.False
	}

	## `rocx lint <dir>…`: refuses Html.source_text in hand-written .roc files (a call, not a mention:
	## comments, `\\` lines and string literals don't count). 1 if any has it.
	lint! : List(Str) => I32
	lint! = |dirs| {
		var $failed = Bool.False
		for dir in dirs {
			if !Fs.is_dir!(dir) {
				_ = Stderr.line!("✗ ${dir}: no such directory")
				$failed = Bool.True
			}
			for path in Fs.files!(dir, ".roc", |_| Bool.False) {
				text = Fs.read_or_empty!(path)
				if !Commands.is_generated(text) {
					for numbered in text.split_on("\n").map_with_index(|line, i| { line, n: i + 1 }) {
						if Commands.calls_source_text(Commands.code_of(numbered.line)) {
							_ = Stderr.line!("✗ ${path}:${numbered.n.to_str()}: Html.source_text puts text in a page as markup; only rocx may write it")
							$failed = Bool.True
						}
					}
				}
			}
		}
		if ($failed) 1 else 0
	}
}
