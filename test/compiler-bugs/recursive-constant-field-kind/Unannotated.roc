# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back) whose record literal's field no annotation gives a
# kind. The group's shared boundary generalizes `holder`, and with it the
# undetermined kind variable of its `run` field. Each closed instance is
# evaluated at compile time; its frame must bind that kind variable to the
# field's storage, not to the instance's committed kind (`[#Required]`) or,
# for the canonical instance, a sealed flex (`[]`).

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)({}, 1) == 1
