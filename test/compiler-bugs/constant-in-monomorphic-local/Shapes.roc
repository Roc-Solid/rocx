# A polymorphic constant read inside a local function whose type mentions
# only its enclosing function's type variable. The local generalizes nothing
# of its own, so checking records no instantiation at its uses; the instance
# of `holder` it reads, at the enclosing function's variable, is forwarded
# through each use of the local (a call, a function value, a call from
# another such local) to the enclosing function's scheme, and from there to
# the expect that fixes the type.

holder = { run: |x| x }

called = |other| {
	inner = |x| [other, (holder.run)(x)]
	inner(other)
}

passed = |other| {
	inner = |x| [other, (holder.run)(x)]
	[other].map(inner)
}

nested = |other| {
	inner = |x| [other, (holder.run)(x)]
	twice = |y| inner(y).concat(inner(y))
	twice(other)
}

expect called("a") == ["a", "a"]
expect called(1.U8) == [1, 1]
expect passed("b") == [["b", "b"]]
expect nested(2.I64) == [2, 2, 2, 2]
