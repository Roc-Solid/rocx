import pf.Browser

## Sound files, from a handler: `Audio.play!("/sounds/eat.wav")` plays any file the browser can
## (WAV, MP3, Ogg, …). A path beginning with `/` is the site's, under its base, as a request's is;
## a whole URL is anywhere. Nothing is prepared in advance: the browser fetches a file the first
## time it plays it, and keeps it.
##
## A play is a `Browser.call!("audio.play", { url, volume, rate })`: once the handler is done and
## the page is patched, and once for a handler that waits for the server and runs again. The
## player is the audio plugin's script (`AudioPlayer.plugin({})` in the app's plugins), which every
## page loads. Only a handler plays; while computing, and on the server, it fails. Browsers keep a
## page quiet until the reader has done something on it: until then, nothing plays. A file that
## can't be played is told on the console.
Audio := [].{

	## Plays the sound file at `url`, at its own volume and speed.
	play! : Str => {}
	play! = |url| Audio.play_with!(url, { volume: 1.0, rate: 1.0 })

	## The same, at a `volume` (0 to 1), and a `rate`: 2.0 is twice as fast, and an octave up.
	play_with! : Str, { volume : F64, rate : F64 } => {}
	play_with! = |url, { volume, rate }| Browser.call!("audio.play", { url, volume: number(volume), rate: number(rate) })
}

## A number JSON has, that a sound could use (0 to 1000); else (NaN, an infinity, below 0) 1.
number : F64 -> F64
number = |x| if (x >= 0.0 and x <= 1000.0) x else 1.0

expect number(0.5) == 0.5
expect number(-1.0) == 1.0
expect number(2000.0) == 1.0
