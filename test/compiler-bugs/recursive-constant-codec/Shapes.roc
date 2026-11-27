# Polymorphic constants in recursive binding groups with functions that encode
# or parse a record. Each constant reads a member that reads it back, so the
# group's shared boundary generalizes the constant (over the hole `_`), and the
# member's generated codec relation is copied at the constant's use of it. A
# read of a constant carries no evidence, so the constant must own no
# requirement: the relation belongs where a weak value's would, and each
# closed instance of the constant evaluates with no dictionary.

Job(c, i) : { run : c, i -> Str }

enqueue : Job(c, i), i -> Str
	where [i.Json.Encodable([])]
enqueue = |_job, input| Json.to_str(input)

Input : { n : U64 }

deliver : Job(_, Input)
deliver = { run: |_context, input| again(input) }

again : Input -> Str
again = |input| enqueue(deliver, { ..input, n: input.n + 1 })

show : { run : _, { n : U64 } -> Str }
show = { run: |_context, input| shown(input) }

shown : { n : U64 } -> Str
shown = |input| {
	_ = show
	Json.to_str(input)
}

read : { run : _, Str -> { n : U64 } }
read = { run: |_context, text| parsed(text) }

parsed : Str -> { n : U64 }
parsed = |text| {
	_ = read
	match Json.parse(text) {
		Ok(record) => record
		Err(InvalidJson(_)) => { n: 0 }
	}
}

expect (deliver.run)({}, { n: 1 }) == "{\"n\":2}"
expect (deliver.run)("a context", { n: 2 }) == "{\"n\":3}"
expect (show.run)({}, { n: 1 }) == "{\"n\":1}"
expect (read.run)({}, "{\"n\":4}") == { n: 4 }
