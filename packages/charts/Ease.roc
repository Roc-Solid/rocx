## A glide toward a goal, a frame at a time: each frame goes a share of the way that is left, more
## the longer the frame, and the rest at once when it is close, so a glide ends (and with it, the
## frames a chart asks for).
Ease := [].{

	## `from` moved toward `to` for a frame of `ms` milliseconds: a fifth of the way in a 16 ms
	## frame (60 a second), all of it in one of 80 ms or more, or when it is within `close`.
	toward : Dec, Dec, F64, Dec -> Dec
	toward = |from, to, ms, close| {
		next = from + (to - from) * Ease.share(ms)
		if Dec.abs(to - next) <= close {
			to
		} else {
			next
		}
	}

	## The share of the way left that a frame of `ms` milliseconds goes: `ms / 80`, at most all of it.
	share : F64 -> Dec
	share = |ms| {
		whole = (ms * 1000.0).round_to_i64_try() ?? 16000
		Dec.min(Dec.max(whole.to_dec() / 80000.0, 0.0), 1.0)
	}
}

expect Ease.share(16.0) == 0.2
expect Ease.share(200.0) == 1.0
expect Ease.share(-5.0) == 0.0
expect Ease.toward(0.0, 100.0, 16.0, 0.5) == 20.0
expect Ease.toward(99.0, 100.0, 16.0, 1.0) == 100.0
expect Ease.toward(0.0, 100.0, 80.0, 0.5) == 100.0
