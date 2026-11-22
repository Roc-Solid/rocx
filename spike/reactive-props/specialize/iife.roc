app [main!] { pf: platform "../../../web/platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

Shows := [].{
	view! : { label : () => Str, sep : () => Str } => Html
	view! = |{ label: label!, sep: sep! }| {
		first = label!()
		parts = ["a", "b"].map((|label| |x| x.concat(label))(label!()))
		Html.element("p", [], [Html.text_of(|| Str.join_with(["a", "b"].map((|label, sep| |x| x.concat(label).concat(sep))(label!(), sep!())), sep!())), Html.text(first), Html.text(Str.join_with(parts, ""))])
	}
}

main! : {} => Html
main! = |{}| {
	(word!, _set_word!) = create_signal!("one")
	Html.component(|| Shows.view!({ label: || word!(), sep: || "," }))
}
