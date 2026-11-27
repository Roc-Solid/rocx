# A polymorphic constant (`holder`, a record holding a function: its type
# `{ run : a -> a }` is generalized) read inside a local function whose type
# mentions only its enclosing function's variable: `inner : t -> List(t)`,
# where `t` is `outer`'s. `inner` generalizes nothing of its own, so
# checking records no instantiation at `inner(other)`; the instance of
# `holder` it reads at `t` has to reach `outer`, and through it the expect,
# which fixes `t` to `Str`.

holder = { run: |x| x }

outer = |other| {
	inner = |x| [other, (holder.run)(x)]
	inner(other)
}

expect outer("a") == ["a", "a"]
