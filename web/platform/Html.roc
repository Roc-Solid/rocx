import Host
import Transition

## Markup in which holes are computations. A component builds it once; the runtime runs each hole
## (`text_of`, `html_of`, `list_of`, `attr_of`…) and runs it again when what it read changes,
## patching only its own node. Handlers are effects (`on`), not messages. A hole that reads nothing
## that changes is static (`text`, `attr`, `class_if`…): written once, with nothing to run.
Html :: [
	Element(Str, List(Html.Attr), List(Html)),
	Void(Str, List(Html.Attr)),
	Text(Str),
	Raw(Str),
	Doctype,
	TextOf(() => Str),
	HtmlOf(() => Html),
	HoleOf(() => Html),
	ListOf(() => List(Html)),
	Fragment(List(Html)),
	Loading(Html, List(Html)),
	Errored((Str, (() => {}) -> Html), List(Html)),
	Switched(() => Try(Str, [None]), () => Html, Html),
	Branched(() => Try(Str, [None]), () => Html),
	Each(U64 => List({ key : Str, row : () => Html }), Html),
	Component(() => Html),
	Provided(Str, U64, List(Html)),
	NoHydration(List(Html)),
	Listen(Str, List(Html.Attr)),
].{
	Attr := [
		Value(Str, Str),
		ValueOf(Str, () => Str),
		Optional(Str, Str),
		OptionalOf(Str, () => Str),
		Flag(Str, Bool),
		FlagOf(Str, () => Bool),
		ClassIf(Str, Bool),
		ClassOf(Str, () => Bool),
		StyleVar(Str, Str),
		StyleOf(Str, () => Str),
		On(Str, () => {}),
		OnValue(Str, Str => {}),
		OnChecked(Str, Bool => {}),
		OnKey(Str, Str => {}),
		OnKeys(Str, Html.Keys => {}),
		OnNamedKey(Str, Str, () => {}),
		OnPrevent(Str, () => {}),
		OnFrame(F64 => {}),
		OnViewport(Html.Viewport => {}),
		OnPoint(Str, Html.Point => {}),
		OnData(Str, List(Html.DragItem) => {}),
		OnFiles(Str, List(Html.File) => {}),
		DragData(List((Str, Str))),
		DragDataOf(() => List((Str, Str))),
		DragImage(Str),
		DragImageOf(() => Str),
		Key(Str),
		KeyOf(() => Str),
		Animate([In, Out, Both, Move], Transition),
		AnimateOf([In, Out, Both, Move], () => Transition),
	]

	## A key pressed, and the modifier keys held with it (`on:keydown.keys={|keys| …}`): the key as
	## the browser names it (`event.key`: `"k"`, `"K"` with Shift, `"Enter"`, `"ArrowUp"`), and
	## whether each modifier key was held. `mod` is ⌘ on macOS and Ctrl elsewhere: `meta` there,
	## `ctrl` here.
	Keys : { key : Str, shift : Bool, ctrl : Bool, alt : Bool, meta : Bool, mod : Bool }

	## What of an element's content shows (`on:viewport={|view| …}`), in whole pixels: how far it is
	## scrolled (`top`, `left`: `scrollTop`, `scrollLeft`), and the width and height it shows inside
	## its borders (`width`, `height`: `clientWidth`, `clientHeight`). A virtual list reads it to
	## render only the rows that show.
	Viewport : { top : U64, left : U64, width : U64, height : U64 }

	## Where the pointer is over an element (`on:pointermove.point={|point| …}`): shares of its box's
	## width and height, from 0 (its left, its top) to 1 (its right, its bottom), to thousandths, so the
	## same place on a narrow screen and a wide one is the same point. Live cursors send it.
	Point : { x : Dec, y : Dec }

	## A piece of what a drag carries, by its type (`on:drop.data={|items| …}`): `text/plain`,
	## `text/uri-list`, `text/html`, or an app's own (`application/x-acme-card+json`), as another page
	## or program put it there, or a `drag:data={…}` here.
	DragItem : { type : Str, value : Str }

	## A file dropped, pasted or chosen (`on:drop.files={|files| …}`, `on:change.files` on an
	## `<input type="file">`): its name, its type (`image/png`; `""` when the browser can't tell), its
	## size in bytes, and a `blob:` URL the page reads it by while the element that took it is there
	## (`<img src={file.url}>` shows a picture). An action sends it (its URL is a form field's value).
	File : { name : Str, type : Str, size : U64, url : Str }

	text : Str -> Html
	text = |content| Text(content)

	text_of : (() => Str) -> Html
	text_of = |compute| TextOf(compute)

	## The static text of a `.rocx` file's `<script>` or `<style>`, as written. Only rocx writes this,
	## and `rocx lint` refuses it in hand-written code: it is source, never data.
	source_text : Str -> Html
	source_text = |content| Raw(content)

	## `<!doctype html>`, as a page's document begins.
	doctype : {} -> Html
	doctype = |{}| Doctype

	html_of : (() => Html) -> Html
	html_of = |compute| HtmlOf(compute)

	## What a hole (`{x}`, D-070) shows of its value, by its type: text (escaped), a number's digits
	## (`{count}`), or markup as it is. rocx writes `Html.hole(x)` for a hole that reads nothing
	## that changes, and `Html.hole_of(|| Html.hole(x))` for one that does; the compiler picks what to do from
	## `x`'s type, through Roc's encoding: `Str.encode(Hole)` is `Hole.encode_str`, a number's is
	## its `encode_*`, and `Html.encode` is the markup itself. A value of another type (a record, a
	## `Bool`) is a compile error at the hole: it has no `encode`, or `Hole` no `encode_*` for it.
	hole : a -> Html where [a.encode : a, Html.Hole -> Try(Html, [])]
	hole = |value|
		match value.encode(Hole) {
			Ok(markup) => markup
		}

	## A hole that reads what changes, run again when it does: rocx writes `Html.hole_of(|| Html.hole(x))`.
	## While what it shows is text alone, the runtime patches the text, as a text hole's
	## (`<!--x-->`); when it is markup, it is a markup hole's range (`<!--html-->`).
	hole_of : (() => Html) -> Html
	hole_of = |compute| HoleOf(compute)

	## What a name a `match` arm binds reads (D-070: rocx makes it a getter, so the arm stays while
	## its value changes) once its arm no longer holds: never, as the arm is made again first; if it
	## ever is, a failure, the nearest `<Errored>`'s.
	unmatched! : Str => a
	unmatched! = |why| {
		Host.fail!(why)
		crash "unreachable: fail! doesn't return"
	}

	## Markup in a hole is itself.
	encode : Html, Html.Hole -> Try(Html, [])
	encode = |self, _| Ok(self)

	## The format a hole encodes its value in (`Html.hole`): text as a text node, a number as its
	## digits. Nothing else: a hole showing a `Bool` or a record is a compile error.
	Hole := [Hole].{
		encode_str : Html.Hole, Str -> Try(Html, [])
		encode_str = |_, words| Ok(Text(words))

		encode_u8 : Html.Hole, U8 -> Try(Html, [])
		encode_u8 = |_, number| Ok(Text(number.to_str()))

		encode_u16 : Html.Hole, U16 -> Try(Html, [])
		encode_u16 = |_, number| Ok(Text(number.to_str()))

		encode_u32 : Html.Hole, U32 -> Try(Html, [])
		encode_u32 = |_, number| Ok(Text(number.to_str()))

		encode_u64 : Html.Hole, U64 -> Try(Html, [])
		encode_u64 = |_, number| Ok(Text(number.to_str()))

		encode_u128 : Html.Hole, U128 -> Try(Html, [])
		encode_u128 = |_, number| Ok(Text(number.to_str()))

		encode_i8 : Html.Hole, I8 -> Try(Html, [])
		encode_i8 = |_, number| Ok(Text(number.to_str()))

		encode_i16 : Html.Hole, I16 -> Try(Html, [])
		encode_i16 = |_, number| Ok(Text(number.to_str()))

		encode_i32 : Html.Hole, I32 -> Try(Html, [])
		encode_i32 = |_, number| Ok(Text(number.to_str()))

		encode_i64 : Html.Hole, I64 -> Try(Html, [])
		encode_i64 = |_, number| Ok(Text(number.to_str()))

		encode_i128 : Html.Hole, I128 -> Try(Html, [])
		encode_i128 = |_, number| Ok(Text(number.to_str()))

		encode_f32 : Html.Hole, F32 -> Try(Html, [])
		encode_f32 = |_, number| Ok(Text(number.to_str()))

		encode_f64 : Html.Hole, F64 -> Try(Html, [])
		encode_f64 = |_, number| Ok(Text(number.to_str()))

		encode_dec : Html.Hole, Dec -> Try(Html, [])
		encode_dec = |_, number| Ok(Text(number.to_str()))
	}

	list_of : (() => List(Html)) -> Html
	list_of = |compute| ListOf(compute)

	## Several, side by side: what a fragment (`<>…</>`) is, for plain Roc code.
	join : List(Html) -> Html
	join = |parts| Fragment(parts)

	## Nothing: the empty fragment (`<></>`), for plain Roc code.
	empty : {} -> Html
	empty = |{}| Fragment([])

	element : Str, List(Attr), List(Html) -> Html
	element = |tag, attrs, children| Element(tag, attrs, children)

	void : Str, List(Attr) -> Html
	void = |tag, attrs| Void(tag, attrs)

	attr : Str, Str -> Attr
	attr = |name, value| Value(name, value)

	attr_of : Str, (() => Str) -> Attr
	attr_of = |name, compute| ValueOf(name, compute)

	## An attribute that is there only when its value isn't empty (`name??={…}`), as Svelte leaves
	## out one whose value is undefined.
	optional : Str, Str -> Attr
	optional = |name, value| Optional(name, value)

	## The same, computed: there only while its value isn't empty.
	optional_of : Str, (() => Str) -> Attr
	optional_of = |name, compute| OptionalOf(name, compute)

	## One property of the element's `style` (`style:color={…}`), or a custom property
	## (`style:--size={…}`), joining its static `style`. Data can't write CSS: a name that isn't
	## letters and dashes (or `--` and letters, digits, `_` and `-`) is dropped, and so is a value
	## with anything but letters, digits, spaces and `.,%#()-+` in it, or a function that isn't one
	## that computes a value (`rgb(…)`, `calc(…)`, `var(…)`; never `url(…)`). In `Html.to_str` too,
	## so an email's colour may come from data, as email clients want it: inline, no variables.
	style_var : Str, Str -> Attr
	style_var = |name, value| StyleVar(name, value)

	## The same, computed (`style:color={…}` reading a signal), patched as it changes.
	style_of : Str, (() => Str) -> Attr
	style_of = |name, compute| StyleOf(name, compute)

	flag : Str, Bool -> Attr
	flag = |name, is_on| Flag(name, is_on)

	flag_of : Str, (() => Bool) -> Attr
	flag_of = |name, compute| FlagOf(name, compute)

	## The class `name` when `is_on` is true (`class:name={…}`), joining the element's other classes.
	class_if : Str, Bool -> Attr
	class_if = |name, is_on| ClassIf(name, is_on)

	class_of : Str, (() => Bool) -> Attr
	class_of = |name, compute| ClassOf(name, compute)

	on : Str, (() => {}) -> Attr
	on = |event, handler| On(event, handler)

	on_value : Str, (Str => {}) -> Attr
	on_value = |event, handler| OnValue(event, handler)

	on_checked : Str, (Bool => {}) -> Attr
	on_checked = |event, handler| OnChecked(event, handler)

	## A handler given the key pressed (`on:keydown.key={|key| …}`).
	on_key : Str, (Str => {}) -> Attr
	on_key = |event, handler| OnKey(event, handler)

	## A handler given the key pressed and the modifier keys held (`on:keydown.keys={|keys| …}`):
	## `if keys.mod and keys.key == "Enter" …`.
	on_keys : Str, (Html.Keys => {}) -> Attr
	on_keys = |event, handler| OnKeys(event, handler)

	## A handler for one key (`on:keydown.ArrowUp={…}`), pressed with no modifier key held, or for a
	## combination (`on:keydown.Shift+Enter`, `Mod+K`), pressed with exactly those held: Shift+Enter
	## isn't Enter. `wanted` is the key's name, as the browser has it, after the modifier keys
	## (`Shift`, `Ctrl`, `Alt`, `Meta`, and `Mod`: ⌘ on macOS, Ctrl elsewhere), joined by `+`. A
	## letter is the same in either case, and is the key in its place on the keyboard when the
	## layout types something else there (Alt+K on macOS types ˚). The browser doesn't also do what
	## the key would (an arrow key a game takes doesn't scroll the page; ⌘K doesn't focus its search).
	on_named_key : Str, Str, (() => {}) -> Attr
	on_named_key = |event, wanted, handler| OnNamedKey(event, wanted, handler)

	## A handler that takes over what the browser would do (`on:click.prevent={…}`): the event's
	## default is prevented before it runs, so a link's click goes where the handler says, not to its
	## `href`.
	on_prevent : Str, (() => {}) -> Attr
	on_prevent = |event, handler| OnPrevent(event, handler)

	## A handler run every animation frame while the element is on the page (`on:frame.ms={|ms| …}`),
	## given the milliseconds since the last one (at most 100: a tab that comes back resumes, rather
	## than jumps).
	on_frame : (F64 => {}) -> Attr
	on_frame = |handler| OnFrame(handler)

	## A handler given what of the element's content shows (`on:viewport={|view| …}`, a
	## `Html.Viewport`): once the element is on the page, then each time it scrolls or changes size, at
	## most once an animation frame. Nothing runs on the server, which can't measure: render a first
	## view the server and the browser agree on, and let the handler's measure replace it.
	on_viewport : (Html.Viewport => {}) -> Attr
	on_viewport = |handler| OnViewport(handler)

	## A handler given where the pointer is over the element (`on:pointermove.point={|point| …}`, a
	## `Html.Point`: shares of its box). For `pointermove` (and `mousemove`, `touchmove`), at most once an
	## animation frame, with the latest place: a pointer that moves 240 times a second runs it 60 times.
	on_point : Str, (Html.Point => {}) -> Attr
	on_point = |event, handler| OnPoint(event, handler)

	## A handler given whether the page shows (`<Document on:visibilitychange.visible={|shown| …} />`):
	## false when its tab is hidden (another tab, the window minimised, the screen locked), true when it
	## shows again.
	on_visible : Str, (Bool => {}) -> Attr
	on_visible = |event, handler| OnChecked(event, handler)

	## A handler given every piece a drag carries but its files (`on:drop.data={|items| …}`), each by
	## its type, in the order they were put on it; a paste's too (`on:paste.data`). `on:drop.value` is
	## its `text/plain` alone.
	on_data : Str, (List(Html.DragItem) => {}) -> Attr
	on_data = |event, handler| OnData(event, handler)

	## A handler given the files dropped (`on:drop.files={|files| …}`), pasted (`on:paste.files`), or
	## chosen in an `<input type="file">` (`on:change.files`): `Html.File`s, each read by its `blob:`
	## URL, which goes when the element that took it does.
	on_files : Str, (List(Html.File) => {}) -> Attr
	on_files = |event, handler| OnFiles(event, handler)

	## What the element's drag carries for other pages and programs (`drag:data={[("text/uri-list",
	## url), ("text/plain", title)]}`), each by its type, put on it as the drag starts: a link dropped in
	## another tab opens, a title in an editor is typed. A drop on this page reads it with
	## `on:drop.data`.
	drag_data : List((Str, Str)) -> Attr
	drag_data = |items| DragData(items)

	## The same, computed: what it says as the drag starts.
	drag_data_of : (() => List((Str, Str))) -> Attr
	drag_data_of = |compute| DragDataOf(compute)

	## What a drag of the element shows under the pointer (`drag:image={"ghost-${card.id}"}`): the
	## element with that `id` (hidden or not), drawn as the drag starts, held where the element was
	## taken (a card grabbed a third of the way across is held a third of the way across its image).
	## The same image follows a finger (a drag by touch or a pen).
	drag_image : Str -> Attr
	drag_image = |id| DragImage(id)

	## The same, computed.
	drag_image_of : (() => Str) -> Attr
	drag_image_of = |compute| DragImageOf(compute)

	## The element's name on the page (`key={card.id}`): where one with a key goes and another with the
	## same key comes, in one change of the page, it is the same element, moved, and with
	## `transition:move` it glides from the one's place to the other's. Any value (`key_text`): on a
	## `.map` row's root, it is the row's key too (D-071).
	key : a -> Attr
	key = |id| Key(Html.key_text(id))

	## The same, computed (`key={card.id}` in a `.map`'s row, whose name is a getter).
	key_of : (() => a) -> Attr
	key_of = |compute| KeyOf(|| Html.key_text(compute()))

	## A key as text: a string as it is, any other value as `Str.inspect` writes it (`7`, `Done`).
	key_text : a -> Str
	key_text = |id| {
		inspected = Str.inspect(id)
		if inspected.starts_with("\"") and inspected.ends_with("\"") and inspected != "\"" {
			inspected.drop_prefix("\"").drop_suffix("\"")
		} else {
			inspected
		}
	}

	## An animation the element plays as it comes with a `.map`'s row or the part an `if` or `match` makes (`In`,
	## `transition:in={…}`), as it goes with one (`Out`, `transition:out={…}`), or both (`Both`,
	## `transition={…}`); or as it moves (`Move`, `transition:move={…}`: only its pace counts). See
	## `Transition`.
	transition : [In, Out, Both, Move], Transition -> Attr
	transition = |way, animation| Animate(way, animation)

	## The same, computed (it reads a signal or an accessor): the one it says when the element comes
	## or goes is the one played.
	transition_of : [In, Out, Both, Move], (() => Transition) -> Attr
	transition_of = |way, compute| AnimateOf(way, compute)

	loading : Html, List(Html) -> Html
	loading = |fallback, children| Loading(fallback, children)

	errored : (Str, (() => {}) -> Html), List(Html) -> Html
	errored = |fallback, children| Errored(fallback, children)

	## The part a hole's `if` or `match` makes, as Solid's `<Show>` and `<Switch>` make
	## theirs: `case!` names the branch that holds (`Ok(name)`; `Err(None)`: none, the fallback), and a
	## change of the name makes the part anew; `made!` makes the branch's part, as a component is made
	## (where it is rendered, once, its reads untracked). A level of the page (D-040) is one too.
	switched : (() => Try(Str, [None])), (() => Html), Html -> Html
	switched = |case!, made!, fallback| Switched(case!, made!, fallback)

	## What rocx writes for a hole's `if` or `match` that reads what changes (D-070): the part the
	## branch `case!` names makes (`made!`), made anew when the name changes, as `switched`'s is; but
	## no level of the page (D-040), so a read of where it is in it belongs to the level around it.
	branched : (() => Try(Str, [None])), (() => Html) -> Html
	branched = |case!, made!| Branched(case!, made!)

	## Rows, by key (`rows!`, `rows_at!`): `rows!`, given the list's id, says which rows there are
	## now, and how to make each; the runtime keeps a row while its key is there, and moves it.
	each : (U64 => List({ key : Str, row : () => Html })), Html -> Html
	each = |made!, fallback| Each(made!, fallback)

	## What rocx writes for a hole's `.map` whose list reads what changes (D-071):
	##
	##     {...todos!().map(|todo| <li key={todo.id}>{todo.text}</li>)}
	##
	## is a row per key (the row's root's `key`), made once, moved as the list changes, and dropped
	## with its key, as Solid 2.0's `<For>` keeps them. Roc's values have no identity, so the row says
	## its key. The row's name reads its item now (rocx makes it a getter, as a match arm's names), and
	## `.map_with_index(|todo, i| …)`'s index, which changes as rows move, too. `keyed` may read what
	## changes. Each time the list is read again, a row is told its item changed only when it isn't `==`
	## the one it had, and then its holes that read it run again (a value a node has already is no patch).
	rows! : (() => List(a)), (a => k), ((() => a), (() => U64) => Html) => Html where [a.is_eq : a, a -> Bool]
	rows! = |items!, keyed, make| {
		rows_now! = |id| {
			items = items!()
			var $inspected = List.with_capacity(items.len())
			for item in items {
				$inspected = $inspected.append(Html.key_text(keyed(item)))
			}
			keys = Html.row_keys($inspected)
			var $rows = List.with_capacity(items.len())
			var $index = 0.U64
			for item in items {
				row_key = keys.get($index) ?? $index.to_str()
				$rows = $rows.append(Html.row!(id, row_key, item, |item!| make(item!, || Host.row_index!(id, row_key))))
				$index = $index + 1
			}
			$rows
		}
		Each(rows_now!, Html.empty({}))
	}

	## A `.map_with_index` whose row's key is its index (`key={i}`, D-071): a row per position (Solid's
	## old `<Index>`), its name reading the item there now; its index, the position's, a value.
	rows_at! : (() => List(a)), ((() => a), U64 => Html) => Html where [a.is_eq : a, a -> Bool]
	rows_at! = |items!, make| {
		rows_now! = |id| {
			var $rows = []
			var $index = 0.U64
			for item in items!() {
				at = $index
				$rows = $rows.append(Html.row!(id, at.to_str(), item, |item!| make(item!, at)))
				$index = $index + 1
			}
			$rows
		}
		Each(rows_now!, Html.empty({}))
	}

	## A row: its item kept by the host under its key (so the row's name reads the item there now),
	## and how to make the row.
	row! : U64, Str, a, ((() => a) => Html) => { key : Str, row : () => Html } where [a.is_eq : a, a -> Bool]
	row! = |id, row_key, item, make| {
		boxed = Box.box(|| item)
		last = Box.unbox(Host.row_last!(id, row_key, boxed))
		Host.row_set!(id, row_key, boxed, last() == item)
		item! = || {
			current = Box.unbox(Host.row_get!(id, row_key))
			current()
		}
		{ key: row_key, row: || make(item!) }
	}

	## The keys, each once: the second of two equal keys is another row (`#1`), and so on. How many of
	## each came before is a `Dict`'s, so a list of ten thousand rows takes ten thousand lookups.
	row_keys : List(Str) -> List(Str)
	row_keys = |keys| {
		var $seen = Dict.empty()
		var $out = List.with_capacity(keys.len())
		for one in keys {
			count = $seen.get(one) ?? 0.U64
			$seen = $seen.insert(one, count + 1)
			$out = $out.append(if (count == 0) one else "${one}#${count.to_str()}")
		}
		$out
	}

	## A component, as Solid runs one: where it is rendered, once, its reads not tracked. rocx writes
	## a component's call (`<Picks />`) inside one, so what it reads from a context is what is above
	## the place it is rendered. Its value props are getters (D-039): `<Shows label={word!()} />` is
	## `Html.component(|| Shows.view!({ label: || word!() }))`, and the component reads `label!()`
	## where its code reads `label`, so a hole that reads it is patched and the component is kept.
	component : (() => Html) -> Html
	component = |run!| Component(run!)

	## Reads, saying where (`Ui/Chart.rocx:44:39`): a dev build (`rocx dev`, `rocx build --dev`) writes
	## each accessor a component's body calls (`goal!()`) as `Html.read_at!("…", goal!)`, so the
	## browser's runtime can say where a read made once, as the component runs, is (Solid 2.0's dev
	## warning: what shows won't follow it). rocx writes this; any other build has none.
	read_at! : Str, (() => a) => a
	read_at! = |place, read!| {
		outer = Host.read_at!(place)
		value = read!()
		_ = Host.read_at!(outer)
		value
	}

	## The document's title (`<Title>`, `Title.view!`): the text `children` say (their text, and
	## what their holes compute), told to the runtime by a hole of its own, which renders nothing,
	## so it is told again when what it read changes, and taken back when its part goes. The last
	## one rendered that is still there is the title: in the browser `document.title`, and, as the
	## server renders a page, a `<title data-rocx>` it puts first in `<head>`, before the root
	## layout's own `<title>`, which stands when there is none.
	document_title : List(Html) -> Html
	document_title = |children|
		TextOf(
			|| {
				Host.title!(plain!(children))
				""
			},
		)

	## `<Meta>`, `<Link>` and `<Style>` (@solidjs/meta's): `tag`, an element (rocx writes it, its
	## attributes an element's: `<Meta name="description" content={post!().summary} />`) in the
	## document's `<head>`, from anywhere in the page, while it is rendered. A text hole of its own
	## that renders nothing where it is (`<!--x--><!--/x-->`), whose run computes the element's
	## attributes and text (so it tracks what they read) and tells the runtime its markup
	## (`Host.head!`). They are in the order they first ran (a layout's before its page's), before
	## `</head>`; a `<Meta>` with the same `name` (or `property`), `http-equiv`, `charset` or
	## `itemprop`, and `media`, as one before it takes that one's place, as @solidjs/meta's do. A
	## `<Link>` or a `<Style>` is never taken out for another.
	document_head : Html -> Html
	document_head = |tag|
		TextOf(
			|| {
				now = head_filled!(tag)
				Host.head!(head_key(now), head_markup(now))
				""
			},
		)

	## Handlers on the whole document (`<Document on:keydown.Mod+K={open!} />`), written as an
	## element's are (any but `on:frame.ms`): attached where it is rendered, and taken off when that
	## goes (an `if`'s branch switched, a row going), as Solid's `makeEventListener` is. Nothing on the
	## page, on the server or in the browser.
	on_document : List(Attr) -> Html
	on_document = |handlers| Listen("document", handlers)

	## The same, on the window (`<Window on:resize={…} />`): its resizes, its scrolls, `online` and
	## `offline`.
	on_window : List(Attr) -> Html
	on_window = |handlers| Listen("window", handlers)

	## What is inside, given a context's value (its name, and the id the runtime keeps it by).
	provided : Str, U64, List(Html) -> Html
	provided = |name, value, children| Provided(name, value, children)

	## What is inside, rendered on the server only (`<NoHydration>`, Solid's name): as static markup,
	## every hole run once and written without its comments, between `<!--nohydration-->` and
	## `<!--/nohydration-->`. The browser keeps the server's nodes there and never builds, adopts or
	## patches them. In the browser's copy of a `.rocx` file, rocx leaves this with no children (a
	## placeholder), so what is inside isn't in the wasm. A handler inside would never run: rocx
	## refuses one written inside, and the server refuses to render one a component put there.
	no_hydration : List(Html) -> Html
	no_hydration = |children| NoHydration(children)

	## Markup with nothing to run in it as HTML, as the server renders it: an email's HTML, or what
	## an `expect` compares. A computation (a hole that reads a signal), an `if`'s part, a `.map`'s rows
	## or a component needs the runtime: here it is an error.
	to_str : Html -> Str
	to_str = |node| static_str(node, Bool.False)

	## The markup as JSON for the runtime, each computation, handler and fallback kept by it (its id
	## in the JSON). Static parts are plain: `{"t":"e","tag":…,"a":[…],"c":[…]}`, `{"t":"s","v":…}`,
	## `{"t":"raw","v":…}` (a `<script>`'s or `<style>`'s text, as written), `{"t":"doctype"}`;
	## holes name what they run: `{"t":"x","r":id}` text, `{"t":"h","r":id}` markup, `{"t":"hx","r":id}`
	## either (`Html.hole_of`: its run answers a JSON string while it shows text alone, else markup), `{"t":"l","r":id}` a list; boundaries hold their parts, and so does `{"t":"nh","c":[…]}`, a `<NoHydration>`.
	serialize! : Html => Str
	serialize! = |node|
		match node {
			Element(tag, attrs, children) => "{\"t\":\"e\",\"tag\":${json_str(tag)},\"a\":[${attributes!(tag, unfilled(tag, attrs))}],\"c\":[${nodes!(children)}]}"
			Void(tag, attrs) => "{\"t\":\"e\",\"tag\":${json_str(tag)},\"a\":[${attributes!(tag, unfilled(tag, attrs))}],\"c\":[]}"
			Text(content) => "{\"t\":\"s\",\"v\":${json_str(content)}}"
			Raw(content) => "{\"t\":\"raw\",\"v\":${json_str(content)}}"
			Doctype => "{\"t\":\"doctype\"}"
			TextOf(compute) => "{\"t\":\"x\",\"r\":${keep!(|| json_str(compute()))}}"
			HtmlOf(compute) => "{\"t\":\"h\",\"r\":${keep!(|| serialize!(compute()))}}"
			# What it shows: its text alone as a JSON string (as a text hole's, `"…"`), or its markup's JSON.
			HoleOf(compute) => "{\"t\":\"hx\",\"r\":${
				keep!(
					|| match compute() {
						Text(content) => json_str(content)
						markup => serialize!(markup)
					},
				)
			}}"
			ListOf(compute) => "{\"t\":\"l\",\"r\":${keep!(|| "[${nodes!(compute())}]")}}"
			Fragment(parts) => "{\"t\":\"f\",\"c\":[${nodes!(parts)}]}"
			Loading(fallback, children) => "{\"t\":\"loading\",\"fallback\":${made!(fallback)},\"c\":[${nodes!(children)}]}"
			Errored(fallback, children) => {
				shown! = || {
					boundary = Host.boundary!({})
					serialize!(fallback(Host.problem!({}), || Host.retry!(boundary)))
				}
				"{\"t\":\"errored\",\"r\":${keep!(shown!)},\"c\":[${nodes!(children)}]}"
			}
			# A hole's if or match's part (D-070), a level's: what `r` answers is the case's name (`"#…"`:
			# never empty, so truthy), and the runtime makes the part anew when it changes.
			Switched(case!, made, fallback) => "{\"t\":\"show\",\"r\":${keep!(|| case_json!(case!))},\"with\":${keep!(|| serialize!(made()))},\"fallback\":${made!(fallback)}}"
			Branched(case!, made) => "{\"t\":\"show\",\"b\":1,\"r\":${keep!(|| case_json!(case!))},\"with\":${keep!(|| serialize!(made()))},\"fallback\":{\"t\":\"f\",\"c\":[]}}"
			Each(made_rows!, fallback) => {
				id = Host.for_new!({})
				listed! = || {
					var $out = []
					for entry in made_rows!(id) {
						row = entry.row
						$out = $out.append("{\"k\":${json_str(entry.key)},\"r\":${keep!(|| serialize!(row()))}}")
					}
					"[${Str.join_with($out, ",")}]"
				}
				"{\"t\":\"for\",\"id\":${id.to_str()},\"r\":${keep!(listed!)},\"fallback\":${made!(fallback)}}"
			}
			Component(run!) => "{\"t\":\"c\",\"r\":${keep!(|| serialize!(run!()))}}"
			Provided(name, value, children) => "{\"t\":\"ctx\",\"n\":${json_str(name)},\"v\":${value.to_str()},\"c\":[${nodes!(children)}]}"
			NoHydration(children) => "{\"t\":\"nh\",\"c\":[${nodes!(children)}]}"
			Listen(target, handlers) => "{\"t\":\"listen\",\"to\":${json_str(target)},\"a\":[${attributes!(target, handlers)}]}"
		}
}

## Markup's text, its holes computed (`<Title>`'s children): what `textContent` would say.
plain! : List(Html) => Str
plain! = |parts| {
	var $out = ""
	for part in parts {
		said =
			match part {
				Text(content) => content
				TextOf(compute) => compute()
				Element(_, _, children) => plain!(children)
				Fragment(children) => plain!(children)
				NoHydration(children) => plain!(children)
				HtmlOf(compute) => plain!([compute()])
				HoleOf(compute) => plain!([compute()])
				ListOf(compute) => plain!(compute())
				_ => ""
			}
		$out = $out.concat(said)
	}
	$out
}

## A `<Meta>`, `<Link>` or `<Style>`'s element as it is now: its computed attributes run (so its
## hole tracks what they read), and its text (a `<Style>`'s CSS) read.
head_filled! : Html => Html
head_filled! = |element|
	match element {
		Void(tag, attrs) => Void(tag, filled_attributes!(attrs))
		Element(tag, attrs, children) => Element(tag, filled_attributes!(attrs), [Raw(raw_text!(children))])
		_ => element
	}

## Attributes with each computed one run: static ones.
filled_attributes! : List(Html.Attr) => List(Html.Attr)
filled_attributes! = |attrs| {
	var $out = []
	for attribute in attrs {
		now =
			match attribute {
				ValueOf(name, compute) => Value(name, compute())
				OptionalOf(name, compute) => Optional(name, compute())
				FlagOf(name, compute) => Flag(name, compute())
				ClassOf(name, compute) => ClassIf(name, compute())
				StyleOf(name, compute) => StyleVar(name, compute())
				other => other
			}
		$out = $out.append(now)
	}
	$out
}

## The text of an element whose content isn't markup (`<style>`): as written (`Html.source_text`)
## and as its holes say, never escaped, with nothing that could close it (`</` becomes `<\/`, which
## CSS reads as the same).
raw_text! : List(Html) => Str
raw_text! = |parts| {
	var $out = ""
	for part in parts {
		said =
			match part {
				Raw(content) => content
				Text(content) => content
				TextOf(compute) => compute()
				Fragment(children) => raw_text!(children)
				HtmlOf(compute) => raw_text!([compute()])
				HoleOf(compute) => raw_text!([compute()])
				ListOf(compute) => raw_text!(compute())
				_ => ""
			}
		$out = $out.concat(said)
	}
	$out.replace_each("</", "<\\/")
}

## A head element's markup: `data-rocx` first, so hydrating passes over it.
head_markup : Html -> Str
head_markup = |element|
	match element {
		Void(tag, attrs) => static_str(Void(tag, [Flag("data-rocx", Bool.True)].concat(attrs)), Bool.True)
		Element(tag, attrs, children) => static_str(Element(tag, [Flag("data-rocx", Bool.True)].concat(attrs), children), Bool.True)
		_ => ""
	}

## What a later `<Meta>` takes the place of an earlier one by (@solidjs/meta's): its `name` (or
## `property`, the same), `http-equiv`, `charset` or `itemprop`, with its `media`. "" for any
## other element, and a `<meta>` with none of them: kept beside the others.
head_key : Html -> Str
head_key = |element|
	match element {
		Void("meta", attrs) => {
			valued = |wanted|
				attrs.keep_oks(
					|attribute|
						match attribute {
							Value(name, value) if name.caseless_ascii_equals(wanted) => Ok(value)
							Optional(name, value) if name.caseless_ascii_equals(wanted) and !value.is_empty() => Ok(value)
							Flag(name, on) if name.caseless_ascii_equals(wanted) and on => Ok("")
							_ => Err(NotIt)
						},
				).first()
			media =
				match valued("media") {
					Ok(value) => " media=${value}"
					Err(_) => ""
				}
			named =
				match (valued("name"), valued("property"), valued("http-equiv"), valued("charset"), valued("itemprop")) {
					(Ok(name), _, _, _, _) => "name=${name}"
					(_, Ok(name), _, _, _) => "name=${name}"
					(_, _, Ok(equiv), _, _) => "http-equiv=${equiv.with_ascii_lowercased()}"
					(_, _, _, Ok(_), _) => "charset"
					(_, _, _, _, Ok(prop)) => "itemprop=${prop}"
					_ => ""
				}
			if (named.is_empty()) "" else "meta ${named}${media}"
		}
		_ => ""
	}

## What an `if`'s or `match`'s part shows, and a fallback (a `<Loading>`'s), for its JSON:
## made when it shows, as a component is (`{"t":"c"}`): where it is rendered, once, its reads
## untracked, owned by its part, and made again each time it shows again. So a value prop in it is
## read then, not when the page was. Nothing to make for none (`Html.empty`, a fallback's default).
## A `.map`'s rows and an `if`'s or `match`'s part are made when they come too, by computations
## of their own (`"r"`, `"with"`).
made! : Html => Str
made! = |part| {
	later = "{\"t\":\"c\",\"r\":${keep!(|| Html.serialize!(part))}}"
	match part {
		Fragment(parts) => if (parts.is_empty()) "{\"t\":\"f\",\"c\":[]}" else later
		_ => later
	}
}

## A case's name as the runtime compares it (`"#name"`), or `false` when none holds.
case_json! : (() => Try(Str, [None])) => Str
case_json! = |case!|
	match case!() {
		Ok(name) => json_str("#${name}")
		Err(_) => "false"
	}

## Runs a handler; a handler answers nothing.
handled! : (() => {}) => Str
handled! = |handler| {
	handler()
	""
}

keep! : (() => Str) => Str
keep! = |run| Host.keep!(Box.box(run)).to_str()

nodes! : List(Html) => Str
nodes! = |parts| {
	var $out = []
	for part in parts {
		$out = $out.append(Html.serialize!(part))
	}
	Str.join_with($out, ",")
}

## An element's attributes, `tag`'s (which URLs it may have depends on it: `safe_value`).
attributes! : Str, List(Html.Attr) => Str
attributes! = |tag, attrs| {
	var $out = []
	for attribute in attrs {
		$out = $out.append(
			match attribute {
				Value(name, value) => "[\"v\",${json_str(name)},${json_str(safe_value(tag, name, value))}]"
				ValueOf(name, compute) => "[\"vo\",${json_str(name)},${keep!(|| json_str(safe_value(tag, name, compute())))}]"
				Optional(name, value) => "[\"o\",${json_str(name)},${json_str(safe_value(tag, name, value))}]"
				OptionalOf(name, compute) => "[\"oo\",${json_str(name)},${keep!(|| json_str(safe_value(tag, name, compute())))}]"
				StyleVar(name, value) => "[\"sv\",${json_str(name)},${json_str(safe_style(name, value))}]"
				StyleOf(name, compute) =>
					if plain_property(name) {
						"[\"so\",${json_str(name)},${keep!(|| json_str(safe_css(compute())))}]"
					} else {
						"[\"sv\",${json_str(name)},\"\"]"
					}
				Flag(name, is_on) => "[\"f\",${json_str(name)},${if (is_on) "true" else "false"}]"
				FlagOf(name, compute) => "[\"fo\",${json_str(name)},${keep!(|| if (compute()) "true" else "false")}]"
				ClassIf(name, is_on) => "[\"ci\",${json_str(name)},${if (is_on) "true" else "false"}]"
				ClassOf(name, compute) => "[\"co\",${json_str(name)},${keep!(|| if (compute()) "true" else "false")}]"
				On(event, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(handler))}]"
				OnValue(event, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(|| handler(Host.event_value!({}))))}]"
				OnChecked(event, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(|| handler(Host.event_value!({}) == "true")))}]"
				OnKey(event, handler) => "[\"onk\",${json_str(event)},${keep!(|| handled!(|| handler(Host.event_value!({}))))}]"
				OnKeys(event, handler) => "[\"onk\",${json_str(event)},${keep!(|| handled!(|| handler(keys_of(Host.event_value!({})))))},\"keys\"]"
				OnNamedKey(event, wanted, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(handler))},${json_str(wanted)}]"
				OnPrevent(event, handler) => "[\"onp\",${json_str(event)},${keep!(|| handled!(handler))}]"
				OnFrame(handler) => "[\"frame\",\"frame\",${keep!(|| handled!(|| handler(frame_ms(Host.event_value!({})))))}]"
				OnViewport(handler) => "[\"view\",\"viewport\",${keep!(|| handled!(|| handler(viewport_of(Host.event_value!({})))))}]"
				OnPoint(event, handler) => "[\"pt\",${json_str(event)},${keep!(|| handled!(|| handler(point_of(Host.event_value!({})))))}]"
				OnData(event, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(|| handler(drag_items_of(Host.event_value!({})))))},\".data\"]"
				OnFiles(event, handler) => "[\"on\",${json_str(event)},${keep!(|| handled!(|| handler(files_of(Host.event_value!({})))))},\".files\"]"
				DragData(items) => "[\"dd\",\"data\",${json_str(pairs_json(items))}]"
				DragDataOf(compute) => "[\"ddo\",\"data\",${keep!(|| json_str(pairs_json(compute())))}]"
				DragImage(id) => "[\"dd\",\"image\",${json_str(id)}]"
				DragImageOf(compute) => "[\"ddo\",\"image\",${keep!(|| json_str(compute()))}]"
				Key(id) => "[\"k\",${json_str(id)}]"
				KeyOf(compute) => "[\"ko\",${keep!(|| json_str(compute()))}]"
				Animate(way, animation) => "[\"tr\",${way_name(way)},${animation.json()}]"
				AnimateOf(way, compute) => "[\"tro\",${way_name(way)},${keep!(|| compute().json())}]"
			},
		)
	}
	Str.join_with($out, ",")
}

## An element's attributes, without an `<input type="password">`'s `value`: what was typed in one is
## never written into a page (a form filled in again after a refused post, say), whatever the
## component says.
unfilled : Str, List(Html.Attr) -> List(Html.Attr)
unfilled = |tag, attrs| {
	secret = |attribute|
		match attribute {
			Value("type", kind) => kind.with_ascii_lowercased() == "password"
			_ => Bool.False
		}
	filled = |attribute|
		match attribute {
			Value(name, _) => name == "value"
			ValueOf(name, _) => name == "value"
			Optional(name, _) => name == "value"
			OptionalOf(name, _) => name == "value"
			_ => Bool.False
		}
	if tag == "input" and attrs.any(secret) {
		attrs.keep_if(|attribute| !filled(attribute))
	} else {
		attrs
	}
}

## Which way a transition plays, as the runtime names it.
way_name : [In, Out, Both, Move] -> Str
way_name = |way|
	match way {
		In => "\"in\""
		Out => "\"out\""
		Both => "\"both\""
		Move => "\"move\""
	}

## Markup with nothing to run in it as HTML (`Html.to_str`), `quiet` inside a `<NoHydration>`,
## where the server writes no comments but the region's own.
static_str : Html, Bool -> Str
static_str = |node, quiet|
	match node {
		Element(tag, attrs, children) => {
			open = "<${tag}${static_attributes(tag, unfilled(tag, attrs))}>"
			if (void_elements.contains(tag)) open else "${open}${static_nodes(children, quiet)}</${tag}>"
		}
		Void(tag, attrs) => {
			open = "<${tag}${static_attributes(tag, unfilled(tag, attrs))}>"
			if (void_elements.contains(tag)) open else "${open}</${tag}>"
		}
		Text(content) => escape(content)
		Raw(content) => content
		Doctype => "<!doctype html>"
		Fragment(parts) => static_nodes(parts, quiet)
		Loading(_, children) => marked("loading", static_nodes(children, quiet), quiet)
		Errored(_, children) => marked("errored", static_nodes(children, quiet), quiet)
		Provided(_, _, children) => static_nodes(children, quiet)
		NoHydration(children) => marked("nohydration", static_nodes(children, Bool.True), quiet)
		# Handlers on the document or the window: nothing on the page.
		Listen(_, _) => ""
		_ => crash "Html.to_str renders markup with nothing to run in it: a computation, an if's part, a .map's rows or a component needs the runtime"
	}

## `inner` between a part's comments (`<!--label-->…<!--/label-->`), or as it is when `quiet`.
marked : Str, Str, Bool -> Str
marked = |label, inner, quiet| if (quiet) inner else "<!--${label}-->${inner}<!--/${label}-->"

## Static parts, as `Html.to_str` renders them.
static_nodes : List(Html), Bool -> Str
static_nodes = |parts, quiet| parts.fold("", |out, part| out.concat(static_str(part, quiet)))

## An element's static attributes, as the server's walker writes them: its classes in one `class`
## first, the others as written, its styles in one `style` last. Values are made safe as
## `serialize!` makes them, and escaped.
static_attributes : Str, List(Html.Attr) -> Str
static_attributes = |tag, attrs| {
	found = attrs.fold(
		{ classes: [], styles: [], others: [] },
		|state, attribute|
			match attribute {
				Value("class", value) => { ..state, classes: state.classes.append(value) }
				Value("style", value) => { ..state, styles: state.styles.append(value) }
				Value(name, value) => { ..state, others: state.others.append("${name}=\"${escape(safe_value(tag, name, value))}\"") }
				Optional(name, value) => if (value.is_empty()) state else { ..state, others: state.others.append("${name}=\"${escape(safe_value(tag, name, value))}\"") }
				Flag(name, is_on) => if (is_on) { ..state, others: state.others.append(name) } else state
				ClassIf(name, is_on) => if (is_on) { ..state, classes: state.classes.append(name) } else state
				StyleVar(name, value) => {
					safe = safe_style(name, value)
					if (safe.is_empty()) state else { ..state, styles: state.styles.append("${name}: ${safe}") }
				}
				ValueOf(_, _) => crash "Html.to_str renders static attributes: a computed one needs the runtime"
				OptionalOf(_, _) => crash "Html.to_str renders static attributes: a computed one needs the runtime"
				FlagOf(_, _) => crash "Html.to_str renders static attributes: a computed one needs the runtime"
				ClassOf(_, _) => crash "Html.to_str renders static attributes: a computed one needs the runtime"
				StyleOf(_, _) => crash "Html.to_str renders static attributes: a computed one needs the runtime"
				# Handlers, keys and transitions render nothing.
				_ => state
			},
	)
	classes = if (found.classes.is_empty()) [] else ["class=\"${escape(Str.join_with(found.classes, " "))}\""]
	styles = if (found.styles.is_empty()) [] else ["style=\"${escape(Str.join_with(found.styles, "; "))}\""]
	classes.concat(found.others).concat(styles).fold("", |out, attribute| out.concat(" ${attribute}"))
}

void_elements : List(Str)
void_elements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

## Text as HTML: `<`, `>`, `&` and quotes as entities.
escape : Str -> Str
escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&#39;")

## A key press, as the runtime says it for `.keys`: whether Shift, Ctrl, Alt, Meta and Mod were held
## (`1` or `0` each), then the key.
keys_of : Str -> Html.Keys
keys_of = |said| {
	bytes = said.to_utf8()
	held = |at|
		match bytes.get(at) {
			Ok(byte) => byte == '1'
			Err(_) => Bool.False
		}
	{ key: Str.from_utf8_lossy(bytes.drop_first(5)), shift: held(0), ctrl: held(1), alt: held(2), meta: held(3), mod: held(4) }
}

## What shows of an element, from the runtime's `top,left,width,height` (whole pixels); what isn't a
## number is 0.
viewport_of : Str -> Html.Viewport
viewport_of = |said| {
	parts = said.split_on(",").map(|part| U64.from_str(part) ?? 0)
	at = |index| parts.get(index) ?? 0
	{ top: at(0), left: at(1), width: at(2), height: at(3) }
}

expect viewport_of("120,0,800,600") == { top: 120, left: 0, width: 800, height: 600 }
expect viewport_of("") == { top: 0, left: 0, width: 0, height: 0 }

## Where the pointer is, from the runtime's `x,y`: thousandths of the element's width and height,
## whole numbers from 0 to 1000 (Roc reads an integer with far less code than a float).
point_of : Str -> Html.Point
point_of = |said| {
	parts = said.split_on(",").map(|part| U64.min(U64.from_str(part) ?? 0, 1000))
	share = |index| (parts.get(index) ?? 0).to_dec() / 1000.0
	{ x: share(0), y: share(1) }
}

expect point_of("250,1000") == { x: 0.25, y: 1.0 } and point_of("") == { x: 0.0, y: 0.0 } and point_of("5000,7") == { x: 1.0, y: 0.007 }

## What a drag carries, from the runtime's JSON (`[{"type":…,"value":…}]`); none if it isn't that.
drag_items_of : Str -> List(Html.DragItem)
drag_items_of = |said|
	match Json.parse(said) {
		Ok(items) => items
		Err(_) => []
	}

expect drag_items_of("[{\"type\":\"text/uri-list\",\"value\":\"https://example.com/\"}]") == [{ type: "text/uri-list", value: "https://example.com/" }] and drag_items_of("") == []

## The files dropped, pasted or chosen, from the runtime's JSON (`[{"name":…,"type":…,"size":…,"url":…}]`).
files_of : Str -> List(Html.File)
files_of = |said|
	match Json.parse(said) {
		Ok(files) => files
		Err(_) => []
	}

expect files_of("[{\"name\":\"a.png\",\"type\":\"image/png\",\"size\":3,\"url\":\"blob:x\"}]") == [{ name: "a.png", type: "image/png", size: 3, url: "blob:x" }]

## Types and values as the runtime reads a drag's data: `[["text/plain","…"],…]`.
pairs_json : List((Str, Str)) -> Str
pairs_json = |items| "[${Str.join_with(items.map(|(kind, value)| "[${json_str(kind)},${json_str(value)}]"), ",")}]"

expect pairs_json([("text/plain", "a \"b\"")]) == "[[\"text/plain\",\"a \\\"b\\\"\"]]" and pairs_json([]) == "[]"

## A frame's milliseconds, from the whole microseconds the runtime sends (Roc reads an integer with
## far less code than a float), at most 100.
frame_ms : Str -> F64
frame_ms = |micros| F64.min((U64.from_str(micros) ?? 0).to_f64() / 1000.0, 100.0)

## A style's value, if it is plain: letters, digits, spaces and `.,%#()-+`, and no function but
## one that computes a value (`css_functions`); otherwise none.
safe_css : Str -> Str
safe_css = |value| {
	bytes = value.to_utf8()
	if (bytes.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or " .,%#()-+".to_utf8().contains(byte)) and computes_only(bytes)) value else ""
}

## A style property's value as `safe_css` makes it, and none for a name that isn't plain.
safe_style : Str, Str -> Str
safe_style = |name, value| if (plain_property(name)) safe_css(value) else ""

## A property's name as rocx takes one: letters and dashes (`color`, `-webkit-line-clamp`), or a
## custom property's, `--` then letters, digits, `_` and `-`.
plain_property : Str -> Bool
plain_property = |name| {
	bytes = name.to_utf8()
	if name.starts_with("--") {
		bytes.len() > 2 and bytes.drop_first(2).all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-')
	} else {
		!bytes.is_empty() and bytes.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '-')
	}
}

## Whether every function a value calls (the name before each `(`) is one that only computes a
## value (`css_functions`): none that loads something (`url(…)`, `image-set(…)`, `src(…)`).
computes_only : List(U8) -> Bool
computes_only = |bytes| {
	var $name = []
	var $ok = Bool.True
	for byte in bytes {
		if byte == '(' {
			called = Str.from_utf8_lossy($name).with_ascii_lowercased()
			if !(called.is_empty() or css_functions.contains(called)) {
				$ok = Bool.False
			}
			$name = []
		} else if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' {
			$name = $name.append(byte)
		} else {
			$name = []
		}
	}
	$ok
}

## The functions a style's value may call: colours, arithmetic, transforms, gradients, timing and
## filters, which compute a value and load nothing.
css_functions : List(Str)
css_functions = ["rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix", "light-dark", "calc", "min", "max", "clamp", "var", "round", "mod", "rem", "abs", "sign", "pow", "sqrt", "hypot", "sin", "cos", "tan", "translate", "translatex", "translatey", "translate3d", "scale", "scalex", "scaley", "rotate", "skew", "skewx", "skewy", "matrix", "perspective", "linear-gradient", "radial-gradient", "conic-gradient", "repeating-linear-gradient", "repeating-radial-gradient", "repeating-conic-gradient", "cubic-bezier", "steps", "minmax", "repeat", "fit-content", "blur", "brightness", "contrast", "drop-shadow", "grayscale", "hue-rotate", "invert", "opacity", "saturate", "sepia"]

url_attributes : List(Str)
url_attributes = ["href", "src", "action", "formaction", "poster", "cite"]

## The attributes in which the browser only ever shows a URL as an image: `<img src>`, `<link
## href>` (an icon), `<source src>` and `<video poster>`. (`srcset`, `<img>`'s and `<source>`'s, is
## never checked: it holds nothing but images.)
image_attributes : List((Str, Str))
image_attributes = [("img", "src"), ("link", "href"), ("source", "src"), ("video", "poster")]

## An attribute's value on a `tag` element, made safe: a URL that could run script is replaced
## with `about:invalid#rocx-unsafe-url`. Allowed anywhere: a relative URL, or http, https, mailto
## and tel (`safe_url`). Allowed in an image attribute (`image_attributes`) too: a `data:image/…`
## URL, svg included (`data:image/svg+xml,…`, a favicon an app writes inline). An image of any type
## runs no script: the browser shows an SVG in an `<img>` or as an icon as a picture, its scripts
## off. But an SVG the browser opens as a document runs its scripts, so a `data:` URL anywhere else
## is refused as before: an `<iframe>`'s or `<embed>`'s `src`, an `<a href>` someone opens, a form's
## `action`. The tag and the attribute are compared without case, as the browser reads them.
safe_value : Str, Str, Str -> Str
safe_value = |tag, name, value| {
	if !url_attributes.any(|each| name.caseless_ascii_equals(each)) or safe_url(value) {
		value
	} else if image_attributes.any(|(element, attribute)| tag.caseless_ascii_equals(element) and name.caseless_ascii_equals(attribute)) and compact(value).starts_with("data:image/") {
		value
	} else {
		"about:invalid#rocx-unsafe-url"
	}
}

## A URL as the browser reads its scheme: case aside, without the tabs, line breaks and spaces it
## ignores (`java\nscript:` runs; so does `DATA:image/…`).
compact : Str -> Str
compact = |url| Str.from_utf8_lossy(url.to_utf8().keep_if(|byte| byte > ' ')).with_ascii_lowercased()

## A relative URL, or one whose scheme is http, https, mailto or tel. Browsers ignore tabs, line
## breaks and leading spaces in a URL (`java\nscript:` runs), so those are dropped before looking.
safe_url : Str -> Bool
safe_url = |url| {
	match compact(url).split_first(":") {
		Err(NotFound) => Bool.True
		Ok({ before, after: _ }) =>
			if before.contains("/") or before.contains("?") or before.contains("#") {
				Bool.True
			} else {
				["http", "https", "mailto", "tel"].contains(before)
			}
	}
}

hex_digits : List(U8)
hex_digits = "0123456789abcdef".to_utf8()

json_str : Str -> Str
json_str = |text| {
	var $out = ['"']
	for byte in text.to_utf8() {
		$out =
			if byte == '"' {
				$out.concat(['\\', '"'])
			} else if byte == '\\' {
				$out.concat(['\\', '\\'])
			} else if byte == '\n' {
				$out.concat(['\\', 'n'])
			} else if byte < 32 {
				$out.concat(['\\', 'u', '0', '0', hex_digits.get((byte // 16).to_u64()) ?? '0', hex_digits.get((byte % 16).to_u64()) ?? '0'])
			} else {
				$out.append(byte)
			}
	}
	Str.from_utf8_lossy($out.append('"'))
}

expect safe_value("a", "href", "java\nscript:alert(1)") == "about:invalid#rocx-unsafe-url"
expect safe_value("a", "href", "/signals?x=1") == "/signals?x=1"
expect safe_value("a", "title", "javascript:fine as text") == "javascript:fine as text"
unsafe = "about:invalid#rocx-unsafe-url"

svg = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E"

png = "data:image/png;base64,iVBORw0KGgo="

# data:image/… only where it is shown as an image; svg too there.
expect [("img", "src"), ("link", "href"), ("source", "src"), ("video", "poster")].all(|(tag, name)| safe_value(tag, name, svg) == svg and safe_value(tag, name, png) == png)
expect [("a", "href"), ("iframe", "src"), ("embed", "src"), ("area", "href"), ("form", "action"), ("button", "formaction"), ("blockquote", "cite"), ("img", "href"), ("link", "src"), ("audio", "poster")].all(|(tag, name)| safe_value(tag, name, svg) == unsafe and safe_value(tag, name, png) == unsafe)
expect safe_value("img", "srcset", "data:text/html,x 1x") == "data:text/html,x 1x"
# Case and what the browser drops from a URL change nothing.
expect safe_value("img", "src", "DATA:image/svg+xml,x") == "DATA:image/svg+xml,x" and safe_value("IMG", "SRC", " Data:Image/PNG;base64,x") == " Data:Image/PNG;base64,x"
expect safe_value("link", "href", "data:\nimage/svg+xml,x") == "data:\nimage/svg+xml,x" and safe_value("source", "src", "da\tta:image/webp,x") == "da\tta:image/webp,x"
expect safe_value("iframe", "src", "DATA:image/svg+xml,x") == unsafe and safe_value("a", "href", "data:\nimage/svg+xml,x") == unsafe and safe_value("A", "HREF", "javascript:x") == unsafe and safe_value("EMBED", "Src", " data:image/svg+xml,x") == unsafe
# data:text/html, and any other data: that isn't an image, nowhere.
expect [("img", "src"), ("link", "href"), ("source", "src"), ("video", "poster"), ("a", "href"), ("iframe", "src")].all(|(tag, name)| safe_value(tag, name, "data:text/html,<script>alert(1)</script>") == unsafe and safe_value(tag, name, "DATA:text/html;image/png,x") == unsafe and safe_value(tag, name, "data:,image/png") == unsafe)
expect safe_value("img", "src", "javascript:alert(1)") == unsafe and safe_value("link", "href", "jav\nascript:alert(1)") == unsafe
expect safe_css("12.5%") == "12.5%" and safe_css("red; background: url(x)") == ""
expect safe_css("url(x)") == "" and safe_css("URL(x)") == "" and safe_css("image-set(a 1x)") == "" and safe_css("calc(var(--a) + (2px - 1%))") == "calc(var(--a) + (2px - 1%))"
expect safe_css("hsl(120 50% 40%)") == "hsl(120 50% 40%)" and safe_css("#11734b") == "#11734b"
expect plain_property("color") and plain_property("-webkit-line-clamp") and plain_property("--size-2") and !plain_property("col0r") and !plain_property("--") and !plain_property("a:b") and !plain_property("")
expect Html.to_str(Html.element("h1", [Html.attr("style", "font-size: 22px"), Html.style_var("color", "#11734b"), Html.style_var("background", "url(x)"), Html.style_var("x;y", "red")], [])) == "<h1 style=\"font-size: 22px; color: #11734b\"></h1>"
expect keys_of("01001k") == { key: "k", shift: Bool.False, ctrl: Bool.True, alt: Bool.False, meta: Bool.False, mod: Bool.True }
expect keys_of("10000Enter").shift and keys_of("10000Enter").key == "Enter" and keys_of("").key == ""
expect frame_ms("16667") > 16.6 and frame_ms("16667") < 16.7 and frame_ms("500000") == 100.0
expect Html.to_str(Html.join([Html.doctype({}), Html.element("p", [], [Html.text("Tom & 'Jerry' <b>"), Html.empty({})])])) == "<!doctype html><p>Tom &amp; &#39;Jerry&#39; &lt;b&gt;</p>"
expect Html.to_str(Html.element("style", [], [Html.source_text("p > a { color: red }")])) == "<style>p > a { color: red }</style>"
expect Html.to_str(Html.element("li", [Html.attr("id", "a"), Html.attr("class", "row"), Html.class_if("active", Bool.True), Html.class_if("gone", Bool.False)], [])) == "<li class=\"row active\" id=\"a\"></li>"
expect Html.to_str(Html.void("input", [Html.attr("type", "checkbox"), Html.flag("checked", Bool.True), Html.flag("disabled", Bool.False), Html.optional("name", ""), Html.optional("title", "a \"b\"")])) == "<input type=\"checkbox\" checked title=\"a &quot;b&quot;\">"
expect Html.to_str(Html.element("a", [Html.attr("href", " java\tscript:alert(1)"), Html.optional("formaction", "javascript:x")], [Html.text("x")])) == "<a href=\"about:invalid#rocx-unsafe-url\" formaction=\"about:invalid#rocx-unsafe-url\">x</a>"
expect Html.to_str(Html.join([Html.void("link", [Html.attr("rel", "icon"), Html.attr("href", "data:image/svg+xml,<svg/>")]), Html.element("iframe", [Html.attr("src", "data:image/svg+xml,<svg/>")], [])])) == "<link rel=\"icon\" href=\"data:image/svg+xml,&lt;svg/&gt;\"><iframe src=\"about:invalid#rocx-unsafe-url\"></iframe>"
expect Html.to_str(Html.element("span", [Html.style_var("--size", "32px"), Html.attr("style", "color: red"), Html.style_var("--bad", "1px; background: url(x)")], [])) == "<span style=\"--size: 32px; color: red\"></span>"
expect Html.to_str(Html.element("div", [], [Html.void("br", []), Html.element("img", [Html.attr("src", "/a.png")], []), Html.void("p", [])])) == "<div><br><img src=\"/a.png\"><p></p></div>"
expect Html.to_str(Html.element("button", [Html.on("click", || {}), Html.key("k")], [Html.join([Html.text("a"), Html.text("b")])])) == "<button>ab</button>"
expect Html.to_str(Html.element("main", [], [Html.no_hydration([Html.element("p", [], [Html.text("a & b")]), Html.join([Html.text("c")])]), Html.text("d")])) == "<main><!--nohydration--><p>a &amp; b</p>c<!--/nohydration-->d</main>"
expect Html.to_str(Html.no_hydration([Html.loading(Html.empty({}), [Html.text("in")]), Html.no_hydration([Html.text("nested")])])) == "<!--nohydration-->innested<!--/nohydration-->"
expect Html.to_str(Html.void("input", [Html.attr("type", "password"), Html.attr("name", "password"), Html.attr("value", "hunter2")])) == "<input type=\"password\" name=\"password\">"
expect Html.to_str(Html.void("input", [Html.attr("name", "q"), Html.optional("value", "roc"), Html.attr("type", "PASSWORD")])) == "<input name=\"q\" type=\"PASSWORD\">"
expect Html.to_str(Html.void("input", [Html.attr("type", "text"), Html.attr("value", "Ada")])) == "<input type=\"text\" value=\"Ada\">"

expect head_markup(Void("meta", [Value("name", "description"), Value("content", "A \"quiet\" place")])) == "<meta data-rocx name=\"description\" content=\"A &quot;quiet&quot; place\">"
expect head_markup(Element("style", [], [Raw("p { color: red }")])) == "<style data-rocx>p { color: red }</style>"
expect head_key(Void("meta", [Value("property", "og:title"), Value("content", "x")])) == "meta name=og:title"
expect head_key(Void("meta", [Value("name", "theme-color"), Value("media", "(prefers-color-scheme: dark)")])) == "meta name=theme-color media=(prefers-color-scheme: dark)"
expect head_key(Void("meta", [Flag("charset", Bool.True)])) == "meta charset"
expect head_key(Void("link", [Value("rel", "canonical")])) == ""

expect Html.row_keys(["a", "b", "a", "a"]) == ["a", "b", "a#1", "a#2"]
