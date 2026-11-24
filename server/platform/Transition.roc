## An animation an element plays as it comes and as it goes, as Svelte's transitions are: written
## on the element (`transition={…}` both ways, `transition:in={…}`, `transition:out={…}`), played
## when a `.map`'s row or an `if`'s or `match`'s part that has it comes or goes. One that goes stays on the
## page, its holes no longer run, until its animations are over; then the runtime takes it away.
##
##     <li transition={Transition.fade}>{todo!().text}</li>
##     <rect transition:out={Transition.grow(Bottom).plus(Transition.fade).ms(150)} … />
##
## `transition:move={Transition.glide}` is how it moves: when a change of the page moves it (a row
## put in another order, pushed by one that comes or goes; or, with a `key`, taken out of one list as
## an element with the same key comes into another), it glides from where it was to where it is
## (FLIP: its new place, played backwards from its old one). Only the pace of the transition counts
## there (`ms`, `delay`, `easing`).
##
##     <li key={card.id} transition:move={Transition.glide}>{card.title}</li>
##
## A transition is the element's style while it is hidden (`opacity: 0`, `scale: 1 0`): it comes from
## that to its own style, and goes from its own to that, the same way back. The browser plays it
## (`element.animate`), so it costs Roc nothing per frame. For someone who asked their system for
## less motion, none plays.
Transition :: { hidden : List((Str, Str)), ms : U64, delay : U64, easing : Str, origin : Str }.{

	## Faded in and out.
	fade : Transition
	fade = Transition.style([("opacity", "0")])

	## Coming from `x` and `y` pixels away (and going there), faded.
	fly : { x : Dec, y : Dec } -> Transition
	fly = |{ x, y }| Transition.style([("translate", "${x.to_str()}px ${y.to_str()}px"), ("opacity", "0")])

	## Scaled from `start` (0 is nothing, 1 its own size), faded.
	scale : Dec -> Transition
	scale = |start| Transition.style([("scale", start.to_str()), ("opacity", "0")])

	## No hidden style, at a pace for moving (250 ms, easing out): what `transition:move` plays.
	glide : Transition
	glide = Transition.style([]).ms(250).easing("cubic-bezier(0.2, 0, 0, 1)")

	## Grown out of one of its edges, as a bar grows out of its axis: scaled to nothing toward it.
	grow : [Top, Bottom, Left, Right] -> Transition
	grow = |edge|
		match edge {
			Top => Transition.style([("scale", "1 0")]).origin("top")
			Bottom => Transition.style([("scale", "1 0")]).origin("bottom")
			Left => Transition.style([("scale", "0 1")]).origin("left")
			Right => Transition.style([("scale", "0 1")]).origin("right")
		}

	## The element's style while it is hidden, any CSS properties: `[("opacity", "0"), ("translate",
	## "0 8px")]`. A value with anything but letters, digits, spaces and `.,%#()-+` in it is dropped,
	## as a custom property's is: data can't write CSS.
	style : List((Str, Str)) -> Transition
	style = |hidden| { hidden, ms: 200, delay: 0, easing: "ease-out", origin: "" }

	## How long it takes, in milliseconds (200 unless said).
	ms : Transition, U64 -> Transition
	ms = |self, duration| { ..self, ms: duration }

	## How long it waits before it starts, in milliseconds.
	delay : Transition, U64 -> Transition
	delay = |self, wait| { ..self, delay: wait }

	## Its pace, a CSS easing (`"ease-out"` unless said): `"linear"`, `"cubic-bezier(0.2, 0, 0, 1)"`.
	## Going, it is played backwards, so `ease-out` coming is `ease-in` going.
	easing : Transition, Str -> Transition
	easing = |self, pace| { ..self, easing: pace }

	## Where it scales from, a CSS `transform-origin` (`"bottom"`, `"50% 100%"`). Inside an `<svg>`,
	## it is the element's own box's.
	origin : Transition, Str -> Transition
	origin = |self, at| { ..self, origin: at }

	## Both at once: `other`'s style too (its value, where both set a property), at this one's pace.
	plus : Transition, Transition -> Transition
	plus = |self, other| {
		kept = self.hidden.keep_if(|(name, _)| !other.hidden.any(|(theirs, _)| theirs == name))
		{ ..self, hidden: kept.concat(other.hidden), origin: if (self.origin.is_empty()) other.origin else self.origin }
	}

	## What the runtime is given: `{"h":[[property,value],…],"ms":…,"delay":…,"easing":…,"origin":…}`.
	## Only plain values are in it (see `style`), so nothing in it needs escaping.
	json : Transition -> Str
	json = |self| {
		hidden =
			self.hidden
				.keep_if(|(name, value)| plain_name(name) and !value.is_empty() and plain_value(value))
				.map(|(name, value)| "[\"${name}\",\"${value}\"]")
		pace = if (plain_value(self.easing)) self.easing else "ease-out"
		from = if (plain_value(self.origin)) self.origin else ""
		"{\"h\":[${Str.join_with(hidden, ",")}],\"ms\":${self.ms.to_str()},\"delay\":${self.delay.to_str()},\"easing\":\"${pace}\",\"origin\":\"${from}\"}"
	}
}

## A CSS property's name: lowercase letters and `-`.
plain_name : Str -> Bool
plain_name = |name| !name.is_empty() and name.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or byte == '-')

## Letters, digits, spaces and `.,%#()-+`: a value that can't end the declaration, or the JSON.
plain_value : Str -> Bool
plain_value = |value| value.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or " .,%#()-+".to_utf8().contains(byte))

expect Transition.fade.json() == "{\"h\":[[\"opacity\",\"0\"]],\"ms\":200,\"delay\":0,\"easing\":\"ease-out\",\"origin\":\"\"}"
expect Transition.grow(Bottom).plus(Transition.fade).ms(150).json() == "{\"h\":[[\"scale\",\"1 0\"],[\"opacity\",\"0\"]],\"ms\":150,\"delay\":0,\"easing\":\"ease-out\",\"origin\":\"bottom\"}"
expect Transition.fly({ x: 0.0, y: -8.0 }).json() == "{\"h\":[[\"translate\",\"0.0px -8.0px\"],[\"opacity\",\"0\"]],\"ms\":200,\"delay\":0,\"easing\":\"ease-out\",\"origin\":\"\"}"
expect Transition.style([("background", "url(\"x\"); color: red"), ("Opacity", "0"), ("opacity", "0.5")]).json() == "{\"h\":[[\"opacity\",\"0.5\"]],\"ms\":200,\"delay\":0,\"easing\":\"ease-out\",\"origin\":\"\"}"
expect Transition.fade.plus(Transition.scale(0.5)).json() == "{\"h\":[[\"scale\",\"0.5\"],[\"opacity\",\"0\"]],\"ms\":200,\"delay\":0,\"easing\":\"ease-out\",\"origin\":\"\"}"
expect Transition.fade.easing("x; y").delay(50).json() == "{\"h\":[[\"opacity\",\"0\"]],\"ms\":200,\"delay\":50,\"easing\":\"ease-out\",\"origin\":\"\"}"
