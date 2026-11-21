import Host

## Sound files, from a handler: `Audio.play!("/sounds/eat.wav")` plays any file the browser can
## (WAV, MP3, Ogg, …). A path beginning with `/` is the site's, under its base, as a request's is;
## a whole URL is anywhere. Nothing is prepared in advance: the browser fetches a file the first
## time it plays it, and keeps it.
##
## A play goes as a `Browser.call!` does: once the handler is done and the page is patched, and once
## for a handler that waits for the server and runs again. Only a handler plays; while computing,
## and on the server, it fails. Browsers keep a page quiet until the reader has done something on
## it: until then, nothing plays. A file that can't be played is told on the console.
Audio := [].{
	play! : Str => {}
	play! = |url| Audio.play_with!(url, { volume: 1.0, rate: 1.0 })

	## The same, at a `volume` (0 to 1), and a `rate`: 2.0 is twice as fast, and an octave up.
	play_with! : Str, { volume : F64, rate : F64 } => {}
	play_with! = |url, { volume, rate }| Host.browser_call!("rocx:audio", "{\"url\":${Json.to_str(url)},\"volume\":${number(volume)},\"rate\":${number(rate)}}")
}

## A number as JSON has it; one JSON hasn't (NaN, an infinity), or none a sound could use, is 1.
number : F64 -> Str
number = |x| if (x >= 0.0 and x <= 1000.0) x.to_str() else "1"

expect number(0.5) == "0.5"
expect number(-1.0) == "1"
