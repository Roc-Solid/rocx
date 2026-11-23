import Host

Env := [].{

	## The current directory.
	cwd! : {} => Str
	cwd! = |{}| Host.cwd!({})

	## An environment variable; `NotFound` when it isn't set (or is empty).
	var! : Str => Try(Str, [NotFound])
	var! = |name| {
		value = Host.env_var!(name)
		if (value.is_empty()) Err(NotFound) else Ok(value)
	}

	## This executable's path, as the system says it was started.
	exe_path! : {} => Str
	exe_path! = |{}| Host.exe_path!({})

	## This process's id.
	pid! : {} => U32
	pid! = |{}| Host.pid!({})

	## Whether a process with this id is running.
	alive! : U32 => Bool
	alive! = |pid| Host.alive!(pid)
}
