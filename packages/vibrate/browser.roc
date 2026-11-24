## Vibration as the browser's half of an app sees it: `Vibrate` (`once!`, `pattern!`), on the
## browser's platform (`rocx build --client` names this header there). `main.roc` has it and the
## plugin (`Vibrator`), on the server's.
package [Vibrate] { pf: platform "../../web/platform/main.roc" }
