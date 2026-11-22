import pf.Env
import pf.Server

## Where the journal is served from, for what needs whole URLs (the feeds, the sitemap): the
## `ORIGIN` setting (`https://journal.example.com`) when the server has one, else the address the
## request came to. Server-only (it reads the environment).
Site := [].{

	origin! : Server.Request => Str
	origin! = |request|
		match Env.var!("ORIGIN") {
			Ok(origin) => origin.drop_suffix("/")
			Err(NotFound) => "http://${Server.header(request, "host") ?? "localhost:18140"}"
		}
}
