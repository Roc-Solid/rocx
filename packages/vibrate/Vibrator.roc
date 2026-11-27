import pf.Plugin
import "static/vibrate.js" as script : List(U8)

## The vibrate plugin: the browser's half, a script every page loads
## (`/rocx/plugins/vibrate/vibrate.js`, before start.js), which passes what `Vibrate.pattern!`
## asks for to `navigator.vibrate`. Listed once, in the app's plugins:
##
## ```roc
## plugins: [Vibrator.plugin({})]
## ```
##
## A phone app (D-063's native host) needs no script: the phone's own handler buzzes.
Vibrator := [].{

	## The plugin: the script, served before the app and its middleware, and loaded by every page.
	## (A function even with no options: a plugin is generic in the app's context, and a value can
	## have only one type.)
	plugin : {} -> Plugin.Value(context)
	plugin = |{}| {
		name: "vibrate",
		files: [{ path: "vibrate.js", at: Plugin, content_type: "text/javascript", body: script }],
		scripts: ["vibrate.js"],
	}
}
