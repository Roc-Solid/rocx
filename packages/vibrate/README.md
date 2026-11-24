# vibrate

The phone's vibration motor for Roc Solid apps, as a plugin: a handler buzzes it once or in a
pattern. In a browser the plugin's script passes the pattern to `navigator.vibrate` (Chrome on
Android buzzes; a computer's browser, Safari and Firefox do nothing). On an Android phone, an app
on D-063's native host, the phone's own handler buzzes, with no script.

```roc
# main.roc: the header names the package, and the plugins list the browser's half
app [program] { vibrate: "…/packages/vibrate/main.roc", pf: platform "…/server/platform/main.roc" }

import vibrate.Vibrator

program = App.program({ …, plugins: [Vibrator.plugin({})] })
```

```roc
# Any component, page or module, in either half
import vibrate.Vibrate

<button on:click={|| Vibrate.once!(400)}>Buzz</button>
<button on:click={|| Vibrate.pattern!([200, 100, 200])}>Buzz twice</button>
```

## The parts

| Module | Where | What it does |
|---|---|---|
| `Vibrate` | both halves (`main.roc` and `browser.roc` list it) | `once!(ms)`, `pattern!(list)`: a `Browser.call!("vibrate.pattern", { pattern })`, milliseconds on, off, on…; each step at most 10 s, at most 32 steps. |
| `Vibrator` | the server's half | `plugin({})`: the plugin, whose one file is the browser's script (`static/vibrate.js`, served at `/rocx/plugins/vibrate/vibrate.js`), which every page the server renders loads before start.js (D-050). |

## When it buzzes

A buzz goes as any `Browser.call!` does: once the handler is done and the screen is patched with
what it wrote. Only a handler (or an effect's apply, or a timer's) buzzes; while computing, and on
the server, it fails. A browser may refuse to buzz for a page the reader hasn't touched yet, and that
is no failure.

## On a phone

D-063's Android host has a native half for this plugin (native/android/app's `Calls.kt`):
`vibrate.pattern` is Android's `Vibrator`, the pattern as a waveform. The app's manifest asks for
`android.permission.VIBRATE`, which Android grants at install.
