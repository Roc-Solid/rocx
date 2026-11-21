## HTML as a tree, and the things in it found as a person finds them: by role and accessible name,
## by text, by label, by test id. The queries are Testing Library's (`getByRole`, `getByText`,
## `getByLabelText`, `getByTestId`), with its rules, so a test says what someone sees and not how
## the page is built:
##
##     page = Dom.parse(Html.to_str(Greeting.view({ name: "Ada" })))
##     expect page.text_of(Role("heading")) == Ok("Hello, Ada")
##     expect page.contains(Named("button", "Wave"))
##
## It reads HTML that closes its elements, as Roc Solid writes it and a browser serializes it: void
## elements (`<br>`, `<input>`) need no end tag, `<script>` and `<style>` hold text as written,
## `<textarea>` and `<title>` text, and an end tag closes the elements still open inside it.
Dom :: [
	Element(Str, List((Str, Str)), List(Dom)),
	Text(Str),
	Comment(Str),
	Root(List(Dom)),
].{

	## What to look for in a page:
	##
	## - `Role(role)`: elements with that ARIA role, their own (`role="tab"`) or their tag's
	##   (`<button>` is a button, `<a href>` a link, `<h2>` a heading, `<input type="checkbox">` a
	##   checkbox, `<ul>` a list, `<li>` a listitem, `<nav>` navigation…).
	## - `Named(role, name)`: and whose accessible name is `name`: its `aria-labelledby`, its
	##   `aria-label`, its `<label>`, its `alt`, its text (a button's, a link's, a heading's, a
	##   cell's), its `title`.
	## - `Text(text)`: elements whose own text (not their children's) is `text`.
	## - `Label(text)`: the form control a `<label>` with that text names (by `for`, or inside it),
	##   or whose `aria-label` or `aria-labelledby` says it.
	## - `TestId(id)`: the element with `data-testid="id"`.
	## - `Tag(tag)`: elements by their tag name (`"title"`, `"meta"`), hidden or not.
	## - `Attr(name, value)`: elements whose attribute `name` is `value`, hidden or not.
	##
	## Roles, names, text and labels skip what a reader can't see: an element that is `hidden`,
	## `aria-hidden="true"` or `display: none` in its `style`, and what is inside it; `<head>`,
	## `<script>`, `<style>`, `<template>`. Text is compared as a reader sees it: its whitespace
	## collapsed, and trimmed.
	Query : [Role(Str), Named(Str, Str), Text(Str), Label(Str), TestId(Str), Tag(Str), Attr(Str, Str)]

	## HTML as a tree (the document, or a fragment of one).
	parse : Str -> Dom
	parse = |html| parse_bytes(html.to_utf8())

	## Every element `query` finds inside `node`, in the page's order.
	all : Dom, Query -> List(Dom)
	all = |node, query| found(index(node), query).map(|entry| entry.node)

	## The one element `query` finds inside `node`: `NotFound` says what there is instead, and
	## `TooMany` how many there are.
	get : Dom, Query -> Try(Dom, [NotFound(Str), TooMany(Str)])
	get = |node, query| {
		entries = index(node)
		matches = found(entries, query)
		match matches {
			[one] => Ok(one.node)
			[] => Err(NotFound(missing(entries, query)))
			_ => Err(TooMany("${matches.len().to_str()} elements are ${described(query)}"))
		}
	}

	## The first element `query` finds inside `node`.
	first : Dom, Query -> Try(Dom, [NotFound(Str)])
	first = |node, query| {
		entries = index(node)
		match found(entries, query) {
			[one, ..] => Ok(one.node)
			[] => Err(NotFound(missing(entries, query)))
		}
	}

	## Whether `query` finds anything inside `node`.
	contains : Dom, Query -> Bool
	contains = |node, query| !found(index(node), query).is_empty()

	## How many elements `query` finds inside `node`.
	count : Dom, Query -> U64
	count = |node, query| found(index(node), query).len()

	## The text of the one element `query` finds inside `node`.
	text_of : Dom, Query -> Try(Str, [NotFound(Str), TooMany(Str)])
	text_of = |node, query| node.get(query).map_ok(|element| element.text())

	## The text of each element `query` finds inside `node`: a list's items, a column's cells.
	texts : Dom, Query -> List(Str)
	texts = |node, query| node.all(query).map(|element| element.text())

	## What a reader reads in it: its text, without `<script>`s, `<style>`s and `<template>`s,
	## whitespace collapsed and trimmed.
	text : Dom -> Str
	text = |node| normalize(content(node))

	## Its attribute `name` (`""` for one written bare, as `checked`).
	attr : Dom, Str -> Try(Str, [Missing])
	attr = |node, name|
		match node {
			Element(_, attrs, _) =>
				match value(attrs, name.with_ascii_lowercased()) {
					Ok(found_value) => Ok(found_value)
					Err(_) => Err(Missing)
				}
			_ => Err(Missing)
		}

	## Its tag's name, in lower case; `""` for text, a comment or the document.
	tag : Dom -> Str
	tag = |node|
		match node {
			Element(name, _, _) => name
			_ => ""
		}

	## Whether `class` is one of its classes.
	has_class : Dom, Str -> Bool
	has_class = |node, class|
		match node.attr("class") {
			Ok(classes) => classes.split_on(" ").contains(class)
			Err(_) => Bool.False
		}

	## Whether two trees are the same: their tags, their attributes in order, their text and their
	## comments. `==` on two `Dom`s, or on `Try`s holding them.
	is_eq : Dom, Dom -> Bool
	is_eq = |one, other|
		match (one, other) {
			(Element(tag_one, attrs_one, children_one), Element(tag_other, attrs_other, children_other)) => tag_one == tag_other and attrs_one == attrs_other and children_one == children_other
			(Text(said_one), Text(said_other)) => said_one == said_other
			(Comment(said_one), Comment(said_other)) => said_one == said_other
			(Root(children_one), Root(children_other)) => children_one == children_other
			_ => Bool.False
		}

	## The role and the accessible name of each element inside `node` that a reader can reach, in
	## the page's order: what `Role` and `Named` look through (Testing Library's `logRoles`), for a
	## `dbg` when a query finds nothing.
	roles : Dom -> List((Str, Str))
	roles = |node| {
		entries = index(node)
		entries.keep_if(|entry| !entry.hidden and !entry.role.is_empty()).map(|entry| (entry.role, name_of(entries, entry)))
	}
}

# The queries.

## An element of the tree being searched, with what the queries look at: where it is (its child
## indices from the top: an element's identity), its role, and whether a reader can see it.
Entry : { node : Dom, path : List(U64), tag : Str, attrs : List((Str, Str)), role : Str, hidden : Bool }

## Every element inside `node`, in the page's order.
index : Dom -> List(Entry)
index = |node|
	match node {
		Element(tag, attrs, children) => walk(children, [], hides(tag, attrs), sectioning.contains(tag), [])
		Root(children) => walk(children, [], Bool.False, Bool.False, [])
		_ => []
	}

walk : List(Dom), List(U64), Bool, Bool, List(Entry) -> List(Entry)
walk = |nodes, path, hidden, sectioned, start| {
	var $entries = start
	var $at = 0
	for child in nodes {
		$entries =
			match child {
				Element(tag, attrs, children) => {
					here = path.append($at)
					gone = hidden or hides(tag, attrs)
					entry = { node: child, path: here, tag, attrs, role: role_of(tag, attrs, sectioned), hidden: gone }
					walk(children, here, gone, sectioned or sectioning.contains(tag), $entries.append(entry))
				}
				_ => $entries
			}
		$at = $at + 1
	}
	$entries
}

found : List(Entry), Dom.Query -> List(Entry)
found = |entries, query|
	match query {
		Role(role) => entries.keep_if(|entry| !entry.hidden and entry.role == role)
		Named(role, name) => {
			wanted = normalize(name)
			entries.keep_if(|entry| !entry.hidden and entry.role == role and name_of(entries, entry) == wanted)
		}
		Text(text) => {
			wanted = normalize(text)
			if wanted.is_empty() {
				[]
			} else {
				entries.keep_if(|entry| !entry.hidden and !unread.contains(entry.tag) and own_text(entry.node) == wanted)
			}
		}
		Label(text) => labelled(entries, normalize(text))
		TestId(id) => entries.keep_if(|entry| value(entry.attrs, "data-testid") == Ok(id))
		Tag(tag) => {
			wanted = tag.with_ascii_lowercased()
			entries.keep_if(|entry| entry.tag == wanted)
		}
		Attr(name, wanted) => {
			lower = name.with_ascii_lowercased()
			entries.keep_if(|entry| value(entry.attrs, lower) == Ok(wanted))
		}
	}

## The form controls labelled `wanted`: by a `<label>`'s text, an `aria-label` or an
## `aria-labelledby`.
labelled : List(Entry), Str -> List(Entry)
labelled = |entries, wanted| {
	by_label =
		entries
			.keep_if(|entry| entry.tag == "label" and !entry.hidden and normalize(content(entry.node)) == wanted)
			.keep_oks(|label| target_of(entries, label))
			.map(|entry| entry.path)
	by_aria =
		entries
			.keep_if(|entry| !entry.hidden and (normalize(value(entry.attrs, "aria-label") ?? "") == wanted or labelled_by(entries, entry) == Ok(wanted)))
			.map(|entry| entry.path)
	paths = by_label.concat(by_aria)
	entries.keep_if(|entry| paths.contains(entry.path))
}

## The control a `<label>` names: the one its `for` gives the id of, or the first inside it.
target_of : List(Entry), Entry -> Try(Entry, [NotFound])
target_of = |entries, label|
	match value(label.attrs, "for") {
		Ok(id) => entries.find_first(|entry| labelable(entry) and value(entry.attrs, "id") == Ok(id))
		Err(_) => entries.find_first(|entry| labelable(entry) and inside(entry, label))
	}

labelable : Entry -> Bool
labelable = |entry| ["button", "input", "meter", "output", "progress", "select", "textarea"].contains(entry.tag) and !(entry.tag == "input" and input_type(entry.attrs) == "hidden")

inside : Entry, Entry -> Bool
inside = |entry, outer| entry.path.len() > outer.path.len() and entry.path.starts_with(outer.path)

## Its accessible name, as a screen reader says it (the W3C's accname, its common cases).
name_of : List(Entry), Entry -> Str
name_of = |entries, entry|
	match labelled_by(entries, entry) {
		Ok(name) => name
		Err(_) => {
			label = normalize(value(entry.attrs, "aria-label") ?? "")
			if (label.is_empty()) normalize(native_name(entries, entry)) else label
		}
	}

## The text of the elements its `aria-labelledby` names, in that order.
labelled_by : List(Entry), Entry -> Try(Str, [None])
labelled_by = |entries, entry| {
	ids = (value(entry.attrs, "aria-labelledby") ?? "").split_on(" ").keep_if(|id| !id.is_empty())
	if ids.is_empty() {
		Err(None)
	} else {
		texts = ids.keep_oks(|id| entries.find_first(|other| value(other.attrs, "id") == Ok(id))).map(|other| content(other.node))
		Ok(normalize(Str.join_with(texts, " ")))
	}
}

## Its name from what it is: a control's labels, an image's `alt`, a button's or a link's text…
native_name : List(Entry), Entry -> Str
native_name = |entries, entry| {
	attrs = entry.attrs
	title = value(attrs, "title") ?? ""
	kind = input_type(attrs)
	if entry.tag == "input" and ["button", "submit", "reset"].contains(kind) {
		match value(attrs, "value") {
			Ok(said) => said
			Err(_) => if (kind == "submit") "Submit" else if (kind == "reset") "Reset" else title
		}
	} else if entry.tag == "input" and kind == "image" {
		value(attrs, "alt") ?? (if (title.is_empty()) "Submit" else title)
	} else if labelable(entry) and entry.tag != "button" {
		labels = entries.keep_if(|other| other.tag == "label" and target_of(entries, other).map_ok(|target| target.path) == Ok(entry.path)).map(|label| content(label.node))
		if !labels.is_empty() {
			Str.join_with(labels, " ")
		} else if !title.is_empty() {
			title
		} else {
			value(attrs, "placeholder") ?? ""
		}
	} else if entry.tag == "img" or entry.tag == "area" {
		value(attrs, "alt") ?? title
	} else if entry.tag == "fieldset" or entry.tag == "table" or entry.tag == "figure" {
		caption = if (entry.tag == "fieldset") "legend" else if (entry.tag == "table") "caption" else "figcaption"
		match entries.find_first(|other| other.tag == caption and inside(other, entry)) {
			Ok(found_caption) => content(found_caption.node)
			Err(_) => title
		}
	} else if from_content.contains(entry.role) {
		said = normalize(name_content(entry.node))
		if (said.is_empty()) title else said
	} else {
		title
	}
}

## The roles whose name is their content: a button's text, a link's, a heading's.
from_content : List(Str)
from_content = ["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link", "listitem", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab", "tooltip", "treeitem"]

## Content as a name has it: what a reader sees, an image as its `alt`, an element with an
## `aria-label` as that.
name_content : Dom -> Str
name_content = |node|
	match node {
		Text(said) => said
		Element(tag, attrs, children) =>
			if hides(tag, attrs) {
				""
			} else {
				label = value(attrs, "aria-label") ?? ""
				if !label.is_empty() {
					" ${label} "
				} else if tag == "img" or tag == "area" {
					" ${value(attrs, "alt") ?? ""} "
				} else {
					children.fold("", |out, child| out.concat(name_content(child)))
				}
			}
		Root(children) => children.fold("", |out, child| out.concat(name_content(child)))
		Comment(_) => ""
	}

## The role an element has: its `role`'s first word, or its tag's (HTML-AAM's common cases).
role_of : Str, List((Str, Str)), Bool -> Str
role_of = |tag, attrs, sectioned| {
	written = (value(attrs, "role") ?? "").trim().split_on(" ").first() ?? ""
	if (written.is_empty()) implicit_role(tag, attrs, sectioned) else written
}

implicit_role : Str, List((Str, Str)), Bool -> Str
implicit_role = |tag, attrs, sectioned| {
	has_href = value(attrs, "href").is_ok()
	named = value(attrs, "aria-label").is_ok() or value(attrs, "aria-labelledby").is_ok()
	match tag {
		"a" | "area" => if (has_href) "link" else ""
		"button" => "button"
		"input" => input_role(attrs)
		"textarea" => "textbox"
		"select" => if (value(attrs, "multiple").is_ok()) "listbox" else "combobox"
		"option" => "option"
		"h1" | "h2" | "h3" | "h4" | "h5" | "h6" => "heading"
		"ul" | "ol" | "menu" => "list"
		"li" => "listitem"
		"nav" => "navigation"
		"main" => "main"
		"header" => if (sectioned) "" else "banner"
		"footer" => if (sectioned) "" else "contentinfo"
		"aside" => "complementary"
		"section" => if (named) "region" else ""
		"form" => "form"
		"article" => "article"
		"table" => "table"
		"tr" => "row"
		"td" => "cell"
		"th" => if (value(attrs, "scope") == Ok("row")) "rowheader" else "columnheader"
		"thead" | "tbody" | "tfoot" => "rowgroup"
		"img" => if (value(attrs, "alt") == Ok("")) "presentation" else "img"
		"dialog" => "dialog"
		"progress" => "progressbar"
		"meter" => "meter"
		"output" => "status"
		"hr" => "separator"
		"fieldset" | "details" | "optgroup" => "group"
		"figure" => "figure"
		"p" => "paragraph"
		"blockquote" => "blockquote"
		"dl" => "list"
		"dt" => "term"
		"dd" => "definition"
		_ => ""
	}
}

input_role : List((Str, Str)) -> Str
input_role = |attrs| {
	listed = value(attrs, "list").is_ok()
	match input_type(attrs) {
		"button" | "submit" | "reset" | "image" => "button"
		"checkbox" => "checkbox"
		"radio" => "radio"
		"range" => "slider"
		"number" => "spinbutton"
		"search" => if (listed) "combobox" else "searchbox"
		"hidden" | "password" | "color" | "date" | "datetime-local" | "month" | "time" | "week" | "file" => ""
		_ => if (listed) "combobox" else "textbox"
	}
}

input_type : List((Str, Str)) -> Str
input_type = |attrs| (value(attrs, "type") ?? "text").with_ascii_lowercased()

## The elements a `<header>` or `<footer>` inside is no longer the page's banner or footer.
sectioning : List(Str)
sectioning = ["article", "aside", "main", "nav", "section"]

## The elements whose text a reader never reads.
unread : List(Str)
unread = ["script", "style", "template"]

## Whether a reader can't see the element, nor what is inside it.
hides : Str, List((Str, Str)) -> Bool
hides = |tag, attrs| {
	style = (value(attrs, "style") ?? "").replace_each(" ", "").with_ascii_lowercased()
	value(attrs, "hidden").is_ok()
		or value(attrs, "aria-hidden") == Ok("true")
		or ["head", "noscript", "script", "style", "template"].contains(tag)
		or (tag == "input" and input_type(attrs) == "hidden")
		or style.contains("display:none")
		or style.contains("visibility:hidden")
}

## What `NotFound` says: what was asked, and what there is instead.
missing : List(Entry), Dom.Query -> Str
missing = |entries, query| {
	seen = entries.keep_if(|entry| !entry.hidden and !entry.role.is_empty())
	quoted = |texts| Str.join_with(texts.map(|said| "\"${said}\""), ", ")
	instead =
		match query {
			Role(_) => Str.join_with(seen.map(|entry| entry.role), ", ")
			Named(role, _) => {
				names = seen.keep_if(|entry| entry.role == role).map(|entry| name_of(entries, entry))
				if (names.is_empty()) Str.join_with(seen.map(|entry| entry.role), ", ") else quoted(names)
			}
			Label(_) => quoted(entries.keep_if(|entry| entry.tag == "label" and !entry.hidden).map(|entry| normalize(content(entry.node))))
			_ => ""
		}
	there =
		match query {
			Role(_) => "the roles here: "
			Named(role, _) => if (seen.any(|entry| entry.role == role)) "the ${role}s here: " else "the roles here: "
			Label(_) => "the labels here: "
			_ => ""
		}
	if (instead.is_empty()) "nothing is ${described(query)}" else "nothing is ${described(query)}; ${there}${instead}"
}

## The query in words.
described : Dom.Query -> Str
described = |query|
	match query {
		Role(role) => "a ${role}"
		Named(role, name) => "a ${role} named \"${name}\""
		Text(text) => "an element whose text is \"${text}\""
		Label(text) => "a control labelled \"${text}\""
		TestId(id) => "an element with data-testid=\"${id}\""
		Tag(tag) => "a <${tag}>"
		Attr(name, wanted) => "an element with ${name}=\"${wanted}\""
	}

## The value of the attribute `name` (the first, if it is written twice).
value : List((Str, Str)), Str -> Try(Str, [NotFound])
value = |attrs, name| attrs.find_first(|(written, _)| written == name).map_ok(|(_, said)| said)

## Its text, as `textContent` has it, without `<script>`, `<style>` and `<template>`.
content : Dom -> Str
content = |node|
	match node {
		Text(said) => said
		Comment(_) => ""
		Element(tag, _, children) => if (unread.contains(tag)) "" else children.fold("", |out, child| out.concat(content(child)))
		Root(children) => children.fold("", |out, child| out.concat(content(child)))
	}

## Its own text: the text directly in it, not in its elements, as Testing Library's `getByText`
## reads it.
own_text : Dom -> Str
own_text = |node|
	match node {
		Element(_, _, children) =>
			normalize(
				children.fold(
					"",
					|out, child|
						match child {
							Text(said) => out.concat(said)
							_ => out
						},
				),
			)
		_ => ""
	}

## Text as a reader sees it: each run of whitespace (no-break spaces too) one space, none at the
## ends.
normalize : Str -> Str
normalize = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $gap = Bool.False
	var $i = 0
	while $i < bytes.len() {
		byte = at(bytes, $i)
		no_break = byte == 0xC2 and at(bytes, $i + 1) == 0xA0
		blank = no_break or byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0C
		$out = if (blank) $out else if ($gap and !$out.is_empty()) $out.append(' ').append(byte) else $out.append(byte)
		$gap = blank
		$i = if (no_break) $i + 2 else $i + 1
	}
	Str.from_utf8_lossy($out)
}

# The parser.

## An element still open while parsing: its tag, its attributes, and its children so far.
Open : { tag : Str, attrs : List((Str, Str)), children : List(Dom) }

parse_bytes : List(U8) -> Dom
parse_bytes = |bytes| {
	var $open = [{ tag: "", attrs: [], children: [] }]
	var $i = 0
	while $i < bytes.len() {
		(open, next) = step(bytes, $open, $i)
		$open = open
		$i = next
	}
	closed = pop_to(pop_to($open, 1), 1)
	match closed.first() {
		Ok(top) => Root(top.children)
		Err(_) => Root([])
	}
}

## One piece of the page from `i`: text up to the next `<`, or the markup there.
step : List(U8), List(Open), U64 -> (List(Open), U64)
step = |bytes, open, i| {
	n = bytes.len()
	lt = index_of_byte(bytes, '<', i) ?? n
	if lt > i {
		(add(open, Text(decode(bytes.sublist({ start: i, len: lt - i })))), lt)
	} else {
		next = at(bytes, i + 1)
		if bytes.sublist({ start: i, len: 4 }) == "<!--".to_utf8() {
			end = index_of(bytes, "-->".to_utf8(), i + 4) ?? n
			(add(open, Comment(slice(bytes, i + 4, end))), end + 3)
		} else if next == '!' or next == '?' {
			(open, (index_of_byte(bytes, '>', i) ?? n) + 1)
		} else if next == '/' {
			name_end = span(bytes, i + 2, |byte| !is_space(byte) and byte != '>')
			end = index_of_byte(bytes, '>', name_end) ?? n
			(close(open, lower(slice(bytes, i + 2, name_end))), end + 1)
		} else if is_letter(next) {
			name_end = span(bytes, i + 1, |byte| !is_space(byte) and byte != '>' and byte != '/')
			name = lower(slice(bytes, i + 1, name_end))
			read = attributes(bytes, name_end, [])
			if read.closed or void_elements.contains(name) {
				(add(open, Element(name, read.attrs, [])), read.next)
			} else if ["script", "style", "textarea", "title"].contains(name) {
				close_at = index_of(bytes, "</${name}".to_utf8(), read.next) ?? n
				inner = bytes.sublist({ start: read.next, len: close_at - read.next })
				said = if (name == "textarea" or name == "title") decode(inner) else Str.from_utf8_lossy(inner)
				children = if (said.is_empty()) [] else [Text(said)]
				end = index_of_byte(bytes, '>', close_at) ?? n
				(add(open, Element(name, read.attrs, children)), end + 1)
			} else {
				(open.append({ tag: name, attrs: read.attrs, children: [] }), read.next)
			}
		} else {
			(add(open, Text("<")), i + 1)
		}
	}
}

## A tag's attributes from `from` to its `>`: them, whether it ended `/>`, and where after it.
attributes : List(U8), U64, List((Str, Str)) -> { attrs : List((Str, Str)), closed : Bool, next : U64 }
attributes = |bytes, from, so_far| {
	i = span(bytes, from, is_space)
	byte = at(bytes, i)
	if i >= bytes.len() {
		{ attrs: so_far, closed: Bool.False, next: i }
	} else if byte == '>' {
		{ attrs: so_far, closed: Bool.False, next: i + 1 }
	} else if byte == '/' and at(bytes, i + 1) == '>' {
		{ attrs: so_far, closed: Bool.True, next: i + 2 }
	} else if byte == '/' {
		attributes(bytes, i + 1, so_far)
	} else {
		name_end = span(bytes, i + 1, |each| !is_space(each) and each != '=' and each != '>' and each != '/')
		name = lower(slice(bytes, i, name_end))
		after_name = span(bytes, name_end, is_space)
		if at(bytes, after_name) == '=' {
			start = span(bytes, after_name + 1, is_space)
			quote = at(bytes, start)
			if quote == '"' or quote == '\'' {
				end = index_of_byte(bytes, quote, start + 1) ?? bytes.len()
				attributes(bytes, end + 1, so_far.append((name, decode(bytes.sublist({ start: start + 1, len: end - start - 1 })))))
			} else {
				end = span(bytes, start, |each| !is_space(each) and each != '>')
				attributes(bytes, end, so_far.append((name, decode(bytes.sublist({ start, len: end - start })))))
			}
		} else {
			attributes(bytes, after_name, so_far.append((name, "")))
		}
	}
}

## `node` added to the innermost open element, text joined to the text before it.
add : List(Open), Dom -> List(Open)
add = |open, node|
	match open.last() {
		Ok(top) => {
			children =
				match (top.children.last(), node) {
					(Ok(Text(before)), Text(more)) => top.children.drop_last(1).append(Text(before.concat(more)))
					_ => top.children.append(node)
				}
			open.drop_last(1).append({ ..top, children })
		}
		Err(_) => open
	}

## An end tag: the elements open inside the one it ends, and that one, closed. One that isn't open
## is ignored.
close : List(Open), Str -> List(Open)
close = |open, name|
	match open.find_last_index(|element| element.tag == name) {
		Ok(at_index) => if (at_index == 0) open else pop_to(open, at_index)
		Err(_) => open
	}

## The open elements closed until `count` are left.
pop_to : List(Open), U64 -> List(Open)
pop_to = |open, count| {
	var $open = open
	while $open.len() > count {
		$open =
			match $open.last() {
				Ok(top) => add($open.drop_last(1), Element(top.tag, top.attrs, top.children))
				Err(_) => []
			}
	}
	$open
}

void_elements : List(Str)
void_elements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

## Text with its character references (`&amp;`, `&#39;`, `&#x2014;`, `&middot;`) as the characters.
decode : List(U8) -> Str
decode = |bytes|
	if !bytes.contains('&') {
		Str.from_utf8_lossy(bytes)
	} else {
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			byte = at(bytes, $i)
			(more, next) = if (byte == '&') reference(bytes, $i) else ([byte], $i + 1)
			$out = $out.concat(more)
			$i = next
		}
		Str.from_utf8_lossy($out)
	}

## The character the reference at `i` is, and where after it; an `&` that starts none is itself.
reference : List(U8), U64 -> (List(U8), U64)
reference = |bytes, i| {
	semi = index_of_byte(bytes, ';', i + 1) ?? bytes.len()
	if semi >= bytes.len() or semi - i > 32 {
		(['&'], i + 1)
	} else {
		point = code_point(bytes.sublist({ start: i + 1, len: semi - i - 1 }))
		if (point == 0) (['&'], i + 1) else (utf8(point), semi + 1)
	}
}

## The code point a reference's name (`amp`, `#39`, `#x2014`) stands for; 0 for none.
code_point : List(U8) -> U32
code_point = |name|
	if name.first() == Ok('#') {
		digits = name.drop_first(1)
		if (digits.first() == Ok('x') or digits.first() == Ok('X')) number(digits.drop_first(1), 16) else number(digits, 10)
	} else {
		word = Str.from_utf8_lossy(name)
		match named_references.find_first(|(written, _)| written == word) {
			Ok((_, point)) => point
			Err(_) => 0
		}
	}

## Digits in `base` as a number; 0 for none, or for more than Unicode has.
number : List(U8), U32 -> U32
number = |digits, base| {
	var $value = 0
	var $fine = !digits.is_empty()
	for digit in digits {
		worth = digit_worth(digit)
		$fine = $fine and worth < base and $value <= 0x10FFFF
		$value = if ($fine) $value * base + worth else 0
	}
	if ($fine and $value <= 0x10FFFF) $value else 0
}

digit_worth : U8 -> U32
digit_worth = |digit|
	if digit >= '0' and digit <= '9' {
		(digit - '0').to_u32()
	} else if digit >= 'a' and digit <= 'f' {
		(digit - 'a').to_u32() + 10
	} else if digit >= 'A' and digit <= 'F' {
		(digit - 'A').to_u32() + 10
	} else {
		99
	}

## A code point in UTF-8.
utf8 : U32 -> List(U8)
utf8 = |point|
	if point < 0x80 {
		[point.to_u8_wrap()]
	} else if point < 0x800 {
		[(0xC0 + point // 64).to_u8_wrap(), (0x80 + point % 64).to_u8_wrap()]
	} else if point < 0x10000 {
		[(0xE0 + point // 4096).to_u8_wrap(), (0x80 + (point // 64) % 64).to_u8_wrap(), (0x80 + point % 64).to_u8_wrap()]
	} else {
		[(0xF0 + point // 262144).to_u8_wrap(), (0x80 + (point // 4096) % 64).to_u8_wrap(), (0x80 + (point // 64) % 64).to_u8_wrap(), (0x80 + point % 64).to_u8_wrap()]
	}

## The named references pages use; `rocx` writes these, and a browser may.
named_references : List((Str, U32))
named_references = [
	("amp", 38),
	("lt", 60),
	("gt", 62),
	("quot", 34),
	("apos", 39),
	("nbsp", 160),
	("middot", 183),
	("mdash", 8212),
	("ndash", 8211),
	("hellip", 8230),
	("copy", 169),
	("reg", 174),
	("trade", 8482),
	("times", 215),
	("minus", 8722),
	("larr", 8592),
	("rarr", 8594),
	("uarr", 8593),
	("darr", 8595),
	("laquo", 171),
	("raquo", 187),
	("lsquo", 8216),
	("rsquo", 8217),
	("ldquo", 8220),
	("rdquo", 8221),
	("bull", 8226),
	("deg", 176),
	("plusmn", 177),
	("para", 182),
	("sect", 167),
	("euro", 8364),
	("pound", 163),
	("yen", 165),
	("cent", 162),
	("shy", 173),
	("ensp", 8194),
	("emsp", 8195),
	("thinsp", 8201),
	("zwj", 8205),
	("zwnj", 8204),
	("check", 10003),
	("star", 9734),
]

at : List(U8), U64 -> U8
at = |bytes, i| bytes.get(i) ?? 0

## The bytes from `from` to `to`, as text.
slice : List(U8), U64, U64 -> Str
slice = |bytes, from, to| if (to <= from) "" else Str.from_utf8_lossy(bytes.sublist({ start: from, len: to - from }))

## Where the bytes from `from` stop being ones `keep` keeps.
span : List(U8), U64, (U8 -> Bool) -> U64
span = |bytes, from, keep| {
	var $i = from
	while $i < bytes.len() and keep(at(bytes, $i)) {
		$i = $i + 1
	}
	$i
}

index_of_byte : List(U8), U8, U64 -> Try(U64, [NotFound])
index_of_byte = |bytes, wanted, from| {
	end = span(bytes, from, |byte| byte != wanted)
	if (end < bytes.len()) Ok(end) else Err(NotFound)
}

index_of : List(U8), List(U8), U64 -> Try(U64, [NotFound])
index_of = |bytes, wanted, from| {
	var $i = from
	var $found = Err(NotFound)
	while $found.is_err() and $i + wanted.len() <= bytes.len() {
		$found = if (bytes.sublist({ start: $i, len: wanted.len() }) == wanted) Ok($i) else $found
		$i = $i + 1
	}
	$found
}

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0C

is_letter : U8 -> Bool
is_letter = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')

lower : Str -> Str
lower = |text| text.with_ascii_lowercased()

# Tests.

## A page as Roc Solid renders one: a form, a list, a table, hidden parts, holes' comments.
sample : Dom
sample = Dom.parse(
	Str.join_with(
		[
			"<!doctype html><html lang=\"en\"><head><title>Groceries &middot; Shop</title><style>p > a { color: red }</style></head>",
			"<body><header><nav aria-label=\"Main\"><a href=\"/\">Home</a> <a href=\"/about\" class=\"nav current\">About</a></nav></header>",
			"<main><h1>Groceries</h1><!--loading--><p data-testid=\"total\">Total: <b>3</b></p><!--/loading-->",
			"<ul aria-label=\"List\"><li>Milk</li><li class=\"done\">Eggs &amp; ham</li><li hidden>Gone</li></ul>",
			"<form><label for=\"item\">New item</label><input id=\"item\" name=\"item\" placeholder=\"What?\">",
			"<label><input type=\"checkbox\" checked> Urgent</label>",
			"<input type=\"submit\" value=\"Add\"><button type=\"button\" aria-label=\"Clear all\">&times;</button>",
			"<button><img src=\"/x.svg\" alt=\"Remove\"></button><textarea aria-labelledby=\"note-label\">a &lt;b&gt;</textarea><span id=\"note-label\">Note</span></form>",
			"<article><header><h2>Recipe</h2></header><table><tr><th>Name</th></tr><tr><td>Bread</td></tr></table></article>",
			"<div aria-hidden=\"true\"><button>Hidden</button></div><div style=\"display: none\"><p>Not shown</p></div>",
			"<script>if (a < b && c > d) { done() }</script><p>Tom &amp; &#39;Jerry&#39; &#x2014;&nbsp; &lt;b&gt; &bogus; & more</p></main>",
			"<footer><p>Made with Roc</p></footer></body></html>",
		],
		"",
	),
)

expect sample.text_of(Role("heading")) == Err(TooMany("2 elements are a heading"))
expect sample.texts(Role("heading")) == ["Groceries", "Recipe"]
expect sample.text_of(Named("heading", "Recipe")) == Ok("Recipe")
expect sample.texts(Role("link")) == ["Home", "About"]
expect sample.get(Named("link", "About")).map_ok(|link| link.attr("href")) == Ok(Ok("/about"))
expect sample.get(Named("link", "About")).map_ok(|link| link.has_class("current") and !link.has_class("cur")) == Ok(Bool.True)
expect sample.texts(Role("listitem")) == ["Milk", "Eggs & ham"]
expect sample.get(Named("list", "List")).map_ok(|list| list.count(Role("listitem"))) == Ok(2)
expect sample.contains(Named("navigation", "Main"))
expect sample.count(Role("banner")) == 1 and sample.count(Role("contentinfo")) == 1
expect sample.contains(Named("textbox", "New item"))
expect sample.get(Label("New item")).map_ok(|input| input.attr("name")) == Ok(Ok("item"))
expect sample.get(Named("checkbox", "Urgent")).map_ok(|box| box.attr("checked")) == Ok(Ok(""))
expect sample.get(Label("Urgent")).map_ok(|box| box.tag()) == Ok("input")
expect sample.contains(Named("button", "Add")) and sample.contains(Named("button", "Clear all")) and sample.contains(Named("button", "Remove"))
expect sample.get(Label("Note")).map_ok(|area| area.text()) == Ok("a <b>")
expect sample.contains(Named("textbox", "Note"))
expect !sample.contains(Named("button", "Hidden")) and !sample.contains(Text("Not shown")) and !sample.contains(Text("Gone"))
expect sample.contains(Tag("title")) and sample.text_of(Tag("title")) == Ok("Groceries · Shop")
expect !sample.contains(Text("Groceries · Shop"))
expect sample.text_of(TestId("total")) == Ok("Total: 3")
expect sample.text_of(Text("Total:")) == Ok("Total: 3")
expect sample.texts(Attr("href", "/")) == ["Home"]
expect sample.texts(Role("cell")) == ["Bread"] and sample.texts(Role("columnheader")) == ["Name"]
expect sample.text_of(Text("Tom & 'Jerry' — <b> &bogus; & more")) == Ok("Tom & 'Jerry' — <b> &bogus; & more")
expect !sample.contains(Text("if (a < b && c > d) { done() }"))
expect sample.get(Tag("script")).map_ok(|script| script.text()) == Ok("")
expect sample.get(Named("button", "Save")) == Err(NotFound("nothing is a button named \"Save\"; the buttons here: \"Add\", \"Clear all\", \"Remove\""))
expect sample.get(Named("tab", "One")) == Err(NotFound("nothing is a tab named \"One\"; the roles here: banner, navigation, link, link, main, heading, paragraph, list, listitem, listitem, form, textbox, checkbox, button, button, button, img, textbox, article, heading, table, row, columnheader, row, cell, paragraph, contentinfo, paragraph"))
expect sample.get(Label("Name")) == Err(NotFound("nothing is a control labelled \"Name\"; the labels here: \"New item\", \"Urgent\""))
expect sample.get(TestId("none")) == Err(NotFound("nothing is an element with data-testid=\"none\""))
expect sample.roles().take_first(3) == [("banner", ""), ("navigation", "Main"), ("link", "Home")]

# The parser's edges.
expect Dom.parse("a <b>bold</b> <i>c</B> d").text() == "a bold c d"
expect Dom.parse("<p>one<p>two").texts(Role("paragraph")) == ["onetwo", "two"]
expect Dom.parse("<p>1 < 2 and 3 > 2</p>").text() == "1 < 2 and 3 > 2"
expect Dom.parse("<div title=bare data-x = 'single \"q\"' hidden></div>").get(Tag("div")).map_ok(|div| (div.attr("title"), div.attr("data-x"), div.attr("hidden"), div.attr("nope"))) == Ok((Ok("bare"), Ok("single \"q\""), Ok(""), Err(Missing)))
expect Dom.parse("<br/><img src=x /><p>after</p>").count(Tag("p")) == 1
expect Dom.parse("<p>&#128512; &#xE9;&eacute;</p>").text() == "😀 é&eacute;"
expect Dom.parse("<style>a{}</style><p>x</p><!-- note <p>not</p> -->").count(Tag("p")) == 1
expect Dom.parse("").text() == "" and Dom.parse("<").text() == "<"
expect Dom.parse("<p>a<b>c</b></p>") == Dom.parse("<p>a<b>c</b>") and Dom.parse("<p>a</p>") != Dom.parse("<p>b</p>")
expect Dom.parse("<P CLASS=\"A\">Up</P>").get(Tag("p")).map_ok(|p| p.attr("class")) == Ok(Ok("A"))
