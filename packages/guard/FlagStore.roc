import pf.Env
import pf.Kv
import pf.Log
import Flag
import Flags

## Feature flags while the server runs: the environment it is in, and the rules set in place of
## the code's (overrides), kept in the server's memory (`Kv`, D-043) under `guard:flags`. An admin
## page lists the flags and sets or resets their rules here. A restart forgets the overrides, and
## the code's rules stand again.
##
##     on = FlagStore.is_on!(Features.new_checkout, { user: context.user, groups: [] })
##     FlagStore.set!("new_checkout", Flags.rollout(50))?
FlagStore := [].{

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

## Applies `change` to the overrides, reading them again when another request changed them first.
changed! : Change => Try({}, [FlagErr(Str)])
changed! = |change| {
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
