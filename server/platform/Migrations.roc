import Db
import Log

## The schema, applied when the server starts: the platform's own tables first (the actors'
## state), then the plugins' (each recorded as `<plugin>/<name>`), then the app's
## (`program.migrations`). Each is applied once, in order, in a
## transaction of its own, and recorded in `rocx_migrations`; on Postgres, two servers starting at
## once take turns (an advisory lock), so none is applied twice (on SQLite and Turso, a transaction
## holds the write lock from its start).
Migrations := [].{

	## The platform's own, for the database it has (D-045): each says which it is for.
	own : [Postgres, Sqlite] -> List({ name : Str, sql : Str })
	own = |flavor|
		all_own
			.keep_if(
				|migration|
					match (migration.on, flavor) {
						(Any, _) => Bool.True
						(Postgres, Postgres) => Bool.True
						(Sqlite, Sqlite) => Bool.True
						_ => Bool.False
					},
			)
			.map(|migration| { name: migration.name, sql: migration.sql })

	## Applies each of `migrations` the database hasn't seen, in order; the first that fails stops
	## the rest, and says why.
	apply! : List({ name : Str, sql : Str }) => Try({}, Str)
	apply! = |migrations|
		match Db.script!("create table if not exists rocx_migrations (name text primary key, applied_at timestamptz not null default current_timestamp)") {
			Err(DbErr(why)) => Err("migrations: ${why}")
			Ok({}) => {
				var $applied = Ok({})
				for migration in migrations {
					$applied =
						match $applied {
							Ok({}) => apply_one!(migration)
							Err(why) => Err(why)
						}
				}
				$applied
			}
		}
}

all_own : List({ name : Str, sql : Str, on : [Any, Postgres, Sqlite] })
all_own = [
	{
		# The jobs queue was the platform's here too, until jobs were a package (D-034): its table
		# is the jobs plugin's now (`jobs/0001_jobs`), which a database migrated before has.
		name: "rocx/0001 jobs and actors",
		on: Postgres,
		sql: Str.join_with(
			[
				"create table rocx_actors (",
				"    kind text not null,",
				"    key text not null,",
				"    state text not null,",
				"    updated_at timestamptz not null default now(),",
				"    primary key (kind, key)",
				");",
			],
			"\n",
		),
	},
	{
		# Brings a jobs queue made by the platform's first migration up to date; a database
		# without one gets it from the jobs plugin, as it is now.
		name: "rocx/0002 job keys, cancelling, the outbox",
		on: Postgres,
		sql: Str.join_with(
			[
				"do $$",
				"begin",
				"    if to_regclass('rocx_jobs') is not null then",
				# A key is one job's while it is pending (queued or running), not forever: the
				# next may have it once that one is done.
				"        alter table rocx_jobs drop constraint if exists rocx_jobs_unique_key_key;",
				"        create unique index if not exists rocx_jobs_pending_key on rocx_jobs (unique_key) where state in ('queued', 'running');",
				"        alter table rocx_jobs drop constraint if exists rocx_jobs_state_check;",
				"        alter table rocx_jobs add constraint rocx_jobs_state_check check (state in ('queued', 'running', 'done', 'failed', 'canceled'));",
				"        create index if not exists rocx_jobs_listed on rocx_jobs (state, kind, id);",
				"    end if;",
				"end $$;",
			],
			"\n",
		),
	},
	{
		# The dev mailbox keeps its mail in the server's memory (`Kv`), database or not (D-028):
		# the table it had goes, with the mail of past runs.
		name: "rocx/0003 the dev mailbox in memory",
		on: Postgres,
		sql: "drop table if exists rocx_outbox",
	},
	{
		# Actors' timers, kept until the turn that handled each has ended (D-057): its number (random,
		# the app's), whom it tells what, and when (milliseconds since the Unix epoch).
		name: "rocx/0004 actor timers",
		on: Postgres,
		sql: Str.join_with(
			[
				"create table rocx_actor_timers (",
				"    id bigint primary key,",
				"    kind text not null,",
				"    key text not null,",
				"    message text not null,",
				"    at_ms bigint not null,",
				"    created_at timestamptz not null default now()",
				");",
			],
			"\n",
		),
	},
	{
		# The actors' state, on SQLite: Postgres's 0001, without the jobs that were there once.
		name: "rocx/0001 jobs and actors",
		on: Sqlite,
		sql: Str.join_with(
			[
				"create table rocx_actors (",
				"    kind text not null,",
				"    key text not null,",
				"    state text not null,",
				"    updated_at text not null default current_timestamp,",
				"    primary key (kind, key)",
				");",
			],
			"\n",
		),
	},
	{
		# Postgres's 0004, on SQLite (and Turso).
		name: "rocx/0002 actor timers",
		on: Sqlite,
		sql: Str.join_with(
			[
				"create table rocx_actor_timers (",
				"    id integer primary key,",
				"    kind text not null,",
				"    key text not null,",
				"    message text not null,",
				"    at_ms integer not null,",
				"    created_at text not null default current_timestamp",
				");",
			],
			"\n",
		),
	},
]

apply_one! : { name : Str, sql : Str } => Try({}, Str)
apply_one! = |migration| {
	done = Db.transaction!(
		|{}| {
			if Db.backend!({}) == Postgres {
				_ = Db.run!("select pg_advisory_xact_lock(7230)", [])?
			}
			seen : List({ seen : I64 })
			seen = Db.all!("select 1 as seen from rocx_migrations where name = $1", [Text(migration.name)])?
			if seen.is_empty() {
				Db.script!(migration.sql)?
				_ = Db.run!("insert into rocx_migrations (name) values ($1)", [Text(migration.name)])?
				Ok(Bool.True)
			} else {
				Ok(Bool.False)
			}
		},
	)
	match done {
		Ok(applied) => {
			if (applied) Log.info!("rocx server: migrated", { migration: migration.name }) else {}
			Ok({})
		}
		Err(DbErr(why)) => Err("migration ${migration.name}: ${why}")
		Err(BadRow(why)) => Err("migration ${migration.name}: ${why}")
	}
}
