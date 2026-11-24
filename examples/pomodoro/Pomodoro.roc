## The timer's rules, pure, the same in the browser, on a phone and on the server: the two kinds of
## session, how long each is, what follows one, and how a time left is shown. The page keeps the
## state (signals) and the clock (an interval); the server keeps the sessions done (Store).
Pomodoro := [].{

	## What the timer is timing.
	Mode : [Focus, Break]

	## The clock: stopped (paused, or not started), or running until a moment (`Time.now_millis!`'s).
	Clock : [Paused, Until(U64)]

	## Today, as `GET /api/today` and `POST /api/sessions` answer it: the focus sessions done since
	## midnight (the server's), and how many make a good day.
	Today : { done : U64, goal : U64 }

	## A focus session done, as the page sends it.
	Done : { minutes : U64 }

	paused : Pomodoro.Clock
	paused = Paused

	focus : Pomodoro.Mode
	focus = Focus

	## A session's length, in minutes: 25 to focus, 5 to rest, as Cirillo's technique has it.
	minutes : Pomodoro.Mode -> U64
	minutes = |mode|
		match mode {
			Focus => 25
			Break => 5
		}

	## A session's length, in milliseconds.
	length : Pomodoro.Mode -> U64
	length = |mode| Pomodoro.minutes(mode) * 60 * 1000

	## What follows a session.
	next : Pomodoro.Mode -> Pomodoro.Mode
	next = |mode|
		match mode {
			Focus => Break
			Break => Focus
		}

	## A mode's name, on its tab and in the title.
	name : Pomodoro.Mode -> Str
	name = |mode|
		match mode {
			Focus => "Focus"
			Break => "Break"
		}

	## What is left of `until`, at `now`: none once it has passed.
	left : U64, U64 -> U64
	left = |until, now| until - U64.min(until, now)

	## A time left as a clock shows it, rounded up to the second (0.2 s left is 00:01, as a kitchen
	## timer's): `25:00`, `04:59`, `00:00`.
	clock : U64 -> Str
	clock = |ms| {
		seconds = (ms + 999) // 1000
		"${two(seconds // 60)}:${two(seconds % 60)}"
	}

	## The share of a session still to go, in thousandths: the ring's `stroke-dasharray`.
	share : U64, Pomodoro.Mode -> U64
	share = |ms, mode| U64.min(1000, ms * 1000 // Pomodoro.length(mode))

	## The day's progress toward its goal, as a CSS width: `37.5%`, never past `100%`.
	progress : Pomodoro.Today -> Str
	progress = |{ done, goal }|
		if goal == 0 {
			"100%"
		} else {
			tenths = U64.min(1000, done * 1000 // goal)
			whole = tenths // 10
			if (tenths % 10 == 0) "${whole.to_str()}%" else "${whole.to_str()}.${(tenths % 10).to_str()}%"
		}

	## How many focus sessions make a good day.
	daily_goal : U64
	daily_goal = 8
}

two : U64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

expect Pomodoro.clock(Pomodoro.length(Focus)) == "25:00"
expect Pomodoro.clock(299_001) == "05:00"
expect Pomodoro.clock(299_000) == "04:59"
expect Pomodoro.clock(200) == "00:01"
expect Pomodoro.clock(0) == "00:00"
expect Pomodoro.left(1000, 400) == 600
expect Pomodoro.left(1000, 1400) == 0
expect Pomodoro.share(Pomodoro.length(Break), Break) == 1000
expect Pomodoro.share(Pomodoro.length(Focus) // 4, Focus) == 250
expect Pomodoro.share(0, Focus) == 0
expect Pomodoro.next(Focus) == Break and Pomodoro.next(Break) == Focus
expect Pomodoro.progress({ done: 3, goal: 8 }) == "37.5%"
expect Pomodoro.progress({ done: 4, goal: 8 }) == "50%"
expect Pomodoro.progress({ done: 12, goal: 8 }) == "100%"
expect Pomodoro.progress({ done: 0, goal: 8 }) == "0%"
