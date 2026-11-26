import pf.Endpoint
import pf.Channel
import pf.Events
import pf.Server

## The server's endpoints, as the browser's copy has them (a method and a URL): what the profile
## reads (`GET /api/<name>`), and what it sends (`POST /api/rename`). The tests answer them.
Api := [].{
	User : { id : U64, name : Str }
	Post : { title : Str }

	current_user! : {} => User
	current_user! = |{}| Endpoint.remote("GET", "/api/current_user").read!()

	posts_of! : U64 => List(Post)
	posts_of! = |id| Endpoint.remote("GET", "/api/posts_of/${id.to_str()}").read!()

	friends! : {} => List(Str)
	friends! = |{}| Endpoint.remote("GET", "/api/friends").read!()

	likes! : {} => U64
	likes! = |{}| Endpoint.remote("GET", "/api/likes").read!()

	notifications! : {} => U64
	notifications! = |{}| Endpoint.remote("GET", "/api/notifications").read!()

	## Renames who you are, from a handler: the new name, or why there is none.
	rename! : Str => Str
	rename! = |name|
		match Endpoint.remote("POST", "/api/rename").send!(name) {
			Ok(renamed) => renamed
			Err(problem) => Server.explain(problem)
		}

	## GET /api/reads: what the reads page shows (D-023), an endpoint as the browser's copy has it,
	## its method and URL.
	reads : {} -> Endpoint({}, {}, { count : U64, weeks : Str })
	reads = |{}| Endpoint.remote("GET", "/api/reads")

	## What an org's news carries (D-020).
	News : { title : Str, n : U64 }

	## The channel at /news/<org>, as the browser's copy has it: its method and URL.
	news : { org : Str } -> Endpoint({}, {}, Channel(Str, News, [Hello(Str)]))
	news = |{ org }| Endpoint.remote("CHANNEL", "/news/${org}")

	## GET /api/changes, its events: each says what the reads page shows has changed.
	changes : {} -> Endpoint({}, {}, Events(Str))
	changes = |{}| Endpoint.remote("GET", "/api/changes")

	## GET /api/slow: a read the tests answer slowly, with the page it was asked for (`?page=`) and
	## how many times it has been asked (`version`).
	slow : {} -> Endpoint({}, {}, { page : U64, version : U64 })
	slow = |{}| Endpoint.remote("GET", "/api/slow")

	## GET /api/flaky: a read the tests answer slowly, or fail when told to.
	flaky : {} -> Endpoint({}, {}, { n : U64 })
	flaky = |{}| Endpoint.remote("GET", "/api/flaky")
}
