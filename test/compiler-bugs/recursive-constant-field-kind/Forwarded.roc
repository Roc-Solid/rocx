# NOT the bug fixed here, still open with the fix: the constant read inside
# a generic function (`forwarded`, generic over the context), so the
# instance is forwarded to the call that closes its type. --specialize=no
# passes with the fix; --specialize=yes stops in Monotype at "unresolved
# record field kind reached Monotype sealing" (restoredConstantInstance
# seals the type of each instance root of the constant, one of which still
# holds the generalized kind variable). Upstream main fails the same way;
# rocx-fixes-4 passes.

holder = { run: |_context, input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

forwarded = |context, input| (holder.run)(context, input)

expect forwarded(4.U8, 5) == 5
