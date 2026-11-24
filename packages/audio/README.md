# audio

Sound files for Roc Solid apps, as a plugin (D-051). A handler plays any file the browser can
(WAV, MP3, Ogg, …), at a volume and a rate, with nothing prepared in advance: the browser fetches a
file the first time it plays it, and keeps it.

```roc
# main.roc: the header names the package, and the plugins list the player
app [program] { audio: "…/packages/audio/main.roc", pf: platform "…/server/platform/main.roc" }

import audio.AudioPlayer

program = App.program({ …, plugins: [AudioPlayer.plugin({})] })
```

```roc
# Any component, page or module, in either half
import audio.Audio

<button on:click={|| Audio.play!("/sounds/eat.wav")}>Eat</button>
<button on:click={|| Audio.play_with!("/sounds/pop.wav", { volume: 0.5, rate: 2.0 })}>Pop</button>
```

## The parts

| Module | Where | What it does |
|---|---|---|
| `Audio` | both halves (`main.roc` and `browser.roc` list it) | `play!(url)`, `play_with!(url, { volume, rate })`: a `Browser.call!("audio.play", { url, volume, rate })`. A volume is 0 to 1; a rate of 2.0 is twice as fast and an octave up. A number no sound could use (NaN, below 0, above 1000) is 1. |
| `AudioPlayer` | the server's half | `plugin({})`: the plugin, whose one file is the player's script (`static/audio.js`, served at `/rocx/plugins/audio/audio.js`), which every page the server renders loads before start.js (D-050). |

`static/audio.js` registers the browser effect `audio.play` on `window.rocxEffects`, which
`Browser.call!` finds: it makes an `Audio` for the URL (one that begins with `/` put under the
site's base by `under`, which the runtime gives every effect, so `/sounds/eat.wav` is
`/rocx/sounds/eat.wav` on a copy of the site served at `/rocx/`), sets its volume and rate (its pitch
moving with its speed), and plays it. A file that can't be played is told on the console; a page the
reader hasn't touched yet is kept quiet by the browser, and that is no failure.

## When it plays

A play goes as any `Browser.call!` does: once the handler is done and the page is patched with what
it wrote, and once for a handler that waits for the server and runs again. Only a handler (or an
effect's apply, or a timer's) plays; while computing, and on the server, it fails. Without the plugin
in the app's plugins, a play is told on the console: "no effect is called audio.play: the audio
plugin's script registers it: is the audio plugin in the app's plugins?"

## Sound files

The package brings none: the app serves its own, as any other file (`--static`). The docs site's are
in `site/static/sounds/` and the quiz example's in `examples/quiz/static/sounds/`, chiptune notes
and a mallet and a reed that a script of each makes (`site/sounds.mjs`, `examples/quiz/sounds.mjs`).
A whole URL plays from anywhere.

## Moving to it

`Audio.play!` was the platforms' own, and its player web/runtime.js's (`rocx:audio`), so every app
shipped the player. An app that plays sounds now names the package in its header, imports
`audio.Audio` where it imported `pf.Audio`, and lists `AudioPlayer.plugin({})`. Its sound files and
their paths stay as they were.

## On a phone

An app on D-063's Android host plays with no script: the host's native handler for `audio.play`
(native/android/app's `Calls.kt`) is a MediaPlayer, which fetches a path from the app's server (as
the browser's `under` puts it under the site) at the volume and rate given, its pitch moving with
its speed. examples/pomodoro plays its chime this way.
