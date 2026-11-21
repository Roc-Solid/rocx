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
## server, it fails. Names beginning with `rocx:` are the runtime's own (`rocx:audio` is `Audio.play!`).
Browser := [].{
	call! : Str, arg => {} where [arg.Json.Encodable([Infinity, NaN, NegativeInfinity, ..])]
	call! = |name, arg|
		match Json.to_str_try(arg) {
			Ok(json) => Host.browser_call!(name, json)
			Err(_) => Host.fail!("Browser.call!(\"${name}\"): its argument holds a number JSON can't write (an F64 that is NaN or an infinity)")
		}
}
