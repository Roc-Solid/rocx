import Host

## The app's settings, from the process's environment: secrets, and what differs from one machine
## to another (`ORIGIN`, `APP_SECRET`, an API's key), read alike in a request, a job or a schedule.
## And whether the server was started with `--dev`, for what only development may do.
Env := [].{

	## The environment variable `name`, as the server was started with it; `NotFound` when it has
	## none.
	var! : Str => Try(Str, [NotFound])
	var! = |name|
		match Host.env_var!(name) {
			Ok(value) => Ok(value)
			Err(_) => Err(NotFound)
		}

	## Whether the server was started with `--dev`.
	dev! : {} => Bool
	dev! = |{}| !Host.setting!("dev").is_empty()
}
