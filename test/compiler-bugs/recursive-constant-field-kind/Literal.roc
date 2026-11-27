# NOT the bug fixed here, still open with the fix: a field whose type
# carries a requirement (an untyped number literal). The group generalizes
# that variable too, where a constant of its own keeps it weak. Upstream
# main crashes under both strategies; rocx-fixes-4 reports "This top-level
# value still has an unresolved polymorphic type".

holder = { n: 1, run: |input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

expect (holder.run)(1) == 1
