app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

Shows := [].{
	view! : { label : Str, n : U64 } => Html
	view! = |{ label, n }| {
		(clicks!, set_clicks!) = create_signal!(0.U64)
		Html.element("div", [], [
			Html.element("button", [Html.on("click", || set_clicks!(clicks!() + 1))], [Html.text_of(|| "${label} ${clicks!().to_str()}")]),
			Html.element("p", [Html.attr_of("title", || label)], [Html.text_of(|| (n * 2).to_str())]),
			Html.element("ul", [], [Html.text_of(|| Str.join_with(["a", "b", "c"].map(|x| x.concat(label)), ","))]),
		])
	}
}

main! : {} => Html
main! = |{}| {
	(word!, set_word!) = create_signal!("one")
	(count!, _set_count!) = create_signal!(1.U64)
	Html.element("main", [Html.on("click", || set_word!("two"))], [
		Html.component(|| Shows.view!({ label: "s0", n: 0 })),
		Html.component(|| Shows.view!({ label: "s1", n: 1 })),
		Html.component(|| Shows.view!({ label: "s2", n: 2 })),
		Html.component(|| Shows.view!({ label: "s3", n: 3 })),
		Html.component(|| Shows.view!({ label: "s4", n: 4 })),
		Html.component(|| Shows.view!({ label: "s5", n: 5 })),
	])
}
