import Host

## The page's own JavaScript, from a handler, for what the platform has no module for: a vibration,
## the clipboard, an analytics event (a sound file is `Audio.play!`). `Browser.call!("vibrate",
## { ms: 50 })` calls the function the page gave the runtime as `vibrate`, with the argument as JSON,
## parsed, as Elm's ports do:
##
##     Runtime.load(wasm, { effects: { vibrate: ({ ms }) => navigator.vibrate(ms) } })
##
## (or `window.rocxEffects = { vibrate… }`, for a page start.js wakes up). A call runs once the
## handler is done, after the page is patched with what it wrote, so the function sees the page as
## the handler left it; a handler that waits for the server, and runs again, calls it once. It answers
## nothing. Only a handler calls: while computing (a hole, a memo, a component's body), and on the
## server, it fails. Names beginning with `rocx:` are the runtime's own (`rocx:audio` is `Audio.play!`,
## `rocx:focus` is `Browser.focus!`).
Browser := [].{

	## Calls the page's function `name` with `arg`, as JSON, once the handler is done. It fails
	## outside a handler, on the server, and for an argument JSON can't write.
	call! : Str, arg => {} where [arg.Json.Encodable(e)]
	call! = |name, arg|
		match Json.to_str_try(arg) {
			Ok(json) => Host.browser_call!(name, json)
			Err(_) => Host.fail!("Browser.call!(\"${name}\"): its argument holds a number JSON can't write (an F64 that is NaN or an infinity)")
		}

	## Moves the keyboard's focus to the element whose `id` this is, once the handler is done and the
	## page is patched, so a field the handler's writes show is there by then; nothing if there is
	## none. From a handler, or an effect's apply: `on_settled!(|| Browser.focus!("card-title"))`
	## focuses a field as its part shows. While computing, and on the server, it fails, as
	## `Browser.call!` does.
	focus! : Str => {}
	focus! = |id| Host.browser_call!("rocx:focus", Json.to_str(id))
}
