import pf.Actor
import pf.Env
import pf.Log
import guard.Flag
import guard.Flags

## Feature flags while the server runs: the environment it is in, and the rules set in place of
## the code's (overrides), kept in the server's memory, and in Postgres when it has a database (so
## they outlive a restart). An admin page lists the flags and sets or resets their rules here.
##
##     on = FlagStore.is_on!(Features.new_checkout, { user: context.user, groups: [] })
##     FlagStore.set!("new_checkout", Flags.rollout(50))?
##
## The overrides are an actor's state (`rocx_guard_flags`). PROPOSALS.md ("Memory: state between
## requests") would make reading them a lookup in memory rather than an actor's message (a read
## writes nothing to Postgres: it changes nothing).
FlagStore := [].{

	## The overrides' actor (`rocx build` lists it in the app's `program.actors`).
	kept : Actor.Kind(List(Flags.Override), Change, List(Flags.Override))
	kept = Actor.define({
		name: "rocx_guard_flags",
		initial: |_key| [],
		receive!: |_me, overrides, change| {
			next =
				match change {
					Read => overrides
					Set(given) => Flags.set(overrides, given.name, given.rule)
					Reset(name) => Flags.reset(overrides, name)
				}
			{ state: next, reply: next }
		},
	})

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
	overrides! = |{}|
		match Actor.ask!(FlagStore.kept, "overrides", Read) {
			Ok(overrides) => overrides
			Err(ActorErr(why)) => {
				Log.warn!("guard: the flags' overrides couldn't be read; the code's rules stand", { error: why })
				[]
			}
		}

	## What flags are decided with now: the environment, and the overrides.
	settings! : {} => Flags.Settings
	settings! = |{}| { env: FlagStore.env!({}), overrides: FlagStore.overrides!({}) }

	## Whether `who` has `flag` on now.
	is_on! : Flag, Flags.Who => Bool
	is_on! = |flag, who| Flags.is_on(flag, FlagStore.settings!({}), who)

	## Each of `flags`, decided for `who` now: what a page sends the browser (a server function's
	## answer), so the browser shows what the server rendered.
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

## What the overrides' actor is told.
Change : [Read, Set(Flags.Override), Reset(Str)]

changed! : Change => Try({}, [FlagErr(Str)])
changed! = |change|
	match Actor.ask!(FlagStore.kept, "overrides", change) {
		Ok(_) => Ok({})
		Err(ActorErr(why)) => Err(FlagErr(why))
	}
