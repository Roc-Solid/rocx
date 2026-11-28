## Audio as the browser's half of an app sees it: `Audio` (`play!`, `play_with!`), on the browser's
## platform (`rocx generate --client` names this header there). `main.roc` has it and the plugin
## (`AudioPlayer`), on the server's.
package [Audio] { pf: platform "../../web/platform/main.roc" }
