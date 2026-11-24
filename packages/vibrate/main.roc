## Vibration for Roc Solid apps: the phone's motor, buzzed from a handler (`Vibrate.once!`,
## `Vibrate.pattern!`), and the plugin that serves the browser's half, a script that passes it to
## `navigator.vibrate` (`Vibrator.plugin`). It names the server platform, for the plugin; the
## browser's half sees `Vibrate` alone (`browser.roc`), which both halves compile. On an Android
## phone (D-063) the phone's own handler buzzes. See README.md.
package [Vibrate, Vibrator] { pf: platform "../../server/platform/main.roc" }
