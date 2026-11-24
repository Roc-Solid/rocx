import pf.Browser

## The phone's vibration motor, from a handler: `Vibrate.once!(400)` buzzes for 400 ms,
## `Vibrate.pattern!([200, 100, 200])` buzzes, rests and buzzes again (milliseconds on, off, on…,
## as the browser's `navigator.vibrate` takes them).
##
## A buzz is a `Browser.call!("vibrate.pattern", { pattern })`, once the handler is done and the
## screen is patched. In a browser the plugin's script (`Vibrator.plugin({})` in the app's plugins)
## passes it to `navigator.vibrate`: Chrome on Android buzzes; a browser with no motor, or none it
## lets a page use (a computer's, Safari, Firefox), does nothing, and that is no failure. On an
## Android phone (D-063's native host) the phone's handler buzzes, with no script. Only a handler
## buzzes; while computing, and on the server, it fails.
Vibrate := [].{

	## Buzzes once, for `ms` milliseconds (at most 10 s).
	once! : U64 => {}
	once! = |ms| Vibrate.pattern!([ms])

	## Buzzes, rests, buzzes…: milliseconds on, off, on…, each at most 10 s.
	pattern! : List(U64) => {}
	pattern! = |pattern| Browser.call!("vibrate.pattern", { pattern: clamp(pattern) })
}

## A pattern a motor could play: each step at most 10 s, at most 32 steps.
clamp : List(U64) -> List(U64)
clamp = |pattern| pattern.take_first(32).map(|ms| if (ms > 10000) 10000 else ms)

expect clamp([200, 100, 200]) == [200, 100, 200]
expect clamp([20000]) == [10000]
expect clamp(List.repeat(1, 40)).len() == 32
