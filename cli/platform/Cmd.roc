import Child
import Host

## A command: a program (no shell: its arguments go to it as they are), the directory it runs in,
## environment variables added to this program's, and its input. Made with `Cmd.new`, then run to
## its end (`output!`, `merged!`, `status!`) or started beside this program (`spawn!`).
##
## ```roc
## ran = Cmd.new("roc").args(["fmt", "--stdin"]).stdin(code).output!()?
## code = Cmd.new("cargo").args(["build", "--release"]).cwd("server/host").status!()?
## ```
Cmd := { program : Str, arguments : List(Str), dir : Str, vars : List(Str), input : Str }.{
	new : Str -> Cmd
	new = |program| { program: program, arguments: [], dir: "", vars: [], input: "" }

	args : Cmd, List(Str) -> Cmd
	args = |cmd, more| { ..cmd, arguments: cmd.arguments.concat(more) }

	arg : Cmd, Str -> Cmd
	arg = |cmd, one| { ..cmd, arguments: cmd.arguments.append(one) }

	## The directory it runs in ("" for this program's).
	cwd : Cmd, Str -> Cmd
	cwd = |cmd, path| { ..cmd, dir: path }

	## An environment variable it gets, besides this program's.
	env : Cmd, Str, Str -> Cmd
	env = |cmd, name, value| { ..cmd, vars: cmd.vars.append("${name}=${value}") }

	## Its input (to its end; nothing by default). Not for `spawn!`, whose input is this program's.
	stdin : Cmd, Str -> Cmd
	stdin = |cmd, text| { ..cmd, input: text }

	## Run to its end: its exit code (128 plus the signal's number when a signal ended it), and what
	## it wrote to stdout and to stderr. `CantStart` when it couldn't be started at all.
	output! : Cmd => Try({ code : I32, stdout : Str, stderr : Str }, [CantStart(Str)])
	output! = |cmd|
		match Host.run!(cmd.program, cmd.arguments, cmd.dir, cmd.vars, cmd.input, 0) {
			Ok(ran) => Ok({ code: ran.code, stdout: ran.out, stderr: ran.err })
			Err(why) => Err(CantStart("${cmd.program}: ${why}"))
		}

	## Run to its end: its exit code, and its stdout and stderr as one text, in the order it wrote them.
	merged! : Cmd => Try({ code : I32, output : Str }, [CantStart(Str)])
	merged! = |cmd|
		match Host.run!(cmd.program, cmd.arguments, cmd.dir, cmd.vars, cmd.input, 1) {
			Ok(ran) => Ok({ code: ran.code, output: ran.out })
			Err(why) => Err(CantStart("${cmd.program}: ${why}"))
		}

	## Run to its end with this program's stdout and stderr: its exit code.
	status! : Cmd => Try(I32, [CantStart(Str)])
	status! = |cmd|
		match Host.run!(cmd.program, cmd.arguments, cmd.dir, cmd.vars, cmd.input, 2) {
			Ok(ran) => Ok(ran.code)
			Err(why) => Err(CantStart("${cmd.program}: ${why}"))
		}

	## Started beside this program, with its stdin, stdout and stderr: `Events.next!` says when it
	## ends (`Exited`).
	spawn! : Cmd => Try(Child, [CantStart(Str)])
	spawn! = |cmd|
		match Host.spawn!(cmd.program, cmd.arguments, cmd.dir, cmd.vars) {
			Ok(n) => {
				child : Child
				child = { id: n }
				Ok(child)
			}
			Err(why) => Err(CantStart("${cmd.program}: ${why}"))
		}

	## This program replaced by the command (its arguments, directory and environment): children
	## still running are sent SIGTERM and waited for (up to ten seconds) first. Returns only when it
	## couldn't be started.
	exec! : Cmd => Try({}, [CantStart(Str)])
	exec! = |cmd| Err(CantStart("${cmd.program}: ${Host.exec!(cmd.program, cmd.arguments, cmd.dir, cmd.vars)}"))
}
