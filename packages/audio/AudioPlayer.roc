import pf.Plugin
import "static/audio.js" as player : List(U8)

## The audio plugin: the player, a script every page loads (`/rocx/plugins/audio/audio.js`, before
## start.js), which plays what `Audio.play!` asks for. Listed once, in the app's plugins:
##
## ```roc
## plugins: [AudioPlayer.plugin({})]
## ```
AudioPlayer := [].{

	## The plugin: the player's script, served before the app and its middleware, and loaded by
	## every page. (A function even with no options: a plugin is generic in the app's context, and a
	## value can have only one type.)
	plugin : {} -> Plugin.Value(context, ctx)
	plugin = |{}| {
		name: "audio",
		files: [{ path: "audio.js", at: Plugin, content_type: "text/javascript", body: player }],
		scripts: ["audio.js"],
	}
}
