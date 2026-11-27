# The same with a second field the generic function does not read
# (`count`): nothing in `counted` commits that field's kind, so the read's
# own type still has an undetermined kind when the instance is looked up,
# and the lookup took it for an open type: "a read of polymorphic constant
# root 0 names no instance (edge use)" under --specialize=yes, with or
# without the canonical root's fix.

mixed = { count: 3.U64, run: |_context, input| added(input) }

added : U64 -> U64
added = |input| {
	_ = mixed
	input + 10
}

counted = |context, input| (mixed.run)(context, input)

expect counted(1.I32, 1) == 11
