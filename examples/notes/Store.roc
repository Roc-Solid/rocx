import pf.Db
import pf.Endpoint
import pf.Log
import Note
import Token

## Notes in Postgres: every query the app makes, in one place (the tables are
## migrations/0001_notes.sql). Every query about notes or tokens names the person they are for, in
## its `where`: a note that isn't theirs is a note that isn't there, so one person's id in another's
## request finds nothing, whichever way it came (a page, the API, MCP).
##
## Ids are `bigint`s in Postgres and text everywhere else: queries read them as `id::text`, and a
## parameter sent as text is read by Postgres as the type its place wants. Dates are ISO 8601, UTC.
Store := [].{

	## Someone who signs in: their id, their address, and their session epoch (Session.roc).
	Person : { id : Str, email : Str, epoch : U64 }

	## What a query can fail with: no such row, or the database's own error.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## What a route answers for a query that failed: a 404 for a row that isn't there (or isn't
	## yours), a 500 for the rest, its details in the server's log rather than in the answer.
	refused! : Store.Problem => Endpoint.Refusal
	refused! = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) => {
				Log.error!("notes: a query failed", { error: why })
				Status(500, "Your notes couldn't be read or saved just now; try again.")
			}
			BadRow(why) => {
				Log.error!("notes: a row didn't read", { error: why })
				Status(500, "Your notes couldn't be read or saved just now; try again.")
			}
		}

	# ---- People ----

	## Someone, by id (what a session cookie says).
	person! : Str => Try(Store.Person, Store.Problem)
	person! = |id| {
		found : Try(List(Store.Person), [DbErr(Str), BadRow(Str)])
		found = Db.all!("select id::text as id, email, session_epoch as epoch from people where id = $1", [Text(numbered(id)?)])
		first(found?)
	}

	## Someone, by address: the one there is, or someone new. Signing in with a link is how anyone
	## joins, so a new person's notebook starts with a note of welcome (`welcome`).
	person_for! : Str => Try(Store.Person, Store.Problem)
	person_for! = |email| {
		made : Try(List(Store.Person), [DbErr(Str), BadRow(Str)])
		made = Db.all!(
			"insert into people (email) values ($1) on conflict ((lower(email))) do nothing returning id::text as id, email, session_epoch as epoch",
			[Text(email)],
		)
		match made? {
			[person] => {
				_ = Store.create!(person.id, welcome)?
				Ok(person)
			}
			_ => {
				found : Try(List(Store.Person), [DbErr(Str), BadRow(Str)])
				found = Db.all!("select id::text as id, email, session_epoch as epoch from people where lower(email) = lower($1)", [Text(email)])
				first(found?)
			}
		}
	}

	## Every session of someone's refused from now on: their epoch goes up, and the cookies signed
	## with the old one no longer pass (Session.roc). The new epoch.
	sign_out_everywhere! : Str => Try(U64, Store.Problem)
	sign_out_everywhere! = |person| {
		raised : Try(List({ epoch : U64 }), [DbErr(Str), BadRow(Str)])
		raised = Db.all!("update people set session_epoch = session_epoch + 1 where id = $1 returning session_epoch as epoch", [Text(numbered(person)?)])
		first(raised?).map_ok(|row| row.epoch)
	}

	# ---- Notes ----

	## Someone's notes, pinned ones first, then the latest changed: the archived ones, or the rest;
	## with `tags`, only notes with every one of them.
	notes! : Str, { archived : Bool, tags : List(Str) } => Try(List(Note.Summary), Store.Problem)
	notes! = |person, { archived, tags }| {
		rows : Try(List(Listed), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select ${listed} left(plain, 220) as marked from notes where person_id = $1 and archived = $2 and tags @> $3 order by pinned desc, updated_at desc, id desc limit 200",
			[Text(numbered(person)?), Bool(archived), Db.array(tags.map(|tag| Text(tag)))],
		)
		Ok(rows?.map(summary))
	}

	## Someone's notes that match `query`, best first, archived ones too: its words found by
	## Postgres's full-text search (`websearch_to_tsquery`, so `"two words"`, `or` and `-not` work as
	## they do in a search engine), the title's words weighing more than the body's, each snippet
	## with the matches marked (`ts_headline`). Tags alone list the notes with them.
	search! : Str, Note.Query => Try(List(Note.Summary), Store.Problem)
	search! = |person, query|
		if query.words.is_empty() {
			Store.notes!(person, { archived: Bool.False, tags: query.tags })
		} else {
			rows : Try(List(Listed), [DbErr(Str), BadRow(Str)])
			rows = Db.all!(
				"select ${listed} ts_headline('english', plain, q, $4) as marked from notes, websearch_to_tsquery('english', $2) as q where person_id = $1 and search @@ q and tags @> $3 order by ts_rank(search, q) desc, updated_at desc limit 50",
				[Text(numbered(person)?), Text(query.words), Db.array(query.tags.map(|tag| Text(tag))), Text(headline)],
			)
			Ok(rows?.map(summary))
		}

	## Someone's tags, and how many of their notes (not archived) have each: the sidebar's.
	tags! : Str => Try(List(Note.Tagged), Store.Problem)
	tags! = |person| {
		rows : Try(List(Note.Tagged), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select tag as name, count(*) as count from notes, unnest(tags) as tag where person_id = $1 and not archived group by tag order by count(*) desc, tag limit 50",
			[Text(numbered(person)?)],
		)
		Ok(rows?)
	}

	## One of someone's notes, whole.
	note! : Str, Str => Try(Note.Full, Store.Problem)
	note! = |person, id| one!("select ${full} from notes where person_id = $1 and id = $2", [Text(numbered(person)?), Text(numbered(id)?)])

	## A new note.
	create! : Str, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Store.Problem)
	create! = |person, note|
		one!(
			"insert into notes (person_id, title, body, tags) values ($1, $2, $3, $4) returning ${full}",
			[Text(numbered(person)?), Text(note.title), Text(note.body), Db.array(note.tags.map(|tag| Text(tag)))],
		)

	## A note's title, body and tags, changed.
	update! : Str, Str, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Store.Problem)
	update! = |person, id, note|
		one!(
			"update notes set title = $3, body = $4, tags = $5, updated_at = now() where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Text(note.title), Text(note.body), Db.array(note.tags.map(|tag| Text(tag)))],
		)

	## `text` added at a note's end, a blank line before it. One statement, so two agents appending
	## to one note at once each add theirs: neither reads the body, then writes it back over the
	## other's.
	append! : Str, Str, Str => Try(Note.Full, Store.Problem)
	append! = |person, id, text|
		one!(
			"update notes set body = case when btrim(body, E' \\n\\t\\r') = '' then $3 else rtrim(body, E' \\n\\t\\r') || E'\\n\\n' || $3 end, updated_at = now() where person_id = $1 and id = $2 and length(body) + length($3) + 2 <= 100000 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Text(text)],
		)

	## A note's tags, all of them, as given.
	set_tags! : Str, Str, List(Str) => Try(Note.Full, Store.Problem)
	set_tags! = |person, id, tags|
		one!(
			"update notes set tags = $3, updated_at = now() where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Db.array(tags.map(|tag| Text(tag)))],
		)

	## A note archived (out of the way, kept, still found by search), or brought back.
	set_archived! : Str, Str, Bool => Try(Note.Full, Store.Problem)
	set_archived! = |person, id, archived|
		one!(
			"update notes set archived = $3, pinned = pinned and not $3, updated_at = now() where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Bool(archived)],
		)

	## A note pinned to the top of the list, or let go. Its place in time doesn't change.
	set_pinned! : Str, Str, Bool => Try(Note.Full, Store.Problem)
	set_pinned! = |person, id, pinned|
		one!(
			"update notes set pinned = $3 where person_id = $1 and id = $2 and not archived returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Bool(pinned)],
		)

	## A note gone for good.
	delete! : Str, Str => Try({}, Store.Problem)
	delete! = |person, id| {
		gone = Db.run!("delete from notes where person_id = $1 and id = $2", [Text(numbered(person)?), Text(numbered(id)?)])?
		if (gone == 0) Err(NotFound) else Ok({})
	}

	# ---- Personal access tokens ----

	## Someone's tokens, oldest first.
	tokens! : Str => Try(List(Token.Listed), Store.Problem)
	tokens! = |person| {
		rows : Try(List(Token.Listed), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select ${token_columns} from tokens where person_id = $1 order by created_at, id", [Text(numbered(person)?)])
		Ok(rows?)
	}

	## A new token, by its hash (the token itself is never kept), its hint and its name.
	add_token! : Str, { name : Str, hash : Str, hint : Str, read_only : Bool } => Try(Token.Listed, Store.Problem)
	add_token! = |person, token| {
		rows : Try(List(Token.Listed), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"insert into tokens (person_id, name, hash, hint, read_only) values ($1, $2, $3, $4, $5) returning ${token_columns}",
			[Text(numbered(person)?), Text(token.name), Text(token.hash), Text(token.hint), Bool(token.read_only)],
		)
		first(rows?)
	}

	## One of someone's tokens revoked: gone, so the next request with it is refused.
	revoke_token! : Str, Str => Try({}, Store.Problem)
	revoke_token! = |person, id| {
		gone = Db.run!("delete from tokens where person_id = $1 and id = $2", [Text(numbered(person)?), Text(numbered(id)?)])?
		if (gone == 0) Err(NotFound) else Ok({})
	}

	## Whose token has `hash`, and whether it may write; its last use noted (at most once a minute,
	## so an agent's busy minute writes one row, not one a call).
	bearer! : Str => Try({ person : Store.Person, token : Str, read_only : Bool }, Store.Problem)
	bearer! = |hash| {
		rows : Try(List({ id : Str, email : Str, epoch : U64, token : Str, read_only : Bool }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"with used as (update tokens set last_used_at = now() where hash = $1 and (last_used_at is null or last_used_at < now() - interval '1 minute')) select p.id::text as id, p.email, p.session_epoch as epoch, t.id::text as token, t.read_only from tokens t join people p on p.id = t.person_id where t.hash = $1",
			[Text(hash)],
		)
		first(rows?).map_ok(|row| { person: { id: row.id, email: row.email, epoch: row.epoch }, token: row.token, read_only: row.read_only })
	}
}

## A note in a list, as a query reads it: `marked` is its snippet, matches marked.
Listed : { id : Str, title : Str, tags : List(Str), pinned : Bool, archived : Bool, updated : Str, marked : Str }

## The columns a list of notes reads, before its snippet.
listed : Str
listed = "id::text as id, title, array_to_json(tags) as tags, pinned, archived, ${iso("updated_at")} as updated,"

## The columns a whole note reads.
full : Str
full = "id::text as id, title, body, array_to_json(tags) as tags, pinned, archived, ${iso("created_at")} as created, ${iso("updated_at")} as updated"

## The columns a token reads.
token_columns : Str
token_columns = "id::text as id, name, hint, read_only, ${iso("created_at")} as created, coalesce(${iso("last_used_at")}, '') as last_used"

## A timestamp column as ISO 8601, in UTC.
iso : Str -> Str
iso = |column| "to_char(${column} at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"

## `ts_headline`'s options: up to two pieces of about twenty words around the matches, each match
## between the marks `Note.pieces` reads.
headline : Str
headline = "StartSel=${Note.start_mark}, StopSel=${Note.stop_mark}, MaxWords=24, MinWords=10, MaxFragments=2, FragmentDelimiter=\" … \""

summary : Listed -> Note.Summary
summary = |row| { id: row.id, title: row.title, tags: row.tags, pinned: row.pinned, archived: row.archived, updated: row.updated, snippet: Note.pieces(row.marked) }

## An id as Postgres will read it: digits, or no such row (so `abc` is a 404, not a query that
## fails).
numbered : Str -> Try(Str, [NotFound])
numbered = |id| if (I64.from_str(id).is_ok()) Ok(id) else Err(NotFound)

## The one row a query found, or `NotFound`.
first : List(a) -> Try(a, [NotFound])
first = |rows|
	match rows {
		[row, ..] => Ok(row)
		[] => Err(NotFound)
	}

## The one note a query returns.
one! : Str, List(Db.Value) => Try(Note.Full, Store.Problem)
one! = |sql, params| {
	rows : Try(List(Note.Full), [DbErr(Str), BadRow(Str)])
	rows = Db.all!(sql, params)
	first(rows?)
}

## The note every new notebook starts with.
welcome : { title : Str, body : Str, tags : List(Str) }
welcome = {
	title: "Welcome to Notes",
	tags: ["notes"],
	body: Str.join_with(
		[
			"Notes are written in **Markdown**: `#` for a heading, `-` for a list, `- [ ]` for a task,",
			"`**bold**` and `_italics_`. The editor shows how a note looks as you write it.",
			"",
			"- [x] Sign in",
			"- [ ] Write a note, and give it a tag or two",
			"- [ ] Pin the ones you open every day",
			"- [ ] Make a token in **Settings**, and let an AI client read and write your notes over MCP",
			"",
			"Search finds words in titles and bodies: `\"exact phrase\"`, `-without`, and `#tag` to look",
			"only at a tag's notes.",
		],
		"\n",
	),
}
