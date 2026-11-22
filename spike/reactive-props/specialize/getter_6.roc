app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

Shows := [].{
	view! : { label : () => Str, n : () => U64 } => Html
	view! = |{ label, n }| {
		(clicks!, set_clicks!) = create_signal!(0.U64)
		Html.element("div", [], [
			Html.element("button", [Html.on("click", || set_clicks!(clicks!() + 1))], [Html.text_of(|| "${label()} ${clicks!().to_str()}")]),
			Html.element("p", [Html.attr_of("title", || label())], [Html.text_of(|| (n() * 2).to_str())]),
			Html.element("ul", [], [Html.text_of(|| lend!(label(), |label_now| Str.join_with(["a", "b", "c"].map(|x| x.concat(label_now)), ",")))]),
		])
	}
}

main! : {} => Html
main! = |{}| {
	(word!, set_word!) = create_signal!("one")
	(count!, _set_count!) = create_signal!(1.U64)
	Html.element("main", [Html.on("click", || set_word!("two"))], [
		Html.component(|| Shows.view!({ label: || "${word!()} 0", n: || count!() + 0 })),
		Html.component(|| Shows.view!({ label: || "${word!()} 1", n: || count!() + 1 })),
		Html.component(|| Shows.view!({ label: || "${word!()} 2", n: || count!() + 2 })),
		Html.component(|| Shows.view!({ label: || "${word!()} 3", n: || count!() + 3 })),
		Html.component(|| Shows.view!({ label: || "${word!()} 4", n: || count!() + 4 })),
		Html.component(|| Shows.view!({ label: || "${word!()} 5", n: || count!() + 5 })),
	])
}

lend! : a, (a => b) => b
lend! = |value, use!| use!(value)
