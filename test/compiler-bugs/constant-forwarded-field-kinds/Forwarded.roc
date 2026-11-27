# A constant in a recursive binding group (`holder` reads `again`, which
# reads `holder` back), read inside a generic function (`forwarded`, generic
# over the context). The group's shared boundary generalizes `holder`, and
# with it the undetermined kind variable of its `run` field. The read in
# `forwarded` is forwarded to the call that closes its type, so the
# specialization of `forwarded` at U8 looks the instance up by its closed
# type among the constant's instance roots, measuring the type of each. The
# canonical root's type gave the kind variable a type (`[]`), not a kind, so
# its field stayed undetermined: "unresolved record field kind reached
# Monotype sealing" under --specialize=yes.

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

forwarded = |context, input| (holder.run)(context, input)

expect forwarded(4.U8, 5) == 5
