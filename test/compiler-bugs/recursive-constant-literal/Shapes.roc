# Unannotated constants in recursive binding groups whose types reach a
# variable that carries a requirement: a number literal's, or a member's
# arithmetic on it. Each constant reads a member that reads it back, so the
# group's shared boundary generalizes the constant. A polymorphic constant
# owns no requirement, though, so such a variable stays one weak variable
# shared by every use and by the members that share it, as it does for a
# constant of its own: a use fixes it, or the module's end defaults it.

holder = { n: 1, run: |input| again(input) }

again : U64 -> U64
again = |input| {
	_ = holder
	input
}

counted = { n: 3, run: |input| twice(input) }

twice : U64 -> U64
twice = |input| {
	_ = counted
	input * 2
}

stepper = { run: |input| step(input) }

step = |input| {
	_ = stepper
	input + 1
}

expect (holder.run)(1) == 1
expect holder.n == 1
expect (counted.run)(3) == 6
expect counted.n + 1.U8 == 4
expect (stepper.run)(1) == 2
expect step(2.U8) == 3
