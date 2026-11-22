## The journal's writers (made-up people). A post's `author` names one of these by `id`; the content
## rules refuse a post whose author isn't here. Plain data, small enough for the browser too.
Authors := [].{

	Author : { id : Str, name : Str, en : Str, pl : Str }

	all : List(Authors.Author)
	all = [
		{
			id: "iris-vale",
			name: "Iris Vale",
			en: "Iris bakes on weekends, keeps a notebook in every coat and edits the journal. She thinks most problems look smaller after a walk.",
			pl: "Iris piecze w weekendy, w każdej kurtce trzyma notes i redaguje dziennik. Uważa, że po spacerze większość problemów wydaje się mniejsza.",
		},
		{
			id: "hanna-wierzba",
			name: "Hanna Wierzba",
			en: "Hanna writes about gardens, trains and the sea. She translates the journal into Polish, and sometimes the other way round.",
			pl: "Hanna pisze o ogrodach, pociągach i morzu. Tłumaczy dziennik na polski, a czasem w drugą stronę.",
		},
		{
			id: "theo-marsh",
			name: "Theo Marsh",
			en: "Theo fixes bicycles and writes small programs, often in the same afternoon. He likes tools that fit in a pocket.",
			pl: "Theo naprawia rowery i pisze małe programy, często tego samego popołudnia. Lubi narzędzia, które mieszczą się w kieszeni.",
		},
	]

	## The writer with this id.
	find : Str -> Try(Authors.Author, [NotFound])
	find = |id| Authors.all.find_first(|author| author.id == id)

	## Their name, or the id itself for one who isn't here.
	name_of : Str -> Str
	name_of = |id|
		match Authors.find(id) {
			Ok(author) => author.name
			Err(NotFound) => id
		}

	## A few lines about them, in `lang`.
	bio : Authors.Author, Str -> Str
	bio = |author, lang| if (lang == "pl") author.pl else author.en
}

expect Authors.name_of("hanna-wierzba") == "Hanna Wierzba"
expect Authors.find("nobody").is_err()
