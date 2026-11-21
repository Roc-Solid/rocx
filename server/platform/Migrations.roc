import Db
import Log

## The schema, applied when the server starts: the platform's own tables first (the jobs queue,
## the actors' state, the outbox), then the app's (`program.migrations`). Each is applied once, in order, in a
## transaction of its own, and recorded in `rocx_migrations`; two servers starting at once take
## turns (an advisory lock), so none is applied twice.
Migrations := [].{
	own : List({ name : Str, sql : Str })
	own = [
		{
			name: "rocx/0001 jobs and actors",
			sql: Str.join_with(
				[
					"create table rocx_jobs (",
					"    id bigserial primary key,",
					"    kind text not null,",
					"    input text not null,",
					"    state text not null default 'queued' check (state in ('queued', 'running', 'done', 'failed')),",
					"    attempts int not null default 0,",
					"    max_attempts int not null default 5,",
					"    run_at timestamptz not null default now(),",
					"    locked_at timestamptz,",
					"    finished_at timestamptz,",
					"    last_error text,",
					"    unique_key text unique,",
					"    created_at timestamptz not null default now()",
					");",
					"create index rocx_jobs_ready on rocx_jobs (run_at, id) where state = 'queued';",
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
			name: "rocx/0002 job keys, cancelling, the outbox",
			sql: Str.join_with(
				[
					# A key is one job's while it is pending (queued or running), not forever: the
					# next may have it once that one is done.
					"alter table rocx_jobs drop constraint rocx_jobs_unique_key_key;",
					"create unique index rocx_jobs_pending_key on rocx_jobs (unique_key) where state in ('queued', 'running');",
					"alter table rocx_jobs drop constraint rocx_jobs_state_check;",
					"alter table rocx_jobs add constraint rocx_jobs_state_check check (state in ('queued', 'running', 'done', 'failed', 'canceled'));",
					"create index rocx_jobs_listed on rocx_jobs (state, kind, id);",
					# Email kept instead of sent (no SMTP server): the dev mailbox's.
					"create table rocx_outbox (",
					"    id bigserial primary key,",
					"    sent_at timestamptz not null default now(),",
					"    from_address text not null,",
					"    to_address text not null,",
					"    subject text not null,",
					"    text text not null,",
					"    html text not null,",
					"    raw text not null",
					");",
				],
				"\n",
			),
		},
		{
			# The dev mailbox keeps its mail in the server's memory (`Kv`), database or not (D-028):
			# the table it had goes, with the mail of past runs.
			name: "rocx/0003 the dev mailbox in memory",
			sql: "drop table if exists rocx_outbox",
		},
	]

	## Applies each of `migrations` the database hasn't seen, in order; the first that fails stops
	## the rest, and says why.
	apply! : List({ name : Str, sql : Str }) => Try({}, Str)
	apply! = |migrations|
		match Db.script!("create table if not exists rocx_migrations (name text primary key, applied_at timestamptz not null default now())") {
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

apply_one! : { name : Str, sql : Str } => Try({}, Str)
apply_one! = |migration| {
	done = Db.transaction!(
		|{}| {
			_ = Db.run!("select pg_advisory_xact_lock(7230)", [])?
			seen : List({ seen : I64 })
			seen = Db.all!("select 1::int8 as seen from rocx_migrations where name = $1", [Text(migration.name)])?
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
			if (applied) Log.line!("rocx server: migrated: ${migration.name}") else {}
			Ok({})
		}
		Err(DbErr(why)) => Err("migration ${migration.name}: ${why}")
		Err(BadRow(why)) => Err("migration ${migration.name}: ${why}")
	}
}
