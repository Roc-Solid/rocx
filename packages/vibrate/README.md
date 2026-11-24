# vibrate

Buzz the phone's vibration motor from a handler in a Roc Solid app, once or in a pattern. In a
browser, the package's plugin passes the pattern to `navigator.vibrate`. In an Android app on the
native host, the host plays it on Android's `Vibrator`. The user guide is the docs site's
[Vibrate page](https://roc-solid.github.io/ecosystem/vibrate); this file is the reference.

## Installing it

Name the package in the app's header and add the plugin to the app's plugins:

```roc
# main.roc
app [program] { pf: platform "…/server/platform/main.roc", vibrate: "…/packages/vibrate/main.roc" }

import vibrate.Vibrator
import Generated/App

program = App.program({
	# …
	plugins: [Vibrator.plugin({})],
})
```

Then import `Vibrate` wherever a handler buzzes, in a page, a component or a module:

```roc
import vibrate.Vibrate

<button on:click={|| Vibrate.once!(400)}>Buzz</button>
<button on:click={|| Vibrate.pattern!([200, 100, 200])}>Buzz twice</button>
```

## API

| Module | Compiled by | Function | What it does |
|---|---|---|---|
| `Vibrate` | both halves (`main.roc` and `browser.roc` expose it) | `once! : U64 => {}` | Buzzes once for that many milliseconds. Same as `pattern!([ms])`. |
| | | `pattern! : List(U64) => {}` | Buzzes in a pattern: milliseconds on, off, on, and so on, as `navigator.vibrate` takes them. Each step is cut to 10 s at most, and only the first 32 steps play. |
| `Vibrator` | the server's half (`main.roc` alone) | `plugin : {} -> Plugin.Value(context, ctx)` | The plugin. Its one file is the browser's script, `static/vibrate.js`, served at `/rocx/plugins/vibrate/vibrate.js` and loaded by every page before `start.js`. |

`plugin` takes `{}` even though it has no options. A plugin is generic in the app's context type,
and in Roc a plain value can have only one type, so the plugin is a function.

## How it works

`Vibrate.pattern!` is `Browser.call!("vibrate.pattern", { pattern })`, so a buzz follows the rules
of every `Browser.call!`:

- It runs once the handler is done and the page is patched with what the handler wrote. A handler
  that waits for the server and runs again buzzes once.
- Only a handler can buzz: an event's handler, an effect's `apply`, or a timer's callback. Calling it
  while computing (a hole, a memo, a component's body) or on the server fails.

**In a browser**, the plugin's script registers the effect `vibrate.pattern` on
`window.rocxEffects` and passes the pattern to `navigator.vibrate`. Chrome on Android buzzes.
Desktop browsers, Safari and Firefox don't let a page use a motor, so there the call does nothing,
and nothing fails. A browser may also refuse to buzz for a page the reader hasn't touched yet; that
isn't an error either.

**On an Android phone**, an app on the native host needs no script. The host sends a plugin's
`Browser.call!` to a native handler with the same name (`native/android/app/src/dev/rocx/phone/Calls.kt`):
`vibrate.pattern` plays the pattern on Android's `Vibrator` as a waveform. The app's manifest asks
for `android.permission.VIBRATE`, which Android grants at install.

## Used by

`examples/pomodoro` buzzes `[300, 150, 300]` when a focus session ends, beside the chime it plays
with `packages/audio`.
