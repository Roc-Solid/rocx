import Host

## Random numbers from the operating system (for a salt, a token, an id). Shaped as basic-cli's,
## so packages written for it (roc-pg's `random_u64!`) take these as they are.
Random := [].{

	## A random U64. Always `Ok`: the `Try` is basic-cli's shape.
	seed_u64! : () => Try(U64, [RandomErr(Str)])
	seed_u64! = || Ok(Host.random_u64!({}))

	## `count` random bytes: a token, a key.
	bytes! : U64 => List(U8)
	bytes! = |count| Host.random_bytes!(count)
}
