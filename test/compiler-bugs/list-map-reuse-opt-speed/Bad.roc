app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Server

## A row: a label and a number, 32 bytes.
Row : { label : Str, n : U64 }

## A cell: text, or a button and its action. Elsewhere in the program a button's action is a
## closure that captures a string, so a cell is bigger than a row; the transform below makes text
## alone, and a cell holding none of those closures would be as big as a row.
Cell : [Text(Str), Button(Str, ({} -> Str))]

rows : U64 -> List(Row)
rows = |keep| [{ label: "alpha", n: 1 }, { label: "beta", n: 2 }, { label: "gamma", n: 3 }, { label: "delta", n: 4 }].keep_if(|row| row.n > keep)

## The map's transform: a cell of text. It makes no closure of its own.
cell : Row -> Cell
cell = |row| Text(row.label)

said : Cell -> Str
said = |each|
	match each {
		Text(text) => text
		Button(label, press) => "${label}: ${press({})}"
	}

program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
	respond!: |request, _started| {
		# A unique list (keep_if made it), mapped with a known transform: --opt=speed may reuse its
		# allocation for the cells.
		cells = rows(request.path.count_utf8_bytes()).map(cell)
		# A button whose action captures the path: the program's cells hold closures like it.
		all = cells.concat([Button("path", |{}| "pressed ${request.path}")])
		Server.response(200, [], Str.join_with(all.map(said), "; "))
	},
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}
