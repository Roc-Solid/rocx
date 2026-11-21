import Flag
import Hash

## Who has a feature flag on, decided the same way on the server and, through the values the
## server sends it, in the browser.
##
##     settings = { env: "production", overrides }       # the server's: `FlagStore.settings!`
##     if Flags.is_on(new_checkout, settings, { user: "ada", groups: ["staff"] }) { … }
##
##     values = Flags.values([new_checkout, dark_mode], settings, who)   # for the page
##     Flags.enabled(values, "new_checkout")                              # in a component
##
## A flag's rule is what an override says, if one is set (`set`, from an admin page, kept by the
## server), or else what the code says for the environment (`Flag.in_env`), or else the flag's own.
Flags := [].{

	## Who is asking: a user's id ("" when no one is signed in) and the groups they are in.
	Who : { user : Str, groups : List(Str) }

	## A rule set while the server runs, in place of what the code says, until it is reset.
	Override : { name : Str, rule : Flag.Rule }

	## What the server knows when it decides: the environment it runs in, and the overrides set.
	Settings : { env : Str, overrides : List(Override) }

	## Flags decided for one person, by name: what the server sends a page, so the browser shows
	## what the server rendered.
	Values : List({ name : Str, on : Bool })

	## On for everyone.
	on : Flag.Rule
	on = { on: Bool.True, percent: 100, users: [], groups: [] }

	## Off for everyone.
	off : Flag.Rule
	off = { on: Bool.False, percent: 0, users: [], groups: [] }

	## On for `percent` of signed-in users (0 to 100), each in or out the same way every time.
	rollout : U64 -> Flag.Rule
	rollout = |percent| { on: Bool.True, percent: U64.min(percent, 100), users: [], groups: [] }

	## On for these users and anyone in these groups, and no one else.
	only : List(Str), List(Str) -> Flag.Rule
	only = |users, groups| { on: Bool.True, percent: 0, users, groups }

	## No one signed in.
	anyone : Who
	anyone = { user: "", groups: [] }

	## The rule a flag has now: the override set for it, or the code's for the environment.
	rule_for : Flag, Settings -> Flag.Rule
	rule_for = |flag, settings|
		match settings.overrides.find_first(|each| each.name == flag.name) {
			Ok(found) => found.rule
			Err(_) => flag.rule_in(settings.env)
		}

	## Whether `who` has `flag` on.
	is_on : Flag, Settings, Who -> Bool
	is_on = |flag, settings, who| Flags.decide(Flags.rule_for(flag, settings), flag.name, who)

	## Whether the rule `given` puts `who` in, for the flag called `name`: off is off; then the users, the
	## groups, and the share of the signed-in (all, at 100).
	decide : Flag.Rule, Str, Who -> Bool
	decide = |given, name, who|
		if !given.on {
			Bool.False
		} else if given.percent >= 100 {
			Bool.True
		} else if !who.user.is_empty() and given.users.contains(who.user) {
			Bool.True
		} else if given.groups.any(|group| who.groups.contains(group)) {
			Bool.True
		} else if who.user.is_empty() {
			Bool.False
		} else {
			Flags.bucket(name, who.user) < given.percent
		}

	## Where `user` falls for the flag `name`, 0 to 99: in a rollout of `percent` when below it.
	## The flag's name is part of it, so a user early in one rollout isn't early in all of them.
	bucket : Str, Str -> U64
	bucket = |name, user| Hash.bucket("${name}/${user}", 100)

	## Each flag decided for `who`: what a page sends the browser.
	values : List(Flag), Settings, Who -> Values
	values = |flags, settings, who| flags.map(|flag| { name: flag.name, on: Flags.is_on(flag, settings, who) })

	## Whether the flag called `name` is on in `decided` (`values`); off when it isn't there.
	enabled : Values, Str -> Bool
	enabled = |decided, name|
		match decided.find_first(|each| each.name == name) {
			Ok(found) => found.on
			Err(_) => Bool.False
		}

	## The overrides, with the rule `given` for the flag called `name` (in place of one set before).
	set : List(Override), Str, Flag.Rule -> List(Override)
	set = |overrides, name, given| Flags.reset(overrides, name).append({ name, rule: { ..given, percent: U64.min(given.percent, 100) } })

	## The overrides, without one for the flag called `name`: the code's rule again.
	reset : List(Override), Str -> List(Override)
	reset = |overrides, name| overrides.keep_if(|each| each.name != name)

	## Each flag as an admin page shows it: its name, what it is for, the rule in force, the
	## code's rule for the environment, and whether an override replaces it.
	describe : List(Flag), Settings -> List({ name : Str, about : Str, rule : Flag.Rule, code : Flag.Rule, overridden : Bool })
	describe = |flags, settings|
		flags.map(
			|flag| {
				code = flag.rule_in(settings.env)
				{ name: flag.name, about: flag.about, rule: Flags.rule_for(flag, settings), code, overridden: settings.overrides.any(|each| each.name == flag.name) }
			},
		)

	## Overrides as text (JSON), to keep them: in the server's memory, in Postgres.
	overrides_to_str : List(Override) -> Str
	overrides_to_str = |overrides| Json.to_str(overrides)

	## Overrides from `overrides_to_str`'s text; none from text that isn't (nothing kept yet).
	overrides_from_str : Str -> List(Override)
	overrides_from_str = |text| {
		parsed : Try(List(Override), [InvalidJson(Str)])
		parsed = Json.parse(text)
		parsed ?? []
	}
}

checkout : Flag
checkout = Flag.define("new_checkout", "The one-page checkout", Flags.rollout(25)).in_env("dev", Flags.on)

prod : Flags.Settings
prod = { env: "production", overrides: [] }

ada : Flags.Who
ada = { user: "ada", groups: [] }

## The ids `user-0`, `user-1`, … of `count` users.
users : U64 -> List(Str)
users = |count| {
	var $ids = []
	var $n = 0
	while $n < count {
		$ids = $ids.append("user-${$n.to_str()}")
		$n = $n + 1
	}
	$ids
}

## How many of a thousand signed-in users have `flag` on.
counted : Flag, Flags.Settings -> U64
counted = |flag, settings| users(1000).keep_if(|user| Flags.is_on(flag, settings, { user, groups: [] })).len()

# On and off, for everyone, signed in or not.
expect Flags.is_on(Flag.define("a", "", Flags.on), prod, Flags.anyone)
expect !Flags.is_on(Flag.define("a", "", Flags.off), prod, ada)
# Off is off, whoever is listed.
expect !Flags.is_on(Flag.define("a", "", { ..Flags.only(["ada"], ["staff"]), on: Bool.False }), prod, { user: "ada", groups: ["staff"] })
# Users and groups.
expect Flags.is_on(Flag.define("a", "", Flags.only(["ada"], [])), prod, ada)
expect !Flags.is_on(Flag.define("a", "", Flags.only(["ada"], [])), prod, { user: "bob", groups: [] })
expect Flags.is_on(Flag.define("a", "", Flags.only([], ["staff"])), prod, { user: "bob", groups: ["staff"] })
expect Flags.is_on(Flag.define("a", "", Flags.only([], ["staff"])), prod, { user: "", groups: ["staff"] })
expect !Flags.is_on(Flag.define("a", "", Flags.only([""], [])), prod, Flags.anyone)

# A rollout: about its share of users (25% of 1000, give or take 5 points), the same each time;
# no one signed out (they have no id to be counted by), until 100.
expect {
	count = counted(checkout, prod)
	count > 200 and count < 300
}
expect counted(checkout, prod) == counted(checkout, prod)
expect !Flags.is_on(checkout, prod, Flags.anyone)
expect counted(Flag.define("a", "", Flags.rollout(0)), prod) == 0
expect counted(Flag.define("a", "", Flags.rollout(100)), prod) == 1000
expect Flags.is_on(Flag.define("a", "", Flags.rollout(100)), prod, Flags.anyone)
expect Flags.rollout(250).percent == 100
# Raising a rollout only adds people: everyone in at 10% is in at 30%.
expect users(1000).all(
	|user| {
		who = { user, groups: [] }
		!Flags.is_on(Flag.define("a", "", Flags.rollout(10)), prod, who) or Flags.is_on(Flag.define("a", "", Flags.rollout(30)), prod, who)
	},
)
# Two flags at 50% don't pick the same half.
expect users(100).any(
	|user| {
		who = { user, groups: [] }
		Flags.is_on(Flag.define("a", "", Flags.rollout(50)), prod, who) != Flags.is_on(Flag.define("b", "", Flags.rollout(50)), prod, who)
	},
)
# A rollout and a group: either puts you in.
expect Flags.is_on(Flag.define("a", "", { ..Flags.rollout(0), groups: ["beta"] }), prod, { user: "zed", groups: ["beta"] })

# The environment's rule, where the code gives one.
expect Flags.is_on(checkout, { env: "dev", overrides: [] }, Flags.anyone)
# An override wins over the code, and goes when reset.
expect {
	overrides = Flags.set([], "new_checkout", Flags.off)
	!Flags.is_on(checkout, { env: "dev", overrides }, ada) and Flags.is_on(checkout, { env: "dev", overrides: Flags.reset(overrides, "new_checkout") }, ada)
}
expect Flags.set(Flags.set([], "a", Flags.off), "a", Flags.on) == [{ name: "a", rule: Flags.on }]
expect Flags.set([], "a", { ..Flags.on, percent: 900 }) == [{ name: "a", rule: Flags.on }]

# Values: what the browser gets, and reads; a flag it wasn't sent is off.
expect Flags.values([checkout, Flag.define("dark", "", Flags.on)], prod, Flags.anyone) == [{ name: "new_checkout", on: Bool.False }, { name: "dark", on: Bool.True }]
expect Flags.enabled([{ name: "dark", on: Bool.True }], "dark")
expect !Flags.enabled([{ name: "dark", on: Bool.True }], "light")

# Overrides as text and back.
expect {
	overrides = Flags.set(Flags.set([], "a", Flags.only(["ada"], ["staff"])), "b", Flags.rollout(5))
	Flags.overrides_from_str(Flags.overrides_to_str(overrides)) == overrides
}
expect Flags.overrides_from_str("") == []
expect Flags.overrides_from_str("{\"not\":\"a list\"}") == []

# What an admin page shows: the rule in force, the code's, and whether it is overridden.
expect {
	described = Flags.describe([checkout], { env: "production", overrides: Flags.set([], "new_checkout", Flags.on) })
	described == [{ name: "new_checkout", about: "The one-page checkout", rule: Flags.on, code: Flags.rollout(25), overridden: Bool.True }]
}
expect Flags.describe([checkout], { env: "dev", overrides: [] }) == [{ name: "new_checkout", about: "The one-page checkout", rule: Flags.on, code: Flags.on, overridden: Bool.False }]
