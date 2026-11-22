## Pseudo-random numbers, purely: each one comes with the seed for the next. A component keeps the
## seed in a signal, so the same steps always give the same numbers.
Random := [].{

	## A number from 0 up to (not including) 1, and the next seed.
	float : U64 -> { value : F64, seed : U64 }
	float = |seed| {
		next = step(seed)
		{ value: next.to_f64() / 2147483648.0, seed: next }
	}

	## A whole number from 0 up to (not including) `count`, and the next seed.
	below : U64, U64 -> { value : U64, seed : U64 }
	below = |seed, count| {
		next = step(seed)
		# The high bits: a linear congruential generator's low ones repeat quickly.
		{ value: (next // 65536) % (if (count == 0) 1 else count), seed: next }
	}
}

## The C library's old generator, modulo 2^31: the product stays well under 2^64.
step : U64 -> U64
step = |seed| (seed % 2147483648 * 1103515245 + 12345) % 2147483648

expect Random.float(1).value >= 0.0 and Random.float(1).value < 1.0
expect Random.below(42, 10).value < 10
expect Random.float(7).seed != 7
