app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

Shows := [].{
	view! : { label : Box(() => Str), n : Box(() => U64) } => Html
	view! = |{ label, n }| {
		(clicks!, set_clicks!) = create_signal!(0.U64)
		Html.element("div", [], [
			Html.element("button", [Html.on("click", || set_clicks!(clicks!() + 1))], [Html.text_of(|| "${(Box.unbox(label))()} ${clicks!().to_str()}")]),
			Html.element("p", [Html.attr_of("title", || (Box.unbox(label))())], [Html.text_of(|| ((Box.unbox(n))() * 2).to_str())]),
			Html.element("ul", [], [Html.text_of(|| lend!((Box.unbox(label))(), |label_now| Str.join_with(["a", "b", "c"].map(|x| x.concat(label_now)), ",")))]),
		])
	}
}

main! : {} => Html
main! = |{}| {
	(word!, set_word!) = create_signal!("one")
	(count!, _set_count!) = create_signal!(1.U64)
	Html.element("main", [Html.on("click", || set_word!("two"))], [
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 0"), n: Box.box(|| count!() + 0) })),
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 1"), n: Box.box(|| count!() + 1) })),
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 2"), n: Box.box(|| count!() + 2) })),
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 3"), n: Box.box(|| count!() + 3) })),
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 4"), n: Box.box(|| count!() + 4) })),
		Html.component(|| Shows.view!({ label: Box.box(|| "${word!()} 5"), n: Box.box(|| count!() + 5) })),
	])
}

lend! : a, (a => b) => b
lend! = |value, use!| use!(value)
