import Inline

## A document's blocks, as `Md.parse` makes them: a list of these is a document. A heading has its
## `id` (from its text, made unique in the document), for anchors and a table of contents. A code
## block's `lang` is the first word of its info string (```` ```roc ````), `""` for none. `Raw` is an
## HTML block as the source wrote it, which renderers escape unless told otherwise.
Block := [
	Paragraph(List(Inline)),
	Heading({ level : U64, id : Str, content : List(Inline) }),
	Code({ lang : Str, info : Str, text : Str }),
	Quote(List(Block)),
	Unordered({ tight : Bool, items : List(Item) }),
	Ordered({ start : U64, tight : Bool, items : List(Item) }),
	Table({ align : List([Default, Left, Center, Right]), head : List(List(Inline)), rows : List(List(List(Inline))) }),
	Raw(Str),
	Rule,
].{

	## Two the same: compared with `==`.
	is_eq : _

	## A list's item: its blocks, and its box if it is a task (`- [ ] write it`, `- [x] done`). In a
	## tight list (no blank lines between its items) a paragraph shows without its `<p>`.
	Item : { task : [None, Open, Done], blocks : List(Block) }

	## The words of a document's text, code blocks included, without the marks.
	plain : List(Block) -> Str
	plain = |blocks| Str.join_with(blocks.map(Block.plain_one), "\n")

	## One block's words.
	plain_one : Block -> Str
	plain_one = |block|
		match block {
			Paragraph(content) => Inline.plain(content)
			Heading(heading) => Inline.plain(heading.content)
			Code(code) => code.text
			Quote(inner) => Block.plain(inner)
			Unordered(list) => Str.join_with(list.items.map(|item| Block.plain(item.blocks)), "\n")
			Ordered(list) => Str.join_with(list.items.map(|item| Block.plain(item.blocks)), "\n")
			Table(table) => Str.join_with(table.head.concat(table.rows.join()).map(Inline.plain), " ")
			Raw(_) => ""
			Rule => ""
		}
}

expect Block.plain([Heading({ level: 1, id: "hi", content: [Text("Hi")] }), Paragraph([Text("there")]), Rule]) == "Hi\nthere\n"
expect [Paragraph([Text("a"), Emph([Text("b")])]), Rule] == [Paragraph([Text("a"), Emph([Text("b")])]), Rule]
expect Paragraph([Text("a")]) != Paragraph([Text("b")])
