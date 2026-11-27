# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back) with a field whose type carries a requirement: the
# number literal's `from_numeral`. A constant of its own keeps that type
# weak, one type every use shares, defaulted when the module finishes. The
# group's shared boundary generalized it with the constant instead, so the
# constant was polymorphic over a variable with a requirement no read of a
# constant can supply: its canonical instance put the literal in a field of
# type `[]`. Boxy stops at a Dev/codegen layout invariant
# (tag_payload_struct_access) while evaluating it, Monotype at "measuring a
# closed checked type did not record its Monotype".

holder = { n: 1, run: |input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)(1) == 1
