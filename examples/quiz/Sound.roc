import audio.Audio

## Pinwheel's sounds (`static/sounds/`, which `sounds.mjs` makes), played from a handler, an
## effect's apply or a timer, when the page's sound is on.
Sound := [].{

	## What there is to hear: the clock's last seconds, a choice sent, someone joining, a question
	## opening, a right answer, a wrong one, and the podium.
	Name : [Tick, Tock, Pick, Join, Go, Right, Wrong, Podium]

	## Plays `name`, if `on`.
	play! : Bool, Sound.Name => {}
	play! = |on, name| if (on) Audio.play!("/sounds/${Sound.file(name)}.wav") else {}

	## A sound's file, without its `.wav`.
	file : Sound.Name -> Str
	file = |name|
		match name {
			Tick => "tick"
			Tock => "tock"
			Pick => "pick"
			Join => "join"
			Go => "go"
			Right => "right"
			Wrong => "wrong"
			Podium => "podium"
		}
}

expect [Tick, Wrong, Podium].map(Sound.file) == ["tick", "wrong", "podium"]
