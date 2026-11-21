## A feature flag, as the app's code defines it: its name, what it is for, and who has it on (its
## `Rule`), the same everywhere or with a rule of its own in some environments.
##
##     new_checkout = Flag.define("new_checkout", "The one-page checkout", Flags.rollout(10))
##         .in_env("dev", Flags.on)
##
## What the code says is the default: a rule set while the server runs (`Flags.set`, from an
## admin page) takes its place until it is reset. `Flags` decides who has it on.
Flag := { name : Str, about : Str, rule : Rule, environments : List({ env : Str, rule : Rule }) }.{

	## Who has a flag on:
	##
	## - `on`: off is off for everyone, whatever the rest says (a kill switch); on, the rest decide;
	## - `users`: these users have it on;
	## - `groups`: and anyone in one of these groups (staff, beta testers);
	## - `percent`: and this share of everyone else who is signed in, 0 to 100, each user in or
	##   out the same way every time (by a hash of the flag's name and theirs), so raising it only
	##   adds people. At 100, everyone, signed in or not.
	##
	## `Flags.on`, `Flags.off`, `Flags.rollout(25)` and `Flags.only(users, groups)` make the usual
	## ones; `{ ..Flags.rollout(25), groups: ["staff"] }` mixes them.
	Rule : { on : Bool, percent : U64, users : List(Str), groups : List(Str) }

	## A flag: its name (what the server and the browser ask for it by), what it is for (for an
	## admin page), and its rule.
	define : Str, Str, Rule -> Flag
	define = |name, about, rule| { name, about, rule, environments: [] }

	## The flag with `rule` in the environment `env` (`dev`, `staging`, as the server says which it
	## is in: see the package's README), and its own rule elsewhere.
	in_env : Flag, Str, Rule -> Flag
	in_env = |flag, env, rule| { ..flag, environments: flag.environments.keep_if(|each| each.env != env).append({ env, rule }) }

	## The rule the code gives the flag in `env`.
	rule_in : Flag, Str -> Rule
	rule_in = |flag, env|
		match flag.environments.find_first(|each| each.env == env) {
			Ok(found) => found.rule
			Err(_) => flag.rule
		}
}

everyone : Flag.Rule
everyone = { on: Bool.True, percent: 100, users: [], groups: [] }

nobody : Flag.Rule
nobody = { on: Bool.False, percent: 0, users: [], groups: [] }

expect Flag.define("x", "", nobody).rule_in("prod") == nobody
expect Flag.define("x", "", nobody).in_env("dev", everyone).rule_in("dev") == everyone
expect Flag.define("x", "", nobody).in_env("dev", everyone).rule_in("prod") == nobody
# Said twice for one environment: the last.
expect Flag.define("x", "", nobody).in_env("dev", everyone).in_env("dev", nobody).rule_in("dev") == nobody
expect Flag.define("x", "", nobody).in_env("dev", everyone).in_env("dev", nobody).environments.len() == 1
