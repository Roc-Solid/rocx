import Host

## The app's settings, from the process's environment: secrets, and what differs from one machine
## to another (`APP_SECRET`, an API's key), read alike in a request, a job or a schedule. And
## whether the server was started with `--dev` (or `--debug`), for what only development (or a test)
## may do, and where the app is (`public_url!`), for the links it sends.
Env := [].{

	## The environment variable `name`, as the server was started with it; `NotFound` when it has
	## none. The file `--env-file` names (`rocx dev` names the `.env` where it runs) is read into the
	## environment first, so `ANTHROPIC_API_KEY=…` there is read here as if the shell had exported
	## it; a variable the environment already has keeps its value. Without the flag no file is read,
	## a `.env` beside the server neither (D-088, D-098).
	var! : Str => Try(Str, [NotFound])
	var! = |name|
		match Host.env_var!(name) {
			Ok(value) => Ok(value)
			Err(_) => Err(NotFound)
		}

	## Whether the server was started with `--dev`.
	dev! : {} => Bool
	dev! = |{}| !Host.setting!("dev").is_empty()

	## Whether the server was started with `--debug`, which tests start it with (its debug paths under
	## `/__rocx/`), never a deployed server: what a plugin keeps for a test to read (the dev mailbox's
	## mail) rather than doing.
	debug! : {} => Bool
	debug! = |{}| !Host.setting!("debug").is_empty()

	## Where the app is, as the world reaches it, for a link it sends (in an email, to another
	## server): `--public-url` or `PUBLIC_URL` when the server was started with one
	## (`https://status.example.com`: the proxy in front of it), without the `/` at its end; else
	## where the server listens (`http://127.0.0.1:8080`), with the port it was given, or the one the
	## system gave it for `--port 0`. Never a request's `Host`, which whoever asks writes.
	public_url! : {} => Str
	public_url! = |{}| Host.setting!("public_url")
}
