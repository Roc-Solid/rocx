import Host

## What the server was started with: its flags (or their environment variables), as the host keeps
## them.
Setting := [].{

	## A setting's value, or "" when it wasn't given.
	text! : Str => Str
	text! = |name| Host.setting!(name)

	## A setting that is a number, or `default`.
	number! : Str, U64 => U64
	number! = |name, default| U64.from_str(Host.setting!(name)) ?? default

	## Whether the server has a database (`--database-url`, or `DATABASE_URL`).
	database! : {} => Bool
	database! = |{}| !Host.setting!("database").is_empty()
}
