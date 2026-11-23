## Audio for Roc Solid apps: sound files, played from a handler (`Audio.play!`), and the plugin that
## serves the player, the script that plays them in the browser (`AudioPlayer.plugin`). It names
## the server platform, for the plugin; the browser's half sees `Audio` alone (`browser.roc`), which
## both halves compile, so a component that plays a sound type-checks on each. See README.md.
package [Audio, AudioPlayer] { pf: platform "../../server/platform/main.roc" }
