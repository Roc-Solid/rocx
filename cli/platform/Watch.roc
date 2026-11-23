import Host

Watch := [].{

	## Watches `dir` and everything under it, but for hidden entries and directories named in `skip`
	## (`["build", "node_modules"]`): a file reported changed is one whose size or modification time
	## changed, or that appeared or went (`Events.next!`, `Changed`).
	dir! : Str, List(Str) => Try({}, [CantWatch(Str)])
	dir! = |dir, skip|
		match Host.watch!(dir, skip) {
			Ok({}) => Ok({})
			Err(why) => Err(CantWatch("${dir}: ${why}"))
		}
}
