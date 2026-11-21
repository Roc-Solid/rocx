## Bands: `count` equal slots across a range, one for each bar, with `padding` (a share of each
## slot, 0 to 1) left empty, half on each side of the bar. A count and a slot may be fractions: a
## chart gliding from seven bars to six has six and a half slots on the way, and a bar moving from
## the first slot to the third is in slot 1.5 halfway there.
Band := { count : Dec, range : (Dec, Dec), padding : Dec }.{

	## `count` slots across `range`, a `padding` share of each left empty.
	band : Dec, (Dec, Dec), Dec -> Band
	band = |count, range, padding| { count, range, padding: Dec.min(Dec.max(padding, 0.0), 1.0) }

	## How wide a slot is: the range shared out.
	slot : Band -> Dec
	slot = |self| {
		(r0, r1) = self.range
		if (self.count <= 0.0) 0.0 else (r1 - r0) / self.count
	}

	## How wide a bar is: its slot, less the padding.
	width : Band -> Dec
	width = |self| self.slot() * (1.0 - self.padding)

	## Where the bar in slot `index` starts.
	at : Band, Dec -> Dec
	at = |self, index| {
		(r0, _) = self.range
		r0 + self.slot() * (index + self.padding / 2.0)
	}

	## The middle of slot `index`: where its label goes.
	center : Band, Dec -> Dec
	center = |self, index| {
		(r0, _) = self.range
		r0 + self.slot() * (index + 0.5)
	}
}

expect Band.band(4, (0.0, 400.0), 0.2).slot() == 100.0
expect Band.band(4, (0.0, 400.0), 0.2).width() == 80.0
expect Band.band(4, (0.0, 400.0), 0.2).at(0) == 10.0
expect Band.band(4, (0.0, 400.0), 0.2).at(3) == 310.0
expect Band.band(4, (0.0, 400.0), 0.2).center(1) == 150.0
expect Band.band(4, (40.0, 440.0), 0.0).at(2) == 240.0
expect Band.band(0, (0.0, 400.0), 0.2).width() == 0.0
expect Band.band(2, (0.0, 100.0), 7.0).width() == 0.0
expect Band.band(6.5, (0.0, 650.0), 0.0).at(1.5) == 150.0
