## The arithmetic of a moment in a video: how far along a span a frame is, eased, sprung or through
## keyframes, and what a number or a text is there. Frames are whole (`U64`, from 0, as
## `Player.clock!`'s `frame!` gives them); what they make is a share (`F64`, 0 to 1) or a value made
## from one. Every function gives the same answer for the same frame, so a frame looks the same
## played live, scrubbed to, or rendered.
##
##     percent = Timeline.tween(frame, 40, 120, 0.0, 100.0, Out)       # 0 until 40, 100 from 120
##     opacity = Timeline.keys(frame, [(0, 0.0), (10, 1.0), (110, 1.0), (120, 0.0)])
##     pop = Timeline.spring(frame - 30, 30)                           # past 1 and back, settling
Timeline := [].{

	## How a motion goes along its span: steadily (`Linear`), starting slowly (`In`), ending slowly
	## (`Out`), both (`InOut`), or ending past its goal and coming back (`Back`). The curves are
	## cubic, as CSS's ease-in and ease-out nearly are.
	Easing : [Linear, In, Out, InOut, Back]

	## How far `frame` is along the span from `from` to `to`: 0 at `from` and before, 1 at `to` and
	## after, steadily between. A span of no length is 0 before it and 1 from it on.
	progress : U64, U64, U64 -> F64
	progress = |frame, from, to| {
		if to <= from {
			if frame >= from {
				1.0
			} else {
				0.0
			}
		} else if frame <= from {
			0.0
		} else if frame >= to {
			1.0
		} else {
			(frame - from).to_f64() / (to - from).to_f64()
		}
	}

	## A share (0 to 1; outside, held at its end) as `easing` moves it: what was steady, eased.
	ease : F64, Easing -> F64
	ease = |share, easing| {
		x = F64.min(F64.max(share, 0.0), 1.0)
		match easing {
			Linear => x
			In => x * x * x
			Out => {
				left = 1.0 - x
				1.0 - left * left * left
			}
			InOut =>
				if x < 0.5 {
					4.0 * x * x * x
				} else {
					left = 2.0 - 2.0 * x
					1.0 - left * left * left / 2.0
				}
			Back => {
				# easeOutBack: about a tenth past the goal, and back.
				pull = 1.70158
				left = x - 1.0
				1.0 + (pull + 1.0) * left * left * left + pull * left * left
			}
		}
	}

	## How far `frame` is along the span from `from` to `to`, eased: `progress`, then `ease`.
	eased : U64, U64, U64, Easing -> F64
	eased = |frame, from, to, easing| Timeline.ease(Timeline.progress(frame, from, to), easing)

	## The value `share` of the way from `a` to `b`: `a` at 0, `b` at 1 (a share past either end
	## goes past it, as `Back`'s and a spring's do).
	mix : F64, F64, F64 -> F64
	mix = |a, b, share| a + (b - a) * share

	## A value going from `a` to `b` over the span from `from` to `to`, eased: `a` until `from`, `b`
	## from `to` on.
	tween : U64, U64, U64, F64, F64, Easing -> F64
	tween = |frame, from, to, a, b, easing| Timeline.mix(a, b, Timeline.eased(frame, from, to, easing))

	## A value through keyframes, each `(frame, value)` in the order of their frames: the first's
	## value until its frame, then steadily from each to the next, then the last's. None is 0.
	##
	##     Timeline.keys(frame, [(0, 0.0), (10, 1.0), (110, 1.0), (120, 0.0)])   # in, held, out
	keys : U64, List((U64, F64)) -> F64
	keys = |frame, points| Timeline.keys_with(frame, points, Linear)

	## A value through keyframes as `keys`, each move between two of them eased: a pointer that
	## glides from place to place and rests at each.
	keys_with : U64, List((U64, F64)), Easing -> F64
	keys_with = |frame, points, easing| {
		var $before = NotYet
		for point in points {
			(at, value) = point
			match $before {
				NotYet =>
					if frame <= at {
						return value
					}
				Was(from, last) =>
					if frame <= at {
						return Timeline.mix(last, value, Timeline.eased(frame, from, at, easing))
					}
			}
			$before = Was(at, value)
		}
		match $before {
			NotYet => 0.0
			Was(_, last) => last
		}
	}

	## A spring let go at frame 0, from 0 toward 1, `fps` frames a second: it overshoots a little
	## and settles in about a second (stiffness 100, damping 10, mass 1, as Remotion's spring
	## starts). Give it the frames since it was let go (`frame - 30`, with frames before 30 kept
	## at 0 by `since`). For another feel, `spring_with`.
	spring : U64, U64 -> F64
	spring = |frame, fps| Timeline.spring_with(frame, fps, { stiffness: 100.0, damping: 10.0, mass: 1.0 })

	## A spring let go at frame 0, from 0 toward 1: stiffer is quicker, more damping overshoots less
	## (none at `damping * damping >= 4 * stiffness * mass`), heavier is slower. 0 frames a second
	## is taken as 30.
	spring_with : U64, U64, { stiffness : F64, damping : F64, mass : F64 } -> F64
	spring_with = |frame, fps, { stiffness, damping, mass }| {
		t = frame.to_f64() / (if (fps == 0) 30.0 else fps.to_f64())
		natural = F64.sqrt(stiffness / mass)
		ratio = damping / (2.0 * F64.sqrt(stiffness * mass))
		if ratio < 1.0 {
			# Under-damped: an oscillation that dies away.
			ringing = natural * F64.sqrt(1.0 - ratio * ratio)
			1.0 - Timeline.exp(0.0 - ratio * natural * t) * (F64.cos(ringing * t) + ratio * natural / ringing * F64.sin(ringing * t))
		} else if ratio == 1.0 {
			1.0 - Timeline.exp(0.0 - natural * t) * (1.0 + natural * t)
		} else {
			spread = natural * F64.sqrt(ratio * ratio - 1.0)
			fast = 0.0 - natural * ratio - spread
			slow = 0.0 - natural * ratio + spread
			1.0 - (fast * Timeline.exp(slow * t) - slow * Timeline.exp(fast * t)) / (fast - slow)
		}
	}

	## The frames since `start`: 0 before it. For a spring or a span that starts at a frame.
	since : U64, U64 -> U64
	since = |frame, start| if (frame <= start) 0 else frame - start

	## `seconds` at `fps` frames a second, in whole frames (rounded).
	frames_of : F64, U64 -> U64
	frames_of = |seconds, fps| Timeline.whole_u64(seconds * fps.to_f64())

	## `value` rounded to a whole number: a count shown as it climbs.
	round : F64 -> I64
	round = |value| value.round_to_i64_try() ?? 0

	## The first `share` (0 to 1) of `text`'s characters: a text as it is typed, a character at a
	## time. A character is a code point, so an emoji or an accent may take two steps.
	typed : Str, F64 -> Str
	typed = |text, share| {
		bytes = text.to_utf8()
		# A code point starts at each byte that doesn't continue one (10xxxxxx).
		count = bytes.keep_if(|byte| byte.bitwise_and(0xC0) != 0x80).len()
		keep = Timeline.whole_u64(F64.min(F64.max(share, 0.0), 1.0) * count.to_f64())
		var $seen = 0
		var $index = 0
		for byte in bytes {
			if byte.bitwise_and(0xC0) != 0x80 {
				if $seen == keep {
					return Str.from_utf8_lossy(bytes.take_first($index))
				}
				$seen = $seen + 1
			}
			$index = $index + 1
		}
		text
	}

	## e to the power `x`.
	exp : F64 -> F64
	exp = |x| F64.pow(2.718281828459045, x)

	## `value` rounded to a whole number, 0 below 0.
	whole_u64 : F64 -> U64
	whole_u64 = |value| if (value <= 0.0) 0 else value.round_to_u64_try() ?? 0
}

expect Timeline.progress(0, 10, 20) == 0.0
expect Timeline.progress(10, 10, 20) == 0.0
expect Timeline.progress(15, 10, 20) == 0.5
expect Timeline.progress(25, 10, 20) == 1.0
expect Timeline.progress(9, 10, 10) == 0.0 and Timeline.progress(10, 10, 10) == 1.0
expect Timeline.ease(0.5, Linear) == 0.5
expect Timeline.ease(0.0, Out) == 0.0 and Timeline.ease(1.0, Out) == 1.0
expect Timeline.ease(0.5, Out) == 0.875 and Timeline.ease(0.5, In) == 0.125
expect Timeline.ease(0.5, InOut) == 0.5
expect Timeline.ease(2.0, In) == 1.0
expect Timeline.ease(0.8, Back) > 1.0 and Timeline.ease(1.0, Back) == 1.0
expect Timeline.tween(30, 20, 40, 0.0, 100.0, Linear) == 50.0
expect Timeline.tween(0, 20, 40, 10.0, 100.0, Out) == 10.0
expect Timeline.keys(0, [(10, 1.0), (20, 3.0)]) == 1.0
expect Timeline.keys(15, [(10, 1.0), (20, 3.0)]) == 2.0
expect Timeline.keys(30, [(10, 1.0), (20, 3.0)]) == 3.0
expect Timeline.keys(5, []) == 0.0
expect Timeline.keys_with(15, [(10, 0.0), (20, 8.0)], InOut) == 4.0
expect Timeline.keys_with(12, [(10, 0.0), (20, 8.0)], InOut) < Timeline.keys(12, [(10, 0.0), (20, 8.0)])
expect Timeline.spring(0, 30) == 0.0
expect Timeline.spring(90, 30) > 0.99 and Timeline.spring(90, 30) < 1.01
expect Timeline.spring_with(90, 30, { stiffness: 100.0, damping: 20.0, mass: 1.0 }) > 0.99
expect Timeline.spring_with(90, 30, { stiffness: 100.0, damping: 40.0, mass: 1.0 }) < 1.0
expect [10, 15, 20, 25, 30].map(|frame| Timeline.spring(frame, 30)).any(|x| x > 1.0)
expect Timeline.since(10, 30) == 0 and Timeline.since(45, 30) == 15
expect Timeline.frames_of(1.5, 30) == 45
expect Timeline.round(2.5) == 3 and Timeline.round(-1.4) == -1
expect Timeline.typed("Sat 14 Nov", 0.0) == ""
expect Timeline.typed("Sat 14 Nov", 0.3) == "Sat"
expect Timeline.typed("Sat 14 Nov", 1.0) == "Sat 14 Nov"
expect Timeline.typed("née", 0.67) == "né"
