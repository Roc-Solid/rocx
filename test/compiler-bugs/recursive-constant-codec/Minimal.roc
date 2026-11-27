# A constant in a recursive binding group: `holder` reads `shown`, which
# reads `holder` back. The group's shared boundary generalizes `holder` (over
# its hole `_`), so it is a polymorphic constant, evaluated per closed
# instance. `shown`'s generated codec relation (`{ n : U64 }.Json.Encodable`)
# is copied where `holder` uses `shown`, and was captured as a requirement of
# `holder`'s scheme, which a read of a constant never supplies.

holder : { run : _, { n : U64 } -> Str }
holder = { run: |_context, input| shown(input) }

shown : { n : U64 } -> Str
shown = |input| {
	_ = holder
	Json.to_str(input)
}

expect (holder.run)({}, { n: 1 }) == "{\"n\":1}"
