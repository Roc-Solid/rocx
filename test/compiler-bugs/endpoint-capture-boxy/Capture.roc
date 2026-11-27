# A function value a top-level constant holds, made by a function with a
# where clause. Its closure captures `holder`, of a nominal type over the
# function's type variable `a` that only a function field mentions: the
# capture's representation is the same for every `a`, so the function that
# made the closure describes it statically, as `Holder(a)`.

Holder(a) :: { name : Str, read : Str -> a }

Rules := {}.{
	parse : Rules, Str -> Str
	parse = |_, text| Str.concat(text, "!")
}

reader : Holder(a), rules -> (Str -> a) where [rules.parse : rules, Str -> a]
reader = |holder, rules| |text| if text == "" crash holder.name else rules.parse(text)

rules : Rules
rules = {}

read : Str -> Str
read = reader({ name: "holder", read: |text| text }, rules)

expect read("a") == "a!"
