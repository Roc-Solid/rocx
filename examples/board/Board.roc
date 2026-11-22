import Rank

## A board as a page shows it, and the rules both halves share: the order cards show in, and
## where a move puts one. The server reads a board from its database (`Store`) and answers it at
## `GET /b/<board>`; the page reads it there, and applies the moves still on their way to it
## (`moved`), so a dragged card shows where it was dropped before the server has it.
##
## Ids are strings here (SQLite's integers, as text): they are keys on the page and in JSON.
Board := [].{

	## Someone on the board: the name and colour they picked when they joined.
	Person : { id : Str, name : Str, color : Str }

	## A column, ordered among the others by its rank.
	Column : { id : Str, name : Str, rank : Str }

	## A line of a card's checklist.
	Item : { id : Str, text : Str, done : Bool }

	## A card. `assignee` is a person's id or `""`; `due` a date (`2026-11-30`) or `""`; `labels`
	## the keys of `Board.labels`.
	Card : {
		id : Str,
		column : Str,
		rank : Str,
		title : Str,
		description : Str,
		labels : List(Str),
		assignee : Str,
		due : Str,
		archived : Bool,
		checklist : List(Board.Item),
	}

	## Who is editing a card (`Lease.roc`): no one else may change it meanwhile.
	Lease : { card : Str, person : Str, name : Str }

	## A board in the front page's list: how many cards it shows.
	Summary : { slug : Str, name : Str, cards : I64 }

	## A whole board, as `GET /b/<board>` answers it: who is asking (`me`), and the server's date
	## (`today`: the browser has no clock yet), which says which cards are overdue.
	Data : {
		slug : Str,
		name : Str,
		today : Str,
		me : Board.Person,
		columns : List(Board.Column),
		cards : List(Board.Card),
		people : List(Board.Person),
		leases : List(Board.Lease),
	}

	## What the board's channel says when something changed: who did it, and what (`""`: nothing
	## worth saying, a lease taken or let go). Every page on the board reads it again.
	News : { by : Str, did : Str }

	## A card put in `column`, just before the card `before` (`""`: at the column's end).
	Move : { card : Str, column : Str, before : Str }

	## What an open card's form sends: its title, description, assignee (a person's id, or `""`) and
	## due date (`2026-11-30`, or `""`).
	Fields : { title : Str, description : Str, assignee : Str, due : Str }

	## A label put on a card (`on`: `"true"`), or taken off (`"false"`): form fields are text.
	LabelSet : { label : Str, on : Str }

	## A checklist line ticked (`done`: `"true"`), or not (`"false"`).
	Tick : { item : Str, done : Str }

	## How often an open card renews its edit lease (`Lease.roc`, which keeps it for 30 s).
	renew_every : U64
	renew_every = 10_000

	## Where a card is, for a move's arithmetic: what the server reads of every card in a column.
	Spot : { id : Str, column : Str, rank : Str }

	## A label a card may have: its key, which picks its colour (`data-label` in the styles), and
	## its name.
	Label : { key : Str, name : Str }

	## The labels there are.
	labels : List(Board.Label)
	labels = [
		{ key: "bug", name: "Bug" },
		{ key: "feature", name: "Feature" },
		{ key: "design", name: "Design" },
		{ key: "ops", name: "Ops" },
		{ key: "research", name: "Research" },
		{ key: "urgent", name: "Urgent" },
	]

	## The colours someone may pick when they join: their avatar's and their cursor's.
	colors : List(Str)
	colors = ["#d9480f", "#c2255c", "#9c36b5", "#3b5bdb", "#0b7285", "#2b8a3e", "#5c940d", "#e67700"]

	## The columns, left to right.
	columns_in_order : List(Board.Column) -> List(Board.Column)
	columns_in_order = |columns| columns.sort_with(|a, b| by_rank(a.rank, a.id, b.rank, b.id))

	## The cards a column shows, top to bottom: its own, not archived, by rank (ties, which the
	## server never makes, by id).
	column_cards : List(Board.Card), Str -> List(Board.Card)
	column_cards = |cards, column| cards.keep_if(|card| card.column == column and !card.archived).sort_with(|a, b| by_rank(a.rank, a.id, b.rank, b.id))

	## The rank a move gives its card: between the card just before `move.before` in the column and
	## `move.before`, or after the column's last card when `before` is `""` or not there (moved away
	## meanwhile). `spots` are every card of the board, archived ones too, so the new rank is
	## different from every other rank in the column.
	rank_for : List(Board.Spot), Board.Move -> Str
	rank_for = |spots, move| {
		others = spots.keep_if(|each| each.column == move.column and each.id != move.card).sort_with(|a, b| by_rank(a.rank, a.id, b.rank, b.id))
		match others.find_first_index(|each| each.id == move.before) {
			Ok(index) => {
				low = if (index == 0) "" else (others.get(index - 1) ?? { id: "", column: "", rank: "" }).rank
				high = (others.get(index) ?? { id: "", column: "", rank: "" }).rank
				Rank.between(low, high)
			}
			Err(_) => Rank.between((others.last() ?? { id: "", column: "", rank: "" }).rank, "")
		}
	}

	## Whether a move would change anything: a card dropped just above the card it is already
	## above (or at the end of the column it ends) stays.
	changes : List(Board.Card), Board.Move -> Bool
	changes = |cards, move|
		if move.card == move.before {
			Bool.False
		} else {
			match cards.find_first(|card| card.id == move.card) {
				Ok(card) if card.column == move.column => {
					shown = Board.column_cards(cards, move.column)
					next =
						match shown.find_first_index(|each| each.id == move.card) {
							Ok(index) => (shown.get(index + 1) ?? { ..card, id: "" }).id
							Err(_) => ""
						}
					next != move.before
				}
				Ok(_) => Bool.True
				Err(_) => Bool.False
			}
		}

	## The board with a move applied: what the server will have once it takes it. Applying it
	## twice is applying it once (the card's neighbours are the same the second time), as a page
	## must: a move still on its way is applied to the board read again after another's.
	moved : Board.Data, Board.Move -> Board.Data
	moved = |board, move|
		if board.columns.any(|column| column.id == move.column) and board.cards.any(|card| card.id == move.card) {
			rank = Board.rank_for(board.cards.map(Board.spot), move)
			{ ..board, cards: board.cards.map(|card| if (card.id == move.card) { ..card, column: move.column, rank } else card) }
		} else {
			board
		}

	## The card with an open card's form applied: what the server will have once it has it.
	saved : Board.Card, Board.Fields -> Board.Card
	saved = |card, fields| { ..card, title: fields.title.trim(), description: fields.description.trim(), assignee: fields.assignee, due: fields.due.trim() }

	## The card with a label put on or taken off (twice is once).
	labelled : Board.Card, Board.LabelSet -> Board.Card
	labelled = |card, set| {
		without = card.labels.drop_if(|label| label == set.label)
		{ ..card, labels: if (set.on == "true") without.append(set.label) else without }
	}

	## The card with a checklist line ticked or not (twice is once).
	ticked : Board.Card, Board.Tick -> Board.Card
	ticked = |card, tick| { ..card, checklist: card.checklist.map(|item| if (item.id == tick.item) { ..item, done: tick.done == "true" } else item) }

	## A card up or down its column by one, as its card's buttons move it (for a keyboard, or a
	## touch screen that drags nothing): the move, or `Stays` at the column's top or end.
	nudged : List(Board.Card), Str, [Up, Down] -> Try(Board.Move, [Stays])
	nudged = |cards, id, way|
		match cards.find_first(|card| card.id == id) {
			Err(_) => Err(Stays)
			Ok(card) => {
				shown = Board.column_cards(cards, card.column)
				index = shown.find_first_index(|each| each.id == id) ?? 0
				id_at = |at| (shown.get(at) ?? { ..card, id: "" }).id
				match way {
					Up => if (index == 0) Err(Stays) else Ok({ card: id, column: card.column, before: id_at(index - 1) })
					Down => if (index + 1 >= shown.len()) Err(Stays) else Ok({ card: id, column: card.column, before: id_at(index + 2) })
				}
			}
		}

	## A card the board shows, by id: not one archived.
	shown_card : List(Board.Card), Str -> Try(Board.Card, [NotFound])
	shown_card = |cards, id|
		match cards.find_first(|card| card.id == id and !card.archived) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## The name of a label, by its key.
	label_name : Str -> Str
	label_name = |key| (Board.labels.find_first(|label| label.key == key) ?? { key, name: key }).name

	## A card, by id.
	card_of : List(Board.Card), Str -> Try(Board.Card, [NotFound])
	card_of = |cards, id|
		match cards.find_first(|card| card.id == id) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## Where a card is.
	spot : Board.Card -> Board.Spot
	spot = |card| { id: card.id, column: card.column, rank: card.rank }

	## How far a checklist is: done, of how many.
	progress : List(Board.Item) -> { done : U64, total : U64 }
	progress = |items| { done: items.count_if(|item| item.done), total: items.len() }

	## A card's title, trimmed, or why it won't do.
	title_of : Str -> Try(Str, Str)
	title_of = |text| sized(text, 200, "A card needs a title.", "A title is 200 characters at most.")

	## A column's name, trimmed, or why it won't do.
	column_name_of : Str -> Try(Str, Str)
	column_name_of = |text| sized(text, 60, "A column needs a name.", "A column's name is 60 characters at most.")

	## A board's name, trimmed, or why it won't do.
	board_name_of : Str -> Try(Str, Str)
	board_name_of = |text| sized(text, 60, "A board needs a name.", "A board's name is 60 characters at most.")

	## Someone's name, trimmed, or why it won't do.
	person_name_of : Str -> Try(Str, Str)
	person_name_of = |text| sized(text, 40, "Pick a name.", "A name is 40 characters at most.")

	## A line of a checklist, trimmed, or why it won't do.
	item_of : Str -> Try(Str, Str)
	item_of = |text| sized(text, 200, "A checklist line needs words.", "A checklist line is 200 characters at most.")

	## A card's description, or why it won't do.
	description_of : Str -> Try(Str, Str)
	description_of = |text| if (text.to_utf8().len() > 4000) Err("A description is 4,000 characters at most.") else Ok(text.trim())

	## A due date as a date field sends it (`2026-11-30`), or `""` for none; or why it won't do.
	due_of : Str -> Try(Str, Str)
	due_of = |text| {
		trimmed = text.trim()
		bytes = trimmed.to_utf8()
		digits_at = |indexes| indexes.all(|index| bytes.get(index).map_ok(|byte| byte >= '0' and byte <= '9') ?? Bool.False)
		if trimmed.is_empty() {
			Ok("")
		} else if bytes.len() == 10 and digits_at([0, 1, 2, 3, 5, 6, 8, 9]) and bytes.get(4) == Ok('-') and bytes.get(7) == Ok('-') {
			Ok(trimmed)
		} else {
			Err("A due date looks like 2026-11-30.")
		}
	}

	## A board's address, from its name: lowercase letters and digits, with dashes between words
	## (`"Q3 Launch!"` is `"q3-launch"`); `""` when the name has neither.
	slug_of : Str -> Str
	slug_of = |name| {
		words = Str.from_utf8_lossy(name.with_ascii_lowercased().to_utf8().map(|byte| if ((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9')) byte else ' '))
		Str.join_with(words.split_on(" ").drop_if(|word| word.is_empty()), "-")
	}

	## Where to go after joining: a path on this site (`then`), or the front page. Never another
	## site (`//elsewhere.example`), which would make the joining page a way to send people there.
	after_join : Str -> Str
	after_join = |then| if (then.starts_with("/") and !then.starts_with("//") and !then.starts_with("/\\")) then else "/"

	## The card a page's query opens (`?card=12`), or `""`.
	card_in_query : Str -> Str
	card_in_query = |query|
		match query.split_on("&").find_first(|pair| pair.starts_with("card=")) {
			Ok(pair) => {
				id = pair.drop_prefix("card=")
				if (I64.from_str(id).is_ok()) id else ""
			}
			Err(_) => ""
		}

	## What a page's presence says about the card it has open: `card-12`, or `""` for none. Others'
	## pages show who has which card open from it.
	status_of : Str -> Str
	status_of = |card| if (card.is_empty()) "" else "card-${card}"

	## Whether a card is late: past its due date (`""`: none), and not in the board's last column,
	## where finished work goes.
	is_overdue : Board.Data, Board.Card -> Bool
	is_overdue = |board, card| {
		finished = Board.columns_in_order(board.columns).last().map_ok(|column| column.id == card.column) ?? Bool.False
		!finished and !card.due.is_empty() and Rank.compare(card.due, board.today) == Before
	}

	## An open card's form, checked as the server checks it: the fields, trimmed, or why not. The
	## page checks first, so a title left empty is said at once rather than sent.
	fields_of : Board.Fields -> Try(Board.Fields, Str)
	fields_of = |fields|
		match (Board.title_of(fields.title), Board.description_of(fields.description), Board.due_of(fields.due)) {
			(Ok(title), Ok(description), Ok(due)) => Ok({ title, description, assignee: fields.assignee, due })
			(Err(why), _, _) | (_, Err(why), _) | (_, _, Err(why)) => Err(why)
		}

	## A due date, short: `"2026-11-30"` is `"30 Nov"`.
	short_date : Str -> Str
	short_date = |date|
		match date.split_on("-") {
			[_, month, day] => {
				name = months.get((U64.from_str(month) ?? 1) - 1) ?? ""
				"${(U64.from_str(day) ?? 0).to_str()} ${name}"
			}
			_ => date
		}

	## Someone, by id (a card's assignee, a lease's holder).
	person : List(Board.Person), Str -> Try(Board.Person, [NotFound])
	person = |people, id|
		match people.find_first(|each| each.id == id) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}

	## Who is editing a card, if anyone.
	lease_of : List(Board.Lease), Str -> Try(Board.Lease, [NotFound])
	lease_of = |leases, card|
		match leases.find_first(|lease| lease.card == card) {
			Ok(found) => Ok(found)
			Err(_) => Err(NotFound)
		}
}

## The months, as a due date shows them.
months : List(Str)
months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

## `text`, trimmed, unless it is empty or longer than `most` bytes.
sized : Str, U64, Str, Str -> Try(Str, Str)
sized = |text, most, empty, long| {
	trimmed = text.trim()
	if trimmed.is_empty() {
		Err(empty)
	} else if trimmed.to_utf8().len() > most {
		Err(long)
	} else {
		Ok(trimmed)
	}
}

## Rank first, then id: the order the server's queries use too (`order by rank, id`).
by_rank : Str, Str, Str, Str -> [Before, Same, After]
by_rank = |rank_a, id_a, rank_b, id_b|
	match Rank.compare(rank_a, rank_b) {
		Same => compare_ids(id_a, id_b)
		other => other
	}

## Ids are numbers written out: a shorter one is smaller.
compare_ids : Str, Str -> [Before, Same, After]
compare_ids = |a, b| {
	length_a = a.to_utf8().len()
	length_b = b.to_utf8().len()
	if length_a < length_b {
		Before
	} else if length_a > length_b {
		After
	} else {
		Rank.compare(a, b)
	}
}

card : Str, Str, Str -> Board.Card
card = |id, column, rank| { id, column, rank, title: "Card ${id}", description: "", labels: [], assignee: "", due: "", archived: Bool.False, checklist: [] }

sample : Board.Data
sample = {
	slug: "launch",
	name: "Launch",
	today: "2026-11-22",
	me: { id: "1", name: "Ada", color: "#c2255c" },
	columns: [{ id: "1", name: "To do", rank: "i" }, { id: "2", name: "Doing", rank: "r" }],
	cards: [card("10", "1", "c"), card("11", "1", "i"), card("12", "1", "r"), card("20", "2", "i"), { ..card("13", "1", "m"), archived: Bool.True }],
	people: [],
	leases: [],
}

ids : Board.Data, Str -> List(Str)
ids = |board, column| Board.column_cards(board.cards, column).map(|each| each.id)

# A column shows its cards by rank, without the archived ones.
expect ids(sample, "1") == ["10", "11", "12"]

# To another column, at its top, between two cards, at its end.
expect ids(Board.moved(sample, { card: "11", column: "2", before: "20" }), "2") == ["11", "20"]
expect ids(Board.moved(sample, { card: "12", column: "1", before: "11" }), "1") == ["10", "12", "11"]
expect ids(Board.moved(sample, { card: "10", column: "1", before: "" }), "1") == ["11", "12", "10"]
expect ids(Board.moved(sample, { card: "10", column: "2", before: "" }), "2") == ["20", "10"]

# A card that went before one that has since gone ends up at the column's end.
expect ids(Board.moved(sample, { card: "10", column: "1", before: "99" }), "1") == ["11", "12", "10"]

# Twice is once.
expect {
	move = { card: "12", column: "1", before: "10" }
	Board.moved(Board.moved(sample, move), move) == Board.moved(sample, move)
}

# A card or a column that isn't there changes nothing.
expect Board.moved(sample, { card: "77", column: "1", before: "" }) == sample
expect Board.moved(sample, { card: "10", column: "9", before: "" }) == sample

# Between 11 (`i`) and 12 (`r`) is the archived 13 (`m`): a card put before 12 goes between 13 and
# 12, so it never shares a rank with a card in the column, archived or not.
expect Board.rank_for(sample.cards.map(Board.spot), { card: "20", column: "1", before: "12" }) == "o"

# A move that changes nothing: before the card it is already above, at the end it is already at,
# or before itself.
expect !Board.changes(sample.cards, { card: "10", column: "1", before: "11" })
expect !Board.changes(sample.cards, { card: "12", column: "1", before: "" })
expect !Board.changes(sample.cards, { card: "12", column: "1", before: "12" })
expect Board.changes(sample.cards, { card: "12", column: "1", before: "10" })
expect Board.changes(sample.cards, { card: "12", column: "2", before: "" })

expect Board.progress([{ id: "1", text: "a", done: Bool.True }, { id: "2", text: "b", done: Bool.False }]) == { done: 1, total: 2 }
expect compare_ids("9", "10") == Before

expect Board.slug_of("Q3 Launch!") == "q3-launch"
expect Board.slug_of("  Acme   Rocket  ") == "acme-rocket"
expect Board.slug_of("!!!") == ""
expect Board.after_join("/b/launch?card=3") == "/b/launch?card=3"
expect Board.after_join("//elsewhere.example") == "/"
expect Board.after_join("https://elsewhere.example") == "/"
expect Board.card_in_query("card=12") == "12"
expect Board.card_in_query("x=1&card=7") == "7"
expect Board.card_in_query("card=evil") == ""
expect Board.short_date("2026-11-30") == "30 Nov"
expect Board.short_date("2027-01-05") == "5 Jan"
expect Board.due_of("2026-11-30") == Ok("2026-11-30")
expect Board.due_of("") == Ok("")
expect Board.due_of("30/11/2026").is_err()
expect Board.title_of("  Fix it  ") == Ok("Fix it")
expect Board.title_of("   ").is_err()

# Up and down a column, by one; not past its ends.
expect Board.nudged(sample.cards, "11", Up) == Ok({ card: "11", column: "1", before: "10" })
expect Board.nudged(sample.cards, "11", Down) == Ok({ card: "11", column: "1", before: "" })
expect Board.nudged(sample.cards, "10", Down) == Ok({ card: "10", column: "1", before: "12" })
expect Board.nudged(sample.cards, "10", Up) == Err(Stays)
expect Board.nudged(sample.cards, "12", Down) == Err(Stays)
expect ids(Board.moved(sample, Board.nudged(sample.cards, "10", Down) ?? { card: "", column: "", before: "" }), "1") == ["11", "10", "12"]

expect Board.labelled(Board.labelled(card("1", "1", "i"), { label: "bug", on: "true" }), { label: "bug", on: "true" }).labels == ["bug"]
expect Board.labelled({ ..card("1", "1", "i"), labels: ["bug", "ops"] }, { label: "bug", on: "false" }).labels == ["ops"]

# Late: due before today, unless it is in the last column (done).
expect Board.is_overdue(sample, { ..card("1", "1", "i"), due: "2026-11-21" })
expect !Board.is_overdue(sample, { ..card("1", "1", "i"), due: "2026-11-22" })
expect !Board.is_overdue(sample, { ..card("1", "1", "i"), due: "" })
expect !Board.is_overdue(sample, { ..card("1", "2", "i"), due: "2026-11-21" })
expect Board.fields_of({ title: " Ship it ", description: "", assignee: "", due: "" }) == Ok({ title: "Ship it", description: "", assignee: "", due: "" })
expect Board.fields_of({ title: "", description: "", assignee: "", due: "" }) == Err("A card needs a title.")
expect Board.fields_of({ title: "Ship", description: "", assignee: "", due: "soon" }) == Err("A due date looks like 2026-11-30.")
