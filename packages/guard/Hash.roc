## A small, stable hash of text: the same number for the same text, on every machine, in every
## build. What puts a user in or out of a flag's rollout (`Flags`), and a key in a tally's shard
## (`Tally.shard`). FNV-1a (64 bits), mixed by MurmurHash3's finalizer so that every bit of the
## text moves every bit of the hash; not a cryptographic hash.
Hash := [].{

	## The 64-bit hash of `text`.
	of : Str -> U64
	of = |text| {
		var $hash = 14695981039346656037
		for byte in text.to_utf8() {
			$hash = U64.times_wrap(U64.bitwise_xor($hash, byte.to_u64()), 1099511628211)
		}
		mixed($hash)
	}

	## `text`'s place among `count` (0 up to `count - 1`), the same each time: 0 when `count` is 0.
	bucket : Str, U64 -> U64
	bucket = |text, count| if (count == 0) 0 else Hash.of(text) % count

	## FNV-1a alone, as its authors publish it, without the mixing: for checking against their
	## test values.
	fnv1a : Str -> U64
	fnv1a = |text| {
		var $hash = 14695981039346656037
		for byte in text.to_utf8() {
			$hash = U64.times_wrap(U64.bitwise_xor($hash, byte.to_u64()), 1099511628211)
		}
		$hash
	}
}

## MurmurHash3's 64-bit finalizer (`fmix64`).
mixed : U64 -> U64
mixed = |start| {
	a = U64.times_wrap(U64.bitwise_xor(start, U64.shr_zf_wrap(start, 33)), 0xff51afd7ed558ccd)
	b = U64.times_wrap(U64.bitwise_xor(a, U64.shr_zf_wrap(a, 33)), 0xc4ceb9fe1a85ec53)
	U64.bitwise_xor(b, U64.shr_zf_wrap(b, 33))
}

# FNV-1a's published values (Landon Curt Noll's test suite): "", "a", "foobar".
expect Hash.fnv1a("") == 0xcbf29ce484222325
expect Hash.fnv1a("a") == 0xaf63dc4c8601ec8c
expect Hash.fnv1a("foobar") == 0x85944171f73967e8

# fmix64 sends 0 to 0, and is the same each time.
expect mixed(0) == 0
expect Hash.of("flag/ada") == Hash.of("flag/ada")
expect Hash.of("flag/ada") != Hash.of("flag/adb")

# Buckets stay in range, and spread: 10,000 names over 4 buckets, each within 5% of a quarter.
expect Hash.bucket("anything", 0) == 0
expect {
	var $buckets = []
	for n in (0).until(10000) {
		$buckets = $buckets.append(Hash.bucket("user-${n.to_str()}", 4))
	}
	[0, 1, 2, 3].all(
		|at| {
			count = $buckets.keep_if(|bucket| bucket == at).len()
			count > 2375 and count < 2625
		},
	)
}
