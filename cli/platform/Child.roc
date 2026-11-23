import Host

## A program running beside this one (`Cmd.spawn!`), with its stdin, stdout and stderr. When it ends,
## `Events.next!` says so (`Exited`, with its id). Children still running when this program ends are
## sent SIGTERM.
Child := { id : U64 }.{

	## Asks it to stop (SIGTERM); `Events.next!` says when it has.
	terminate! : Child => {}
	terminate! = |child| Host.kill!(child.id, 15)

	## Stops it now (SIGKILL).
	kill! : Child => {}
	kill! = |child| Host.kill!(child.id, 9)

	## Its id, as `Events.next!`'s `Exited` names it.
	id : Child -> U64
	id = |child| child.id
}
