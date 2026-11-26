import pf.Db
import pf.Endpoint
import pf.Log
import pf.Time
import Note
import Token

## Notes in SQLite, a file beside the server: every query the app makes, in one place (the
## tables are migrations/0001_notes.sql). Every query about notes or tokens names the person they
## are for, in its `where`: a note that isn't theirs is a note that isn't there, so one person's id
## in another's request finds nothing, whichever way it came (a page, the API, MCP).
##
## Ids are integers in SQLite and text everywhere else: queries read them as `cast(id as text)`,
## and a parameter sent as text is compared with an integer column as the number it spells (the
## column's affinity). A moment is kept as milliseconds since the epoch, given from Roc
## (`Time.now_millis!`), and read as ISO 8601, UTC. A note's tags are a JSON list.
Store := [].{

	## Someone who signs in: their id (what packages/auth's sessions keep), and their address.
	Person : { id : Str, email : Str }

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

	## Someone, by id (what a session holds).
	person! : Str => Try(Store.Person, Store.Problem)
	person! = |id| Db.one!("select cast(id as text) as id, email from people where id = $1", [Text(numbered(id)?)])

	## Someone, by address: the one there is, or someone new. Signing in with a link is how anyone
	## joins, so a new person's notebook starts with a note of welcome (`welcome`).
	person_for! : Str => Try(Store.Person, Store.Problem)
	person_for! = |email| {
		made : Try(List(Store.Person), [DbErr(Str), BadRow(Str)])
		made = Db.all!(
			"insert into people (email) values ($1) on conflict (lower(email)) do nothing returning cast(id as text) as id, email",
			[Text(email)],
		)
		match made? {
			[person] => {
				_ = Store.create!(person.id, welcome)?
				Ok(person)
			}
			_ => {
				found : Try(Store.Person, Store.Problem)
				found = Db.one!("select cast(id as text) as id, email from people where lower(email) = lower($1)", [Text(email)])
				found
			}
		}
	}

	# ---- Notes ----

	## Someone's notes, pinned ones first, then the latest changed: the archived ones, or the rest;
	## with `tags`, only notes with every one of them.
	notes! : Str, { archived : Bool, tags : List(Str) } => Try(List(Note.Summary), Store.Problem)
	notes! = |person, { archived, tags }| {
		rows : Try(List(Listed), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select ${listed} substr(notes.plain, 1, 220) as marked from notes where notes.person_id = $1 and notes.archived = $2 and ${tagged("$3")} order by notes.pinned desc, notes.updated_at desc, notes.id desc limit 200",
			[Text(numbered(person)?), Bool(archived), Text(Json.to_str(tags))],
		)
		Ok(rows?.map(summary))
	}

	## Someone's notes that match `query`, best first, archived ones too: its words found by
	## SQLite's full-text search (FTS5, `note_words`: a note's title and what its body reads as,
	## each word by its stem, so "rehearsals" finds "rehearsal"), read as a search engine reads them
	## (`Store.matching`: `"two words"`, `or` and `-not`), the title's words weighing more than the
	## body's (`bm25`), each snippet with the matches marked (`snippet`). Tags alone list the notes
	## with them.
	search! : Str, Note.Query => Try(List(Note.Summary), Store.Problem)
	search! = |person, query|
		if query.words.is_empty() {
			Store.notes!(person, { archived: Bool.False, tags: query.tags })
		} else {
			wanted = Store.matching(query.words)
			if wanted.is_empty() {
				Ok([])
			} else {
				rows : Try(List(Listed), [DbErr(Str), BadRow(Str)])
				rows = Db.all!(
					"select ${listed} snippet(note_words, 1, $4, $5, '…', 24) as marked from note_words join notes on notes.id = note_words.rowid where note_words match $2 and notes.person_id = $1 and ${tagged("$3")} order by bm25(note_words, 10.0, 1.0), notes.updated_at desc limit 50",
					[Text(numbered(person)?), Text(wanted), Text(Json.to_str(query.tags)), Text(Note.start_mark), Text(Note.stop_mark)],
				)
				Ok(rows?.map(summary))
			}
		}

	## A search box's words as an FTS5 query, read as a search engine reads them: each word must be
	## there (`"launch"`), words in quotes are a phrase (`"stretch and folds"`), `or` between them is
	## either, and `-word` (or `-"a phrase"`) is without it. Only letters and digits make words: the
	## rest, which FTS5 would read as its own syntax, splits them, and the words of one (`launch-pad`)
	## are a phrase. `""` when nothing is left to look for (only words without: FTS5 can't ask for
	## everything but).
	matching : Str -> Str
	matching = |text| {
		groups = terms(text.to_utf8()).fold(
			[[]],
			|sofar, term|
				match term {
					Either => sofar.append([])
					Wanted(_) | Without(_) => sofar.drop_last(1).append((sofar.last() ?? []).append(term))
				},
		)
		asked = groups.keep_oks(
			|group| {
				wanted = group.keep_oks(
					|term|
						match term {
							Wanted(found) => Ok(phrase(found))
							_ => Err(None)
						},
				)
				unwanted = group.keep_oks(
					|term|
						match term {
							Without(found) => Ok(" NOT ${phrase(found)}")
							_ => Err(None)
						},
				)
				if (wanted.is_empty()) Err(None) else Ok("${Str.join_with(wanted, " ")}${Str.join_with(unwanted, "")}")
			},
		)
		match asked {
			[one] => one
			_ => Str.join_with(asked.map(|group| "(${group})"), " OR ")
		}
	}

	## Someone's tags, and how many of their notes (not archived) have each: the sidebar's.
	tags! : Str => Try(List(Note.Tagged), Store.Problem)
	tags! = |person| {
		rows : Try(List(Note.Tagged), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select tag.value as name, count(*) as count from notes, json_each(notes.tags) as tag where notes.person_id = $1 and not notes.archived group by tag.value order by count(*) desc, tag.value limit 50",
			[Text(numbered(person)?)],
		)
		Ok(rows?)
	}

	## One of someone's notes, whole.
	note! : Str, Str => Try(Note.Full, Store.Problem)
	note! = |person, id| one!("select ${full} from notes where person_id = $1 and id = $2", [Text(numbered(person)?), Text(numbered(id)?)])

	## A new note, and what its body reads as (`Note.plain`).
	create! : Str, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Store.Problem)
	create! = |person, note|
		one!(
			"insert into notes (person_id, title, body, plain, tags) values ($1, $2, $3, $4, $5) returning ${full}",
			[Text(numbered(person)?), Text(note.title), Text(note.body), Text(Note.plain(note.body)), Text(Json.to_str(note.tags))],
		)

	## A note's title, body and tags, changed, and what its body reads as.
	update! : Str, Str, { title : Str, body : Str, tags : List(Str) } => Try(Note.Full, Store.Problem)
	update! = |person, id, note|
		one!(
			"update notes set title = $3, body = $4, plain = $5, tags = $6, updated_at = $7 where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Text(note.title), Text(note.body), Text(Note.plain(note.body)), Text(Json.to_str(note.tags)), Int(now!({}))],
		)

	## `text` added at a note's end, a blank line before it (`Note.appended`). The body is read and
	## written in one transaction, which holds SQLite's write lock from its start, so two agents
	## appending to one note at once take turns and each adds theirs: neither writes over the
	## other's.
	append! : Str, Str, Str => Try(Note.Full, Store.Problem)
	append! = |person, id, text|
		Db.transaction!(
			|{}| {
				was : { body : Str }
				was = Db.one!("select body from notes where person_id = $1 and id = $2", [Text(numbered(person)?), Text(numbered(id)?)])?
				body = Note.appended(was.body, text)
				one!(
					"update notes set body = $3, plain = $4, updated_at = $5 where person_id = $1 and id = $2 and length($3) <= 100000 returning ${full}",
					[Text(numbered(person)?), Text(numbered(id)?), Text(body), Text(Note.plain(body)), Int(now!({}))],
				)
			},
		)

	## A note's tags, all of them, as given.
	set_tags! : Str, Str, List(Str) => Try(Note.Full, Store.Problem)
	set_tags! = |person, id, tags|
		one!(
			"update notes set tags = $3, updated_at = $4 where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Text(Json.to_str(tags)), Int(now!({}))],
		)

	## A note archived (out of the way, kept, still found by search), or brought back.
	set_archived! : Str, Str, Bool => Try(Note.Full, Store.Problem)
	set_archived! = |person, id, archived|
		one!(
			"update notes set archived = $3, pinned = pinned and not $3, updated_at = $4 where person_id = $1 and id = $2 returning ${full}",
			[Text(numbered(person)?), Text(numbered(id)?), Bool(archived), Int(now!({}))],
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
		Db.one!(
			"insert into tokens (person_id, name, hash, hint, read_only) values ($1, $2, $3, $4, $5) returning ${token_columns}",
			[Text(numbered(person)?), Text(token.name), Text(token.hash), Text(token.hint), Bool(token.read_only)],
		)
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
		_ = Db.run!("update tokens set last_used_at = $2 where hash = $1 and (last_used_at is null or last_used_at < $2 - 60000)", [Text(hash), Int(now!({}))])?
		row : { id : Str, email : Str, token : Str, read_only : Bool }
		row = Db.one!(
			"select cast(p.id as text) as id, p.email, cast(t.id as text) as token, t.read_only from tokens t join people p on p.id = t.person_id where t.hash = $1",
			[Text(hash)],
		)?
		Ok({ person: { id: row.id, email: row.email }, token: row.token, read_only: row.read_only })
	}
}

## A note in a list, as a query reads it: `marked` is its snippet, matches marked.
Listed : { id : Str, title : Str, tags : List(Str), pinned : Bool, archived : Bool, updated : Str, marked : Str }

## The columns a list of notes reads, before its snippet (named with their table, as a search
## reads `note_words` beside it, which has a `title` too).
listed : Str
listed = "cast(notes.id as text) as id, notes.title as title, notes.tags as tags, notes.pinned as pinned, notes.archived as archived, ${iso("notes.updated_at")} as updated,"

## The columns a whole note reads.
full : Str
full = "cast(id as text) as id, title, body, tags, pinned, archived, ${iso("created_at")} as created, ${iso("updated_at")} as updated"

## The columns a token reads.
token_columns : Str
token_columns = "cast(id as text) as id, name, hint, read_only, ${iso("created_at")} as created, coalesce(${iso("last_used_at")}, '') as last_used"

## A moment (milliseconds since the epoch) as ISO 8601, in UTC, to the second.
iso : Str -> Str
iso = |column| "strftime('%Y-%m-%dT%H:%M:%SZ', ${column} / 1000, 'unixepoch')"

## Whether a note has every tag in the JSON list `param` (a statement's `$3`).
tagged : Str -> Str
tagged = |param| "not exists (select 1 from json_each(${param}) as wanted where wanted.value not in (select value from json_each(notes.tags)))"

## Now, in milliseconds since the epoch.
now! : {} => I64
now! = |{}| Time.now_millis!({}).to_i64_wrap()

## What a search asks for, a term at a time: words that must be there, words that mustn't, and
## `or` between two.
Term : [Wanted(List(Str)), Without(List(Str)), Either]

## The terms of a search box's text: a quoted phrase, or a run of anything but spaces and quotes,
## each read as `words` reads it; `-` before one is without it, and `or` alone is either.
terms : List(U8) -> List(Term)
terms = |bytes| {
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		without = byte == '-' and $at + 1 < bytes.len()
		from = if (without) $at + 1 else $at
		if byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' {
			$at = $at + 1
		} else if bytes.get(from) == Ok('"') {
			close = quote_at(bytes, from + 1)
			found = words(bytes.sublist({ start: from + 1, len: close - from - 1 }))
			$out = if (found.is_empty()) $out else $out.append(if (without) Without(found) else Wanted(found))
			$at = close + 1
		} else {
			end = run_end(bytes, from)
			chunk = bytes.sublist({ start: from, len: end - from })
			found = words(chunk)
			$out =
				if !without and found == ["or"] and chunk.len() == 2 {
					$out.append(Either)
				} else if found.is_empty() {
					$out
				} else {
					$out.append(if (without) Without(found) else Wanted(found))
				}
			$at = end
		}
	}
	$out
}

## Where the quote closing a phrase is, from `from` on, or the end.
quote_at : List(U8), U64 -> U64
quote_at = |bytes, from| {
	var $at = from
	while $at < bytes.len() and bytes.get($at) != Ok('"') {
		$at = $at + 1
	}
	$at
}

## Where a run of anything but spaces and quotes, from `from` on, ends.
run_end : List(U8), U64 -> U64
run_end = |bytes, from| {
	var $at = from
	while $at < bytes.len() and !([' ', '\t', '\n', '\r', '"'].contains(bytes.get($at) ?? ' ')) {
		$at = $at + 1
	}
	$at
}

## The words in `bytes`: letters and digits (any script's), lower case; the rest splits them.
words : List(U8) -> List(Str)
words = |bytes| {
	kept = bytes.map(|byte| if (byte >= 128 or (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')) byte else ' ')
	Str.from_utf8_lossy(kept).split_on(" ").keep_if(|word| !word.is_empty()).map(|word| word.with_ascii_lowercased())
}

## Words as an FTS5 phrase: each in that order (one word is a phrase of one).
phrase : List(Str) -> Str
phrase = |each| "\"${Str.join_with(each, " ")}\""

summary : Listed -> Note.Summary
summary = |row| { id: row.id, title: row.title, tags: row.tags, pinned: row.pinned, archived: row.archived, updated: row.updated, snippet: Note.pieces(row.marked) }

## An id as SQLite will compare it: digits, or no such row (so `abc` is a 404, not a query
## that finds nothing as text).
numbered : Str -> Try(Str, [NotFound])
numbered = |id| if (I64.from_str(id).is_ok()) Ok(id) else Err(NotFound)

## The one note a query returns (`Db.one!`, its row a `Note.Full`).
one! : Str, List(Db.Value) => Try(Note.Full, Store.Problem)
one! = |sql, params| Db.one!(sql, params)

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

expect Store.matching("launch") == "\"launch\""
expect Store.matching("Launch -rehearsal") == "\"launch\" NOT \"rehearsal\""
expect Store.matching("\"stretch and folds\" bread") == "\"stretch and folds\" \"bread\""
expect Store.matching("sourdough OR loaf") == "(\"sourdough\") OR (\"loaf\")"
expect Store.matching("a:* & b^ -\"c d\" or") == "\"a\" \"b\" NOT \"c d\""
expect Store.matching("launch-pad") == "\"launch pad\""
expect Store.matching("-alone") == ""
expect Store.matching("żurek") == "\"żurek\""
expect Store.matching("  ") == ""
