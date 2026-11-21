import Admin
import Catalog
import Form
import Listing
import Look
import Paging
import Widget

## The admin's pages, as HTML: the index of tables, a table's rows, a row's form, the question
## before a row is deleted, and why something wasn't done. Each is a page's main part, for
## `Look.document`; links are the admin's path and a query (`Form.link`).
View := [].{

	## What every page knows: the admin's path and title, the tables it shows, what the visitor may
	## do, and the token its forms send back (against cross-site requests).
	Frame : { mount : Str, title : Str, tables : List(Admin.Shown), access : Admin.Access, token : Str }

	## The tables, each with about how many rows it has and what it is.
	index_page : Frame -> Str
	index_page = |frame| {
		rows = frame.tables.map(
			|shown| {
				estimate = if (shown.table.estimate < 0) "<span class=\"muted\">—</span>" else "≈ ${shown.table.estimate.to_str()}"
				add = if (may_create(frame, shown)) "<a href=\"${Look.escape(Form.link(frame.mount, [("table", shown.table.name), ("new", "1")]))}\">Add</a>" else ""
				"<tr><td><a href=\"${Look.escape(Form.link(frame.mount, [("table", shown.table.name)]))}\">${Look.escape(Admin.label(shown))}</a> <code class=\"muted\">${Look.escape(shown.table.name)}</code></td><td>${estimate}</td><td>${Look.escape(shown.table.comment)}</td><td class=\"actions\">${add}</td></tr>"
			},
		)
		table = if (rows.is_empty()) "<p class=\"muted\">No tables to show: the app lists them (<code>tables</code>), or shows every one (<code>include: All</code>).</p>" else "<table><thead><tr><th>Table</th><th>Rows</th><th>About</th><th></th></tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table>"
		"<div class=\"bar\"><h1>${Look.escape(frame.title)}</h1></div>${table}"
	}

	## A table's rows, a page of them, with its search, its filters (`filters`: each column's
	## choices, a value and what to call it) and its pages.
	list_page : Frame, { shown : Admin.Shown, state : Listing.State, page : Paging.Page, rows : List(Catalog.Row), filters : List({ column : Catalog.Column, choices : List((Str, Str)) }), notice : Str } -> Str
	list_page = |frame, listing| {
		shown = listing.shown
		state = listing.state
		name = shown.table.name
		columns = Admin.listed(shown)
		key = Admin.key(shown)
		at = |changed| Look.escape(Form.link(frame.mount, Listing.params(name, changed)))
		heads = columns.map(
			|column| {
				now = state.sort.first() ?? { column: "", descending: Bool.False }
				arrow = if (now.column != column.name) "" else if (now.descending) " ▼" else " ▲"
				"<th><a${if (arrow.is_empty()) "" else " class=\"on\""} href=\"${at(Listing.sorted_by(state, column.name))}\">${Look.escape(Admin.column_label(shown, column.name))}${arrow}</a></th>"
			},
		)
		lines = listing.rows.map(
			|row| {
				cells = columns.map_with_index(
					|column, i| {
						shown_value = cell_html(frame, shown, column, Catalog.cell(row, i), Catalog.null_at(row, i), 80)
						# The first cell opens the row, when the table has a key to find it by.
						if i == 0 and !key.is_empty() {
							key_values = key.map(|each| (each.name, Catalog.cell(row, columns.len() + (key.find_first_index(|other| other.name == each.name) ?? 0))))
							# Its text alone: a foreign key's link would be a link in a link.
							text = if (Catalog.null_at(row, i)) "null" else if (Catalog.cell(row, i).is_empty()) "(empty)" else Widget.shown(Admin.widget(shown, column), Catalog.cell(row, i), 80)
							"<td><a href=\"${Look.escape(View.row_link(frame.mount, name, key_values))}\">${text}</a></td>"
						} else if Catalog.null_at(row, i) {
							"<td class=\"null\">null</td>"
						} else {
							"<td>${shown_value}</td>"
						}
					},
				)
				"<tr>${Str.join_with(cells, "")}</tr>"
			},
		)
		rows_html = if (lines.is_empty()) "<p class=\"muted\">No rows${if (state.search.is_empty() and state.filters.is_empty()) "" else " like that"}.</p>" else "<table><thead><tr>${Str.join_with(heads, "")}</tr></thead><tbody>${Str.join_with(lines, "")}</tbody></table>"
		pager =
			if listing.page.pages <= 1 {
				""
			} else {
				links = Paging.links(listing.page).map(
					|each|
						match each {
							Number(n) => "<a${if (n == listing.page.number) " class=\"on\" aria-current=\"page\"" else ""} href=\"${at({ ..state, page: n })}\">${n.to_str()}</a>"
							Gap => "<span class=\"gap\">…</span>"
						},
				)
				"<nav class=\"pager\" aria-label=\"Pages\">${Str.join_with(links, "")}</nav>"
			}
		range = Paging.shows(listing.page)
		counted = if (listing.page.total == 0) "" else "<p class=\"muted\">${range.first.to_str()}–${range.last.to_str()} of ${listing.page.total.to_str()}</p>"
		search =
			if Admin.searchable(shown).is_empty() {
				""
			} else {
				kept = Listing.params(name, { ..state, search: "", page: 1 }).keep_if(|(_, value)| !value.is_empty()).map(|(field, value)| "<input type=\"hidden\" name=\"${Look.escape(field)}\" value=\"${Look.escape(value)}\">")
				searched_in = Str.join_with(Admin.searchable(shown).map(|column| Admin.column_label(shown, column.name)), ", ")
				clear = if (state.search.is_empty()) "" else " <a href=\"${at({ ..state, search: "", page: 1 })}\">Clear</a>"
				"<form class=\"search\" method=\"get\" action=\"${Look.escape(frame.mount)}\">${Str.join_with(kept, "")}<input type=\"search\" name=\"q\" value=\"${Look.escape(state.search)}\" aria-label=\"Search\" placeholder=\"${Look.escape(searched_in)}\"><button>Search</button>${clear}</form>"
			}
		aside =
			if listing.filters.is_empty() {
				""
			} else {
				groups = listing.filters.map(
					|{ column, choices }| {
						now = state.filters.find_first(|each| each.column == column.name)
						item = |label, is, on| "<li><a${if (on) " class=\"on\"" else ""} href=\"${at(Listing.filtered(state, column.name, is))}\">${Look.escape(label)}</a></li>"
						all = item("All", Err(All), now.is_err())
						values = choices.map(|(value, label)| item(label, Ok(Equal(value)), now == Ok({ column: column.name, is: Equal(value) })))
						nulls = if (column.nullable) [item("null", Ok(Null), now == Ok({ column: column.name, is: Null })), item("not null", Ok(Set), now == Ok({ column: column.name, is: Set }))] else []
						"<h3>By ${Look.escape(Admin.column_label(shown, column.name))}</h3><ul>${all}${Str.join_with(values.concat(nulls), "")}</ul>"
					},
				)
				"<aside><h2>Filter</h2>${Str.join_with(groups, "")}</aside>"
			}
		add = if (may_create(frame, shown)) "<a href=\"${Look.escape(Form.link(frame.mount, [("table", name), ("new", "1")]))}\">Add</a>" else ""
		about = if (shown.table.comment.is_empty()) "" else "<p class=\"muted\">${Look.escape(shown.table.comment)}</p>"
		Str.join_with(
			[
				crumbs(frame, []),
				notice_html(listing.notice),
				"<div class=\"bar\"><h1>${Look.escape(Admin.label(shown))}</h1><span>${add}</span></div>",
				about,
				search,
				"<div class=\"listing${if (aside.is_empty()) " alone" else ""}\"><div class=\"rows\">${rows_html}${pager}${counted}</div>${aside}</div>",
			],
			"",
		)
	}

	## A row's form (`key`: its key's columns and values; `[]` for a new row), with its `values`
	## (each column's text and whether it is null), a reference's `options`, and what went wrong
	## (`problem`) or was done (`notice`). Someone who may only look sees the values.
	row_page : Frame, { shown : Admin.Shown, key : List((Str, Str)), values : List({ name : Str, value : Str, null : Bool }), options : List({ column : Str, options : List((Str, Str)) }), problem : Str, notice : Str } -> Str
	row_page = |frame, row| {
		shown = row.shown
		name = shown.table.name
		creating = row.key.is_empty()
		doing = if (creating) Creating else Editing
		value_of = |column| row.values.find_first(|each| each.name == column.name) ?? { name: column.name, value: "", null: Bool.True }
		heading = if (creating) "Add to ${Admin.label(shown)}" else View.row_title(shown, row.key, row.values)
		columns = Admin.visible(shown).keep_if(|column| !creating or Admin.writable(shown, frame.access, column, Creating))
		fields = columns.map_with_index(
			|column, i| {
				id = "field-${i.to_str()}"
				current = value_of(column)
				label = Look.escape(Admin.column_label(shown, column.name))
				help = Str.join_with(
					[
						if (column.comment.is_empty()) "" else "${Look.escape(column.comment)} ",
						"<span class=\"muted\">${Look.escape(column.type)}${if (column.nullable) "" else ", not null"}</span>",
					],
					"",
				)
				if Admin.writable(shown, frame.access, column, doing) {
					kind = Admin.widget(shown, column)
					options = (row.options.find_first(|each| each.column == column.name) ?? { column: "", options: [] }).options
					link = reference_link(frame, kind, current)
					input = Widget.input({ name: "v.${column.name}", id, column, kind, value: current.value, null: current.null, creating, options })
					"<label for=\"${id}\">${label}</label><div>${input}${link}<span class=\"help\">${help}</span></div>"
				} else {
					shown_value = if (current.null) "<span class=\"value null\">null</span>" else "<span class=\"value\">${cell_html(frame, shown, column, current.value, Bool.False, 0)}</span>"
					"<span class=\"label\">${label}</span><div>${shown_value}<span class=\"help\">${help}</span></div>"
				}
			},
		)
		key_fields = row.key.map(|(column, value)| ("k.${column}", value))
		delete =
			if !creating and frame.access == Edit and shown.options.delete {
				"<a href=\"${Look.escape(Form.link(frame.mount, [("table", name)].concat(key_fields).append(("delete", "1"))))}\">Delete</a>"
			} else {
				""
			}
		writes = frame.access == Edit and columns.any(|column| Admin.writable(shown, frame.access, column, doing))
		body =
			if writes {
				hidden = hidden_fields(frame.token, if (creating) "create" else "update", name, key_fields)
				"<form class=\"edit\" method=\"post\" action=\"${Look.escape(frame.mount)}\">${hidden}<div class=\"fields\">${Str.join_with(fields, "")}</div><div class=\"buttons\"><button class=\"primary\">${if (creating) "Add" else "Save"}</button> <a href=\"${Look.escape(Form.link(frame.mount, [("table", name)]))}\">Back to the list</a></div></form>"
			} else {
				"<div class=\"fields\">${Str.join_with(fields, "")}</div><div class=\"buttons\"><a href=\"${Look.escape(Form.link(frame.mount, [("table", name)]))}\">Back to the list</a></div>"
			}
		problem = if (row.problem.is_empty()) "" else "<p class=\"problem\">${Look.escape(row.problem)}</p>"
		Str.join_with([crumbs(frame, [(Admin.label(shown), Form.link(frame.mount, [("table", name)]))]), notice_html(row.notice), problem, "<div class=\"bar\"><h1>${Look.escape(heading)}</h1><span>${delete}</span></div>", body], "")
	}

	## The question before a row is deleted, and the button that deletes it.
	delete_page : Frame, { shown : Admin.Shown, key : List((Str, Str)), title : Str, problem : Str } -> Str
	delete_page = |frame, asked| {
		name = asked.shown.table.name
		key_fields = asked.key.map(|(column, value)| ("k.${column}", value))
		described = Str.join_with(asked.key.map(|(column, value)| "${Admin.column_label(asked.shown, column)} ${value}"), ", ")
		problem = if (asked.problem.is_empty()) "" else "<p class=\"problem\">${Look.escape(asked.problem)}</p>"
		Str.join_with(
			[
				crumbs(frame, [(Admin.label(asked.shown), Form.link(frame.mount, [("table", name)])), (asked.title, View.row_link(frame.mount, name, asked.key))]),
				problem,
				"<h1>Delete ${Look.escape(asked.title)}?</h1>",
				"<p>The row of ${Look.escape(Admin.label(asked.shown))} whose ${Look.escape(described)} goes, for good. If other rows refer to it, their foreign keys say whether they go with it or keep it from going.</p>",
				"<form class=\"edit\" method=\"post\" action=\"${Look.escape(frame.mount)}\">${hidden_fields(frame.token, "delete", name, key_fields)}<div class=\"buttons\"><button class=\"danger\">Delete</button> <a href=\"${Look.escape(View.row_link(frame.mount, name, asked.key))}\">No, keep it</a></div></form>",
			],
			"",
		)
	}

	## Why something wasn't done.
	problem_page : Frame, Str, Str -> Str
	problem_page = |frame, heading, why| "${crumbs(frame, [])}<h1>${Look.escape(heading)}</h1><p class=\"problem\">${Look.escape(why)}</p>"

	## The link to a row: its table, and its key's columns and values (`k.id=7`).
	row_link : Str, Str, List((Str, Str)) -> Str
	row_link = |mount, table, key| Form.link(mount, [("table", table)].concat(key.map(|(column, value)| ("k.${column}", value))))

	## What a row's page calls it: its title column's value, else its key's values.
	row_title : Admin.Shown, List((Str, Str)), List({ name : Str, value : Str, null : Bool }) -> Str
	row_title = |shown, key, values| {
		titled =
			match Admin.title(shown) {
				Ok(column) =>
					match values.find_first(|each| each.name == column.name) {
						Ok(found) if !found.null and !found.value.is_empty() and !shown.table.key.contains(column.name) => Ok(Widget.cut(found.value.replace_each("\n", " "), 80))
						_ => Err(Untitled)
					}
				Err(NoTitle) => Err(Untitled)
			}
		titled ?? "#${Str.join_with(key.map(|(_, value)| value), ", ")}"
	}

	## What `done` (after a form, sent back to its page) says.
	notice : Str -> Str
	notice = |done|
		match done {
			"created" => "Added."
			"saved" => "Saved."
			"unchanged" => "Nothing changed."
			"deleted" => "Deleted."
			_ => ""
		}
}

may_create : View.Frame, Admin.Shown -> Bool
may_create = |frame, shown| frame.access == Edit and shown.options.create and Admin.visible(shown).any(|column| Admin.writable(shown, Edit, column, Creating))

crumbs : View.Frame, List((Str, Str)) -> Str
crumbs = |frame, trail| {
	links = [(frame.title, frame.mount)].concat(trail).map(|(label, href)| "<a href=\"${Look.escape(href)}\">${Look.escape(label)}</a>")
	"<p class=\"crumbs\">${Str.join_with(links, " › ")}</p>"
}

notice_html : Str -> Str
notice_html = |text| if (text.is_empty()) "" else "<p class=\"notice\" role=\"status\">${Look.escape(text)}</p>"

hidden_fields : Str, Str, Str, List((Str, Str)) -> Str
hidden_fields = |token, action, table, key_fields| {
	fields = [("csrf", token), ("action", action), ("table", table)].concat(key_fields)
	Str.join_with(fields.map(|(name, value)| "<input type=\"hidden\" name=\"${Look.escape(name)}\" value=\"${Look.escape(value)}\">"), "")
}

## A value as HTML: through its widget, a foreign key's a link to the row it refers to (when the
## admin shows that table, and the column is its key).
cell_html : View.Frame, Admin.Shown, Catalog.Column, Str, Bool, U64 -> Str
cell_html = |frame, shown, column, value, null, longest| {
	kind = Admin.widget(shown, column)
	text = Widget.shown(kind, value, longest)
	if null {
		"null"
	} else {
		match refers_to(frame, column) {
			Ok(other) => "<a href=\"${Look.escape(View.row_link(frame.mount, other.table, [(other.column, value)]))}\">${text}</a>"
			Err(Unlinked) => text
		}
	}
}

## The table and column a foreign key refers to, if the admin shows that table and the column is
## its whole key.
refers_to : View.Frame, Catalog.Column -> Try({ table : Str, column : Str }, [Unlinked])
refers_to = |frame, column|
	match column.refers {
		To(other) =>
			match Admin.find(frame.tables, other.table) {
				Ok(target) if target.table.key == [other.column] => Ok(other)
				_ => Err(Unlinked)
			}
		Nothing => Err(Unlinked)
	}

## Beside a foreign key's input: a link to the row it refers to now.
reference_link : View.Frame, Widget.Kind, { name : Str, value : Str, null : Bool } -> Str
reference_link = |frame, kind, current|
	match kind {
		Reference(other) =>
			if current.null or current.value.is_empty() {
				""
			} else {
				match Admin.find(frame.tables, other.table) {
					Ok(target) if target.table.key == [other.column] => " <a href=\"${Look.escape(View.row_link(frame.mount, other.table, [(other.column, current.value)]))}\">Open</a>"
					_ => ""
				}
			}
		_ => ""
	}

column_of : Str, Str -> Catalog.Column
column_of = |name, base| { name, type: base, base, category: "", nullable: Bool.False, defaulted: Bool.False, generated: Bool.False, comment: "", default: "", labels: [], choices: [], refers: Nothing }

authors : Catalog.Table
authors = { name: "authors", comment: "People who write", estimate: 3, columns: [{ ..column_of("id", "int8"), defaulted: Bool.True }, column_of("name", "text")], key: ["id"] }

books : Catalog.Table
books = {
	name: "books",
	comment: "",
	estimate: -1,
	columns: [
		{ ..column_of("id", "int8"), defaulted: Bool.True },
		column_of("title", "text"),
		{ ..column_of("author_id", "int8"), nullable: Bool.True, refers: To({ table: "authors", column: "id" }) },
		{ ..column_of("in_print", "bool"), defaulted: Bool.True, default: "true" },
	],
	key: ["id"],
}

frame_of : Admin.Access -> View.Frame
frame_of = |access| { mount: "/db", title: "Database", tables: [Admin.pair(books, { name: "books", search: ["title"], filters: ["in_print"] }), Admin.pair(authors, { name: "authors" })], access, token: "t0k" }

expect {
	html = View.index_page(frame_of(Edit))
	html.contains("<a href=\"/db?table=books\">Books</a>") and html.contains("<a href=\"/db?table=books&amp;new=1\">Add</a>") and html.contains("≈ 3") and html.contains("People who write")
}
expect !View.index_page(frame_of(ReadOnly)).contains(">Add<")
expect {
	frame = frame_of(Edit)
	shown = Admin.pair(books, { name: "books", search: ["title"], filters: ["in_print"] })
	state = { search: "dune", filters: [], sort: [{ column: "title", descending: Bool.False }], page: 1 }
	html = View.list_page(
		frame,
		{
			shown,
			state,
			page: Paging.of(120, 50, 1),
			rows: [{ cells: ["7", "Dune <1>", "1", "true", "7"], nulls: [Bool.False, Bool.False, Bool.False, Bool.False, Bool.False] }, { cells: ["8", "", "", "false", "8"], nulls: [Bool.False, Bool.False, Bool.True, Bool.False, Bool.False] }],
			filters: [{ column: { ..column_of("in_print", "bool"), nullable: Bool.False }, choices: [("true", "yes"), ("false", "no")] }],
			notice: "Deleted.",
		},
	)
	html.contains("<td><a href=\"/db?table=books&amp;k.id=7\">7</a></td><td>Dune &lt;1&gt;</td><td><a href=\"/db?table=authors&amp;k.id=1\">1</a></td><td>yes</td>")
		and html.contains("<td class=\"null\">null</td>")
		and html.contains("<a class=\"on\" href=\"/db?table=books&amp;q=dune&amp;sort=-title\">Title ▲</a>")
		and html.contains("<a href=\"/db?table=books&amp;q=dune&amp;f.in_print=false&amp;sort=title\">no</a>")
		and html.contains("<input type=\"hidden\" name=\"table\" value=\"books\"><input type=\"hidden\" name=\"sort\" value=\"title\"><input type=\"search\" name=\"q\" value=\"dune\"")
		and html.contains("<a class=\"on\" aria-current=\"page\" href=\"/db?table=books&amp;q=dune&amp;sort=title\">1</a><a href=\"/db?table=books&amp;q=dune&amp;sort=title&amp;page=2\">2</a>")
		and html.contains("1–50 of 120")
		and html.contains("<p class=\"notice\" role=\"status\">Deleted.</p>")
}
expect {
	frame = frame_of(Edit)
	html = View.row_page(
		frame,
		{
			shown: Admin.pair(books, { name: "books" }),
			key: [("id", "7")],
			values: [{ name: "id", value: "7", null: Bool.False }, { name: "title", value: "Dune", null: Bool.False }, { name: "author_id", value: "1", null: Bool.False }, { name: "in_print", value: "true", null: Bool.False }],
			options: [{ column: "author_id", options: [("1", "Ada"), ("2", "Grace")] }],
			problem: "",
			notice: "",
		},
	)
	html.contains("<h1>Dune</h1>")
		and html.contains("<input type=\"hidden\" name=\"csrf\" value=\"t0k\"><input type=\"hidden\" name=\"action\" value=\"update\"><input type=\"hidden\" name=\"table\" value=\"books\"><input type=\"hidden\" name=\"k.id\" value=\"7\">")
		and html.contains("<span class=\"label\">Id</span><div><span class=\"value\">7</span>")
		and html.contains("<select id=\"field-2\" name=\"v.author_id\"><option value=\"\">—</option><option value=\"1\" selected>Ada</option>")
		and html.contains(" <a href=\"/db?table=authors&amp;k.id=1\">Open</a>")
		and html.contains("<a href=\"/db?table=books&amp;k.id=7&amp;delete=1\">Delete</a>")
}
expect {
	html = View.row_page(
		frame_of(Edit),
		{ shown: Admin.pair(books, { name: "books" }), key: [], values: [{ name: "in_print", value: "true", null: Bool.False }], options: [], problem: "23502: null value", notice: "" },
	)
	html.contains("<h1>Add to Books</h1>") and html.contains("value=\"create\"") and html.contains("<label for=\"field-0\">Id</label>") and html.contains("checked") and html.contains("<p class=\"problem\">23502: null value</p>")
}
expect {
	html = View.row_page(frame_of(ReadOnly), { shown: Admin.pair(books, { name: "books" }), key: [("id", "7")], values: [{ name: "title", value: "Dune", null: Bool.False }], options: [], problem: "", notice: "" })
	!html.contains("<form") and !html.contains("Delete") and html.contains("<span class=\"value\">Dune</span>")
}
expect {
	html = View.delete_page(frame_of(Edit), { shown: Admin.pair(books, { name: "books" }), key: [("id", "7")], title: "Dune", problem: "" })
	html.contains("<h1>Delete Dune?</h1>") and html.contains("name=\"action\" value=\"delete\"") and html.contains("whose Id 7 goes")
}
expect {
	html = View.list_page(
		frame_of(Edit),
		{ shown: Admin.pair(books, { name: "books", list: ["author_id", "title"] }), state: { search: "", filters: [], sort: [], page: 1 }, page: Paging.of(1, 50, 1), rows: [{ cells: ["1", "Dune", "7"], nulls: [Bool.False, Bool.False, Bool.False] }], filters: [], notice: "" },
	)
	# A foreign key in the first column: the row's link, not a link in a link.
	html.contains("<td><a href=\"/db?table=books&amp;k.id=7\">1</a></td><td>Dune</td>")
}
expect View.row_title(Admin.pair(books, { name: "books" }), [("id", "7")], [{ name: "title", value: "", null: Bool.False }]) == "#7"
expect View.notice("saved") == "Saved." and View.notice("<script>") == ""
