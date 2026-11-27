# The same with no unused parameter: the crash is the field's kind variable,
# not `_context`'s type variable. A tuple in place of the record (no field
# kinds) passes on upstream main.

holder = { run: |input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)(1) == 1
