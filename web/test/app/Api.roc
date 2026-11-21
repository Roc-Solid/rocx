import pf.Call
import pf.Endpoint
import pf.Events

## The server's functions, as the browser calls them. (In the spike the test answers them; with
## rocx's `server!` they would be defined once, as on master.)
Api := [].{
	User : { id : U64, name : Str }
	Post : { title : Str }

	current_user! : {} => User
	current_user! = |{}| Call.server!("current_user", {})

	posts_of! : U64 => List(Post)
	posts_of! = |id| Call.server!("posts_of", id)

	friends! : {} => List(Str)
	friends! = |{}| Call.server!("friends", {})

	likes! : {} => U64
	likes! = |{}| Call.server!("likes", {})

	notifications! : {} => U64
	notifications! = |{}| Call.server!("notifications", {})

	rename! : Str => Str
	rename! = |name| Call.server!("rename", name)

	## GET /api/reads: what the reads page shows (D-023), an endpoint as the browser's copy has it,
	## its method and URL.
	reads : {} -> Endpoint({}, {}, { count : U64, weeks : Str })
	reads = |{}| Endpoint.remote("GET", "/api/reads")

	## GET /api/changes, its events: each says what the reads page shows has changed.
	changes : {} -> Endpoint({}, {}, Events(Str))
	changes = |{}| Endpoint.remote("GET", "/api/changes")
}
