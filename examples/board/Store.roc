import pf.Db
import pf.Endpoint
import pf.Log
import pf.Time
import Board
import Rank

## Board in SQLite, a file beside the server: every query the app makes, in one place. The
## tables are migrations/0001_board.sql; the route files call these and say what each answer means
## to whoever asked. A row comes back as the record its query is annotated with, by column name
## (`Db.all!`).
##
## Ids are integers in SQLite and strings everywhere else: a query reads them as
## `cast(id as text)`, and a parameter sent as text is compared with an integer column, or written
## to one, as the number it spells (the column's affinity). A moment is milliseconds since the
## epoch, given from Roc (`Time.now_millis!`).
Store := [].{

	## What a query can fail with: no such row, or the database's own error.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## A card's title and its column's name: what the news says moved.
	Named : { title : Str, column : Str }

	## What a route answers for a query that failed: a 404 for a row that isn't there, a 500 for the
	## rest, its details in the server's log rather than in the answer.
	refused! : Store.Problem => Endpoint.Refusal
	refused! = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) => {
				Log.error!("board: a query failed", { error: why })
				Status(500, "The board couldn't be saved or read just now; try again.")
			}
			BadRow(why) => {
				Log.error!("board: a row didn't read", { error: why })
				Status(500, "The board couldn't be saved or read just now; try again.")
			}
		}

	# ---- People ----

	## Someone, by id (the cookie the middleware reads).
	person! : Str => Try(Board.Person, Store.Problem)
	person! = |id|
		if I64.from_str(id).is_err() {
			Err(NotFound)
		} else {
			found : Try(List(Board.Person), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select cast(id as text) as id, name, color from people where id = $1", [Text(id)])
			first(found?)
		}

	## Everyone, by name: the board's assignees and the joining page's quick picks.
	people! : {} => Try(List(Board.Person), [DbErr(Str), BadRow(Str)])
	people! = |{}| Db.all!("select cast(id as text) as id, name, color from people order by lower(name)", [])

	## Joins as `name`, with `color`: someone new, or the one already called that (whatever its
	## case), whose colour becomes `color`. No passwords: picking a name is being them.
	join! : Str, Str => Try(Board.Person, Store.Problem)
	join! = |name, color| {
		found : Try(List(Board.Person), [DbErr(Str), BadRow(Str)])
		found = Db.all!(
			"insert into people (name, color) values ($1, $2) on conflict (lower(name)) do update set color = excluded.color returning cast(id as text) as id, name, color",
			[Text(name), Text(color)],
		)
		first(found?)
	}

	# ---- Boards ----

	## Every board, for the front page.
	boards! : {} => Try(List(Board.Summary), [DbErr(Str), BadRow(Str)])
	boards! = |{}|
		Db.all!(
			"select b.slug, b.name, (select count(*) from cards c where c.board_id = b.id and not c.archived) as cards from boards b order by lower(b.name)",
			[],
		)

	## A new board called `name` at `slug`, with three columns to start with: in one transaction, so
	## a board is never there without them.
	create_board! : Str, Str => Try({}, [Taken, DbErr(Str)])
	create_board! = |slug, name|
		Db.transaction!(
			|{}| {
				made = Db.run!("insert into boards (slug, name) values ($1, $2) on conflict (slug) do nothing", [Text(slug), Text(name)])?
				if made == 0 {
					Err(Taken)
				} else {
					_ = Db.run!(
						"insert into columns (board_id, name, rank) with c (name, rank) as (values ('To do', 'i'), ('Doing', 'r'), ('Done', 'w')) select b.id, c.name, c.rank from boards b, c where b.slug = $1",
						[Text(slug)],
					)?
					Ok({})
				}
			},
		)

	## A whole board, but who is asking and who is editing what: those aren't the database's to say.
	board! : Str => Try({ slug : Str, name : Str, today : Str, columns : List(Board.Column), cards : List(Board.Card), people : List(Board.Person) }, Store.Problem)
	board! = |slug| {
		boards : Try(List({ id : Str, name : Str, today : Str }), [DbErr(Str), BadRow(Str)])
		boards = Db.all!("select cast(id as text) as id, name, date('now') as today from boards where slug = $1", [Text(slug)])
		board = first(boards?)?
		columns : Try(List(Board.Column), [DbErr(Str), BadRow(Str)])
		columns = Db.all!("select cast(id as text) as id, name, rank from columns where board_id = $1 order by rank, id", [Text(board.id)])
		cards : Try(List({ id : Str, column : Str, rank : Str, title : Str, description : Str, labels : List(Str), assignee : Str, due : Str, archived : Bool }), [DbErr(Str), BadRow(Str)])
		cards = Db.all!(
			"select cast(id as text) as id, cast(column_id as text) as \"column\", rank, title, description, labels, coalesce(cast(assignee_id as text), '') as assignee, coalesce(due, '') as due, archived from cards where board_id = $1 order by rank, id",
			[Text(board.id)],
		)
		items : Try(List({ id : Str, card : Str, text : Str, done : Bool }), [DbErr(Str), BadRow(Str)])
		items = Db.all!(
			"select cast(i.id as text) as id, cast(i.card_id as text) as card, i.text, i.done from checklist_items i join cards c on c.id = i.card_id where c.board_id = $1 order by i.id",
			[Text(board.id)],
		)
		all_items = items?
		Ok({
			slug,
			name: board.name,
			today: board.today,
			columns: columns?,
			cards: cards?.map(
				|card| {
					checklist = all_items.keep_if(|item| item.card == card.id).map(|item| { id: item.id, text: item.text, done: item.done })
					{ id: card.id, column: card.column, rank: card.rank, title: card.title, description: card.description, labels: card.labels, assignee: card.assignee, due: card.due, archived: card.archived, checklist }
				},
			),
			people: Store.people!({})?,
		})
	}

	## Whether there is a board at `slug`: what its channel checks.
	board_exists! : Str => Bool
	board_exists! = |slug| {
		found : Try(List({ id : Str }), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select cast(id as text) as id from boards where slug = $1", [Text(slug)])
		match found {
			Ok([_, ..]) => Bool.True
			_ => Bool.False
		}
	}

	# ---- Columns ----

	## A new column called `name`, after the board's last.
	add_column! : Str, Str => Try({}, Store.Problem)
	add_column! = |slug, name|
		Db.transaction!(
			|{}| {
				# The transaction holds the write lock from its start: two columns added at once take
				# turns for the last rank.
				boards : Try(List({ id : Str }), [DbErr(Str), BadRow(Str)])
				boards = Db.all!("select cast(id as text) as id from boards where slug = $1", [Text(slug)])
				board = first(boards?)?
				last : Try(List({ rank : Str }), [DbErr(Str), BadRow(Str)])
				last = Db.all!("select rank from columns where board_id = $1 order by rank desc limit 1", [Text(board.id)])
				rank = Rank.between((last?.first() ?? { rank: "" }).rank, "")
				_ = Db.run!("insert into columns (board_id, name, rank) values ($1, $2, $3)", [Text(board.id), Text(name), Text(rank)])?
				Ok({})
			},
		)

	## Column `column` of the board, called `name` now. Its old name, for the news: read, then
	## written, in one transaction (SQLite's `returning` has the new row only).
	rename_column! : Str, Str, Str => Try(Str, Store.Problem)
	rename_column! = |slug, column, name|
		Db.transaction!(
			|{}| {
				olds : Try(List({ old : Str }), [DbErr(Str), BadRow(Str)])
				olds = Db.all!("select name as old from columns where id = $2 and board_id = (select id from boards where slug = $1)", [Text(slug), Text(column)])
				row = first(olds?)?
				_ = Db.run!("update columns set name = $2 where id = $1", [Text(column), Text(name)])?
				Ok(row.old)
			},
		)

	# ---- Cards ----

	## A new card called `title` at the end of column `column`.
	add_card! : Str, Str, Str => Try(Str, Store.Problem)
	add_card! = |slug, column, title| {
		if I64.from_str(column).is_err() {
			Err(NotFound)
		} else {
			Db.transaction!(
				|{}| {
					place = Store.lock_column!(slug, column)?
					rank = Board.rank_for(Store.spots!(column)?, { card: "", column, before: "" })
					_ = Db.run!(
						"insert into cards (board_id, column_id, rank, title) values ($1, $2, $3, $4)",
						[Text(place.board), Text(column), Text(rank), Text(title)],
					)?
					Ok(place.name)
				},
			)
		}
	}

	## Moves a card (`Board.Move`): its new rank is worked out here, in a transaction that holds the
	## column it goes to, so two cards dropped into one gap at once each get a rank of their own.
	## The card's title and its new column's name, for the news.
	move! : Str, Board.Move => Try(Store.Named, Store.Problem)
	move! = |slug, move|
		if I64.from_str(move.card).is_err() or I64.from_str(move.column).is_err() {
			Err(NotFound)
		} else {
			Db.transaction!(
				|{}| {
					place = Store.lock_column!(slug, move.column)?
					card = Store.card!(slug, move.card)?
					rank = Board.rank_for(Store.spots!(move.column)?, move)
					_ = Db.run!("update cards set column_id = $2, rank = $3, updated_at = $4 where id = $1", [Text(move.card), Text(move.column), Text(rank), Int(now!({}))])?
					Ok({ title: card.title, column: place.name })
				},
			)
		}

	## A card of the board's, by id: its title, whether it is archived.
	card! : Str, Str => Try({ id : Str, title : Str, archived : Bool }, Store.Problem)
	card! = |slug, card|
		if I64.from_str(card).is_err() {
			Err(NotFound)
		} else {
			found : Try(List({ id : Str, title : Str, archived : Bool }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select cast(id as text) as id, title, archived from cards where id = $2 and board_id = (select id from boards where slug = $1)", [Text(slug), Text(card)])
			first(found?)
		}

	## What a card says, written: its title, description, assignee (`""`: no one) and due date
	## (`""`: none).
	save_card! : Str, Str, { title : Str, description : Str, assignee : Str, due : Str } => Try({}, Store.Problem)
	save_card! = |slug, card, fields| {
		changed = Db.run!(
			"update cards set title = $3, description = $4, assignee_id = nullif($5, ''), due = nullif($6, ''), updated_at = $7 where id = $2 and board_id = (select id from boards where slug = $1)",
			[Text(slug), Text(card), Text(fields.title), Text(fields.description), Text(fields.assignee), Text(fields.due), Int(now!({}))],
		)?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	## The card with label `label`, or without it (`on`): its labels are a JSON list, added to at its
	## end, or kept but for `label`, in their order.
	set_label! : Str, Str, Str, Bool => Try({}, Store.Problem)
	set_label! = |slug, card, label, on| {
		changed = Db.run!(
			"update cards set labels = case when $4 then (case when exists (select 1 from json_each(labels) where value = $3) then labels else json_insert(labels, '$[#]', $3) end) else (select json_group_array(value order by key) from json_each(labels) where value <> $3) end, updated_at = $5 where id = $2 and board_id = (select id from boards where slug = $1)",
			[Text(slug), Text(card), Text(label), Bool(on), Int(now!({}))],
		)?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	## The card archived (off the board, kept, with its place), or back.
	set_archived! : Str, Str, Bool => Try({}, Store.Problem)
	set_archived! = |slug, card, archived| {
		changed = Db.run!(
			"update cards set archived = $3, updated_at = $4 where id = $2 and board_id = (select id from boards where slug = $1)",
			[Text(slug), Text(card), Bool(archived), Int(now!({}))],
		)?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	## The card gone for good, its checklist with it.
	delete_card! : Str, Str => Try({}, Store.Problem)
	delete_card! = |slug, card| {
		changed = Db.run!("delete from cards where id = $2 and board_id = (select id from boards where slug = $1)", [Text(slug), Text(card)])?
		if (changed == 0) Err(NotFound) else Ok({})
	}

	# ---- Checklists ----

	## A new line at the end of the card's checklist.
	add_item! : Str, Str, Str => Try({}, Store.Problem)
	add_item! = |slug, card, text| {
		_ = Store.card!(slug, card)?
		_ = Db.run!("insert into checklist_items (card_id, text) values ($1, $2)", [Text(card), Text(text)])?
		Ok({})
	}

	## A line of the card's checklist ticked, or not.
	tick_item! : Str, Str, Str, Bool => Try({}, Store.Problem)
	tick_item! = |slug, card, item, done| {
		_ = Store.card!(slug, card)?
		if I64.from_str(item).is_err() {
			Err(NotFound)
		} else {
			changed = Db.run!("update checklist_items set done = $3 where id = $2 and card_id = $1", [Text(card), Text(item), Bool(done)])?
			if (changed == 0) Err(NotFound) else Ok({})
		}
	}

	## A line of the card's checklist gone.
	delete_item! : Str, Str, Str => Try({}, Store.Problem)
	delete_item! = |slug, card, item| {
		_ = Store.card!(slug, card)?
		if I64.from_str(item).is_err() {
			Err(NotFound)
		} else {
			changed = Db.run!("delete from checklist_items where id = $2 and card_id = $1", [Text(card), Text(item)])?
			if (changed == 0) Err(NotFound) else Ok({})
		}
	}

	# ---- Inside a transaction ----

	## Column `column` of the board, read in a transaction, which holds the write lock from its start:
	## the moves and new cards into it take turns. Its board's id and its name.
	lock_column! : Str, Str => Try({ board : Str, name : Str }, Store.Problem)
	lock_column! = |slug, column| {
		found : Try(List({ board : Str, name : Str }), [DbErr(Str), BadRow(Str)])
		found = Db.all!(
			"select cast(c.board_id as text) as board, c.name from columns c join boards b on b.id = c.board_id where b.slug = $1 and c.id = $2",
			[Text(slug), Text(column)],
		)
		first(found?)
	}

	## Every card in a column, archived ones too, where they are: what a new rank must differ from.
	spots! : Str => Try(List(Board.Spot), [DbErr(Str), BadRow(Str)])
	spots! = |column| Db.all!("select cast(id as text) as id, cast(column_id as text) as \"column\", rank from cards where column_id = $1", [Text(column)])
}

## Now, in milliseconds since the epoch: what a card's `updated_at` is set to.
now! : {} => I64
now! = |{}| Time.now_millis!({}).to_i64_wrap()

## The one row a query found, or `NotFound`.
first : List(row) -> Try(row, [NotFound, ..others])
first = |rows|
	match rows.first() {
		Ok(row) => Ok(row)
		Err(_) => Err(NotFound)
	}
