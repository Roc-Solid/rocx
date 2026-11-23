## What the Rust host does for Roc (../host/src/lib.rs). Paths are absolute or from the current
## directory; an error is the system's message.
Host := [].{

	## Writes to stdout (1) or stderr (2).
	write! : U8, Str => {}

	## All of stdin, as text (bytes that aren't UTF-8 replaced).
	stdin! : {} => Str

	## The current directory.
	cwd! : {} => Str

	## An environment variable, "" when it isn't set.
	env_var! : Str => Str

	## This executable's path.
	exe_path! : {} => Str

	## This process's id.
	pid! : {} => U32

	## Whether a process with this id is running.
	alive! : U32 => Bool

	## Milliseconds on a steady clock (since the host started).
	now_ms! : {} => U64

	## Nanoseconds since the epoch, on the system's clock: as a file's modification time is.
	now_ns! : {} => U64

	## Waits so many milliseconds.
	sleep! : U64 => {}

	## Whether something is at the path (a symbolic link is followed).
	exists! : Str => Bool

	## Whether the path is a directory.
	is_dir! : Str => Bool

	## The file's modification time in nanoseconds since the epoch; 0 when there is none.
	modified! : Str => U64

	## The file's text.
	read! : Str => Try(Str, Str)

	## Writes the file, its directory made first.
	write_file! : Str, Str => Try({}, Str)

	## Makes the file with this text, only if nothing is there (`O_EXCL`): `True` when it made it,
	## `False` when something was there already.
	create_new! : Str, Str => Try(Bool, Str)

	## Renames a file or directory (atomically, on one file system).
	rename! : Str, Str => Try({}, Str)

	## The path with every symbolic link resolved, absolute.
	real_path! : Str => Try(Str, Str)

	## The directory and every one above it that is missing.
	make_dirs! : Str => Try({}, Str)

	## A directory's entries, their names alone, sorted by their bytes.
	list! : Str => Try(List(Str), Str)

	## Deletes a file, or a directory and everything in it; nothing when there is nothing there.
	delete! : Str => Try({}, Str)

	## Copies a file, or a directory and everything in it, to `to` (made, with what it is in).
	copy! : Str, Str => Try({}, Str)

	## Runs a program (no shell) to its end: in a directory ("" for this one), with environment
	## variables added (`NAME=value`), and `stdin` as its input. `mode` 0: its stdout and stderr
	## kept apart (`out`, `err`); 1: both in one pipe, in the order it wrote them (`out`); 2: both
	## this program's own (nothing kept). Its exit code is 128 plus the signal's number when a
	## signal ended it.
	run! : Str, List(Str), Str, List(Str), Str, U8 => Try({ code : I32, out : Str, err : Str }, Str)

	## Starts a program (no shell) beside this one, with this one's stdin, stdout and stderr: its
	## id, for `kill!`. Its end is an event (`next!`).
	spawn! : Str, List(Str), Str, List(Str) => Try(U64, Str)

	## Replaces this program with another (no shell; in a directory, "" for this one's; environment
	## variables added): children still running are sent SIGTERM first, and waited for (up to ten
	## seconds), so what they held (a port) is free. Returns only when it couldn't: why.
	exec! : Str, List(Str), Str, List(Str) => Str

	## Sends a signal (15 SIGTERM, 9 SIGKILL) to a child that is still running; nothing otherwise.
	kill! : U64, I32 => {}

	## Watches a directory and everything under it, but for hidden entries and directories named in
	## `skip`: each file whose size or modification time changes, that appears or that goes is
	## reported (`next!`), once, however many times the system says so.
	watch! : Str, List(Str) => Try({}, Str)

	## Waits for the next event, or `timeout_ms` (0: forever): kind 0, the time ran out; 1, files
	## changed (`paths`, absolute); 2, a child ended (`child`, its exit `code`); 3, a signal came
	## (`code`: 1 SIGHUP, 2 SIGINT, 15 SIGTERM).
	next! : U64 => { kind : U8, paths : List(Str), child : U64, code : I32 }
}
