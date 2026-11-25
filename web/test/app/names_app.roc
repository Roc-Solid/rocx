## Markup built by hand with names a page can't have (D-079), for the tests: a tag that isn't a
## plain name, inline handlers and attribute names that would end the tag (static and computed), a
## `<script>` of data and one of nothing but a `src`. The runtime leaves each out, as the server
## does, and writes what is around them; the computed attribute that is plain follows its signal.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Html
import pf.Solid exposing [create_signal!]

main! : {} => Html
main! = |{}| {
	(said!, set_said!) = create_signal!("alert(2)")
	from_data = "x onmouseover=alert(1)"
	Html.element(
		"section",
		[Html.attr("class", "names")],
		[
			Html.element("p", [Html.attr("class", "kept"), Html.attr("onclick", "window.clicked = 1"), Html.attr(from_data, "y"), Html.attr("data-ok", "1"), Html.attr_of("ONLOAD", || said!()), Html.attr_of("data-said", || said!()), Html.flag("onfocus", Bool.True), Html.optional("a\"b", "z")], [Html.text("plain")]),
			Html.element("img src=x onerror=alert(1)", [], [Html.text("gone")]),
			Html.element("script", [], [Html.text_of(|| said!())]),
			Html.element("SCRIPT", [Html.attr("src", "/evil.js")], []),
			Html.element("custom-el", [Html.attr("xml:lang", "en")], [Html.text("after")]),
			Html.element("button", [Html.attr("class", "say"), Html.on("click", || set_said!("window.said = 1"))], [Html.text("Say")]),
		],
	)
}
