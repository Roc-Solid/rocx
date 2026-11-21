## Base64 (RFC 4648), standard and padded, one way: what email needs (a body that isn't plain
## ASCII, an encoded subject, SMTP's `AUTH PLAIN`). The platform's own, not exposed: an app's Base64,
## both alphabets and both ways, is packages/crypto's, and this goes with email when email becomes
## a package too (D-025).
Base64 := [].{

	## The standard alphabet (`+`, `/`), padded with `=` to a multiple of 4.
	encode : List(U8) -> Str
	encode = |bytes| {
		count = bytes.len()
		var $out = List.with_capacity((count + 2) // 3 * 4)
		var $at = 0
		while $at < count {
			group = byte(bytes, $at).shl_wrap(16).bitwise_or(byte(bytes, $at + 1).shl_wrap(8)).bitwise_or(byte(bytes, $at + 2))
			left = count - $at
			$out = $out.append(letter(group.shr_zf_wrap(18))).append(letter(group.shr_zf_wrap(12)))
			$out = $out.append(if (left > 1) letter(group.shr_zf_wrap(6)) else '=')
			$out = $out.append(if (left > 2) letter(group) else '=')
			$at = $at + 3
		}
		Str.from_utf8_lossy($out)
	}

	## `encode`, in lines of 76 characters, as MIME wants a body.
	lines : List(U8) -> Str
	lines = |bytes| {
		encoded_bytes = Base64.encode(bytes).to_utf8()
		var $out = []
		var $at = 0
		for each in encoded_bytes {
			if $at > 0 and $at % 76 == 0 {
				$out = $out.append('\r').append('\n')
			} else {
				{}
			}
			$out = $out.append(each)
			$at = $at + 1
		}
		Str.from_utf8_lossy($out)
	}
}

byte : List(U8), U64 -> U32
byte = |bytes, at|
	match bytes.get(at) {
		Ok(value) => value.to_u32()
		Err(_) => 0
	}

letter : U32 -> U8
letter = |sextet| "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8().get(sextet.bitwise_and(63).to_u64()) ?? '='

# RFC 4648, section 10.
expect Base64.encode("".to_utf8()) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foob".to_utf8()) == "Zm9vYg=="
expect Base64.encode("fooba".to_utf8()) == "Zm9vYmE="
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.encode([0, 117, 0, 112]) == "AHUAcA=="
expect Base64.encode([251, 255, 191]) == "+/+/"

# MIME lines: 57 bytes make one full line of 76; the 58th starts another.
expect Base64.lines(List.repeat(0, 57)) == Str.repeat("A", 76)
expect Base64.lines(List.repeat(0, 58)) == Str.concat(Str.repeat("A", 76), "\r\nAA==")
expect Base64.lines("foo".to_utf8()) == "Zm9v"
