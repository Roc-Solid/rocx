import pf.Db
import pf.Env
import pf.Kv
import pf.Log
import pf.Plugin
import Flag
import Flags

## Feature flags while the server runs: the environment it is in, and the rules set in place of
## the code's (overrides), kept in the server's memory (`Kv`, D-043) under `guard:flags`. An admin
## page lists the flags and sets or resets their rules here. Without more, a restart forgets the
## overrides, and the code's rules stand again; an app with a database that lists the plugin
## (`FlagStore.plugin({})`, D-057) keeps them in it too, and they outlive a restart.
##
##     on = FlagStore.is_on!(Features.new_checkout, { user: context.user, groups: [] })
##     FlagStore.set!("new_checkout", Flags.rollout(50))?
FlagStore := [].{

	## The overrides kept in the app's database as well as in memory, so a restart (a deploy)
	## keeps them: a plugin (D-033) with a table of its own, `guard_flags` (migration
	## `guard/0001_flags`, for Postgres and for SQLite and Turso), a row a flag. At start it reads
	## the table into memory; after that `set!` and `reset!` write the flag's row and change memory
	## in one transaction. It needs a database: an app without one doesn't list it, and its
	## overrides are in memory alone.
	##
	##     program = App.program({ …, plugins: [FlagStore.plugin({})] })
	plugin : {} -> Plugin.Value(context)
	plugin = |{}| {
		name: "guard",
		migrations: [{ name: "0001_flags", sql: flags_table("timestamptz not null default now()"), on: Postgres }, { name: "0001_flags", sql: flags_table("text not null default current_timestamp"), on: Sqlite }],
		starts: [|_context| loaded!({})],
		needs: [Database],
	}

	## The environment the server runs in, for `Flag.in_env`: `APP_ENV`, if it is set; or else
	## `dev`, when the server was started with `--dev`; or else `production`.
	env! : {} => Str
	env! = |{}|
		match Env.var!("APP_ENV") {
			Ok(value) => if (value.trim().is_empty()) default_env!({}) else value.trim()
			Err(NotFound) => default_env!({})
		}

	## The overrides set. None, and a warning in the log, when they can't be read: the code's rules
	## stand.
	overrides! : {} => List(Flags.Override)
	overrides! = |{}| {
		found : Try(List(Flags.Override), [NotFound, BadValue(Str)])
		found = Kv.get!(kept)
		match found {
			Ok(overrides) => overrides
			Err(NotFound) => []
			Err(BadValue(why)) => {
				Log.warn!("guard: the flags' overrides couldn't be read; the code's rules stand", { error: why })
				[]
			}
		}
	}

	## What flags are decided with now: the environment, and the overrides.
	settings! : {} => Flags.Settings
	settings! = |{}| { env: FlagStore.env!({}), overrides: FlagStore.overrides!({}) }

	## Whether `who` has `flag` on now.
	is_on! : Flag, Flags.Who => Bool
	is_on! = |flag, who| Flags.is_on(flag, FlagStore.settings!({}), who)

	## Each of `flags`, decided for `who` now: what a page sends the browser (a GET endpoint's
	## answer, which the page reads as it renders), so the browser shows what the server rendered.
	values! : List(Flag), Flags.Who => Flags.Values
	values! = |flags, who| Flags.values(flags, FlagStore.settings!({}), who)

	## Each of `flags` as an admin page shows it (`Flags.describe`): the rule in force, the code's,
	## and whether an override replaces it.
	describe! : List(Flag) => List({ name : Str, about : Str, rule : Flag.Rule, code : Flag.Rule, overridden : Bool })
	describe! = |flags| Flags.describe(flags, FlagStore.settings!({}))

	## Sets `rule` for the flag called `name`, in place of the code's, until `reset!`.
	set! : Str, Flag.Rule => Try({}, [FlagErr(Str)])
	set! = |name, rule| changed!(Set({ name, rule }))

	## Drops the override for the flag called `name`: the code's rule again.
	reset! : Str => Try({}, [FlagErr(Str)])
	reset! = |name| changed!(Reset(name))
}

default_env! : {} => Str
default_env! = |{}| if (Env.dev!({})) "dev" else "production"

## Where the overrides are kept (`Kv`).
kept : Str
kept = "guard:flags"

## A change to the overrides.
Change : [Set(Flags.Override), Reset(Str)]

## Applies `change` to the overrides: with the plugin, the flag's row and memory in one
## transaction; else memory alone.
changed! : Change => Try({}, [FlagErr(Str)])
changed! = |change|
	if Plugin.kept!(in_database).is_ok() {
		(name, rule) =
			match change {
				Set(given) => (given.name, Json.to_str(given.rule))
				Reset(given) => (given, "")
			}
		# The row first: every change to a flag writes its row (a reset too, its rule ""), which
		# holds that row until the commit (Postgres's lock, SQLite's write lock, or Turso's conflict,
		# which runs the body again), so changes to one flag reach memory in the order they reach the
		# table. Memory changes before the commit for that reason; a commit that fails then leaves
		# memory ahead of the table until a restart, and says so.
		done = Db.transaction!(
			|{}| {
				_ = Db.run!("insert into guard_flags (name, rule) values ($1, $2) on conflict (name) do update set rule = excluded.rule, updated_at = current_timestamp", [Text(name), Text(rule)])?
				match in_memory!(change) {
					Ok({}) => Ok({})
					Err(FlagErr(why)) => Err(FlagErr(why))
				}
			},
		)
		match done {
			Ok({}) => Ok({})
			Err(FlagErr(why)) => Err(FlagErr(why))
			Err(DbErr(why)) => {
				Log.warn!("guard: a flag's override couldn't be kept in the database", { flag: name, error: why })
				Err(FlagErr("the flags' overrides couldn't be kept: ${why}"))
			}
		}
	} else {
		in_memory!(change)
	}

## Where the plugin's start says the overrides are kept in the database too (`Plugin.keep!`).
in_database : Str
in_database = "guard:flags-kept"

## The plugin's table: a flag's name, its override as JSON ("" once reset: the code's rule), and
## when it last changed.
flags_table : Str -> Str
flags_table = |updated| "create table guard_flags (name text primary key, rule text not null, updated_at ${updated})"

## The plugin's start: the overrides the database keeps, in memory (those it can't read are left
## out, with a warning), and the store told to keep each change there too.
loaded! : {} => Try({}, Str)
loaded! = |{}| {
	found : Try(List({ name : Str, rule : Str }), [DbErr(Str), BadRow(Str)])
	found = Db.all!("select name, rule from guard_flags where rule <> '' order by name", [])
	match found {
		Ok(rows) => {
			var $overrides = []
			for row in rows {
				parsed : Try(Flag.Rule, [InvalidJson(Str)])
				parsed = Json.parse(row.rule)
				$overrides =
					match parsed {
						Ok(rule) => $overrides.append({ name: row.name, rule })
						Err(InvalidJson(why)) => {
							Log.warn!("guard: a flag's override in the database can't be read; the code's rule stands", { flag: row.name, error: why })
							$overrides
						}
					}
			}
			overrides : List(Flags.Override)
			overrides = $overrides
			Kv.set!(kept, overrides, { ttl_ms: 0 })
			Plugin.keep!(in_database, "yes")
			Ok({})
		}
		Err(DbErr(why)) => Err("the flags' overrides: ${why}")
		Err(BadRow(why)) => Err("the flags' overrides: ${why}")
	}
}

## Applies `change` to the overrides in memory, reading them again when another request changed
## them first.
in_memory! : Change => Try({}, [FlagErr(Str)])
in_memory! = |change| {
	var $left = 50
	while $left > 0 {
		was : Try(List(Flags.Override), [NotFound, BadValue(Str)])
		was = Kv.get!(kept)
		overrides = was ?? []
		next =
			match change {
				Set(given) => Flags.set(overrides, given.name, given.rule)
				Reset(name) => Flags.reset(overrides, name)
			}
		stored =
			match was {
				Ok(_) => Kv.swap!(kept, overrides, next, {})
				Err(_) => Kv.add!(kept, next, {}).map_err(|_| Changed)
			}
		if stored.is_ok() {
			return Ok({})
		}
		$left = $left - 1
	}
	Err(FlagErr("the overrides changed under each of 50 tries"))
}
