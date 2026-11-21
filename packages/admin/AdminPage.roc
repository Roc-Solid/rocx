import Admin
import Catalog
import Form
import Listing
import Look
import Paging
import Sql
import View
import Widget

## The admin, answering a request: as the jobs page is, it is the app's to mount, behind its own
## middleware, at a path of its own, with one route file.
##
## ```roc
## # routes/admin/db/+server.roc
## import pf.Db
## import pf.Random
## import pf.Server
## import admin.AdminPage
## import ../../../Middlewares
##
## middleware = Middlewares.staff
##
## respond! : { request : Server.Request, params : {}, context : { user : Str, staff : Bool } } => Server.Response
## respond! = |{ request, context, .. }| AdminPage.respond!(request, context, Admin.admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes! })
## ```
##
## A package can't name the server's platform (see the README), so the app hands the admin the
## three effects it runs on: Postgres's `Db.all!` and `Db.run!`, and `Random.bytes!`.
##
## It reads the schema's catalog for each request, and answers GET (`?table=books` a table's rows,
## `&k.id=7` a row, `&new` a new one, `&delete` the question before deleting one) and POST (a form:
## `action=create|update|delete`). A POST must come from a page of the same site (`Origin`) and send
## back the token its form was given (a cookie's, `rocx_admin_csrf`), or it is refused (403).
AdminPage := [].{

	## A request, as `Server.Request` is.
	Request : { method : Str, path : Str, query : Str, headers : List({ name : Str, value : Str }), body : List(U8) }

	## What the admin runs on: `{ all!: Db.all!, run!: Db.run!, random!: Random.bytes! }`.
	Effects : {
		all! : Str, List(Sql.Param) => Try(List(Catalog.Row), [DbErr(Str), BadRow(Str)]),
		run! : Str, List(Sql.Param) => Try(U64, [DbErr(Str)]),
		random! : U64 => List(U8),
	}

	## The answer to a request, given the context the route's middleware handed on: a page, a
	## redirect after a form, or a refusal. It is a `Server.Response`.
	respond! : Request, context, Admin.Config(context), Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
	respond! = |request, context, config, effects| {
		access = (config.access)(context)
		empty_frame = { mount: config.mount, title: config.title, tables: [], access, token: "" }
		method = if (request.method == "HEAD") "GET" else request.method
		if access == Refused {
			page(403, empty_frame, "Not for you", View.problem_page(empty_frame, "Not for you", "This admin isn't open to you."))
		} else if method != "GET" and method != "POST" {
			{ status: 405, headers: [{ name: "allow", value: "GET, HEAD, POST" }, { name: "content-type", value: "text/plain; charset=utf-8" }], body: Text("The admin answers GET and POST.") }
		} else {
			given = cookie(request.headers, csrf_cookie)
			token = if (AdminPage.is_token(given)) given else AdminPage.hex((effects.random!)(16))
			form = if (method == "POST") Form.fields(Str.from_utf8_lossy(request.body)) else []
			answer =
				if method == "POST" and access != Edit {
					page(403, empty_frame, "Not done", View.problem_page(empty_frame, "Not done", "You may look here, not change anything."))
				} else if method == "POST" and (!AdminPage.same_origin(request.headers) or !AdminPage.is_token(given) or Form.get(form, "csrf") != given) {
					# Before anything is read: another site's page, or one from before the cookie.
					page(403, empty_frame, "Not done", View.problem_page(empty_frame, "Not done", "The form was sent from another site's page, or from an old one: open it again here, and send it again."))
				} else {
					match read_catalog!(effects, config.schema) {
						Err(why) => page(500, empty_frame, "The database", View.problem_page(empty_frame, "The database can't be read", why))
						Ok(tables) => {
							frame = { ..empty_frame, tables: Admin.showing(config, tables), token }
							if method == "POST" {
								write!(form, frame, config.schema, effects)
							} else {
								read!(Form.fields(request.query), frame, config.schema, effects)
							}
						}
					}
				}
			if token == given {
				answer
			} else {
				# The cookie that says what token a form sends back: for the admin's path only, out of
				# scripts' reach, and never sent with a form another site's page posts (`Lax`).
				{ ..answer, headers: answer.headers.append({ name: "set-cookie", value: "${csrf_cookie}=${token}; Path=${cookie_path(config.mount)}; HttpOnly; SameSite=Lax" }) }
			}
		}
	}

	## Bytes as lower-case hex: a token.
	hex : List(U8) -> Str
	hex = |bytes| Str.from_utf8_lossy(bytes.fold([], |out, byte| out.append(hex_digit(byte // 16)).append(hex_digit(byte % 16))))

	## Whether a text is a token the admin gives (32 lower-case hex digits).
	is_token : Str -> Bool
	is_token = |text| text.count_utf8_bytes() == 32 and text.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

	## Whether a request comes from a page of this site, or from no page: a browser says which
	## site's page sent it (`Origin`), as `Server.same_origin` reads it.
	same_origin : List({ name : Str, value : Str }) -> Bool
	same_origin = |headers|
		match header(headers, "origin") {
			Ok(origin) =>
				match origin.split_first("://") {
					Ok({ after, .. }) => header(headers, "host") == Ok(after)
					Err(_) => Bool.False
				}
			Err(Missing) => Bool.True
		}
}

csrf_cookie : Str
csrf_cookie = "rocx_admin_csrf"

## The admin's path as a cookie's `Path`: the characters a path is written with, no more.
cookie_path : Str -> Str
cookie_path = |mount| {
	kept = Str.from_utf8_lossy(mount.to_utf8().keep_if(|byte| byte > 32 and byte < 127 and byte != ';' and byte != ','))
	if (kept.starts_with("/")) kept else "/"
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

header : List({ name : Str, value : Str }), Str -> Try(Str, [Missing])
header = |headers, wanted|
	match headers.find_first(|each| each.name.with_ascii_lowercased() == wanted) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(Missing)
	}

## The value of the cookie `name` ("" without one).
cookie : List({ name : Str, value : Str }), Str -> Str
cookie = |headers, name| {
	pairs = headers.keep_if(|each| each.name.with_ascii_lowercased() == "cookie").map(|each| each.value.split_on(";")).join()
	found = pairs.keep_oks(
		|pair|
			match pair.trim().split_first("=") {
				Ok({ before, after }) if before == name => Ok(after)
				_ => Err(Elsewhere)
			},
	)
	found.first() ?? ""
}

## A whole page.
page : U16, View.Frame, Str, Str -> { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
page = |status, frame, title, body| {
	full = if (title == frame.title) title else "${title} · ${frame.title}"
	{ status, headers: Look.headers, body: Text(Look.document(full, body)) }
}

## On to `location` (a link of the admin's own), after a form.
redirect : Str -> { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
redirect = |location| { status: 303, headers: [{ name: "location", value: location }, { name: "cache-control", value: "no-store" }], body: Text("") }

## The schema's tables, from its catalog.
read_catalog! : AdminPage.Effects, Str => Try(List(Catalog.Table), Str)
read_catalog! = |effects, schema| {
	asked! = |sql|
		match (effects.all!)(sql, [Text(schema)]) {
			Ok(rows) => Ok(rows)
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	tables = asked!(Catalog.tables_sql)?
	columns = asked!(Catalog.columns_sql)?
	enums = asked!(Catalog.enums_sql)?
	constraints = asked!(Catalog.constraints_sql)?
	Ok(Catalog.read(schema, { tables, columns, enums, constraints }))
}

## The rows a statement reads, or why it couldn't.
rows! : AdminPage.Effects, Sql.Statement => Try(List(Catalog.Row), Str)
rows! = |effects, statement|
	match (effects.all!)(statement.sql, statement.params) {
		Ok(found) => Ok(found)
		Err(DbErr(why)) => Err(why)
		Err(BadRow(why)) => Err(why)
	}

## A page: the index, a table's rows, a row, a new row, or the question before deleting one.
read! : List(Form.Field), View.Frame, Str, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
read! = |query, frame, schema, effects| {
	name = Form.get(query, "table")
	if name.is_empty() {
		page(200, frame, frame.title, View.index_page(frame))
	} else {
		match Admin.find(frame.tables, name) {
			Err(NotFound) => page(404, frame, "No such table", View.problem_page(frame, "No such table", "There is no table called ${name} here."))
			Ok(shown) =>
				if Form.asks(query, "new") {
					if frame.access == Edit and shown.options.create {
						values = Admin.visible(shown).map(|column| { name: column.name, value: Widget.initial(column), null: Bool.False })
						row_page!(200, frame, schema, shown, effects, { key: [], values, problem: "", notice: "" })
					} else {
						page(403, frame, Admin.label(shown), View.problem_page(frame, "Not here", "Rows aren't added to ${Admin.label(shown)} here."))
					}
				} else {
					match Listing.key(shown, query) {
						Err(NoKey) => list!(query, frame, schema, shown, effects)
						Ok(key) => one!(query, frame, schema, shown, key, effects)
					}
				}
		}
	}
}

## A table's rows, a page of them.
list! : List(Form.Field), View.Frame, Str, Admin.Shown, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
list! = |query, frame, schema, shown, effects| {
	state = Listing.read(shown, query)
	conditions = Listing.conditions(shown, state)
	read =
		match rows!(effects, Sql.count(schema, shown.table, conditions)) {
			Err(why) => Err(why)
			Ok(counted) => {
				total = U64.from_str(Catalog.cell(counted.first() ?? { cells: [], nulls: [] }, 0)) ?? 0
				paged = Paging.of(total, shown.options.per_page, state.page)
				statement = Sql.rows(
					schema,
					shown.table,
					{ columns: Admin.listed(shown), whole: Admin.key(shown), conditions, order: Listing.order(shown, state), limit: paged.size, offset: Paging.offset(paged), longest: 81 },
				)
				match rows!(effects, statement) {
					Ok(found) => Ok((paged, found))
					Err(why) => Err(why)
				}
			}
		}
	match read {
		Err(why) => page(400, frame, Admin.label(shown), View.problem_page(frame, Admin.label(shown), "Its rows can't be read: ${why}"))
		Ok((paged, found)) => {
			var $filters = []
			for column in Admin.filterable(shown) {
				choices =
					match Admin.widget(shown, column) {
						Checkbox | MaybeBool => [("true", "yes"), ("false", "no")]
						Choice(values) => values.map(|value| (value, value))
						_ =>
							match rows!(effects, Sql.distinct(schema, shown.table, column, 50)) {
								Ok(values) => values.map(|row| (Catalog.cell(row, 0), Widget.cut(Catalog.cell(row, 0), 40)))
								Err(_) => []
							}
					}
				$filters = $filters.append({ column, choices })
			}
			filters = $filters
			body = View.list_page(frame, { shown, state, page: paged, rows: found, filters, notice: View.notice(Form.get(query, "done")) })
			page(200, frame, Admin.label(shown), body)
		}
	}
}

## A row: its form, or the question before deleting it.
one! : List(Form.Field), View.Frame, Str, Admin.Shown, List((Catalog.Column, Str)), AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
one! = |query, frame, schema, shown, key, effects| {
	named = key.map(|(column, value)| (column.name, value))
	match current!(effects, schema, shown, key) {
		Err(Missing) => page(404, frame, Admin.label(shown), View.problem_page(frame, "No such row", "${Admin.label(shown)} has no row whose ${described(shown, named)}."))
		Err(Failed(why)) => page(400, frame, Admin.label(shown), View.problem_page(frame, "No such row", why))
		Ok(values) =>
			if Form.asks(query, "delete") {
				if frame.access == Edit and shown.options.delete {
					title = View.row_title(shown, named, values)
					page(200, frame, "Delete ${title}", View.delete_page(frame, { shown, key: named, title, problem: "" }))
				} else {
					page(403, frame, Admin.label(shown), View.problem_page(frame, "Not here", "Rows of ${Admin.label(shown)} aren't deleted here."))
				}
			} else {
				row_page!(200, frame, schema, shown, effects, { key: named, values, problem: "", notice: View.notice(Form.get(query, "done")) })
			}
	}
}

## A row's visible columns, as the database has them now.
current! : AdminPage.Effects, Str, Admin.Shown, List((Catalog.Column, Str)) => Try(List({ name : Str, value : Str, null : Bool }), [Missing, Failed(Str)])
current! = |effects, schema, shown, key| {
	columns = Admin.visible(shown)
	match rows!(effects, Sql.one(schema, shown.table, columns, key)) {
		Err(why) => Err(Failed(why))
		Ok(found) =>
			match found.first() {
				Err(_) => Err(Missing)
				Ok(row) => Ok(columns.map_with_index(|column, i| { name: column.name, value: Catalog.cell(row, i), null: Catalog.null_at(row, i) }))
			}
	}
}

## A row's page, with the choices of its foreign keys.
row_page! : U16, View.Frame, Str, Admin.Shown, AdminPage.Effects, { key : List((Str, Str)), values : List({ name : Str, value : Str, null : Bool }), problem : Str, notice : Str } => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
row_page! = |status, frame, schema, shown, effects, row| {
	doing = if (row.key.is_empty()) Creating else Editing
	var $options = []
	for column in Admin.visible(shown).keep_if(|each| Admin.writable(shown, frame.access, each, doing)) {
		chosen =
			match Admin.widget(shown, column) {
				Reference(other) =>
					match Admin.find(frame.tables, other.table) {
						Ok(target) if target.table.key == [other.column] =>
							match (Catalog.column(target.table, other.column), Admin.title(target)) {
								(Ok(key_column), Ok(title)) =>
									match rows!(effects, Sql.titles(schema, target.table, key_column, title, 201)) {
										# Too many to choose from: an input instead.
										Ok(found) if found.len() <= 200 => [{ column: column.name, options: found.map(|each| (Catalog.cell(each, 0), Widget.cut(Catalog.cell(each, 1), 60))) }]
										_ => []
									}
								_ => []
							}
						_ => []
					}
				_ => []
			}
		$options = $options.concat(chosen)
	}
	options = $options
	heading = if (row.key.is_empty()) "Add to ${Admin.label(shown)}" else View.row_title(shown, row.key, row.values)
	page(status, frame, heading, View.row_page(frame, { shown, key: row.key, values: row.values, options, problem: row.problem, notice: row.notice }))
}

## A form, sent (by someone who may edit, from one of the admin's pages): a row added, changed or
## deleted, then on to a page that says so; or the form again, with what went wrong.
write! : List(Form.Field), View.Frame, Str, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
write! = |form, frame, schema, effects|
	match Admin.find(frame.tables, Form.get(form, "table")) {
		Err(NotFound) => page(404, frame, "No such table", View.problem_page(frame, "No such table", "There is no table called ${Form.get(form, "table")} here."))
		Ok(shown) =>
			match Form.get(form, "action") {
				"create" => create!(form, frame, schema, shown, effects)
				"update" => update!(form, frame, schema, shown, effects)
				"delete" => delete!(form, frame, schema, shown, effects)
				other => page(400, frame, "Not done", View.problem_page(frame, "Not done", "The admin's forms don't ${other}."))
			}
	}

## What a form sent for each of `columns` it has a field for.
sent : List(Form.Field), List(Catalog.Column) -> List({ name : Str, value : Str, null : Bool })
sent = |form, columns| columns.keep_if(|column| Form.asks(form, "v.${column.name}")).map(|column| { name: column.name, value: Form.get(form, "v.${column.name}"), null: Bool.False })

create! : List(Form.Field), View.Frame, Str, Admin.Shown, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
create! = |form, frame, schema, shown, effects|
	if !shown.options.create {
		page(403, frame, Admin.label(shown), View.problem_page(frame, "Not done", "Rows aren't added to ${Admin.label(shown)} here."))
	} else {
		columns = Admin.visible(shown).keep_if(|column| Admin.writable(shown, Edit, column, Creating) and Form.asks(form, "v.${column.name}"))
		values = columns.keep_oks(
			|column|
				match Widget.param(Admin.widget(shown, column), column, Form.get(form, "v.${column.name}"), Creating) {
					Value(param) => Ok((column, param))
					Default => Err(Default)
				},
		)
		key = Admin.key(shown)
		match rows!(effects, Sql.insert(schema, shown.table, values, key)) {
			Err(why) => row_page!(422, frame, schema, shown, effects, { key: [], values: sent(form, columns), problem: why, notice: "" })
			Ok(found) => {
				row = found.first() ?? { cells: [], nulls: [] }
				if key.is_empty() {
					redirect(Form.link(frame.mount, [("table", shown.table.name), ("done", "created")]))
				} else {
					created = key.map_with_index(|column, i| (column.name, Catalog.cell(row, i)))
					redirect("${View.row_link(frame.mount, shown.table.name, created)}&done=created")
				}
			}
		}
	}

update! : List(Form.Field), View.Frame, Str, Admin.Shown, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
update! = |form, frame, schema, shown, effects|
	match Listing.key(shown, form) {
		Err(NoKey) => page(400, frame, "Not done", View.problem_page(frame, "Not done", "The form doesn't say which row of ${Admin.label(shown)} it changes."))
		Ok(key) => {
			named = key.map(|(column, value)| (column.name, value))
			match current!(effects, schema, shown, key) {
				Err(Missing) => page(404, frame, Admin.label(shown), View.problem_page(frame, "No such row", "${Admin.label(shown)} has no row whose ${described(shown, named)}: it may have been deleted."))
				Err(Failed(why)) => page(400, frame, Admin.label(shown), View.problem_page(frame, "Not done", why))
				Ok(now) => {
					columns = Admin.visible(shown).keep_if(|column| Admin.writable(shown, Edit, column, Editing) and Form.asks(form, "v.${column.name}"))
					changed = columns.keep_oks(
						|column| {
							submitted = Form.get(form, "v.${column.name}")
							kind = Admin.widget(shown, column)
							was = now.find_first(|each| each.name == column.name) ?? { name: column.name, value: "", null: Bool.True }
							if Widget.same(kind, { value: was.value, null: was.null }, submitted) {
								Err(Same)
							} else {
								match Widget.param(kind, column, submitted, Editing) {
									Value(param) => Ok((column, param))
									Default => Err(Same)
								}
							}
						},
					)
					back = View.row_link(frame.mount, shown.table.name, named)
					if changed.is_empty() {
						redirect("${back}&done=unchanged")
					} else {
						statement = Sql.update(schema, shown.table, changed, key)
						match (effects.run!)(statement.sql, statement.params) {
							Ok(0) => page(404, frame, Admin.label(shown), View.problem_page(frame, "No such row", "${Admin.label(shown)} has no row whose ${described(shown, named)}: it may have been deleted."))
							Ok(_) => redirect("${back}&done=saved")
							Err(DbErr(why)) => {
								# The form again: what was sent, and the rest as it is.
								given = sent(form, columns)
								values = now.map(|each| given.find_first(|other| other.name == each.name) ?? each)
								row_page!(422, frame, schema, shown, effects, { key: named, values, problem: why, notice: "" })
							}
						}
					}
				}
			}
		}
	}

delete! : List(Form.Field), View.Frame, Str, Admin.Shown, AdminPage.Effects => { status : U16, headers : List({ name : Str, value : Str }), body : [Text(Str), ..others] }
delete! = |form, frame, schema, shown, effects|
	if !shown.options.delete {
		page(403, frame, Admin.label(shown), View.problem_page(frame, "Not done", "Rows of ${Admin.label(shown)} aren't deleted here."))
	} else {
		match Listing.key(shown, form) {
			Err(NoKey) => page(400, frame, "Not done", View.problem_page(frame, "Not done", "The form doesn't say which row of ${Admin.label(shown)} it deletes."))
			Ok(key) => {
				named = key.map(|(column, value)| (column.name, value))
				statement = Sql.delete(schema, shown.table, key)
				match (effects.run!)(statement.sql, statement.params) {
					Ok(0) => page(404, frame, Admin.label(shown), View.problem_page(frame, "No such row", "${Admin.label(shown)} has no row whose ${described(shown, named)}: it may have been deleted already."))
					Ok(_) => redirect(Form.link(frame.mount, [("table", shown.table.name), ("done", "deleted")]))
					Err(DbErr(why)) => page(409, frame, "Not deleted", View.delete_page(frame, { shown, key: named, title: View.row_title(shown, named, []), problem: why }))
				}
			}
		}
	}

## `id 7`, `book id 1, tag new`: a row's key, said.
described : Admin.Shown, List((Str, Str)) -> Str
described = |shown, key| Str.join_with(key.map(|(column, value)| "${Admin.column_label(shown, column).with_ascii_lowercased()} is ${value}"), " and ")

expect AdminPage.hex([0, 15, 16, 255]) == "000f10ff"
expect AdminPage.is_token("0123456789abcdef0123456789abcdef") and !AdminPage.is_token("0123456789ABCDEF0123456789abcdef") and !AdminPage.is_token("abc")
expect AdminPage.same_origin([{ name: "host", value: "example.com" }, { name: "origin", value: "https://example.com" }])
expect !AdminPage.same_origin([{ name: "host", value: "example.com" }, { name: "origin", value: "https://evil.example" }])
expect !AdminPage.same_origin([{ name: "host", value: "example.com" }, { name: "origin", value: "null" }])
expect AdminPage.same_origin([{ name: "host", value: "example.com" }])
expect cookie([{ name: "cookie", value: "a=1; rocx_admin_csrf=abc; b=2" }], "rocx_admin_csrf") == "abc"
expect cookie([{ name: "cookie", value: "a=1" }], "rocx_admin_csrf") == ""
expect cookie_path("/admin/db") == "/admin/db" and cookie_path("/a;b c") == "/abc" and cookie_path("x") == "/"
