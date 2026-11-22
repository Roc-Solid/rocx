app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

## A getter's default (`?? (|| 5)`) is filled at a direct call; a record a thunk returns gets none.
Stack := [].{
	Props := { label : () => Str, max : (() => U64) ?? (|| 5) }

	view! : Props => Html
	view! = |{ label: label!, max: max! }| Html.text_of(|| "${label!()} ${max!().to_str()}")

	Whole := { label : Str, max : U64 ?? 5 }

	whole! : (() => Whole) => Html
	whole! = |props!| Html.text_of(|| props!().label)
}

main! : {} => Html
main! = |{}| {
	(word!, _set_word!) = create_signal!("one")
	Html.join(
		[
			Html.component(|| Stack.view!({ label: || word!() })),
			# roc check: "This record is missing the field: max"
			Html.component(|| Stack.whole!(|| { label: word!() })),
		],
	)
}
