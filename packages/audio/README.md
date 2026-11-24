# audio

Sound files for Roc Solid apps. A handler plays any file the browser can (WAV, MP3, Ogg, …), at a
volume and a rate, with nothing to load in advance: the browser fetches a file the first time it
plays it, and caches it. The package is a plugin: its script is the player, which every page loads.

The user guide, with the rules for when a sound plays, is the docs site's
[Audio page](https://roc-solid.github.io/ecosystem/audio).

## Installing it

Name the package in the app's header and list the plugin in the program:

```roc
# main.roc
app [program] { audio: "../packages/audio/main.roc", pf: platform "../server/platform/main.roc" }

import audio.AudioPlayer

program = App.program({
	init!,
	middleware: Middlewares.default,
	plugins: [AudioPlayer.plugin({})],
})
```

Then play a sound from any handler, in any component, page or module, on either half of the app:

```roc
import audio.Audio

<button on:click={|| Audio.play!("/sounds/eat.wav")}>Eat</button>
<button on:click={|| Audio.play_with!("/sounds/pop.wav", { volume: 0.5, rate: 2.0 })}>Pop</button>
```

## API

| Module | Where | Function | What it does |
|---|---|---|---|
| `Audio` | both halves (`main.roc` and `browser.roc` list it) | `play! : Str => {}` | Plays the file at the URL, at its own volume and speed. |
| | | `play_with! : Str, { volume : F64, rate : F64 } => {}` | Plays it at a `volume` (0 to 1) and a `rate` (2.0 is twice as fast, and an octave higher). |
| `AudioPlayer` | the server's half | `plugin : {} -> Plugin.Value(context, ctx)` | The plugin. Its one file is the player's script. |

A URL that begins with `/` is the site's, under its base; a whole URL plays from anywhere. A volume
or rate that no sound could use (NaN, an infinity, below 0, above 1000) is replaced by 1 before it
is sent. The player then keeps the volume between 0 and 1 and the rate between 1/16 and 16.

`AudioPlayer.plugin` takes `{}` even though it has no options: a plugin is generic in the app's
context type, and in Roc a plain value can have only one type, so the plugin has to be a function.

## When it plays

`Audio.play!` is a `Browser.call!("audio.play", { url, volume, rate })`, so it follows that
function's rules:

- It runs once the handler is done and the page is patched with what the handler wrote. A handler
  that waits for the server runs again when the answer comes, and plays once.
- Only a handler plays: an event's handler, a timer, or an effect's apply. Called while a hole, a
  memo or a component's body is computed, it fails. On the server, it fails.
- Browsers keep a page silent until the reader has done something on it. Until then nothing plays,
  and the player doesn't report that as an error.
- A file that can't be played is reported on the console. Without the plugin in the app's plugins,
  a play is reported on the console as "no effect is called audio.play: the audio plugin's script
  registers it: is the audio plugin in the app's plugins?"

## How it works

The plugin's one file is `static/audio.js`, served at `/rocx/plugins/audio/audio.js`. The server
adds it to every page it renders, before `start.js`, so the effect is registered before the page
wakes. The script registers the browser effect `audio.play` on `window.rocxEffects`, which
`Browser.call!` looks in. For each play it makes an HTML `Audio` element for the URL, sets its volume
and playback rate (with `preservesPitch` off, so the pitch moves with the speed), and plays it.

A URL that begins with `/` is passed through `under`, which the runtime gives every effect, so
`/sounds/eat.wav` is `/rocx/sounds/eat.wav` on a copy of the site served at `/rocx/`.

## Sound files

The package brings none: the app serves its own, like any other file (`--static`). The docs site's
are in `site/static/sounds/`, the quiz example's in `examples/quiz/static/sounds/` and the pomodoro
example's in `examples/pomodoro/static/sounds/`. Each is made by a script beside it (`sounds.mjs`):
chiptune notes, a mallet, a reed.

## On a phone

An app on the Android host plays with no script. The host's own handler for `audio.play`
(`native/android/app/src/dev/rocx/phone/Calls.kt`) plays the file with a MediaPlayer, fetched from
the app's server when the URL is a path, at the volume and rate given. examples/pomodoro plays its
chime this way.

## Not yet

- A sound can't be stopped, paused or looped once it starts.
- A play answers nothing: the app can't tell when a sound ends, or whether it played.
- A file can't be loaded ahead of its first play.

## Moving from `pf.Audio`

`Audio.play!` used to be part of both platforms. An app that used it names the package in its
header, imports `audio.Audio` where it imported `pf.Audio`, and lists `AudioPlayer.plugin({})`. Its
sound files and their paths stay as they were.
