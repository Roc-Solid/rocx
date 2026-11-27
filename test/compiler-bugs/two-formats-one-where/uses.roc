# Uses of a definition whose where clause asks for two formats' `read`
# (Formats.roc). `Thing` has the first format's `read`, so `thing`'s use
# would check against that requirement alone, and `forward` copies both
# requirements into its own where clause. `roc test` reports the rejection
# and runs the expect beside them.

import Formats

Thing := [T].{
	read : Formats.Left -> Thing
	read = |_| T
}

thing : Thing
thing = Formats.both({})

forward = |x| Formats.both(x)

expect 1 + 1 == 2
