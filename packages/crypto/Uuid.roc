import Hex

## UUIDs (RFC 9562), written as text in lowercase: 36 characters, hex digits in groups of 8, 4, 4, 4
## and 12. Version 7 (`v7`) leads with the time it was made, so ids made later sort after earlier
## ones, as text and as bytes, and rows inserted by id go to the end of an index; version 4 (`v4`)
## is random throughout. Both are given their random bytes (the server platform's `Random.bytes!`)
## and `v7` the time (`Time.now_millis!`), so the module stays plain Roc on no platform and an
## `expect` gives the same bytes and gets the same id.
Uuid := [].{

	## A version 7 UUID: `millis` (milliseconds since 1970; the low 48 bits, enough until the year
	## 10889) in its first 12 digits, then 74 random bits from the first 10 of `random` (a byte
	## missing counts as 0), with the version and variant bits set. Two made in the same millisecond
	## are ordered by their random bits, not by which came first (RFC 9562, 6.2, allows that).
	v7 : U64, List(U8) -> Str
	v7 = |millis, random| {
		at = |index| random.get(index) ?? 0
		time = [5, 4, 3, 2, 1, 0].map(|place| (millis // (256.U64).pow(place)).to_u8_wrap())
		rand = [at(0).bitwise_and(0x0f).bitwise_or(0x70), at(1), at(2).bitwise_and(0x3f).bitwise_or(0x80), at(3), at(4), at(5), at(6), at(7), at(8), at(9)]
		written(time.concat(rand))
	}

	## A version 4 UUID: the first 16 of `random` (a byte missing counts as 0), with the version
	## and variant bits set.
	v4 : List(U8) -> Str
	v4 = |random| {
		given = random.sublist({ start: 0, len: 16 })
		bytes = given.concat(List.repeat(0, 16 - given.len())).map_with_index(
			|byte, index|
				if index == 6 {
					byte.bitwise_and(0x0f).bitwise_or(0x40)
				} else if index == 8 {
					byte.bitwise_and(0x3f).bitwise_or(0x80)
				} else {
					byte
				},
		)
		written(bytes)
	}

	## Whether `text` is a UUID as text: hex digits (either case) in groups of 8, 4, 4, 4 and 12,
	## with hyphens between. Any version, or none (the nil UUID is one).
	is_uuid : Str -> Bool
	is_uuid = |text| {
		chars = text.to_utf8()
		if chars.len() != 36 {
			return Bool.False
		}
		var $at = 0
		for char in chars {
			ok = if ($at == 8 or $at == 13 or $at == 18 or $at == 23) char == '-' else hex(char)
			if !ok {
				return Bool.False
			}
			$at = $at + 1
		}
		Bool.True
	}
}

written : List(U8) -> Str
written = |bytes| {
	part = |start, len| Hex.encode(bytes.sublist({ start, len }))
	"${part(0, 4)}-${part(4, 2)}-${part(6, 2)}-${part(8, 2)}-${part(10, 6)}"
}

hex : U8 -> Bool
hex = |char| (char >= '0' and char <= '9') or (char >= 'a' and char <= 'f') or (char >= 'A' and char <= 'F')

# RFC 9562's own examples: A.6 (version 7, 2022-02-22 19:22:22 UTC) and A.4 (version 4).
expect Uuid.v7(0x017F22E279B0, [0x0C, 0xC3, 0x18, 0xC4, 0xDC, 0x0C, 0x0C, 0x07, 0x39, 0x8F]) == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
expect Uuid.v4([0x91, 0x91, 0x08, 0xf7, 0x52, 0xd1, 0x43, 0x20, 0x9b, 0xac, 0xf8, 0x47, 0xdb, 0x41, 0x48, 0xa8]) == "919108f7-52d1-4320-9bac-f847db4148a8"

# The version and variant bits are set whatever the random bytes say.
expect Uuid.v7(0, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) == "00000000-0000-7fff-bfff-ffffffffffff"
expect Uuid.v7(0, []) == "00000000-0000-7000-8000-000000000000"
expect Uuid.v4(List.repeat(0xff, 16)) == "ffffffff-ffff-4fff-bfff-ffffffffffff"
expect Uuid.v4([]) == "00000000-0000-4000-8000-000000000000"

# Bits above the 48 the time has room for are dropped.
expect Uuid.v7(0x1_0000_0000_0001, []) == "00000000-0001-7000-8000-000000000000"

# The time leads, so a later millisecond sorts after an earlier one, whatever their random bits.
expect Uuid.v7(1_795_864_084_000, List.repeat(0xff, 10)).starts_with("01a221d7-3e20-")
expect Uuid.v7(1_795_864_084_001, []).starts_with("01a221d7-3e21-")

expect Uuid.is_uuid("017f22e2-79b0-7cc3-98c4-dc0c0c07398f")
expect Uuid.is_uuid("017F22E2-79B0-7CC3-98C4-DC0C0C07398F")
expect Uuid.is_uuid("00000000-0000-0000-0000-000000000000")
expect !Uuid.is_uuid("")
expect !Uuid.is_uuid("017f22e279b07cc398c4dc0c0c07398f")
expect !Uuid.is_uuid("017f22e2-79b0-7cc3-98c4-dc0c0c07398")
expect !Uuid.is_uuid("017f22e2-79b0-7cc3-98c4-dc0c0c07398g")
expect !Uuid.is_uuid("017f22e2_79b0-7cc3-98c4-dc0c0c07398f")
expect !Uuid.is_uuid("someone@example.com")
