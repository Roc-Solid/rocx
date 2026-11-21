## Where this browser stands with notifications, as the page's script (`static/push.js`) says in a
## `pushstate` event: `""` until it has looked; `unsupported` (no service workers or Push API, or
## not a secure page: on an iPhone or iPad, a site not added to the Home Screen); `blocked` (the
## user said no, and only the browser's settings can undo it); `off`; `working` (asking,
## subscribing, telling the server); `on`; or `failed:` and why. `<PushButton>` shows it.
PushState := [Unknown, Unsupported, Blocked, Off, Working, On, Failed(Str)].{

	## The state a `pushstate` event's value names.
	parse : Str -> PushState
	parse = |text|
		match text {
			"unsupported" => Unsupported
			"blocked" => Blocked
			"off" => Off
			"working" => Working
			"on" => On
			_ =>
				if text.starts_with("failed:") {
					Failed(text.drop_prefix("failed:").trim())
				} else {
					Unknown
				}
		}

	## The state as the event names it: `parse`, the other way.
	to_str : PushState -> Str
	to_str = |state|
		match state {
			Unknown => ""
			Unsupported => "unsupported"
			Blocked => "blocked"
			Off => "off"
			Working => "working"
			On => "on"
			Failed(why) => "failed:${why}"
		}

	## Whether two are the same state.
	is_eq : PushState, PushState -> Bool
	is_eq = |left, right| PushState.to_str(left) == PushState.to_str(right)

	## Whether notifications are on.
	is_on : PushState -> Bool
	is_on = |state|
		match state {
			On => Bool.True
			_ => Bool.False
		}

	## Whether a click can do nothing now: there is no push here, the user blocked it, or the
	## last click is still at work.
	is_stuck : PushState -> Bool
	is_stuck = |state|
		match state {
			Unsupported | Blocked | Working => Bool.True
			_ => Bool.False
		}

	## What the button says.
	label : PushState -> Str
	label = |state|
		match state {
			On => "Turn notifications off"
			Working => "One moment…"
			_ => "Turn notifications on"
		}

	## What is said beside it.
	note : PushState -> Str
	note = |state|
		match state {
			Unsupported => "This browser can't show notifications from a site. On an iPhone or iPad, add the site to the Home Screen, and open it from there."
			Blocked => "Notifications are blocked for this site: the browser's site settings can allow them."
			On => "Notifications are on in this browser."
			Failed(why) => if (why.is_empty()) "That didn't work." else "That didn't work: ${why}"
			_ => ""
		}
}

expect PushState.parse("on") == On
expect PushState.parse("off") == Off
expect PushState.parse("blocked") == Blocked
expect PushState.parse("unsupported") == Unsupported
expect PushState.parse("working") == Working
expect PushState.parse("failed: the server said 503") == Failed("the server said 503")
expect PushState.parse("") == Unknown
expect PushState.parse("ON") == Unknown

expect ["", "unsupported", "blocked", "off", "working", "on", "failed:why"].all(|text| PushState.parse(text).to_str() == text)

expect PushState.parse("on").is_on()
expect !PushState.parse("off").is_on()
expect PushState.parse("blocked").is_stuck() and PushState.parse("working").is_stuck() and PushState.parse("unsupported").is_stuck()
expect !PushState.parse("off").is_stuck() and !PushState.parse("on").is_stuck() and !PushState.parse("failed:x").is_stuck() and !PushState.parse("").is_stuck()

expect PushState.label(On) == "Turn notifications off"
expect PushState.label(Off) == "Turn notifications on"
expect PushState.label(Unknown) == "Turn notifications on"
expect PushState.note(Off) == ""
expect PushState.note(Failed("")) == "That didn't work."
expect PushState.note(Failed("no network")) == "That didn't work: no network"
