# Unannotated constants in recursive binding groups, each a record literal
# whose fields no annotation gives a kind. Each constant reads a member that
# reads it back, so the group's shared boundary generalizes the constant,
# and with it each field's undetermined kind variable. Every closed instance
# of a constant is evaluated with each kind variable bound to its field's
# storage: the field's value at a required kind (a use reading the field,
# or no use pinning it), its presence slot at an optional one.

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

plain = { run: |input| twice(input) }

twice : U64 -> U64
twice = |input| {
	_ = plain
	input * 2
}

mixed = { count: 3.U64, run: |input| added(input), other: |input| added(input) + 1 }

added : U64 -> U64
added = |input| {
	_ = mixed
	input + 10
}

picked : { run ?: a } -> Try(a, [MissingField])
picked = |record| record.?run

expect (holder.run)({}, 1) == 1
expect (holder.run)("a context", 2) == 2
expect (plain.run)(3) == 6
expect mixed.count + (mixed.run)(1) + (mixed.other)(1) == 26
expect match picked(plain) {
	Ok(run) => run(4) == 8
	Err(MissingField) => False
}
