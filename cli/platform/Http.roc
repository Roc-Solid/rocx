import Host

## GETs of a server on this machine, over plain HTTP: what `rocx build --static` asks the app's
## server for (D-073). No TLS, no redirects followed, no compression asked for.
Http := [].{

	## What a GET answered: its status, its `Content-Type` ("" without one), and its body.
	Answer : { status : U16, content_type : Str, body : List(U8) }

	## A GET of `url` (`http://127.0.0.1:4000/blog`), with these headers (`name: value`) besides
	## `Host`; `CantGet` says why it couldn't ask, or read the answer (nothing listens there yet, say).
	get! : Str, List(Str) => Try(Answer, [CantGet(Str)])
	get! = |url, headers|
		match Host.http_get!(url, headers) {
			Ok(answer) => Ok(answer)
			Err(why) => Err(CantGet("GET ${url}: ${why}"))
		}

	## A TCP port on 127.0.0.1 nothing listens on now, as the system picks one: for a server this
	## program starts.
	free_port! : {} => Try(U16, [NoPort(Str)])
	free_port! = |{}|
		match Host.free_port!({}) {
			Ok(port) => Ok(port)
			Err(why) => Err(NoPort(why))
		}
}
