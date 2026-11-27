## What the Rust host does for Roc (../host/src/lib.rs). Paths are absolute or from the current
## directory; an error is the system's message.
Host := [].{

	## Writes to stdout (1) or stderr (2).
	write! : U8, Str => {}

	## All of stdin, as text (bytes that aren't UTF-8 replaced).
	stdin! : {} => Str

	## One line of stdin, without its line ending (bytes that aren't UTF-8 replaced); an error at the
	## end of the input (or when it can't be read).
	stdin_line! : {} => Try(Str, Str)

	## Whether stdin (0), stdout (1) or stderr (2) is a terminal, not a file or a pipe.
	is_terminal! : U8 => Bool

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

	## The file's bytes.
	read_bytes! : Str => Try(List(U8), Str)

	## Writes the file, its directory made first.
	write_file! : Str, Str => Try({}, Str)

	## Writes the file's bytes, its directory made first.
	write_bytes! : Str, List(U8) => Try({}, Str)

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

	## Makes `link` a symbolic link to `target` (as given: absolute, or from the link's directory),
	## in place of a link or a file there (never a directory): made beside it and renamed into
	## place, so there is always something at `link`.
	symlink! : Str, Str => Try({}, Str)

	## Runs a program (no shell) to its end: in a directory ("" for this one), with environment
	## variables added (`NAME=value`), and `stdin` as its input. `mode` 0: its stdout and stderr
	## kept apart (`out`, `err`); 1: both in one pipe, in the order it wrote them (`out`); 2: both
	## this program's own (nothing kept). Its exit code is 128 plus the signal's number when a
	## signal ended it.
	run! : Str, List(Str), Str, List(Str), Str, U8 => Try({ code : I32, out : Str, err : Str }, Str)

	## Starts a program (no shell) beside this one, with this one's stdin, stdout and stderr, or
	## with its stdout and stderr written to the file `log` names (made, or emptied, first; "" for
	## this one's): its id, for `kill!`. Its end is an event (`next!`).
	spawn! : Str, List(Str), Str, List(Str), Str => Try(U64, Str)

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

	## A GET of `url` (`http://host:port/path`, plain HTTP: a server on this machine), with these
	## headers (`name: value`) besides `Host`, and `Connection: close`: its status, its
	## `Content-Type` ("" without one) and its body, whole (a chunked one put together). Waits up to
	## a minute for each read; an error is why it couldn't ask or read the answer.
	http_get! : Str, List(Str) => Try({ status : U16, content_type : Str, body : List(U8) }, Str)

	## A TCP port on 127.0.0.1 nothing listens on, as the system picks one: for a server this
	## program starts (another program could take it first, which is rare).
	free_port! : {} => Try(U16, Str)

	## Waits for the next event, or `timeout_ms` (0: forever): kind 0, the time ran out; 1, files
	## changed (`paths`, absolute); 2, a child ended (`child`, its exit `code`); 3, a signal came
	## (`code`: 1 SIGHUP, 2 SIGINT, 15 SIGTERM).
	next! : U64 => { kind : U8, paths : List(Str), child : U64, code : I32 }

	## Opens a WebSocket to `url` (`ws://host:port/path`, plain: a server on this machine): its id.
	## A thread reads its messages and keeps them until `ws_request!` or `ws_receive!` takes them.
	ws_connect! : Str => Try(U64, Str)

	## Sends a text message on the socket.
	ws_send! : U64, Str => Try({}, Str)

	## Sends `object` (a JSON object) on the socket with the socket's next `id` (1, 2, 3…) put first
	## in it, and waits for the message answering it (a JSON object whose top-level `id` is that
	## number), wherever it is among those waiting, up to `timeout_ms` (0: as long as it takes): kind
	## 0 with its `text`; 1, nothing in that time; 2, the socket closed (`text`: why); 3, `object`
	## isn't a JSON object (nothing sent). Messages that came before the answer stay, in order.
	ws_request! : U64, Str, U64 => { kind : U8, text : Str }

	## The oldest message still waiting on the socket, up to `timeout_ms` (0: only one there already):
	## kinds as `ws_request!`'s.
	ws_receive! : U64, U64 => { kind : U8, text : Str }

	## Closes the socket (a close frame, then the connection) and forgets it.
	ws_close! : U64 => {}
}
