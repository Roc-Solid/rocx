import Admin
import Catalog
import Form
import Listing
import Look
import Paging
import Widget

## The admin's pages, as HTML: the index of tables, a table's rows, a row's form, the question
## before a row is deleted, and why something wasn't done. Each is a page's main part (a header,
## then panels), for `Look.document`, beside the sidebar `View.side` draws; links are the admin's
## path and a query (`Form.link`).
View := [].{

	## What every page knows: the admin's path and title, the tables it shows, what the visitor may
	## do, and the token its forms send back (against cross-site requests).
	Frame : { mount : Str, title : Str, tables : List(Admin.Shown), access : Admin.Access, token : Str, back : { label : Str, href : Str } }

	## The sidebar: the admin's name, the link back to the app (`back`, if it has one), a link to
	## all its tables, then each table (`on`: the page shown, which the sidebar marks), and what the
	## visitor may do. With no tables (a refusal), only the link back.
	side : Frame, [Overview, Table(Str), Elsewhere] -> Str
	side = |frame, on| {
		overview = if (frame.tables.is_empty()) "" else Look.nav_link({ href: frame.mount, icon: "overview", tone: "accent", label: "All tables", count: "", on: on == Overview })
		tables = frame.tables.map(|shown| Look.nav_link({ href: Form.link(frame.mount, [("table", shown.table.name)]), icon: "table", tone: "neutral", label: Look.escape(Admin.label(shown)), count: "", on: on == Table(shown.table.name) }))
		listed = if (tables.is_empty()) "" else "${Look.nav_label("Tables")}${Str.join_with(tables, "")}"
		foot =
			match frame.access {
				Edit => "Changes are written to the database as each form is sent."
				ReadOnly => "Read only: you may look here, not change anything."
				Refused => ""
			}
		Look.side({ name: frame.title, note: "Tables, in Postgres", home: frame.mount, nav: "${Look.back_link(frame.back)}${overview}${listed}", foot })
	}

	## The tables, each with about how many rows it has and what it is.
	index_page : Frame -> Str
	index_page = |frame| {
		rows = frame.tables.map(
			|shown| {
				estimate = if (shown.table.estimate < 0) "<span class=\"muted\">—</span>" else "≈ ${shown.table.estimate.to_str()}"
				add = if (may_create(frame, shown)) "<a class=\"btn\" href=\"${Look.escape(Form.link(frame.mount, [("table", shown.table.name), ("new", "1")]))}\">${Look.icon("plus")}Add</a>" else ""
				"<tr><td class=\"name\"><a href=\"${Look.escape(Form.link(frame.mount, [("table", shown.table.name)]))}\">${Look.escape(Admin.label(shown))}</a><code class=\"muted\">${Look.escape(shown.table.name)}</code></td><td class=\"n nowrap\">${estimate}</td><td class=\"about\">${Look.escape(shown.table.comment)}</td><td class=\"actions\">${add}</td></tr>"
			},
		)
		body =
			if rows.is_empty() {
				Look.empty("table", "No tables to show", "The app lists them (<code>tables</code>), or shows every one (<code>include: All</code>).")
			} else {
				"<div class=\"table-wrap\"><table class=\"tables\"><thead><tr><th>Table</th><th class=\"n\">Rows</th><th>About</th><th></th></tr></thead><tbody>${Str.join_with(rows, "")}</tbody></table></div>"
			}
		counted = if (rows.len() == 1) "1 table" else "${rows.len().to_str()} tables"
		Str.join_with(
			[
				Look.header({ eyebrow: "Overview", title: Look.escape(frame.title), actions: "" }),
				Look.panel({ eyebrow: "Rows are Postgres's estimates", title: "Tables", aside: "<span>${counted}</span>", body, class: "" }),
			],
			"",
		)
	}

	## A table's rows, a page of them, with its search, a filter under each column's heading (a
	## form of them, with a button that sends it), and its pages.
	list_page : Frame, { shown : Admin.Shown, state : Listing.State, page : Paging.Page, rows : List(Catalog.Row), notice : Str } -> Str
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
		filter_cells = columns.map(|column| "<td>${filter_html(shown, state, column)}</td>")
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
		filtering = !state.filters.is_empty() or !state.invalid.is_empty()
		none = "<tr><td class=\"none\" colspan=\"${columns.len().to_str()}\">No rows${if (state.search.is_empty() and !filtering) "" else " like that"}.</td></tr>"
		body_rows = if (lines.is_empty()) none else Str.join_with(lines, "")
		# The filters' form keeps the table, the search and the sort; a filter changed is the first page.
		kept = Listing.params(name, { ..state, filters: [], page: 1 }).keep_if(|(_, value)| !value.is_empty()).map(|(field, value)| "<input type=\"hidden\" name=\"${Look.escape(field)}\" value=\"${Look.escape(value)}\">")
		rows_html =
			if columns.is_empty() {
				Look.empty("table", "No columns to show", "The app's options for this table list none, or hide them all.")
			} else {
				"<form id=\"filters\" class=\"filters\" method=\"get\" action=\"${Look.escape(frame.mount)}\">${Str.join_with(kept, "")}<div class=\"rows\"><table><thead><tr>${Str.join_with(heads, "")}</tr><tr class=\"filter\">${Str.join_with(filter_cells, "")}</tr></thead><tbody>${body_rows}</tbody></table></div></form>"
			}
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
		foot = if (listing.page.total == 0) "" else "<div class=\"panel-foot\"><span>${range.first.to_str()}–${range.last.to_str()} of ${listing.page.total.to_str()}</span>${pager}</div>"
		search =
			if Admin.searchable(shown).is_empty() {
				""
			} else {
				searched_kept = Listing.params(name, { ..state, search: "", page: 1 }).keep_if(|(_, value)| !value.is_empty()).map(|(field, value)| "<input type=\"hidden\" name=\"${Look.escape(field)}\" value=\"${Look.escape(value)}\">")
				searched_in = Str.join_with(Admin.searchable(shown).map(|column| Admin.column_label(shown, column.name)), ", ")
				clear = if (state.search.is_empty()) "" else " <a href=\"${at({ ..state, search: "", page: 1 })}\">Clear</a>"
				"<form class=\"search\" method=\"get\" action=\"${Look.escape(frame.mount)}\">${Str.join_with(searched_kept, "")}<input type=\"search\" name=\"q\" value=\"${Look.escape(state.search)}\" aria-label=\"Search\" placeholder=\"${Look.escape(searched_in)}\"><button class=\"btn\">${Look.icon("search")}Search</button>${clear}</form>"
			}
		# The filters' button is the form's (`form="filters"`), so it sits beside the search.
		filter_button =
			if columns.is_empty() {
				""
			} else {
				clear = if (filtering) " <a href=\"${at({ ..state, filters: [], invalid: [], page: 1 })}\">Clear filters</a>" else ""
				"<span class=\"filtering\"><button class=\"btn\" form=\"filters\">${Look.icon("filter")}Filter</button>${clear}</span>"
			}
		add = if (may_create(frame, shown)) "<a class=\"btn primary\" href=\"${Look.escape(Form.link(frame.mount, [("table", name), ("new", "1")]))}\">${Look.icon("plus")}Add</a>" else ""
		about = if (shown.table.comment.is_empty()) "" else "<span class=\"meta\">${Look.escape(shown.table.comment)}</span>"
		tools = if (search.is_empty() and filter_button.is_empty()) "" else "<div class=\"tools\">${search}${filter_button}</div>"
		Str.join_with(
			[
				Look.header({ eyebrow: "${trail(frame, [])} · <code>${Look.escape(name)}</code>", title: "${Look.escape(Admin.label(shown))}${about}", actions: add }),
				notice_html(listing.notice),
				"<section class=\"panel rows-panel\">${tools}${rows_html}${foot}</section>",
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
		listed = Form.link(frame.mount, [("table", name)])
		delete =
			if !creating and frame.access == Edit and shown.options.delete {
				"<a class=\"btn danger\" href=\"${Look.escape(Form.link(frame.mount, [("table", name)].concat(key_fields).append(("delete", "1"))))}\">${Look.icon("trash")}Delete</a>"
			} else {
				""
			}
		back = "<a class=\"btn\" href=\"${Look.escape(listed)}\">${Look.icon("back")}Back to the list</a>"
		writes = frame.access == Edit and columns.any(|column| Admin.writable(shown, frame.access, column, doing))
		body =
			if writes {
				hidden = hidden_fields(frame.token, if (creating) "create" else "update", name, key_fields)
				"<form class=\"edit panel\" method=\"post\" action=\"${Look.escape(frame.mount)}\">${hidden}<div class=\"fields\">${Str.join_with(fields, "")}</div><div class=\"panel-foot buttons\">${back}<span class=\"act act-primary\"><button>${if (creating) "Add" else "Save"}</button></span></div></form>"
			} else {
				"<section class=\"panel\"><div class=\"fields\">${Str.join_with(fields, "")}</div><div class=\"panel-foot buttons\">${back}</div></section>"
			}
		problem = problem_html(if (creating) "Not added" else "Not saved", row.problem)
		Str.join_with(
			[
				Look.header({ eyebrow: trail(frame, [(Admin.label(shown), listed)]), title: Look.escape(heading), actions: delete }),
				notice_html(row.notice),
				problem,
				body,
			],
			"",
		)
	}

	## The question before a row is deleted, and the button that deletes it.
	delete_page : Frame, { shown : Admin.Shown, key : List((Str, Str)), title : Str, problem : Str } -> Str
	delete_page = |frame, asked| {
		name = asked.shown.table.name
		key_fields = asked.key.map(|(column, value)| ("k.${column}", value))
		described = Str.join_with(asked.key.map(|(column, value)| "${Admin.column_label(asked.shown, column)} ${value}"), ", ")
		row = View.row_link(frame.mount, name, asked.key)
		delete = Look.button_with("act-danger", "trash", frame.mount, [("csrf", frame.token), ("action", "delete"), ("table", name)].concat(key_fields), "Delete")
		Str.join_with(
			[
				Look.header({ eyebrow: trail(frame, [(Admin.label(asked.shown), Form.link(frame.mount, [("table", name)])), (asked.title, row)]), title: "Delete ${Look.escape(asked.title)}?", actions: "" }),
				problem_html("Not deleted", asked.problem),
				"<section class=\"panel confirm\"><div class=\"callout tone-bad\">${Look.icon("alert")}<div><strong>This can't be undone</strong><p>The row of ${Look.escape(Admin.label(asked.shown))} whose ${Look.escape(described)} goes, for good. If other rows refer to it, their foreign keys say whether they go with it or keep it from going.</p></div></div><div class=\"panel-foot buttons\"><a class=\"btn\" href=\"${Look.escape(row)}\">${Look.icon("back")}No, keep it</a>${delete}</div></section>",
			],
			"",
		)
	}

	## Why something wasn't done.
	problem_page : Frame, Str, Str -> Str
	problem_page = |frame, heading, why| {
		back = if (frame.access == Refused) "" else "<div class=\"panel-foot\"><a class=\"btn\" href=\"${Look.escape(frame.mount)}\">${Look.icon("back")}All tables</a></div>"
		eyebrow = if (frame.access == Refused) Look.escape(frame.title) else trail(frame, [])
		"${Look.header({ eyebrow, title: Look.escape(heading), actions: "" })}<section class=\"panel\"><div class=\"callout tone-bad\">${Look.icon("alert")}<div><p class=\"problem\">${Look.escape(why)}</p></div></div>${back}</section>"
	}

	## The page the admin shows while its options name what the schema doesn't have
	## (`Admin.problems`): each, and nothing of the database.
	problems_page : Frame, List(Str) -> Str
	problems_page = |frame, whys| {
		items = Str.join_with(whys.map(|why| "<li>${Look.escape(why)}</li>"), "")
		"${Look.header({ eyebrow: Look.escape(frame.title), title: "The admin's options", actions: "" })}<section class=\"panel\"><div class=\"callout tone-bad\">${Look.icon("alert")}<div><p class=\"problem\">They name what the schema doesn't have, so the admin shows nothing until they are mended:</p><ul class=\"problem\">${items}</ul></div></div></section>"
	}

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

## A column's filter, under its heading, from its type (`Listing.kind`): an input of a text it
## contains, a range's two (from, to), a select of a boolean's or a choice's values, or an input of
## the value it is (a foreign key); and, for a column that may be null, empty and not empty. A value
## the list ignored stays in its input, marked, with a note of what it should be.
filter_html : Admin.Shown, Listing.State, Catalog.Column -> Str
filter_html = |shown, state, column| {
	name = column.name
	label = Admin.column_label(shown, name)
	equal = filter_value(state, name, Equal)
	nulls = if (state.filters.contains({ column: name, is: Null })) "null" else if (state.filters.contains({ column: name, is: Set })) "set" else ""
	input = |field, attributes, value, described, placeholder| {
		bad = state.invalid.find_first(|each| each.field == field)
		(said, marked) =
			match bad {
				Ok(invalid) => (invalid.value, " aria-invalid=\"true\"")
				Err(_) => (value, "")
			}
		hint = if (placeholder.is_empty()) "" else " placeholder=\"${Look.escape(placeholder)}\""
		"<input ${attributes} name=\"${Look.escape(field)}\" value=\"${Look.escape(said)}\" aria-label=\"${Look.escape(described)}\"${hint}${marked}>"
	}
	select = |field, class, options, selected, described| {
		# A value no option is (a check's value since taken away) is kept, as an option of its own.
		kept = if (selected.is_empty() or options.any(|(value, _)| value == selected)) options else options.append((selected, selected))
		listed = kept.map(|(value, text)| "<option value=\"${Look.escape(value)}\"${if (value == selected) " selected" else ""}>${Look.escape(text)}</option>")
		marked = if (state.invalid.any(|each| each.field == field)) " aria-invalid=\"true\"" else ""
		"<select${class} name=\"${Look.escape(field)}\" aria-label=\"${Look.escape(described)}\"${marked}><option value=\"\">any</option>${Str.join_with(listed, "")}</select>"
	}
	empties = [("null", "empty"), ("set", "not empty")]
	nullable = if (column.nullable) select("is.${name}", " class=\"nulls\"", empties, nulls, "${label}: empty or not") else ""
	# A select of values, with empty and not empty among them (`is.`) for a column that may be null;
	# unless a value is called null or set, which then has a select of its own.
	choose = |values| {
		together = column.nullable and !values.any(|(value, _)| value == "null" or value == "set")
		if together {
			select("is.${name}", "", values.concat(empties), equal ?? nulls, label)
		} else {
			"${select("f.${name}", "", values, equal ?? "", label)}${nullable}"
		}
	}
	control =
		match Listing.kind(shown, column) {
			Contains =>
				match equal {
					# An equal's value (`f.title=…`, from a link) has an input of its own.
					Ok(value) => "${input("f.${name}", "type=\"text\"", value, "${label} is", "equals")}${nullable}"
					Err(_) => "${input("has.${name}", "type=\"text\"", filter_value(state, name, Contains) ?? "", "${label} contains", "contains")}${nullable}"
				}
			Exact => "${input("f.${name}", "type=\"text\"", equal ?? "", "${label} is", "equals")}${nullable}"
			Range(scale) => {
				attributes =
					match scale {
						Integer => "type=\"number\" step=\"1\""
						Decimal => "type=\"number\" step=\"any\""
						Day => "type=\"date\""
						Moment => "type=\"datetime-local\" step=\"1\""
						Time => "type=\"time\" step=\"1\""
					}
				# An equal's value (`f.price=…`, from a link) is a range of one.
				from = filter_value(state, name, AtLeast) ?? (equal ?? "")
				to = filter_value(state, name, AtMost) ?? (equal ?? "")
				"<div class=\"range\"><span>from</span>${input("from.${name}", attributes, from, "${label} from", "")}<span>to</span>${input("to.${name}", attributes, to, "${label} to", "")}</div>${nullable}"
			}
			YesNo => choose([("true", "yes"), ("false", "no")])
			OneOf(values) => choose(values.map(|value| (value, value)))
		}
	notes = state.invalid.keep_if(|each| each.column == name).map(|each| "Ignored: not ${each.expected}").fold([], |seen, note| if (seen.contains(note)) seen else seen.append(note))
	"${control}${Str.join_with(notes.map(|note| "<span class=\"note\">${Look.escape(note)}</span>"), "")}"
}

## The value of a column's filter of one kind, if it has one.
filter_value : Listing.State, Str, [Equal, Contains, AtLeast, AtMost] -> Try(Str, [None])
filter_value = |state, column, wanted| {
	found = state.filters.keep_oks(
		|each|
			match (each.is, wanted) {
				(Equal(value), Equal) if each.column == column => Ok(value)
				(Contains(value), Contains) if each.column == column => Ok(value)
				(AtLeast(value), AtLeast) if each.column == column => Ok(value)
				(AtMost(value), AtMost) if each.column == column => Ok(value)
				_ => Err(None)
			},
	)
	match found.first() {
		Ok(value) => Ok(value)
		Err(_) => Err(None)
	}
}

## The eyebrow over a page's title: the admin's name, then the pages on the way to this one, each a link.
trail : View.Frame, List((Str, Str)) -> Str
trail = |frame, steps| Str.join_with([(frame.title, frame.mount)].concat(steps).map(|(label, href)| "<a href=\"${Look.escape(href)}\">${Look.escape(label)}</a>"), " · ")

## What a form did (`Saved.`), over the page it went back to.
notice_html : Str -> Str
notice_html = |text| if (text.is_empty()) "" else "<section class=\"panel\"><div class=\"callout tone-good\">${Look.icon("check")}<div><p class=\"notice\" role=\"status\">${Look.escape(text)}</p></div></div></section>"

## Why a form wasn't done (`title`, then what Postgres said), over the form again.
problem_html : Str, Str -> Str
problem_html = |title, why| if (why.is_empty()) "" else "<section class=\"panel\"><div class=\"callout tone-bad\" role=\"alert\">${Look.icon("alert")}<div><strong>${Look.escape(title)}</strong><p class=\"problem\">${Look.escape(why)}</p></div></div></section>"

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
frame_of = |access| { mount: "/db", title: "Database", tables: [Admin.pair(books, { name: "books", search: ["title"] }), Admin.pair(authors, { name: "authors" }), shelf], access, token: "t0k", back: { label: "", href: "" } }

## A table of each kind of filter: text, a foreign key, a boolean, an enum and a check (each may be
## null, or not), a number, a moment and a day; a hidden column, and one the list doesn't show.
shelf : Admin.Shown
shelf = {
	table = {
		name: "shelf",
		comment: "",
		estimate: 9,
		columns: [
			column_of("id", "int8"),
			column_of("title", "text"),
			{ ..column_of("author_id", "int8"), nullable: Bool.True, refers: To({ table: "authors", column: "id" }) },
			column_of("in_print", "bool"),
			{ ..column_of("mood", "mood"), nullable: Bool.True, labels: ["happy", "sad"] },
			{ ..column_of("state", "text"), choices: ["draft", "published"] },
			{ ..column_of("price", "numeric"), nullable: Bool.True },
			column_of("published_at", "timestamptz"),
			column_of("born", "date"),
			column_of("secret", "text"),
			column_of("note", "text"),
		],
		key: ["id"],
	}
	Admin.pair(table, { name: "shelf", list: ["id", "title", "author_id", "in_print", "mood", "state", "price", "published_at", "born", "secret"], hidden: ["secret"] })
}

## The list of shelf, for a query, with no rows.
shelf_page : Str -> Str
shelf_page = |query| View.list_page(frame_of(Edit), { shown: shelf, state: Listing.read(shelf, Form.fields(query)), page: Paging.of(120, 50, 1), rows: [], notice: "" })

## The row of filters, in a list's HTML.
filter_row : Str -> Str
filter_row = |html|
	match html.split_first("<tr class=\"filter\">") {
		Ok({ after, .. }) =>
			match after.split_first("</tr>") {
				Ok({ before, .. }) => before
				Err(_) => ""
			}
		Err(_) => ""
	}

expect {
	html = View.index_page(frame_of(Edit))
	html.contains("<a href=\"/db?table=books\">Books</a><code class=\"muted\">books</code>") and html.contains("<a class=\"btn\" href=\"/db?table=books&amp;new=1\">") and html.contains("</svg>Add</a>") and html.contains("≈ 3") and html.contains("People who write")
}
expect !View.index_page(frame_of(ReadOnly)).contains(">Add<")
expect {
	frame = frame_of(Edit)
	shown = Admin.pair(books, { name: "books", search: ["title"] })
	state = { search: "dune", filters: [], invalid: [], sort: [{ column: "title", descending: Bool.False }], page: 1 }
	html = View.list_page(
		frame,
		{
			shown,
			state,
			page: Paging.of(120, 50, 1),
			rows: [{ cells: ["7", "Dune <1>", "1", "true", "7"], nulls: [Bool.False, Bool.False, Bool.False, Bool.False, Bool.False] }, { cells: ["8", "", "", "false", "8"], nulls: [Bool.False, Bool.False, Bool.True, Bool.False, Bool.False] }],
			notice: "Deleted.",
		},
	)
	html.contains("<td><a href=\"/db?table=books&amp;k.id=7\">7</a></td><td>Dune &lt;1&gt;</td><td><a href=\"/db?table=authors&amp;k.id=1\">1</a></td><td>yes</td>")
		and html.contains("<td class=\"null\">null</td>")
		and html.contains("<a class=\"on\" href=\"/db?table=books&amp;q=dune&amp;sort=-title\">Title ▲</a>")
		and html.contains("<input type=\"hidden\" name=\"table\" value=\"books\"><input type=\"hidden\" name=\"sort\" value=\"title\"><input type=\"search\" name=\"q\" value=\"dune\"")
		and html.contains("<form id=\"filters\" class=\"filters\" method=\"get\" action=\"/db\"><input type=\"hidden\" name=\"table\" value=\"books\"><input type=\"hidden\" name=\"q\" value=\"dune\"><input type=\"hidden\" name=\"sort\" value=\"title\"><div class=\"rows\"><table><thead><tr><th>")
		and html.contains("<span class=\"filtering\"><button class=\"btn\" form=\"filters\">")
		and html.contains("</svg>Filter</button></span>")
		and !html.contains("Clear filters")
		and !html.contains("<aside")
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
		and html.contains("<a class=\"btn danger\" href=\"/db?table=books&amp;k.id=7&amp;delete=1\">")
		and html.contains("<span class=\"act act-primary\"><button>Save</button></span>")
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
		{ shown: Admin.pair(books, { name: "books", list: ["author_id", "title"] }), state: { search: "", filters: [], invalid: [], sort: [], page: 1 }, page: Paging.of(1, 50, 1), rows: [{ cells: ["1", "Dune", "7"], nulls: [Bool.False, Bool.False, Bool.False] }], notice: "" },
	)
	# A foreign key in the first column: the row's link, not a link in a link.
	html.contains("<td><a href=\"/db?table=books&amp;k.id=7\">1</a></td><td>Dune</td>")
}
# A filter under each listed column, from its type; none for a hidden column, or one not listed.
expect {
	row = filter_row(shelf_page("table=shelf"))
	row.split_on("<td>").len() == 10
		and row.contains("<td><div class=\"range\"><span>from</span><input type=\"number\" step=\"1\" name=\"from.id\" value=\"\" aria-label=\"Id from\"><span>to</span><input type=\"number\" step=\"1\" name=\"to.id\" value=\"\" aria-label=\"Id to\"></div></td>")
		and row.contains("<td><input type=\"text\" name=\"has.title\" value=\"\" aria-label=\"Title contains\" placeholder=\"contains\"></td>")
		and row.contains("<td><input type=\"text\" name=\"f.author_id\" value=\"\" aria-label=\"Author id is\" placeholder=\"equals\"><select class=\"nulls\" name=\"is.author_id\" aria-label=\"Author id: empty or not\"><option value=\"\">any</option><option value=\"null\">empty</option><option value=\"set\">not empty</option></select></td>")
		and row.contains("<td><select name=\"f.in_print\" aria-label=\"In print\"><option value=\"\">any</option><option value=\"true\">yes</option><option value=\"false\">no</option></select></td>")
		and row.contains("<td><select name=\"is.mood\" aria-label=\"Mood\"><option value=\"\">any</option><option value=\"happy\">happy</option><option value=\"sad\">sad</option><option value=\"null\">empty</option><option value=\"set\">not empty</option></select></td>")
		and row.contains("<td><select name=\"f.state\" aria-label=\"State\"><option value=\"\">any</option><option value=\"draft\">draft</option><option value=\"published\">published</option></select></td>")
		and row.contains("<input type=\"number\" step=\"any\" name=\"from.price\"")
		and row.contains("</div><select class=\"nulls\" name=\"is.price\"")
		and row.contains("<input type=\"datetime-local\" step=\"1\" name=\"to.published_at\"")
		and row.contains("<input type=\"date\" name=\"from.born\"")
		and !row.contains("secret")
		and !row.contains("note")
}
# Filters on: each in its control, a value ignored marked and noted; links and the form keep them.
expect {
	html = shelf_page("table=shelf&has.title=dune&f.author_id=2&f.in_print=false&is.mood=null&from.price=lots&to.price=20&from.published_at=2026-11-01T09%3A30&sort=title")
	row = filter_row(html)
	row.contains("name=\"has.title\" value=\"dune\"")
		and row.contains("name=\"f.author_id\" value=\"2\"")
		and row.contains("<option value=\"false\" selected>no</option>")
		and row.contains("<option value=\"null\" selected>empty</option><option value=\"set\">not empty</option></select></td>")
		and row.contains("<input type=\"number\" step=\"any\" name=\"from.price\" value=\"lots\" aria-label=\"Price from\" aria-invalid=\"true\"><span>to</span><input type=\"number\" step=\"any\" name=\"to.price\" value=\"20\" aria-label=\"Price to\">")
		and row.contains("<span class=\"note\">Ignored: not a number</span></td>")
		and row.contains("name=\"from.published_at\" value=\"2026-11-01T09:30\"")
		and html.contains("<a href=\"/db?table=shelf&amp;sort=title\">Clear filters</a>")
		and html.contains("<form id=\"filters\" class=\"filters\" method=\"get\" action=\"/db\"><input type=\"hidden\" name=\"table\" value=\"shelf\"><input type=\"hidden\" name=\"sort\" value=\"title\"><div class=\"rows\">")
		and html.contains("href=\"/db?table=shelf&amp;has.title=dune&amp;f.author_id=2&amp;f.in_print=false&amp;is.mood=null&amp;to.price=20&amp;from.published_at=2026-11-01T09%3A30&amp;sort=title&amp;page=2\">2</a>")
		and html.contains("<a class=\"on\" href=\"/db?table=shelf&amp;has.title=dune&amp;f.author_id=2&amp;f.in_print=false&amp;is.mood=null&amp;to.price=20&amp;from.published_at=2026-11-01T09%3A30&amp;sort=-title\">Title ▲</a>")
		and html.contains("<tbody><tr><td class=\"none\" colspan=\"9\">No rows like that.</td></tr></tbody>")
}
# Only a value ignored: still a way to clear it.
expect shelf_page("table=shelf&to.born=soon").contains(">Clear filters</a>") and shelf_page("table=shelf&to.born=soon").contains("Ignored: not a date: YYYY-MM-DD")
# An equal's value (from a link) on a text column has an input of its own; on a range, both ends.
expect {
	row = filter_row(shelf_page("table=shelf&f.title=Dune&f.price=9.5"))
	row.contains("<input type=\"text\" name=\"f.title\" value=\"Dune\" aria-label=\"Title is\" placeholder=\"equals\">") and row.contains("name=\"from.price\" value=\"9.5\"") and row.contains("name=\"to.price\" value=\"9.5\"")
}
# A choice called set, in a column that may be null: empty and not empty in a select of their own.
expect {
	odd = Admin.pair({ ..shelf.table, columns: [column_of("id", "int8"), { ..column_of("flag", "text"), nullable: Bool.True, choices: ["set", "unset"] }] }, { name: "shelf" })
	html = View.list_page(frame_of(Edit), { shown: odd, state: Listing.read(odd, Form.fields("f.flag=set")), page: Paging.of(0, 50, 1), rows: [], notice: "" })
	html.contains("<select name=\"f.flag\" aria-label=\"Flag\"><option value=\"\">any</option><option value=\"set\" selected>set</option><option value=\"unset\">unset</option></select><select class=\"nulls\" name=\"is.flag\"")
}
# The sidebar: every table, the one shown marked; a reader is told they may only look.
expect {
	side = View.side(frame_of(Edit), Table("books"))
	side.contains("<a href=\"/db?table=books\" aria-current=\"page\">") and side.contains("<a href=\"/db?table=authors\"><svg") and !side.contains("<a href=\"/db\" aria-current")
}
expect View.side(frame_of(Edit), Overview).contains("<a href=\"/db\" aria-current=\"page\">") and View.side(frame_of(ReadOnly), Elsewhere).contains("Read only")
# The link back to the app, first in the sidebar, when the app gives one; and alone, with no tables.
expect !View.side(frame_of(Edit), Overview).contains("class=\"back\"")
expect {
	back = { label: "Status", href: "/admin" }
	side = View.side({ ..frame_of(Edit), back }, Overview)
	alone = View.side({ ..frame_of(Refused), tables: [], back }, Elsewhere)
	side.contains("<nav class=\"side-nav\" aria-label=\"Database\"><a class=\"back\" href=\"/admin\">") and side.contains("Status</span></a><a href=\"/db\" aria-current=\"page\">")
		and alone.contains("<nav class=\"side-nav\" aria-label=\"Database\"><a class=\"back\" href=\"/admin\">") and !alone.contains("All tables")
}
# A refusal has no way on to the tables; another problem has.
expect !View.problem_page({ ..frame_of(Refused), tables: [] }, "Not for you", "No.").contains("All tables") and View.problem_page(frame_of(Edit), "No such table", "None.").contains(">All tables</a>")
expect {
	html = View.delete_page(frame_of(Edit), { shown: Admin.pair(books, { name: "books" }), key: [("id", "7")], title: "Dune", problem: "23503: still referred to" })
	html.contains("<form class=\"act act-danger\" method=\"post\" action=\"/db\"><input type=\"hidden\" name=\"csrf\" value=\"t0k\"><input type=\"hidden\" name=\"action\" value=\"delete\"><input type=\"hidden\" name=\"table\" value=\"books\"><input type=\"hidden\" name=\"k.id\" value=\"7\">")
		and html.contains("<strong>Not deleted</strong><p class=\"problem\">23503: still referred to</p>")
}
expect View.row_title(Admin.pair(books, { name: "books" }), [("id", "7")], [{ name: "title", value: "", null: Bool.False }]) == "#7"
expect {
	html = View.problems_page(frame_of(Edit), ["`<b>`, in books's `hidden`, isn't a column of books."])
	html.contains("<li>`&lt;b&gt;`, in books&#39;s `hidden`, isn&#39;t a column of books.</li>") and !html.contains("<b>")
}
expect View.notice("saved") == "Saved." and View.notice("<script>") == ""
