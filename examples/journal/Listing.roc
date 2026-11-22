## A post as a list shows it: what the JSON API answers for each post (`GET /api/posts`), and what
## the search island filters as you type. Only the type lives here, with nothing that reads the
## posts themselves, so the browser's half can import it: the posts are the server's
## (`Posts.summary` makes these).
Listing := [].{

	Summary : {
		lang : Str,
		slug : Str,
		url : Str,
		title : Str,
		date : Str,
		author : Str,
		author_name : Str,
		tags : List(Str),
		summary : Str,
		cover : Str,
		minutes : U64,
		translations : List({ lang : Str, url : Str }),
	}
}
