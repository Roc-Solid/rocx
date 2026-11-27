# Unannotated constants in recursive binding groups, each a record literal
# whose fields no annotation gives a kind, read inside generic functions.
# Each constant reads a member that reads it back, so the group's shared
# boundary generalizes the constant, and with it each field's undetermined
# kind variable. A read inside a generic function forwards the instance to
# the call that closes its type, so a specialization looks the instance up
# by its closed type among the constant's instance roots. Both sides of
# that comparison read a kind nothing committed as `required`: the
# canonical root's type, and the read's own type where the function reads
# one field and leaves the other's kind open (`counted`).

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

forwarded = |context, input| (holder.run)(context, input)

forwarded_twice = |context, input| forwarded(context, forwarded(context, input))

mixed = { count: 3.U64, run: |_context, input| added(input) }

added : U64 -> U64
added = |input| {
	_ = mixed
	input + 10
}

counted = |context, input| mixed.count + (mixed.run)(context, input)

expect forwarded(4.U8, 5) == 5
expect forwarded("a context", 6) == 6
expect forwarded_twice({}, 7) == 7
expect counted(1.I32, 1) == 14
