## Join codes: four letters a room is found by, read out loud across a room and typed on a phone.
## Only consonants that can't be mistaken for each other or for a digit (no vowels, so no code
## spells a word; no L, which reads as an I). Plain Roc: the join form's endpoint reads what was
## typed with `Codes.parse`, and the server makes new codes from random bytes (`Codes.from_bytes`).
Codes := [].{

	## The letters a code is made of.
	alphabet : List(U8)
	alphabet = "BCDFGHJKMNPQRSTVWXZ".to_utf8()

	## How many letters a code has.
	length : U64
	length = 4

	## A code from random bytes: each byte picks a letter. Bytes past the last that a fair pick
	## allows (a multiple of the alphabet's size) are passed over, so every letter is as likely;
	## too few bytes give a shorter code, which the caller asks again for.
	from_bytes : List(U8) -> Str
	from_bytes = |bytes| {
		size = Codes.alphabet.len()
		fair = 256 - 256 % size
		picked = bytes.keep_if(|byte| byte.to_u64() < fair).take_first(Codes.length).map(|byte| Codes.alphabet.get(byte.to_u64() % size) ?? 'B')
		Str.from_utf8_lossy(picked)
	}

	## What someone typed, as a code: any case, spaces and dashes left out (`bk-rt` is `BKRT`).
	parse : Str -> Try(Str, [BadCode])
	parse = |typed| {
		letters = typed.with_ascii_uppercased().to_utf8().drop_if(|byte| byte == ' ' or byte == '-')
		if letters.len() == Codes.length and letters.all(|byte| Codes.alphabet.contains(byte)) {
			Ok(Str.from_utf8_lossy(letters))
		} else {
			Err(BadCode)
		}
	}
}

expect Codes.parse("bkrt") == Ok("BKRT")
expect Codes.parse(" bk-rt ") == Ok("BKRT")
expect Codes.parse("BKR") == Err(BadCode)
expect Codes.parse("BKRTX") == Err(BadCode)
expect Codes.parse("BAIT") == Err(BadCode)
expect Codes.parse("") == Err(BadCode)

expect Codes.from_bytes([0, 1, 2, 18]) == "BCDZ"
expect Codes.from_bytes([19, 20, 38]) == "BCB"
# 247 and above would favour the first letters: passed over.
expect Codes.from_bytes([255, 250, 0, 1, 2, 3]) == "BCDF"
expect Codes.from_bytes([7, 8, 9, 10, 11]).to_utf8().len() == Codes.length
expect Codes.parse(Codes.from_bytes([5, 50, 100, 200])).is_ok()
