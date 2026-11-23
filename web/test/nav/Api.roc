import pf.Endpoint
import pf.Channel

## The navigation app's endpoints, as the browser's copy has them (a method and a URL): the tests
## (web/test/navigation.test.mjs) answer them.
Api := [].{

	## GET /api/say/<word>: what the server says of a word.
	say! : Str => Str
	say! = |word| Endpoint.get!(Endpoint.remote("GET", "/api/say/${word}"))

	## GET /api/wait: answered slowly, for a handler that waits for it before it navigates.
	wait! : {} => Str
	wait! = |{}| Endpoint.get!(Endpoint.remote("GET", "/api/wait"))

	## POST /api/leave: an action whose answer sends the visitor elsewhere (`x-rocx-redirect`).
	leave : {} -> Endpoint({}, Str, Str)
	leave = |{}| Endpoint.remote("POST", "/api/leave")

	## The channel at /news/nav: what page A hears while it is there.
	news : {} -> Endpoint({}, {}, Channel(Str, Str, Str))
	news = |{}| Endpoint.remote("CHANNEL", "/news/nav")
}
