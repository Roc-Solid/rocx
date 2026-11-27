# NOT the bug fixed here: a separate regression found while reducing it, and
# still open with the fix. The same recursive group with no annotation on
# the constant and no codec anywhere: under --specialize=no the compile-time
# evaluation of `holder`'s instance crashes ("boxy runtime invariant violated:
# adapted descriptors describe different kinds of value"; a release compiler
# segfaults). rocx-fixes-4 passes; --specialize=yes passes; annotating
# `holder : { run : _, U64 -> U64 }` passes.

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)({}, 1) == 1
