## What a paragraph, a heading or a table's cell is made of: text, and the spans Markdown marks in
## it. `Md.parse` makes these; a renderer (`Md.to_html`, `<Markdown>`) or an app's own walk reads
## them. `Raw` is HTML as the source wrote it, which renderers escape unless told otherwise.
Inline := [
	Text(Str),
	Code(Str),
	Emph(List(Inline)),
	Strong(List(Inline)),
	Strike(List(Inline)),
	Link({ url : Str, title : Str, content : List(Inline) }),
	Image({ url : Str, title : Str, alt : Str }),
	Raw(Str),
	Break,
	SoftBreak,
].{

	## Two the same: compared with `==`.
	is_eq : _

	## The words, without the marks: what a screen reader or a search index wants. A line break is
	## a space; raw HTML is nothing.
	plain : List(Inline) -> Str
	plain = |inlines|
		inlines.fold(
			"",
			|out, inline|
				out.concat(
					match inline {
						Text(text) => text
						Code(code) => code
						Emph(inner) => Inline.plain(inner)
						Strong(inner) => Inline.plain(inner)
						Strike(inner) => Inline.plain(inner)
						Link(link) => Inline.plain(link.content)
						Image(image) => image.alt
						Raw(_) => ""
						Break => " "
						SoftBreak => " "
					},
				),
		)
}

expect Inline.plain([Text("Read "), Strong([Text("the "), Emph([Text("docs")])]), SoftBreak, Code("now")]) == "Read the docs now"
expect Inline.plain([Link({ url: "/a", title: "", content: [Text("here")] }), Raw("<br>"), Image({ url: "x.png", title: "", alt: "a cat" })]) == "herea cat"
